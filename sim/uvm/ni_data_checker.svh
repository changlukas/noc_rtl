// SPDX-License-Identifier: Apache-2.0
// Adapter to the existing AXI scoreboard memory/history algorithms.
class ni_data_checker extends axi_test::axi_scoreboard #(
    NI_INPUT_ID_WIDTH, AXI_ADDR_WIDTH, AXI_DATA_WIDTH, AXI_AWUSER_WIDTH, 0ps
);
    process workers[$];
    function new(); super.new(null); endfunction
    virtual function void report_read_error(string message);
        `uvm_error("AXI_DATA", message)
    endfunction
    task preload(string filename);
        logic [7:0] bytes[axi_addr_t];
        $readmemh(filename, bytes);
        foreach (bytes[address]) memory_q[address].push_back(bytes[address]);
    endtask
    task start();
        enable_all_checks();
        fork
            begin workers.push_back(process::self()); handle_write(); end
        join_none
        for (int i = 0; i < NI_NUM_IDS; i++) begin
            automatic int id = i;
            fork
                begin workers.push_back(process::self()); handle_write_resp(axi_id_t'(id)); end
                begin workers.push_back(process::self()); handle_read(axi_id_t'(id)); end
            join_none
        end
    endtask
    function void stop(); foreach (workers[i]) workers[i].kill(); workers.delete(); endfunction
    function bit drained();
        if (aw_sample.size() || w_sample.size()) return 0;
        foreach (b_sample[i])
            if (b_sample[i].size() || ar_sample[i].size() || r_sample[i].size() || b_queue[i].size()) return 0;
        return 1;
    endfunction
    function void accept(ni_axi_sample sample);
        if (sample.req.aw_valid && sample.rsp.aw_ready) begin
            ax_beat_t beat = new();
            beat.ax_id = sample.req.aw.id;
            beat.ax_addr = sample.req.aw.addr;
            beat.ax_len = sample.req.aw.len;
            beat.ax_size = sample.req.aw.size;
            beat.ax_burst = sample.req.aw.burst;
            beat.ax_lock = sample.req.aw.lock;
            beat.ax_cache = sample.req.aw.cache;
            beat.ax_prot = sample.req.aw.prot;
            beat.ax_qos = sample.req.aw.qos;
            beat.ax_region = sample.req.aw.region;
            beat.ax_atop = sample.req.aw.atop;
            beat.ax_user = sample.req.aw.user;
            aw_sample.push_back(beat);
        end
        if (sample.req.w_valid && sample.rsp.w_ready) begin
            w_beat_t beat = new();
            beat.w_data = sample.req.w.data;
            beat.w_strb = sample.req.w.strb;
            beat.w_last = sample.req.w.last;
            beat.w_user = sample.req.w.user;
            w_sample.push_back(beat);
        end
        if (sample.req.ar_valid && sample.rsp.ar_ready) begin
            ax_beat_t beat = new();
            beat.ax_id = sample.req.ar.id;
            beat.ax_addr = sample.req.ar.addr;
            beat.ax_len = sample.req.ar.len;
            beat.ax_size = sample.req.ar.size;
            beat.ax_burst = sample.req.ar.burst;
            beat.ax_lock = sample.req.ar.lock;
            beat.ax_cache = sample.req.ar.cache;
            beat.ax_prot = sample.req.ar.prot;
            beat.ax_qos = sample.req.ar.qos;
            beat.ax_region = sample.req.ar.region;
            beat.ax_user = sample.req.ar.user;
            ar_sample[sample.req.ar.id].push_back(beat);
        end
        if (sample.rsp.b_valid && sample.req.b_ready) begin
            b_beat_t beat = new();
            beat.b_id = sample.rsp.b.id;
            beat.b_resp = sample.rsp.b.resp;
            beat.b_user = sample.rsp.b.user;
            b_sample[sample.rsp.b.id].push_back(beat);
        end
        if (sample.rsp.r_valid && sample.req.r_ready) begin
            r_beat_t beat = new();
            beat.r_id = sample.rsp.r.id;
            beat.r_data = sample.rsp.r.data;
            beat.r_resp = sample.rsp.r.resp;
            beat.r_last = sample.rsp.r.last;
            beat.r_user = sample.rsp.r.user;
            r_sample[sample.rsp.r.id].push_back(beat);
        end
    endfunction
endclass
