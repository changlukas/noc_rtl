// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module rx_vc_arbiter #(
    parameter int unsigned NUM_DAT_VC = ni_params_pkg::NUM_DAT_VC
) (
    input  wire logic                                    clk_i,
    input  wire logic                                    rst_n_i,
    input  wire ni_flit_pkg::rsp_flit_t                  s_rsp_i,
    input  wire logic                                    s_rsp_valid_i,
    output wire logic                                    s_rsp_ready_o,
    output wire ni_flit_pkg::rsp_flit_t                  m_rsp_o,
    output wire logic                                    m_rsp_valid_o,
    input  wire logic                                    m_rsp_ready_i,
    input  wire ni_flit_pkg::dat_flit_t [NUM_DAT_VC-1:0] s_dat_i,
    input  wire logic                   [NUM_DAT_VC-1:0] s_dat_valid_i,
    output wire logic                   [NUM_DAT_VC-1:0] s_dat_ready_o,
    output wire ni_flit_pkg::dat_flit_t                  m_dat_o,
    output wire logic                                    m_dat_valid_o,
    input  wire logic                                    m_dat_ready_i
);
    localparam int unsigned NUM_ARB_VC = NUM_DAT_VC + 1;
    if (NUM_DAT_VC < 1 || NUM_DAT_VC > (1 << ni_flit_pkg::VC_ID_WIDTH)) begin : gen_invalid_vcs
        initial $fatal(0, "Error: invalid DAT VC count (instance %m)");
    end
    import ni_flit_pkg::*;
    wire [AXI_CH_WIDTH-1:0] channel = s_rsp_i.header[AXI_CH_LSB +: AXI_CH_WIDTH];
    wire is_r = channel == AXI_CH_WIDTH'(AXI_CH_NarrowR);
    wire [NUM_ARB_VC-1:0] r_valid, r_ready;
    wire dat_flit_t [NUM_ARB_VC-1:0] r_data;

    assign r_data[0]     = '{header: s_rsp_i.header, payload: PAYLOAD_WIDTH'(s_rsp_i.payload)};
    assign r_valid[0]    = rst_n_i && s_rsp_valid_i && is_r;
    assign r_data[NUM_DAT_VC:1]  = s_dat_i;
    assign r_valid[NUM_DAT_VC:1] = s_dat_valid_i & {NUM_DAT_VC{rst_n_i}};
    assign s_dat_ready_o = r_ready[NUM_DAT_VC:1];
    assign s_rsp_ready_o = rst_n_i && (is_r ? r_ready[0] : m_rsp_ready_i);
    assign m_rsp_valid_o = rst_n_i && s_rsp_valid_i && !is_r;
    assign m_rsp_o       = m_rsp_valid_o ? s_rsp_i : '0;

    wire ni_flit_pkg::dat_flit_t selected_dat;
    wire selected_valid;
    rr_arb_tree #(
        .NumIn     (NUM_ARB_VC             ),
        .DataType  (ni_flit_pkg::dat_flit_t),
        .AxiVldRdy (1'b1                   ),
        .LockIn    (1'b1                   ),
        .FairArb   (1'b1                   )
    ) i_arb (
        .clk_i   (clk_i                   ),
        .rst_ni  (rst_n_i                 ),
        .flush_i (1'b0                    ),
        .rr_i    ('0                      ),
        .req_i   (r_valid                 ),
        .gnt_o   (r_ready                 ),
        .data_i  (r_data                  ),
        .req_o   (selected_valid          ),
        .gnt_i   (rst_n_i && m_dat_ready_i),
        .data_o  (selected_dat            ),
        .idx_o   (                        )
    );
    assign m_dat_valid_o = rst_n_i && selected_valid;
    assign m_dat_o       = m_dat_valid_o ? selected_dat : '0;
endmodule
`resetall
