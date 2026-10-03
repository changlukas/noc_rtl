// SPDX-License-Identifier: Apache-2.0
// Directed stress uses the existing file master and checkers.
    `define STRESS_ORDER dut.i_response_path.i_ordering
    bit cov_b_stall_inversion = 0, cov_r_stall_inversion = 0;
    bit wr_limit_seen = 0, rd_limit_seen = 0;
    bit wr_limit_reused = 0, rd_limit_reused = 0;
    bit b_storage_full_seen = 0, r_storage_full_seen = 0;
    bit b_storage_reused = 0, r_storage_reused = 0;
    bit [NUM_NSUS-1:0] aw_context_full_seen = '0, ar_context_full_seen = '0;
    bit [NUM_NSUS-1:0] aw_context_reused = '0, ar_context_reused = '0;
    bit hol_wr_progress = 0, hol_rd_progress = 0;
    bit b_output_stalled = 0, r_output_stalled = 0;
    bit read_order_wait_seen = 0, read_order_resumed = 0;
    bit reset_pending_seen = 0, reset_complete = 0;
    int stress_wr_dst[NUM_IDS] = '{default:0};
    int stress_rd_dst[NUM_IDS] = '{default:0};
    wire b_storage_full = &`STRESS_ORDER.i_b_storage.alloc_reg;
    wire r_storage_full;
    if (`STRESS_ORDER.R_ROB_EN) begin : gen_stress_read_storage
        assign r_storage_full = &`STRESS_ORDER.gen_read_reorder_storage.i_r_storage.alloc_reg;
    end else begin : gen_stress_no_read_storage
        assign r_storage_full = 1'b0;
    end

    always @(posedge noc_clk) begin
        if (!noc_rst_n) begin
            wr_limit_seen = 0; rd_limit_seen = 0;
            read_order_wait_seen = 0; read_order_resumed = 0;
            wr_limit_reused = 0; rd_limit_reused = 0;
            b_storage_full_seen = 0; r_storage_full_seen = 0;
            b_storage_reused = 0; r_storage_reused = 0;
            aw_context_full_seen = '0; ar_context_full_seen = '0;
            aw_context_reused = '0; ar_context_reused = '0;
            b_output_stalled = 0; r_output_stalled = 0;
        end else begin
            if (!R_ROB_EN && `STRESS_ORDER.s_ar_valid_i &&
                    `STRESS_ORDER.ar_reorder_required && !`STRESS_ORDER.s_ar_ready_o)
                read_order_wait_seen = 1;
            if (read_order_wait_seen && `STRESS_ORDER.ar_accept) read_order_resumed = 1;
            if (wr_order_full) wr_limit_seen = 1;
            if (rd_order_full) rd_limit_seen = 1;
            if (wr_limit_seen && `STRESS_ORDER.aw_accept) wr_limit_reused = 1;
            if (rd_limit_seen && `STRESS_ORDER.ar_accept) rd_limit_reused = 1;
            if (b_storage_full) b_storage_full_seen = 1;
            if (r_storage_full) r_storage_full_seen = 1;
            if (b_storage_full_seen && `STRESS_ORDER.aw_accept && `STRESS_ORDER.aw_reorder)
                b_storage_reused = 1;
            if (r_storage_full_seen && `STRESS_ORDER.ar_accept && `STRESS_ORDER.ar_reorder)
                r_storage_reused = 1;
            aw_context_full_seen |= aw_context_full;
            ar_context_full_seen |= ar_context_full;
            aw_context_reused |= aw_context_full_seen & aw_context_accept;
            ar_context_reused |= ar_context_full_seen & ar_context_accept;
            if (`STRESS_ORDER.m_b_valid_o && !`STRESS_ORDER.m_b_ready_i) b_output_stalled = 1;
            if (`STRESS_ORDER.m_r_valid_o && !`STRESS_ORDER.m_r_ready_i) r_output_stalled = 1;

        end
    end

    always @(posedge clk) begin
        if (!axi_rst_n) begin
            hol_wr_progress = 0;
            hol_rd_progress = 0;
        end else begin
            if (stress_test == 2) begin
                if (vip.aw_valid && vip.aw_ready) stress_wr_dst[vip.aw_id] = int'(decode_destination(vip.aw_addr));
                if (vip.ar_valid && vip.ar_ready) stress_rd_dst[vip.ar_id] = int'(decode_destination(vip.ar_addr));
                if (memory_b_blocked[0] && aw_context_full[0] && vip.b_valid && vip.b_ready &&
                        stress_wr_dst[vip.b_id] != 0)
                    hol_wr_progress = 1;
                if (memory_r_blocked[0] && ar_context_full[0] && vip.r_valid && vip.r_ready &&
                        stress_rd_dst[vip.r_id] != 0)
                    hol_rd_progress = 1;
            end
        end
    end

    function automatic int decode_destination(input mon_addr_t address);
        for (int rule = 0; rule < topology_pkg::SAM_NUM_RULES; rule++) begin
            if (address >= MON_RULES[rule].start_addr && address < MON_RULES[rule].end_addr)
                return MON_RULES[rule].idx;
        end
        $fatal(1, "Stress monitor address outside SAM");
        return -1;
    endfunction

    task automatic start_scoreboard();
        fork
            begin
                scoreboard.enable_all_checks();
                scoreboard.monitor();
                wait (!axi_rst_n);
                disable fork;
            end
        join_none
    endtask

    task automatic start_stress_phase(input bit is_read);
        // The prefix fills all but one response FIFO entry. North then holds
        // the head request while later destinations return out of order.
        if (response_backpressure && reorder_test == 2) begin
            if (is_read) block_r = 1;
            else block_b = 1;
            fork
                begin
                    repeat (hold_cycles/4) @(posedge clk);
                    #(APPL_DELAY);
                    if (is_read) block_r = 0;
                    else block_b = 0;
                end
            join_none
        end
        if (stress_test == 1 && capacity_target != "per_id") begin
            if (is_read) block_r = 1;
            else block_b = 1;
            fork
                begin
                    repeat (hold_cycles) @(posedge clk);
                    #(APPL_DELAY);
                    if (is_read) block_r = 0;
                    else block_b = 0;
                end
            join_none
        end
        if (stress_test == 2) begin
            if (is_read) block_r = 1;
            else block_b = 1;
            fork
                begin
                    if (is_read) wait (hol_rd_progress);
                    else wait (hol_wr_progress);
                    @(posedge clk);
                    #(APPL_DELAY);
                    if (is_read) block_r = 0;
                    else block_b = 0;
                end
            join_none
        end
    endtask

    task automatic run_reset_recovery(input string directory);
        master_t warmup;
        int seed, reset_delay, pending_writes, pending_reads;
        warmup = new(vip);
        warmup.read_fd = $fopen({directory, "/read.txt"}, "r");
        warmup.write_fd = $fopen({directory, "/write.txt"}, "r");
        warmup.parse_read();
        warmup.parse_write();
        $fclose(warmup.read_fd);
        $fclose(warmup.write_fd);
        seed = 1;
        void'($value$plusargs("seed=%d", seed));
        void'($urandom(seed));
        reset_delay = $urandom_range(2, 24);
        fork : reset_traffic
            begin
                fork warmup.run_aw(); warmup.run_w(); warmup.run_ar(); join
                wait (0);
            end
            begin
                wait (peak_w != 0 && peak_r != 0);
                repeat (reset_delay) @(negedge clk);
            end
        join_any
        disable reset_traffic;
        pending_writes = 0;
        pending_reads = 0;
        foreach (live_w[id]) begin
            pending_writes += live_w[id];
            pending_reads += live_r[id];
        end
        if (pending_writes == 0 || pending_reads == 0) $fatal(1, "Reset missed pending traffic");
        reset_pending_seen = 1;
        $display("RESET_PENDING time=%0t seed=%0d delay=%0d writes=%0d reads=%0d",
            $time, seed, reset_delay, pending_writes, pending_reads);
        rst_n = 0;
        warmup.reset();
        repeat (5) @(negedge clk);
    `ifndef TB_DIRECT_LINK
        // A fresh model instance flushes the router; the session is finalized only once.
        router_ctx = cmodel_router_create("router_after_reset", ROUTER_X, ROUTER_Y,
            MESH_DIM, MESH_DIM, NUM_DAT_VC);
    `endif
        foreach (live_w[id]) begin
            live_w[id] = 0;
            live_r[id] = 0;
            read_beat[id] = 0;
            expected_ar[id].delete();
        end
        b_count = 0; r_count = 0; r_beats = 0; checked_bytes = 0;
        peak_w = 0; peak_r = 0; peak_unique_w = 0; peak_unique_r = 0;
        expected_beats = 0;
        expect_reads(master);
        scoreboard = new(vip);
        scoreboard.preload({directory, "/preload.mem"});
        rst_n = 1;
        wait (axi_rst_n && noc_rst_n);
        start_scoreboard();
        // No requests during this interval: any old response is unsolicited.
        fork : stale_check
            begin
                master_t::b_beat_t b;
                master.drv.recv_b(b);
                $fatal(1, "Stale B response after reset");
            end
            begin
                master_t::r_beat_t r;
                master.drv.recv_r(r);
                $fatal(1, "Stale R response after reset");
            end
            begin
                repeat (2*IO_FIFO_DEPTH+2*CREDIT_DEPTH) @(negedge clk);
            end
        join_any
        disable stale_check;
        master.reset();
        @(posedge clk);
        reset_complete = 1;
    endtask

    task automatic check_stress();
        if (!R_ROB_EN && reorder_test == 2) begin
            $display("READ_ORDER_RECOVERY wait=%0d resumed=%0d", read_order_wait_seen, read_order_resumed);
            if (!read_order_wait_seen || !read_order_resumed)
                $fatal(1, "Read ordering admission wait/recovery not exercised");
        end
    `ifdef NI_COVERAGE
        if (response_backpressure)
            $display("REORDER_BACKPRESSURE write=%0d read=%0d", cov_b_stall_inversion, cov_r_stall_inversion);
        if (response_backpressure && reorder_test == 2 &&
                (!cov_b_stall_inversion || !cov_r_stall_inversion))
            $fatal(1, "Same-ID inversion/output-stall correlation not exercised");
    `endif
        if (response_backpressure && (!b_output_stalled || !r_output_stalled))
            $fatal(1, "Reorder test missed B/R storage output backpressure");
        if (stress_test == 1) begin
            $display("CAPACITY_REUSE target=%s per_id=%b%b context=%b/%b rob=%b%b",
                capacity_target, wr_limit_reused, rd_limit_reused,
                aw_context_reused, ar_context_reused, b_storage_reused, r_storage_reused);
            case (capacity_target)
                "per_id": if (!wr_limit_reused || !rd_limit_reused)
                    $fatal(1, "Per-ID limit/reuse not exercised");
                "context": if (!(&aw_context_reused) || !(&ar_context_reused))
                    $fatal(1, "NSU context full/reuse not exercised");
                "rob": if (!b_storage_reused || !r_storage_reused)
                    $fatal(1, "B/R ROB full/reuse not exercised");
                default: $fatal(1, "Unknown capacity target");
            endcase
        end
        if (stress_test == 2 && (!hol_wr_progress || !hol_rd_progress))
            $fatal(1, "Unblocked destination did not progress during blocking");
        if (stress_test == 3 && (!reset_complete || !reset_pending_seen || b_count == 0 || r_count == 0))
            $fatal(1, "Reset recovery not exercised");
        if (stress_test != 0 || response_backpressure)
            $display("STRESS_PASS type=%0d backpressure=%0d", stress_test, response_backpressure);
    endtask
    `undef STRESS_ORDER
