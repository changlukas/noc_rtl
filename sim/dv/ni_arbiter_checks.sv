// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none
`ifdef NI_COVERAGE
module ni_arbiter_checks #(
    parameter int NUM_INPUTS = 2,
    parameter bit LOCK_IN = 0
) (
    input  wire                  clk_i,
    input  wire                  rst_n_i,
    input  wire                  flush_i,
    input  wire                  enable_i,
    input  wire [NUM_INPUTS-1:0] request_i,
    input  wire [NUM_INPUTS-1:0] grant_i,
    input  wire                  valid_i,
    input  wire                  ready_i
);
    reg locked_reg = 1'b0;
    reg [NUM_INPUTS-1:0] request_reg = '0;
    wire [NUM_INPUTS-1:0] eligible = LOCK_IN && locked_reg ? request_reg : request_i;

    // New requests do not join an arbitration decision already held by backpressure.
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            locked_reg <= 1'b0;
            request_reg <= '0;
        end else if (flush_i) begin
            locked_reg <= 1'b0;
            request_reg <= '0;
        end else if (enable_i) begin
            locked_reg <= valid_i && !ready_i;
            if (!locked_reg) request_reg <= request_i;
        end
    end

    no_bubble: assert property (@(posedge clk_i) disable iff (!rst_n_i || flush_i)
        enable_i && (|request_i) && ready_i |-> valid_i && (|(grant_i & request_i)))
        else $fatal(1, "Eligible request was not granted");
    continuous_transfer: cover property (@(posedge clk_i) disable iff (!rst_n_i || flush_i)
        (valid_i && ready_i)[*4]);
    for (genvar i = 0; i < NUM_INPUTS; i++) begin : gen_input
        int wait_count_reg = 0;
        always @(posedge clk_i or negedge rst_n_i) begin
            if (~rst_n_i) begin
                wait_count_reg <= 0;
            end else if (flush_i || !request_i[i] || grant_i[i]) begin
                wait_count_reg <= 0;
            end else if (enable_i && eligible[i] && valid_i && ready_i) begin
                wait_count_reg <= wait_count_reg + 1;
            end
        end
        bounded_wait: assert property (@(posedge clk_i) disable iff (!rst_n_i || flush_i)
            wait_count_reg < NUM_INPUTS)
            else $fatal(1, "RR requester exceeded grant bound");
        served: cover property (@(posedge clk_i) disable iff (!rst_n_i || flush_i)
            request_i[i] && grant_i[i]);
        if (NUM_INPUTS > 1) begin : gen_contention
            contended_grant: cover property (@(posedge clk_i) disable iff (!rst_n_i || flush_i)
                $countones(eligible) > 1 && request_i[i] && grant_i[i]);
        end
    end
endmodule

bind rr_arb_tree ni_arbiter_checks #(.NUM_INPUTS(NumIn),
    .LOCK_IN(LockIn)) i_fairness (
    .clk_i(clk_i),
    .rst_n_i(rst_ni),
    .flush_i(flush_i),
    .enable_i(1'b1),
    .request_i(req_i),
    .grant_i(gnt_o),
    .valid_i(req_o),
    .ready_i(gnt_i)
);
bind tx_channel_assign ni_arbiter_checks #(.NUM_INPUTS(2)) i_req_fairness (
    .clk_i(clk_i),
    .rst_n_i(rst_n_i),
    .flush_i(1'b0),
    .enable_i(!req_write_lock_reg),
    .request_i({s_req_valid_i[ni_types_pkg::NMU_REQ_AR_IDX],
                s_req_valid_i[ni_types_pkg::NMU_REQ_AW_IDX]}),
    .grant_i({s_req_ready_o[ni_types_pkg::NMU_REQ_AR_IDX],
              s_req_ready_o[ni_types_pkg::NMU_REQ_AW_IDX]}),
    .valid_i(m_req_valid_o && !req_write_lock_reg),
    .ready_i(m_req_ready_i)
);
module ni_credit_forward_checks #(
    parameter int NUM_VC = 2,
    parameter logic [NUM_VC-1:0] VC_MASK = '1
) (
    input  wire              clk_i,
    input  wire              rst_n_i,
    input  wire [NUM_VC-1:0] empty_i,
    input  wire [NUM_VC-1:0] credit_i,
    input  wire [NUM_VC-1:0] returned_i,
    input  wire [NUM_VC-1:0] valid_i
);
    for (genvar i = 0; i < NUM_VC; i++) begin : gen_vc
        if (VC_MASK[i]) begin : gen_active
            eligible: assert property (@(posedge clk_i) disable iff (!rst_n_i)
                !empty_i[i] && (credit_i[i] || returned_i[i]) |-> valid_i[i])
                else $fatal(1, "Eligible TX FIFO head was withheld");
        end
    end
endmodule
bind tx_credit_buffer ni_credit_forward_checks #(
    .NUM_VC(NUM_DAT_VC),
    .VC_MASK(DAT_VC_MASK)
) i_forward_checks (
    .clk_i(clk_i),
    .rst_n_i(rst_n_i),
    .empty_i(dat_empty),
    .credit_i(credit_left),
    .returned_i(dat_credit_return_i),
    .valid_i(m_dat_valid_o)
);

module ni_fifo_wrap_coverage #(
    parameter int DEPTH = 2,
    parameter int PTR_W = 1
) (
    input  wire             clk_i,
    input  wire             rst_n_i,
    input  wire             clear_i,
    input  wire             push_i,
    input  wire             pop_i,
    input  wire [PTR_W-1:0] write_ptr_i,
    input  wire [PTR_W-1:0] read_ptr_i
);
    write_wrap: cover property (@(posedge clk_i) disable iff (!rst_n_i || clear_i)
        push_i && write_ptr_i == DEPTH-1 |=> write_ptr_i == 0);
    read_wrap: cover property (@(posedge clk_i) disable iff (!rst_n_i || clear_i)
        pop_i && read_ptr_i == DEPTH-1 |=> read_ptr_i == 0);
endmodule
bind cc_fifo ni_fifo_wrap_coverage #(.DEPTH(Depth),
    .PTR_W(PtrWidth)) i_wrap_coverage (
    .clk_i(clk_i),
    .rst_n_i(rst_ni),
    .clear_i(clr_i || flush_i),
    .push_i(push_i && !full_o),
    .pop_i(pop_i && !empty_o),
    .write_ptr_i(write_pointer_q),
    .read_ptr_i(read_pointer_q)
);
`endif
`resetall
