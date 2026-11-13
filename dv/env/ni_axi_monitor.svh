// SPDX-License-Identifier: Apache-2.0
class ni_axi_sample extends uvm_sequence_item;
    ni_mon_req_t req;
    ni_mon_resp_t rsp;
    bit reset;
    time sampled_at;
    function new(string name = "ni_axi_sample"); super.new(name); endfunction
    `uvm_object_utils(ni_axi_sample)
endclass

class ni_axi_monitor #(type BASE = tvip_axi_master_write_monitor) extends BASE;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        fork
            super.run_phase(phase);
            forever begin
                ni_axi_sample sample;
                @(vif.monitor_cb);
                sample = new();
                sample.sampled_at = $time;
                sample.reset = !vif.monitor_cb.areset_n;
                sample.req = '0;
                sample.rsp = '0;
                sample.req.aw.id = vif.monitor_cb.awid;
                sample.req.aw.addr = vif.monitor_cb.awaddr;
                sample.req.aw.len = vif.monitor_cb.awlen;
                sample.req.aw.size = vif.monitor_cb.awsize;
                sample.req.aw.burst = vif.monitor_cb.awburst;
                sample.req.aw.lock = vif.monitor_cb.awlock;
                sample.req.aw.cache = vif.monitor_cb.awcache;
                sample.req.aw.prot = vif.monitor_cb.awprot;
                sample.req.aw.qos = vif.monitor_cb.awqos;
                sample.req.aw.region = vif.monitor_cb.awregion;
                sample.req.aw.user = vif.monitor_cb.awuser;
                sample.req.aw_valid = vif.monitor_cb.awvalid;
                sample.rsp.aw_ready = vif.monitor_cb.awready;
                sample.req.w.data = vif.monitor_cb.wdata;
                sample.req.w.strb = vif.monitor_cb.wstrb;
                sample.req.w.last = vif.monitor_cb.wlast;
                sample.req.w_valid = vif.monitor_cb.wvalid;
                sample.rsp.w_ready = vif.monitor_cb.wready;
                sample.req.ar.id = vif.monitor_cb.arid;
                sample.req.ar.addr = vif.monitor_cb.araddr;
                sample.req.ar.len = vif.monitor_cb.arlen;
                sample.req.ar.size = vif.monitor_cb.arsize;
                sample.req.ar.burst = vif.monitor_cb.arburst;
                sample.req.ar.lock = vif.monitor_cb.arlock;
                sample.req.ar.cache = vif.monitor_cb.arcache;
                sample.req.ar.prot = vif.monitor_cb.arprot;
                sample.req.ar.qos = vif.monitor_cb.arqos;
                sample.req.ar.region = vif.monitor_cb.arregion;
                sample.req.ar_valid = vif.monitor_cb.arvalid;
                sample.rsp.ar_ready = vif.monitor_cb.arready;
                sample.rsp.b.id = vif.monitor_cb.bid;
                sample.rsp.b.resp = vif.monitor_cb.bresp;
                sample.rsp.b_valid = vif.monitor_cb.bvalid;
                sample.req.b_ready = vif.monitor_cb.bready;
                sample.rsp.r.id = vif.monitor_cb.rid;
                sample.rsp.r.data = vif.monitor_cb.rdata;
                sample.rsp.r.resp = vif.monitor_cb.rresp;
                sample.rsp.r.last = vif.monitor_cb.rlast;
                sample.rsp.r_valid = vif.monitor_cb.rvalid;
                sample.req.r_ready = vif.monitor_cb.rready;
                transfer_port.write(sample);
            end
        join
    endtask
    `uvm_component_param_utils(ni_axi_monitor #(BASE))
endclass

// Accepted AXI events only. Observation shares the existing sampled monitor.
class ni_perf extends uvm_subscriber #(uvm_sequence_item);
    static int trace_file;
    static int source_phase[NI_NUM_SOURCES];
    int endpoint;
    string role;
    bit in_reset;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        string path;
        super.build_phase(phase);
        if (trace_file == 0) begin
            if (!$value$plusargs("perf_file=%s", path))
                `uvm_fatal("PERF", "Missing performance output path")
            trace_file = $fopen(path, "w");
            if (trace_file == 0) `uvm_fatal("PERF", {"Cannot open ", path})
            $fdisplay(trace_file, "time_ps,role,endpoint,x,y,port,phase,channel,id,addr,len,size,burst,strb,last,resp,user");
        end
    endfunction

    function void emit(string channel, time sampled_at, ni_mon_id_t id = '0,
            ni_mon_addr_t addr = '0, int len = 0, int size = 0, int burst = 0,
            ni_mon_strb_t strb = '0, logic last = 0, int resp = 0,
            ni_mon_user_t user = '0);
        int x = -1, y = -1, port = -1;
        int stage = role == "source" ? source_phase[endpoint] : -1;
        if (!NI_DIRECT_LINK) begin
            x = int'(topology_pkg::ENDPOINT_ID[endpoint].x);
            y = int'(topology_pkg::ENDPOINT_ID[endpoint].y);
            port = int'(topology_pkg::ENDPOINT_ID[endpoint].port_id);
        end
        $fdisplay(trace_file, "%0d,%s,%0d,%0d,%0d,%0d,%0d,%s,%0d,%h,%0d,%0d,%0d,%h,%0d,%0d,%h",
            sampled_at, role, endpoint, x, y, port, stage, channel, id,
            addr, len, size, burst, strb, last, resp, user);
    endfunction

    function void write(uvm_sequence_item item);
        ni_axi_sample s;
        if (!$cast(s, item)) return;
        if (s.reset) begin
            if (!in_reset) emit("RESET", s.sampled_at);
            in_reset = 1;
            return;
        end
        if (in_reset) emit("ENABLE", s.sampled_at);
        in_reset = 0;
        if (s.req.aw_valid && s.rsp.aw_ready)
            emit("AW", s.sampled_at, s.req.aw.id, s.req.aw.addr, s.req.aw.len,
                s.req.aw.size, s.req.aw.burst, '0, 0, 0, s.req.aw.user);
        if (s.req.w_valid && s.rsp.w_ready)
            emit("W", s.sampled_at, '0, '0, 0, 0, 0, s.req.w.strb, s.req.w.last);
        if (s.req.ar_valid && s.rsp.ar_ready)
            emit("AR", s.sampled_at, s.req.ar.id, s.req.ar.addr, s.req.ar.len,
                s.req.ar.size, s.req.ar.burst);
        if (s.rsp.b_valid && s.req.b_ready)
            emit("B", s.sampled_at, s.rsp.b.id, '0, 0, 0, 0, '0, 0, s.rsp.b.resp);
        if (s.rsp.r_valid && s.req.r_ready)
            emit("R", s.sampled_at, s.rsp.r.id, '0, 0, 0, 0, '0, s.rsp.r.last, s.rsp.r.resp);
    endfunction

    function void final_phase(uvm_phase phase);
        super.final_phase(phase);
        if (trace_file != 0) begin
            $fclose(trace_file);
            trace_file = 0;
        end
    endfunction
    `uvm_component_utils(ni_perf)
endclass
