// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module tx_credit_buffer #(
    parameter int unsigned           CTRL_FIFO_DEPTH = 32,
    parameter int unsigned           NUM_DAT_VC      = ni_params_pkg::NUM_DAT_VC,
    parameter int unsigned           DAT_VC_MODE     = ni_params_pkg::NOC_DAT_VC_MODE,
    parameter int unsigned           CREDIT_DEPTH    = ni_params_pkg::CREDIT_DEPTH,
    parameter type                   ctrl_t          = ni_flit_pkg::req_flit_t,
    parameter logic [NUM_DAT_VC-1:0] DAT_VC_MASK     = (DAT_VC_MODE == 1 ? ({NUM_DAT_VC{1'b1}} >> (NUM_DAT_VC/2)) : '1)
) (
    input  wire logic                                    clk_i,
    input  wire logic                                    rst_n_i,
    input  wire ctrl_t                                   s_ctrl_i,
    input  wire logic                                    s_ctrl_valid_i,
    output wire logic                                    s_ctrl_ready_o,
    output wire ctrl_t                                   m_ctrl_o,
    output wire logic                                    m_ctrl_valid_o,
    input  wire logic                                    m_ctrl_ready_i,
    input  wire ni_flit_pkg::dat_flit_t                  s_dat_i,
    input  wire logic                                    s_dat_valid_i,
    output wire logic                   [NUM_DAT_VC-1:0] dat_ready_o,
    output wire ni_flit_pkg::dat_flit_t [NUM_DAT_VC-1:0] m_dat_o,
    output wire logic                   [NUM_DAT_VC-1:0] m_dat_valid_o,
    input  wire logic                   [NUM_DAT_VC-1:0] m_dat_ready_i,
    input  wire logic                   [NUM_DAT_VC-1:0] dat_credit_return_i
);
    import ni_flit_pkg::*;
    localparam int unsigned VC_IDX_W = NUM_DAT_VC > 1 ? $clog2(NUM_DAT_VC) : 1;
    if (CTRL_FIFO_DEPTH < 1) begin : gen_invalid_depth
        initial $fatal(0, "Error: TX FIFO depths must be positive (instance %m)");
    end
    if (NUM_DAT_VC < 1 || NUM_DAT_VC > (1 << VC_ID_WIDTH) || DAT_VC_MODE > 1 ||
            (DAT_VC_MODE == 1 && (NUM_DAT_VC < 2 || NUM_DAT_VC % 2 != 0))) begin : gen_invalid_vc
        initial $fatal(0, "Error: invalid DAT VC configuration (instance %m)");
    end
    if (CREDIT_DEPTH < 2 || (CREDIT_DEPTH & (CREDIT_DEPTH-1)) != 0) begin : gen_invalid_credit_depth
        initial $fatal(0, "Error: CREDIT_DEPTH must be a power of two >= 2 (instance %m)");
    end
    wire ctrl_full, ctrl_empty;
    wire ctrl_t ctrl_head;
    assign s_ctrl_ready_o = rst_n_i && !ctrl_full;
    assign m_ctrl_valid_o = rst_n_i && !ctrl_empty;
    assign m_ctrl_o       = m_ctrl_valid_o ? ctrl_head : '0;
    cc_fifo #(
        .Depth       (CTRL_FIFO_DEPTH),
        .FallThrough (1'b0           ),
        .data_t      (ctrl_t         )
    ) i_ctrl_fifo (
        .clk_i   (clk_i                           ),
        .rst_ni  (rst_n_i                         ),
        .clr_i   (1'b0                            ),
        .flush_i (1'b0                            ),
        .full_o  (ctrl_full                       ),
        .empty_o (ctrl_empty                      ),
        .usage_o (                                ),
        .data_i  (s_ctrl_i                        ),
        .push_i  (s_ctrl_valid_i && s_ctrl_ready_o),
        .data_o  (ctrl_head                       ),
        .pop_i   (m_ctrl_valid_o && m_ctrl_ready_i)
    );
    wire [VC_ID_WIDTH-1:0] dat_vc = s_dat_i.header[VC_ID_LSB +: VC_ID_WIDTH];
    wire [NUM_DAT_VC-1:0] dat_full, dat_empty, dat_pop, dat_req, credit_left;
    wire dat_flit_t [NUM_DAT_VC-1:0] dat_head;
    assign dat_pop = m_dat_ready_i[NUM_DAT_VC-1:0] & dat_req;
    for (genvar vc = 0; vc < NUM_DAT_VC; vc++) begin : gen_dat_vc
        if (DAT_VC_MASK[vc]) begin : gen_active
            assign m_dat_o[vc]       = dat_req[vc] ? dat_head[vc] : '0;
            assign m_dat_valid_o[vc] = dat_req[vc];
            assign dat_ready_o[vc] = rst_n_i && !dat_full[vc];
            assign dat_req[vc] = rst_n_i && !dat_empty[vc] &&
                (credit_left[vc] || dat_credit_return_i[vc]);
            cc_fifo #(
                .Depth       (CREDIT_DEPTH),
                .FallThrough (1'b0        ),
                .data_t      (dat_flit_t  )
            ) i_fifo (
                .clk_i   (clk_i                                                         ),
                .rst_ni  (rst_n_i                                                       ),
                .clr_i   (1'b0                                                          ),
                .flush_i (1'b0                                                          ),
                .full_o  (dat_full[vc]                                                  ),
                .empty_o (dat_empty[vc]                                                 ),
                .usage_o (                                                              ),
                .data_i  (s_dat_i                                                       ),
                .push_i  (s_dat_valid_i && dat_ready_o[vc] && dat_vc == VC_ID_WIDTH'(vc)),
                .data_o  (dat_head[vc]                                                  ),
                .pop_i   (dat_pop[vc]                                                   )
            );
            cc_credit_counter #(
                .NumCredits (CREDIT_DEPTH)
            ) i_credit (
                .clk_i         (clk_i                             ),
                .rst_ni        (rst_n_i                           ),
                .clr_i         (1'b0                              ),
                .credit_o      (                                  ),
                .credit_give_i (rst_n_i && dat_credit_return_i[vc]),
                .credit_take_i (dat_pop[vc]                       ),
                .credit_left_o (credit_left[vc]                   ),
                .credit_crit_o (                                  ),
                .credit_full_o (                                  )
            );
        end else begin : gen_unused
            assign dat_ready_o[vc]   = 1'b0;
            assign dat_full[vc]      = 1'b0;
            assign dat_empty[vc]     = 1'b1;
            assign dat_req[vc]       = 1'b0;
            assign credit_left[vc]   = 1'b0;
            assign dat_head[vc]      = '0;
            assign m_dat_o[vc]       = '0;
            assign m_dat_valid_o[vc] = 1'b0;
        end
    end
    // synthesis translate_off
    always @(posedge clk_i) begin
        if (rst_n_i && s_dat_valid_i) begin
            if ($isunknown(dat_vc) || int'(dat_vc) >= NUM_DAT_VC || !DAT_VC_MASK[VC_IDX_W'(dat_vc)])
                $fatal(1, "invalid TX DAT VC");
            else if (!dat_ready_o[VC_IDX_W'(dat_vc)])
                $fatal(1, "TX DAT FIFO overflow");
        end
    end
    // synthesis translate_on
endmodule
`resetall
