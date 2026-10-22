// SPDX-License-Identifier: Apache-2.0
// Stress observations and reset checks share the integration interfaces.
    `define STRESS_ORDER `NI_NMU.i_response_path.i_ordering
    bit [1:0] cov_same_id_seen = 0, cov_cross_id_seen = 0;
    bit cov_b_stall_inversion = 0, cov_r_stall_inversion = 0;
    bit wr_limit_seen = 0, rd_limit_seen = 0;
    bit wr_limit_reused = 0, rd_limit_reused = 0;
    bit b_storage_full_seen = 0, r_storage_full_seen = 0;
    bit b_storage_reused = 0, r_storage_reused = 0;
    bit [NUM_NSUS-1:0] aw_context_full_seen = '0, ar_context_full_seen = '0;
    bit [NUM_NSUS-1:0] aw_context_reused = '0, ar_context_reused = '0;
    bit b_output_stalled = 0, r_output_stalled = 0;
    bit read_order_wait_seen = 0, read_order_resumed = 0;

    bit [NUM_NSUS-1:0] context_target_mask = '1;
    initial void'($value$plusargs("context_target_mask=%h", context_target_mask));

    wire b_storage_full = &`STRESS_ORDER.i_b_storage.alloc_reg;
    wire r_storage_full;
    if (R_ROB_EN) begin : gen_stress_read_storage
        assign r_storage_full = &`STRESS_ORDER.gen_read_reorder_storage.i_r_storage.alloc_reg;
    end else begin : gen_stress_no_read_storage
        assign r_storage_full = 1'b0;
    end

    always @(posedge noc_clk) begin
        if (!noc_rst_n) begin
            wr_limit_seen = 0; rd_limit_seen = 0;
            cov_same_id_seen = 0; cov_cross_id_seen = 0;
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

    task automatic start_response_hold(input bit is_read);
        if (response_hold_cycles != 0) begin
            if (is_read) block_r = 1;
            else block_b = 1;
            fork
                begin
                    repeat (response_hold_cycles) @(posedge clk);
                    #(APPL_DELAY);
                    if (is_read) block_r = 0;
                    else block_b = 0;
                end
            join_none
        end
    endtask

    function automatic void check_test_conditions();
        if (!R_ROB_EN && check_order == "same_id") begin
            $display("READ_ORDER_RECOVERY wait=%0d resumed=%0d", read_order_wait_seen, read_order_resumed);
            if (!read_order_wait_seen || !read_order_resumed)
                $fatal(1, "Read ordering admission wait/recovery not exercised");
        end
    `ifdef NI_COVERAGE
        if (response_random_delay && check_order != "") begin
            $display("RESPONSE_INVERSION same_id=%b cross_id=%b", cov_same_id_seen, cov_cross_id_seen);
            if (check_order == "cross_id" && !(&cov_cross_id_seen))
                $fatal(1, "Read/write cross-ID response inversion not exercised");
            if (check_order == "same_id" && (!cov_same_id_seen[0] || (R_ROB_EN && !cov_same_id_seen[1])))
                $fatal(1, "Read/write same-ID response inversion not exercised");
        end
        if (check_response_stall)
            $display("REORDER_BACKPRESSURE write=%0d read=%0d", cov_b_stall_inversion, cov_r_stall_inversion);
        if (check_response_stall && check_order == "same_id" &&
                (!cov_b_stall_inversion || (R_ROB_EN && !cov_r_stall_inversion)))
            $fatal(1, "Same-ID inversion/output-stall correlation not exercised");
    `endif
        if (check_response_stall && (!b_output_stalled || !r_output_stalled))
            $fatal(1, "Reorder test missed B/R response output stall");
        if (check_capacity != "") begin
            $display("CAPACITY_REUSE target=%s per_id=%b%b context=%b/%b rob=%b%b",
                check_capacity, wr_limit_reused, rd_limit_reused,
                aw_context_reused, ar_context_reused, b_storage_reused, r_storage_reused);
            case (check_capacity)
                "per_id": if (!wr_limit_reused || !rd_limit_reused)
                    $fatal(1, "Per-ID limit/reuse not exercised");
                "context": if ((aw_context_reused & context_target_mask) != context_target_mask ||
                    (ar_context_reused & context_target_mask) != context_target_mask)
                    $fatal(1, "NSU AW/AR context full/reuse not exercised");
                "rob": if (!b_storage_reused || (R_ROB_EN ? !r_storage_reused : !read_order_resumed))
                    $fatal(1, "B/R reorder capacity/recovery not exercised");
                default: $fatal(1, "Unknown capacity target");
            endcase
        end
        if (reset_recovery && (!control.reset_complete || !control.reset_pending_seen))
            $fatal(1, "Reset recovery not exercised");
        if (check_capacity != "" || reset_recovery || check_response_stall)
            $display("TEST_CONDITIONS_PASS");
    endfunction
    `undef STRESS_ORDER
