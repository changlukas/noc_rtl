// SPDX-License-Identifier: Apache-2.0
class ni_order_checker extends axi_reorder_compare_core #(NI_NUM_NSUS, NI_MON_ID_WIDTH,
        topology_pkg::SAM_NUM_RULES, ni_mon_addr_t, ni_mon_rule_t, NI_MON_RULES, 0,
        ni_mon_aw_chan_t, ni_mon_w_chan_t, ni_mon_b_chan_t, ni_mon_ar_chan_t,
        ni_mon_r_chan_t, ni_mon_req_t, ni_mon_resp_t);
    virtual function void report_error(string message);
        `uvm_error("AXI_ORDER", message)
    endfunction
    virtual function void report_fatal(string message);
        `uvm_fatal("AXI_ORDER", message)
    endfunction
endclass

class ni_scoreboard extends uvm_scoreboard;
    uvm_tlm_analysis_fifo #(uvm_sequence_item) input_fifo[NI_NUM_NSUS+1];
    ni_order_checker ordering;
    ni_data_checker data_check;
    ni_mon_ar_chan_t pending_read[NI_NUM_IDS][$];
    int read_beat[NI_NUM_IDS];
    int pending_write[NI_NUM_IDS];
    int checked_bytes, b_count, r_count, r_beats;
    int response_error;
    bit active;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        foreach (input_fifo[i]) input_fifo[i] = new($sformatf("input_fifo%0d", i), this);
        ordering = new();
        response_error = 0;
        void'($value$plusargs("response_error=%d", response_error));
        foreach (read_beat[i]) begin read_beat[i] = 0; pending_write[i] = 0; end
    endfunction
    task reset_checker();
        string directory;
        if (data_check != null) data_check.stop();
        ordering.reset();
        data_check = new();
        if ($test$plusargs("preload")) begin
            void'($value$plusargs("stim_dir=%s", directory));
            data_check.preload({directory, "/preload.mem"});
        end
        foreach (pending_read[i]) begin
            pending_read[i].delete(); read_beat[i] = 0; pending_write[i] = 0;
        end
        checked_bytes = 0; b_count = 0; r_count = 0; r_beats = 0;
        data_check.start();
    endtask
    task check_source(ni_axi_sample s);
        ni_mon_ar_chan_t ar;
        ni_mon_addr_t address;
        logic [7:0] expected;
        int lo, hi;
        if (s.req.aw_valid && s.rsp.aw_ready) pending_write[s.req.aw.id]++;
        if (s.req.ar_valid && s.rsp.ar_ready) pending_read[s.req.ar.id].push_back(s.req.ar);
        if (s.rsp.b_valid && s.req.b_ready) begin
            if ($isunknown(s.rsp.b.id) || s.rsp.b.id >= NI_NUM_IDS)
                `uvm_fatal("AXI_B_ID", "Invalid BID")
            if (!pending_write[s.rsp.b.id]) `uvm_fatal("AXI_B", "Unsolicited B response")
            if (s.rsp.b.resp !== axi_pkg::resp_t'(response_error))
                `uvm_error("AXI_BRESP", "Invalid BRESP")
            pending_write[s.rsp.b.id]--; b_count++;
        end
        if (s.rsp.r_valid && s.req.r_ready) begin
            if ($isunknown(s.rsp.r.id) || s.rsp.r.id >= NI_NUM_IDS)
                `uvm_fatal("AXI_R_ID", "Invalid RID")
            if (!pending_read[s.rsp.r.id].size()) `uvm_fatal("AXI_R", "Unsolicited R response")
            ar = pending_read[s.rsp.r.id][0];
            if (s.rsp.r.resp !== axi_pkg::resp_t'(response_error) ||
                    s.rsp.r.last !== (read_beat[s.rsp.r.id] == int'(ar.len)))
                `uvm_error("AXI_RRESP", "Invalid RRESP/RLAST")
            address = axi_pkg::beat_addr(ar.addr, ar.size, ar.len, ar.burst, read_beat[s.rsp.r.id]);
            lo = axi_pkg::beat_lower_byte(ar.addr, ar.size, ar.len, ar.burst, AXI_DATA_WIDTH/8, read_beat[s.rsp.r.id]);
            hi = axi_pkg::beat_upper_byte(ar.addr, ar.size, ar.len, ar.burst, AXI_DATA_WIDTH/8, read_beat[s.rsp.r.id]);
            address = axi_pkg::aligned_addr(address, $clog2(AXI_DATA_WIDTH/8));
            for (int lane = lo; lane <= hi; lane++) begin
                data_check.get_byte(address + lane, expected);
                if ($isunknown(expected) || $isunknown(s.rsp.r.data[8*lane+:8]))
                    `uvm_error("AXI_RDATA", "Read comparison contains uninitialized data")
                checked_bytes++;
            end
            r_beats++;
            if (s.rsp.r.last) begin
                void'(pending_read[s.rsp.r.id].pop_front());
                read_beat[s.rsp.r.id] = 0; r_count++;
            end else read_beat[s.rsp.r.id]++;
        end
    endtask
    task run_phase(uvm_phase phase);
        uvm_sequence_item item;
        ni_axi_sample samples[NI_NUM_NSUS+1];
        ni_mon_req_t source_req;
        forever begin
            foreach (input_fifo[i]) begin
                input_fifo[i].get(item);
                if (!$cast(samples[i], item)) `uvm_fatal("SAMPLE", "Unexpected monitor item")
                if (i > 0 && (samples[i].sampled_at != samples[0].sampled_at || samples[i].reset != samples[0].reset))
                    `uvm_fatal("SAMPLE", "AXI monitor clocks/resets are inconsistent")
            end
            if (samples[0].reset) begin
                if (active) begin
                    data_check.stop(); ordering.reset(); active = 0;
                end
                continue;
            end
            if (!active) begin reset_checker(); active = 1; end
            source_req = samples[0].req;
            source_req.aw.user = ni_mon_user_t'(source_req.aw.user[ni_flit_pkg::AXI_USER_WIDTH-1:0]);
            ordering.source_request(source_req, samples[0].rsp);
            for (int i = 0; i < NI_NUM_NSUS; i++)
                ordering.device_request(i, samples[i+1].req, samples[i+1].rsp);
            for (int i = 0; i < NI_NUM_NSUS; i++)
                ordering.device_response(i, samples[i+1].req, samples[i+1].rsp);
            ordering.source_response(source_req, samples[0].rsp);
            data_check.accept(samples[0]);
            check_source(samples[0]);
        end
    endtask
    function bit drained();
        if (!ordering.drained() || data_check == null) return 0;
        if (!data_check.drained()) return 0;
        foreach (pending_read[i])
            if (pending_read[i].size() || pending_write[i]) return 0;
        return 1;
    endfunction
    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (!drained()) `uvm_error("PENDING", "Scoreboard has pending transactions")
    endfunction
    `uvm_component_utils(ni_scoreboard)
endclass
