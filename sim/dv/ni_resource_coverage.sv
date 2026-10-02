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
                full_seen && push_i && !full_i);
            if (full_i) full_seen = 1;
            else if (push_i) full_seen = 0;
        end
    end

endmodule

module ni_credit_coverage (
    input wire clk_i,
    input wire rst_n_i,
    input wire credit_left_i,
    input wire give_i,
    input wire take_i
);
    covergroup credit_cg with function sample(bit available, bit give, bit take);
        option.per_instance = 1;
        cp_available: coverpoint available { bins zero = {0}; bins nonzero = {1}; }
        cp_give: coverpoint give { bins idle = {0}; bins returned = {1}; }
        cp_take: coverpoint take { bins idle = {0}; bins sent = {1}; }
        credit_return_send: cross cp_available, cp_give, cp_take {
            // Taking with neither stored nor returned credit is prohibited by the cell assertion.
            ignore_bins no_credit_send = binsof(cp_available.zero) &&
                binsof(cp_give.idle) && binsof(cp_take.sent);
        }
    endgroup
    credit_cg credit_coverage = new();
    always @(posedge clk_i) begin
        if (rst_n_i) credit_coverage.sample(credit_left_i, give_i, take_i);
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
