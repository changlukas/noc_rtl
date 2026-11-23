`resetall
`timescale 1ns / 1ps
`default_nettype none

module tb_ni_sam;

    import topology_pkg::*;

    sam_addr_t   addr;
    logic        lookup_en;
    sam_result_t sam_idx;
    logic        lookup_valid;
    logic        lookup_error;

    ni_sam #(
        .SAM_NUM_RULES  (SAM_NUM_RULES ),
        .addr_t         (sam_addr_t    ),
        .sam_mask_sel_t (sam_mask_sel_t),
        .sam_result_t   (sam_result_t  ),
        .sam_rule_t     (sam_rule_t    ),
        .SAM            (SAM           )
    ) i_ni_sam (
        .addr_i         (addr        ),
        .lookup_en_i    (lookup_en   ),
        .sam_idx_o      (sam_idx     ),
        .lookup_valid_o (lookup_valid),
        .lookup_error_o (lookup_error)
    );

    // Evaluate rules in descending priority, including at adjacent window boundaries.
    task automatic check_lookup(input sam_addr_t probe);
        integer winner;
        winner = -1;
        for (int r = SAM_NUM_RULES-1; r >= 0; r--) begin
            if (probe >= SAM[r].start_addr && (SAM[r].end_addr == '0 || probe < SAM[r].end_addr)) begin
                winner = r;
                break;
            end
        end
        addr = probe;
        #1ps;
        if (winner >= 0) begin
            assert (lookup_valid && !lookup_error && sam_idx == SAM[winner].idx)
                else $fatal(1, "Incorrect SAM hit at %h, expected rule %0d", probe, winner);
        end else begin
            assert (!lookup_valid && lookup_error && sam_idx == '0)
                else $fatal(1, "Incorrect SAM miss at %h", probe);
        end
    endtask

    initial begin
        addr = '0;
        lookup_en = 1'b0;
        #1ps;
        assert (sam_idx == '0 && !lookup_valid && !lookup_error)
            else $fatal(1, "Disabled lookup exposed a decoder result");

        lookup_en = 1'b1;
        for (int r = 0; r < SAM_NUM_RULES; r++) begin
            check_lookup(SAM[r].start_addr);
            check_lookup(SAM[r].end_addr - 1'b1);
            check_lookup(SAM[r].end_addr);
        end
        check_lookup(48'h0004_0000_0100);
        $display("SAM probe %h: valid=%b dst=(%0d,%0d)", addr, lookup_valid,
                 sam_idx.dst_id.x, sam_idx.dst_id.y);
        $display("PASS: ni_sam checked %0d rules", SAM_NUM_RULES);
        $finish;
    end
endmodule

`resetall
