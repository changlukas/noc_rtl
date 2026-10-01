// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module tx_vc_arbiter #(
    parameter int unsigned           NUM_DAT_VC  = ni_params_pkg::NUM_DAT_VC,
    parameter int unsigned           DAT_VC_MODE = ni_params_pkg::NOC_DAT_VC_MODE,
    parameter logic [NUM_DAT_VC-1:0] DAT_VC_MASK =
        DAT_VC_MODE == 1 ? ({NUM_DAT_VC{1'b1}} >> (NUM_DAT_VC/2)) : '1
) (
    input  wire logic                                    clk_i,
    input  wire logic                                    rst_n_i,
    input  wire ni_flit_pkg::dat_flit_t [NUM_DAT_VC-1:0] s_dat_i,
    input  wire logic                   [NUM_DAT_VC-1:0] s_dat_valid_i,
    output wire logic                   [NUM_DAT_VC-1:0] s_dat_ready_o,
    output wire ni_flit_pkg::dat_flit_t                  m_dat_o,
    output wire logic                                    m_dat_valid_o,
    input  wire logic                                    m_dat_ready_i
);
    localparam int unsigned NUM_ARB_VC = NUM_DAT_VC;
    if (NUM_DAT_VC < 1 || NUM_DAT_VC > (1 << ni_flit_pkg::VC_ID_WIDTH)) begin : gen_invalid_vcs
        initial $fatal(0, "Error: invalid DAT VC count (instance %m)");
    end
    if (DAT_VC_MODE > 1 || (DAT_VC_MODE == 1 && (NUM_DAT_VC < 2 || NUM_DAT_VC % 2 != 0))) begin : gen_invalid_mode
        initial $fatal(0, "Error: invalid DAT VC mode (instance %m)");
    end
    wire ni_flit_pkg::dat_flit_t selected_dat;
    wire selected_valid;
    rr_arb_tree #(
        .NumIn     (NUM_ARB_VC             ),
        .DataType  (ni_flit_pkg::dat_flit_t),
        .AxiVldRdy (1'b1                   ),
        .LockIn    (1'b0                   ),
        .FairArb   (1'b1                   )
    ) i_arb (
        .clk_i   (clk_i                        ),
        .rst_ni  (rst_n_i                      ),
        .flush_i (1'b0                         ),
        .rr_i    ('0                           ),
        .req_i   (s_dat_valid_i & DAT_VC_MASK  ),
        .gnt_o   (s_dat_ready_o[NUM_ARB_VC-1:0]),
        .data_i  (s_dat_i[NUM_ARB_VC-1:0]      ),
        .req_o   (selected_valid               ),
        .gnt_i   (m_dat_ready_i                ),
        .data_o  (selected_dat                 ),
        .idx_o   (                             )
    );
    assign m_dat_valid_o = selected_valid;
    assign m_dat_o       = m_dat_valid_o ? selected_dat : '0;
    for (genvar vc = NUM_ARB_VC; vc < NUM_DAT_VC; vc++) begin : gen_unused
        assign s_dat_ready_o[vc] = 1'b0;
    end
endmodule
`resetall
