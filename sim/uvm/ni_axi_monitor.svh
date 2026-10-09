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
