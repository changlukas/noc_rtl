// SPDX-License-Identifier: Apache-2.0

`resetall
`timescale 1ns / 1ps
`default_nettype none

// Legal edge-of-page bursts and deliberate AXI contract violations.
module tb_nmu_sam_boundary;

    import topology_pkg::*;

    logic clk = 1'b0;
    logic rst_n_i = 1'b0;
    logic s_aw_valid = 1'b0;
    logic s_aw_ready;
    ni_signals_pkg::noc_axi_aw_t s_aw = '0;
    logic m_aw_valid;
    logic m_aw_ready = 1'b1;
    ni_types_pkg::nmu_sam_aw_result_t m_aw;
    logic s_ar_valid = 1'b0;
    logic s_ar_ready;
    ni_signals_pkg::noc_axi_ar_t s_ar = '0;
    logic m_ar_valid;
    logic m_ar_ready = 1'b1;
    ni_types_pkg::nmu_sam_ar_result_t m_ar;

    nmu_sam #(
        .AW_SAM_REG_TYPE (0             ),
        .AR_SAM_REG_TYPE (0             ),
        .SAM_NUM_RULES   (SAM_NUM_RULES ),
        .addr_t          (sam_addr_t    ),
        .sam_mask_sel_t  (sam_mask_sel_t),
        .sam_result_t    (sam_result_t  ),
        .sam_rule_t      (sam_rule_t    ),
        .SAM             (SAM           )
    ) dut (
        .noc_clk_i    (clk       ),
        .noc_rst_n_i  (rst_n_i   ),
        .s_aw_valid_i (s_aw_valid),
        .s_aw_ready_o (s_aw_ready),
        .s_aw_i       (s_aw      ),
        .m_aw_valid_o (m_aw_valid),
        .m_aw_ready_i (m_aw_ready),
        .m_aw_o       (m_aw      ),
        .s_ar_valid_i (s_ar_valid),
        .s_ar_ready_o (s_ar_ready),
        .s_ar_i       (s_ar      ),
        .m_ar_valid_o (m_ar_valid),
        .m_ar_ready_i (m_ar_ready),
        .m_ar_o       (m_ar      )
    );

    always #5ns clk = !clk;

    task automatic transfer(input logic [ni_params_pkg::AXI_ADDR_WIDTH-1:0] addr, input logic [7:0] len,
        input logic [2:0] size, input logic [1:0] burst);
        @(negedge clk);
        s_aw.awaddr  = addr;
        s_aw.awlen   = len;
        s_aw.awsize  = size;
        s_aw.awburst = burst;
        s_ar.araddr  = addr;
        s_ar.arlen   = len;
        s_ar.arsize  = size;
        s_ar.arburst = burst;
        s_aw_valid   = !$test$plusargs("ar_only");
        s_ar_valid   = 1'b1;
        @(posedge clk);
        #1ps;
        assert (s_aw_ready && s_ar_ready && m_aw_valid && m_ar_valid &&
                m_aw.axi == s_aw && m_ar.axi == s_ar)
            else $fatal(1, "SAM boundary transfer changed or stalled");
        @(negedge clk);
        s_aw_valid = 1'b0;
        s_ar_valid = 1'b0;
    endtask

    initial begin
        int invalid_case;
        invalid_case = 0;
        if ($value$plusargs("invalid_case=%d", invalid_case)) begin end
        repeat (2) @(negedge clk);
        rst_n_i = 1'b1;
        case (invalid_case)
            1: transfer(48'hff8, 8'd1, 3'd3, 2'd1); // INCR crosses 4 KB
            2: transfer(48'hff9, 8'd1, 3'd3, 2'd1); // unaligned INCR crosses 4 KB
            3: transfer(48'h100, 8'd2, 3'd3, 2'd2); // invalid WRAP length
            4: transfer(48'h101, 8'd1, 3'd3, 2'd2); // unaligned WRAP
            5: transfer(48'h100, 8'd16, 3'd3, 2'd0); // FIXED exceeds 16 beats
            6: transfer(48'h100, 8'd0, 3'd3, 2'd3); // reserved burst type
            default: begin
                transfer(48'hff8, 8'd1, 3'd3, 2'd0);
                transfer(48'hff9, 8'd15, 3'd3, 2'd0);
                transfer(48'hff9, 8'd0, 3'd3, 2'd1);
                transfer(48'hfe9, 8'd2, 3'd3, 2'd1);
                transfer(48'hff8, 8'd1, 3'd3, 2'd2);
                transfer(48'hff8, 8'd15, 3'd3, 2'd2);
                transfer(48'h100, 8'd16, 3'd3, 2'd1);
                transfer(48'h1000, 8'd63, 3'd6, 2'd1);
            end
        endcase
        if (invalid_case != 0) $fatal(1, "Invalid burst was not detected");
        $display("PASS: SAM boundary AW/AR, FIXED/INCR/WRAP and non-power-of-two lengths");
        $finish;
    end
endmodule
`resetall
