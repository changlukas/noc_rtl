// SPDX-License-Identifier: Apache-2.0
`timescale 1ps / 1ps
`ifdef NI_COVERAGE
// Observe accepted push/pop events; payloads and handshakes are untouched.
module ni_fifo_coverage (
    input wire clk_i,
    input wire rst_n_i,
    input wire full_i,
    input wire empty_i,
    input wire push_i,
    input wire pop_i
);
    bit full_seen = 0;
    covergroup fifo_cg with function sample(bit full, bit empty, bit push_pop, bit recovery);
        option.per_instance = 1;
        cp_full: coverpoint full { bins observed = {1}; }
        cp_empty: coverpoint empty { bins observed = {1}; }
        cp_push_pop: coverpoint push_pop { bins observed = {1}; }
        cp_recovery: coverpoint recovery { bins observed = {1}; }
    endgroup
    fifo_cg fifo_coverage = new();

    always @(posedge clk_i) begin
        if (!rst_n_i) full_seen = 0;
        else begin
            fifo_coverage.sample(full_i, empty_i, push_i && pop_i,
                full_seen && push_i);
            if (full_i) full_seen = 1;
            else if (push_i) full_seen = 0;
        end
    end

endmodule

bind cc_fifo ni_fifo_coverage i_coverage (
    .clk_i   (clk_i),
    .rst_n_i (rst_ni),
    .full_i  (full_o),
    .empty_i (empty_o),
    .push_i  (push_i && !full_o),
    .pop_i   (pop_i && !empty_o)
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
