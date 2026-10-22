// SPDX-License-Identifier: Apache-2.0
class ni_order_checker extends axi_reorder_compare_core #(NI_NUM_NSUS, NI_CHECK_ID_WIDTH,
        topology_pkg::SAM_NUM_RULES, ni_mon_addr_t, ni_mon_rule_t, NI_MON_RULES, 0,
        ni_mon_aw_chan_t, ni_mon_w_chan_t, ni_mon_b_chan_t, ni_mon_ar_chan_t,
        ni_mon_r_chan_t, ni_mon_req_t, ni_mon_resp_t, ni_mon_id_t, NI_CHECK_IDS, NI_NUM_SOURCES);
    virtual function logic [NI_NUM_NSUS-1:0] write_destinations(ni_mon_aw_chan_t aw);
        logic [NI_NUM_NSUS-1:0] destinations = '0;
        ni_mon_addr_t mask = ni_mon_addr_t'(aw.user >> 10);
        int region = addr_region(aw.addr);
        if (aw.user[9:8] != 2'b01) return super.write_destinations(aw);
        for (int r = 0; r < topology_pkg::SAM_NUM_RULES; r++) begin
            if ((NI_MON_RULES[r].start_addr & ~mask) == (NI_MON_RULES[region].start_addr & ~mask))
                destinations[NI_MON_RULES[r].idx] = 1'b1;
        end
        return destinations;
    endfunction
    virtual function ni_mon_aw_chan_t device_aw(ni_mon_aw_chan_t aw, int slave);
        int region = addr_region(aw.addr);
        ni_mon_addr_t mask = ni_mon_addr_t'(aw.user >> 10);
        ni_mon_aw_chan_t result = aw;
        if (aw.user[9:8] == 2'b01) begin
            for (int r = 0; r < topology_pkg::SAM_NUM_RULES; r++) begin
                if (NI_MON_RULES[r].idx == slave &&
                    (NI_MON_RULES[r].start_addr & ~mask) == (NI_MON_RULES[region].start_addr & ~mask))
                    result.addr = NI_MON_RULES[r].start_addr + aw.addr - NI_MON_RULES[region].start_addr;
            end
        end
        result.user = ni_mon_user_t'(aw.user[ni_flit_pkg::AXI_USER_WIDTH-1:0]);
        return result;
    endfunction
    virtual function void report_error(string message);
        `uvm_error("AXI_ORDER", message)
    endfunction
    virtual function void report_fatal(string message);
        `uvm_fatal("AXI_ORDER", message)
    endfunction
endclass

class ni_scoreboard extends uvm_scoreboard;
    uvm_tlm_analysis_fifo #(uvm_sequence_item) input_fifo[NI_NUM_NSUS+NI_NUM_SOURCES];
    ni_order_checker ordering;
    ni_data_checker data_check[NI_NUM_SOURCES];
    ni_mon_ar_chan_t pending_read[NI_CHECK_IDS][$];
    int read_beat[NI_CHECK_IDS];
    int pending_write[NI_CHECK_IDS];
    int checked_bytes = 0, b_count = 0, r_count = 0, r_beats = 0;
    int response_error = 0;
    bit active, concurrent_active;
    int expected_writes = 0, expected_reads = 0, expected_beats = 0;
    int peak_w = 0, peak_r = 0, peak_unique_w = 0, peak_unique_r = 0;
    int b_stall_cnt = 0, r_stall_cnt = 0, aw_stall_cnt = 0, ar_stall_cnt = 0;
    int overlap_cnt = 0, w_during_read_cnt = 0, r_during_write_cnt = 0;
    function int outstanding(bit is_read);
        int count = 0;
        foreach (pending_read[id]) count += is_read ? pending_read[id].size() : pending_write[id];
        return count;
    endfunction

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
        foreach (data_check[i]) if (data_check[i] != null) data_check[i].stop();
        ordering.reset();
        foreach (data_check[i]) data_check[i] = new();
        if ($test$plusargs("preload")) begin
            void'($value$plusargs("stim_dir=%s", directory));
            foreach (data_check[i]) data_check[i].preload({directory, "/preload.mem"});
        end
        foreach (pending_read[i]) begin
            pending_read[i].delete(); read_beat[i] = 0; pending_write[i] = 0;
        end
        checked_bytes = 0; b_count = 0; r_count = 0; r_beats = 0;
        peak_w = 0; peak_r = 0; peak_unique_w = 0; peak_unique_r = 0;
        foreach (data_check[i]) data_check[i].start();
    endtask
    task check_source(ni_axi_sample s, int source);
        ni_mon_ar_chan_t ar;
        ni_mon_addr_t address;
        logic [7:0] expected;
        int lo, hi, total_w, total_r, unique_w = 0, unique_r = 0;
        if (s.req.aw_valid && s.rsp.aw_ready) pending_write[s.req.aw.id]++;
        if (s.req.ar_valid && s.rsp.ar_ready) pending_read[s.req.ar.id].push_back(s.req.ar);
        if (s.rsp.b_valid) begin
            if ($isunknown(s.rsp.b.id) || s.rsp.b.id >= NI_CHECK_IDS)
                `uvm_fatal("AXI_B_ID", "Invalid BID")
            if (!pending_write[s.rsp.b.id]) `uvm_fatal("AXI_B", "Unsolicited B response")
        end
        if (s.rsp.b_valid && s.req.b_ready) begin
            if (s.rsp.b.resp !== axi_pkg::resp_t'(response_error))
                `uvm_error("AXI_BRESP", "Invalid BRESP")
            pending_write[s.rsp.b.id]--; b_count++;
        end
        if (s.rsp.r_valid) begin
            if ($isunknown(s.rsp.r.id) || s.rsp.r.id >= NI_CHECK_IDS)
                `uvm_fatal("AXI_R_ID", "Invalid RID")
            if (!pending_read[s.rsp.r.id].size()) `uvm_fatal("AXI_R", "Unsolicited R response")
        end
        if (s.rsp.r_valid && s.req.r_ready) begin
            ar = pending_read[s.rsp.r.id][0];
            if (s.rsp.r.resp !== axi_pkg::resp_t'(response_error) ||
                    s.rsp.r.last !== (read_beat[s.rsp.r.id] == int'(ar.len)))
                `uvm_error("AXI_RRESP", "Invalid RRESP/RLAST")
            address = axi_pkg::beat_addr(ar.addr, ar.size, ar.len, ar.burst, read_beat[s.rsp.r.id]);
            lo = axi_pkg::beat_lower_byte(ar.addr, ar.size, ar.len, ar.burst, AXI_DATA_WIDTH/8, read_beat[s.rsp.r.id]);
            hi = axi_pkg::beat_upper_byte(ar.addr, ar.size, ar.len, ar.burst, AXI_DATA_WIDTH/8, read_beat[s.rsp.r.id]);
            address = axi_pkg::aligned_addr(address, $clog2(AXI_DATA_WIDTH/8));
            for (int lane = lo; lane <= hi; lane++) begin
                data_check[source].get_byte(address + lane, expected);
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
        total_w = outstanding(0); total_r = outstanding(1);
        foreach (pending_read[id]) begin
            if (pending_write[id]) unique_w++;
            if (pending_read[id].size()) unique_r++;
        end
        if (total_w > peak_w) peak_w = total_w;
        if (total_r > peak_r) peak_r = total_r;
        if (unique_w > peak_unique_w) peak_unique_w = unique_w;
        if (unique_r > peak_unique_r) peak_unique_r = unique_r;
        if (s.rsp.b_valid && !s.req.b_ready) b_stall_cnt++;
        if (s.rsp.r_valid && !s.req.r_ready) r_stall_cnt++;
        if (s.req.aw_valid && !s.rsp.aw_ready) aw_stall_cnt++;
        if (s.req.ar_valid && !s.rsp.ar_ready) ar_stall_cnt++;
        if (concurrent_active) begin
            if (total_w && total_r) overlap_cnt++;
            if (total_r && s.req.w_valid && s.rsp.w_ready) w_during_read_cnt++;
            if (total_w && s.rsp.r_valid && s.req.r_ready) r_during_write_cnt++;
        end
    endtask
    function ni_axi_sample indexed_sample(ni_axi_sample sample, int source);
        ni_axi_sample result = new();
        result.req = sample.req;
        result.rsp = sample.rsp;
        result.req.aw.id = ni_mon_id_t'(source * (1 << NI_MON_ID_WIDTH)) | sample.req.aw.id;
        result.req.ar.id = ni_mon_id_t'(source * (1 << NI_MON_ID_WIDTH)) | sample.req.ar.id;
        result.rsp.b.id = ni_mon_id_t'(source * (1 << NI_MON_ID_WIDTH)) | sample.rsp.b.id;
        result.rsp.r.id = ni_mon_id_t'(source * (1 << NI_MON_ID_WIDTH)) | sample.rsp.r.id;
        return result;
    endfunction
    task run_phase(uvm_phase phase);
        uvm_sequence_item item;
        ni_axi_sample samples[NI_NUM_NSUS+NI_NUM_SOURCES];
        ni_axi_sample indexed;
        forever begin
            foreach (input_fifo[i]) begin
                input_fifo[i].get(item);
                if (!$cast(samples[i], item)) `uvm_fatal("SAMPLE", "Unexpected monitor item")
                if (i > 0 && (samples[i].sampled_at != samples[0].sampled_at || samples[i].reset != samples[0].reset))
                    `uvm_fatal("SAMPLE", "AXI monitor clocks/resets are inconsistent")
            end
            if (samples[0].reset) begin
                if (active) begin
                    foreach (data_check[i]) data_check[i].stop();
                    ordering.reset(); active = 0;
                end
                continue;
            end
            if (!active) begin reset_checker(); active = 1; end
            for (int source = 0; source < NI_NUM_SOURCES; source++) begin
                indexed = indexed_sample(samples[source], source);
                ordering.source_request(indexed.req, indexed.rsp, source);
            end
            for (int i = 0; i < NI_NUM_NSUS; i++)
                ordering.device_request(i, samples[i+NI_NUM_SOURCES].req, samples[i+NI_NUM_SOURCES].rsp);
            for (int i = 0; i < NI_NUM_NSUS; i++)
                ordering.device_response(i, samples[i+NI_NUM_SOURCES].req, samples[i+NI_NUM_SOURCES].rsp);
            for (int source = 0; source < NI_NUM_SOURCES; source++) begin
                indexed = indexed_sample(samples[source], source);
                ordering.source_response(indexed.req, indexed.rsp);
                data_check[source].accept(samples[source]);
                check_source(indexed, source);
            end
        end
    endtask
    function bit drained();
        if (!ordering.drained()) return 0;
        foreach (data_check[i]) if (data_check[i] == null || !data_check[i].drained()) return 0;
        foreach (pending_read[i])
            if (pending_read[i].size() || pending_write[i]) return 0;
        return 1;
    endfunction
    function void check_phase(uvm_phase phase);
        int min_outstanding = 1, min_unique = 1, source_hold = 0;
        super.check_phase(phase);
        void'($value$plusargs("check_min_outstanding=%d", min_outstanding));
        void'($value$plusargs("check_min_unique=%d", min_unique));
        void'($value$plusargs("source_response_hold_cycles=%d", source_hold));
        if (!drained()) `uvm_error("PENDING", "Scoreboard has pending transactions")
        if (b_count != expected_writes || r_count != expected_reads || r_beats != expected_beats ||
                (expected_reads != 0 && checked_bytes == 0))
            `uvm_error("COUNT", $sformatf("B=%0d/%0d R=%0d/%0d beats=%0d/%0d", b_count, expected_writes,
                r_count, expected_reads, r_beats, expected_beats))
        if ((expected_writes && (peak_w < min_outstanding || peak_unique_w < min_unique)) ||
                (expected_reads && (peak_r < min_outstanding || peak_unique_r < min_unique)))
            `uvm_error("OUTSTANDING", "Outstanding/ID coverage not reached")
        if (($test$plusargs("source_response_delay") || source_hold != 0) && (!b_stall_cnt || !r_stall_cnt))
            `uvm_error("STALL", "Response backpressure was not exercised")
        if ($test$plusargs("check_fifo_capacity") && (!aw_stall_cnt || !ar_stall_cnt))
            `uvm_error("CAPACITY", "Required admission stall was not reached")
        if ($test$plusargs("concurrent_rw") && (!overlap_cnt || !w_during_read_cnt || !r_during_write_cnt))
            `uvm_error("CONCURRENT", "Read/write concurrency was not exercised")
    endfunction
    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        $display("COVERAGE peak_w=%0d peak_r=%0d unique_w=%0d unique_r=%0d", peak_w, peak_r, peak_unique_w, peak_unique_r);
        $display("STALL b=%0d r=%0d aw=%0d ar=%0d", b_stall_cnt, r_stall_cnt, aw_stall_cnt, ar_stall_cnt);
        $display("CONCURRENT live=%0d w_during_read=%0d r_during_write=%0d", overlap_cnt, w_during_read_cnt, r_during_write_cnt);
        if (drained()) $display("AXI_ORDERING_CHECK_DRAINED");
        $display("RESPONSE_CHECK expected=%0d writes=%0d read_beats=%0d", response_error, b_count, r_beats);
        $display("NMU_COSIM_COUNTS writes=%0d reads=%0d r_beats=%0d checked_bytes=%0d", b_count, r_count, r_beats, checked_bytes);
    endfunction
    `uvm_component_utils(ni_scoreboard)
endclass
