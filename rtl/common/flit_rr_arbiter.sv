// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

// Arbitrate one flit among eligible VCs on a shared physical link.
module flit_rr_arbiter #(
    parameter int unsigned NUM_DAT_VC = noc_unit_params_pkg::DAT_NUM_VC,
    parameter logic [NUM_DAT_VC-1:0] DAT_VC_MASK =
        NUM_DAT_VC'(1) << noc_unit_params_pkg::DAT_WRITE_VC
) (
    input  wire logic                                    clk_i,
    input  wire logic                                    rst_n_i,
    input  wire noc_payload_pkg::dat_flit_t [NUM_DAT_VC-1:0] s_dat_i,
    input  wire logic                      [NUM_DAT_VC-1:0] s_dat_valid_i,
    output wire logic                      [NUM_DAT_VC-1:0] s_dat_ready_o,
    output wire noc_payload_pkg::dat_flit_t                 m_dat_o,
    output wire logic                      [NUM_DAT_VC-1:0] m_dat_valid_o,
    input  wire logic                      [NUM_DAT_VC-1:0] m_dat_ready_i
);
    localparam int VC_IDX_W = NUM_DAT_VC > 1 ? $clog2(NUM_DAT_VC) : 1;

    if (NUM_DAT_VC < 1) begin : gen_invalid_vcs
        initial $fatal(0, "Error: NUM_DAT_VC must be positive (instance %m)");
    end

    wire noc_payload_pkg::dat_flit_t selected_dat;
    wire [NUM_DAT_VC-1:0] eligible = s_dat_valid_i & m_dat_ready_i & DAT_VC_MASK;
    wire [VC_IDX_W-1:0] selected_vc;
    wire                selected_valid;

    rr_arb_tree #(
        .NumIn     (NUM_DAT_VC                 ),
        .DataType  (noc_payload_pkg::dat_flit_t),
        .AxiVldRdy (1'b0                       ),
        .LockIn    (1'b0                       ),
        .FairArb   (1'b1                       )
    ) i_arb (
        .clk_i   (clk_i                      ),
        .rst_ni  (rst_n_i                    ),
        .flush_i (1'b0                       ),
        .rr_i    ('0                         ),
        .req_i   (eligible                   ),
        .gnt_o   (s_dat_ready_o              ),
        .data_i  (s_dat_i                    ),
        .req_o   (selected_valid             ),
        .gnt_i   (selected_valid && m_dat_ready_i[selected_vc]),
        .data_o  (selected_dat               ),
        .idx_o   (selected_vc                )
    );

    assign m_dat_valid_o = selected_valid ? (NUM_DAT_VC'(1) << selected_vc) : '0;
    assign m_dat_o       = selected_valid ? selected_dat : '0;
endmodule

`resetall
