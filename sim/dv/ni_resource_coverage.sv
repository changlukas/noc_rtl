// SPDX-License-Identifier: Apache-2.0
`timescale 1ps / 1ps
`ifdef NI_COVERAGE
// Bind observers to existing cells; payloads and handshake behavior are untouched.
module ni_fifo_coverage (
    input wire clk_i,
    input wire rst_n_i,
    input wire full_i,
    input wire empty_i,
    input wire push_i,
    input wire pop_i
);
    longint unsigned full_cnt = 0, empty_cnt = 0, push_pop_cnt = 0, recovery_cnt = 0;
    bit full_seen = 0;
    always @(posedge clk_i) begin
        if (!rst_n_i) full_seen = 0;
        else begin
            if (empty_i) empty_cnt++;
            if (full_i) begin
                full_cnt++;
                full_seen = 1;
            end
            if (push_i && pop_i) push_pop_cnt++;
            if (full_seen && push_i && !full_i) begin
                recovery_cnt++;
                full_seen = 0;
            end
        end
    end
    final begin
        $display("NI_COVER scope=%m event=fifo.full count=%0d", full_cnt);
        $display("NI_COVER scope=%m event=fifo.empty count=%0d", empty_cnt);
        $display("NI_COVER scope=%m event=fifo.push_pop count=%0d", push_pop_cnt);
        $display("NI_COVER scope=%m event=fifo.full_recovery count=%0d", recovery_cnt);
    end
endmodule

module ni_credit_coverage (
    input wire clk_i,
    input wire rst_n_i,
    input wire credit_left_i,
    input wire give_i,
    input wire take_i
);
    longint unsigned zero_cnt = 0, refill_cnt = 0, give_take_cnt = 0, zero_give_take_cnt = 0;
    always @(posedge clk_i) begin
        if (rst_n_i) begin
            if (!credit_left_i) zero_cnt++;
            if (!credit_left_i && give_i) refill_cnt++;
            if (give_i && take_i) give_take_cnt++;
            if (!credit_left_i && give_i && take_i) zero_give_take_cnt++;
        end
    end
    final begin
        $display("NI_COVER scope=%m event=credit.zero count=%0d", zero_cnt);
        $display("NI_COVER scope=%m event=credit.refill_from_zero count=%0d", refill_cnt);
        $display("NI_COVER scope=%m event=credit.give_take count=%0d", give_take_cnt);
        $display("NI_COVER scope=%m event=credit.zero_give_take count=%0d", zero_give_take_cnt);
    end
endmodule

bind cc_fifo ni_fifo_coverage i_coverage (
    .clk_i   (clk_i),
    .rst_n_i (rst_ni),
    .full_i  (full_o),
    .empty_i (empty_o),
    .push_i  (push_i),
    .pop_i   (pop_i)
);
bind cc_credit_counter ni_credit_coverage i_coverage (
    .clk_i         (clk_i),
    .rst_n_i       (rst_ni),
    .credit_left_i (credit_left_o),
    .give_i        (credit_give_i),
    .take_i        (credit_take_i)
);
bind nsu_context_buffer ni_fifo_coverage i_aw_coverage (
    .clk_i   (clk_i),
    .rst_n_i (rst_n_i),
    .full_i  (i_aw_context.full_o),
    .empty_i (i_aw_context.empty_o),
    .push_i  (s_aw_valid_i && s_aw_ready_o),
    .pop_i   (s_b_valid_i && s_b_ready_o)
);
bind nsu_context_buffer ni_fifo_coverage i_ar_coverage (
    .clk_i   (clk_i),
    .rst_n_i (rst_n_i),
    .full_i  (i_ar_context.full_o),
    .empty_i (i_ar_context.empty_o),
    .push_i  (s_ar_valid_i && s_ar_ready_o),
    .pop_i   (s_r_valid_i && s_r_ready_o && s_r_i.rlast)
);
`endif
