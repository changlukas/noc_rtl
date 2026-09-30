// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nsu_tx_channel_assign #(
    parameter int unsigned NUM_DAT_VC  = ni_params_pkg::NUM_DAT_VC,
    parameter int unsigned DAT_VC_MODE = ni_params_pkg::NOC_DAT_VC_MODE
) (
    input  wire logic                                    clk_i,
    input  wire logic                                    rst_n_i,
    input  wire ni_flit_pkg::rsp_flit_t                  s_b_i,
    input  wire logic                                    s_b_valid_i,
    output wire logic                                    s_b_ready_o,
    input  wire ni_flit_pkg::dat_flit_t                  s_r_i,
    input  wire logic                                    s_r_valid_i,
    output wire logic                                    s_r_ready_o,
    output wire ni_flit_pkg::rsp_flit_t                  m_rsp_o,
    output wire logic                                    m_rsp_valid_o,
    input  wire logic                                    m_rsp_ready_i,
    output wire ni_flit_pkg::dat_flit_t                  m_dat_o,
    output wire logic                                    m_dat_valid_o,
    input  wire logic                   [NUM_DAT_VC-1:0] dat_ready_i
);
    import ni_flit_pkg::*;
    localparam int unsigned NUM_RSP_CH = 2;
    localparam int unsigned NUM_RD_VC  = DAT_VC_MODE == 1 ? NUM_DAT_VC/2 : NUM_DAT_VC;
    localparam int unsigned RD_VC_BASE = DAT_VC_MODE == 1 ? NUM_DAT_VC/2 : 0;
    localparam int unsigned VC_IDX_W   = NUM_DAT_VC > 1 ? $clog2(NUM_DAT_VC) : 1;
    if (NUM_DAT_VC < 1 || NUM_DAT_VC > (1 << VC_ID_WIDTH) || DAT_VC_MODE > 1 ||
            (DAT_VC_MODE == 1 && (NUM_DAT_VC < 2 || NUM_DAT_VC % 2 != 0))) begin : gen_invalid_vc
        initial $fatal(0, "Error: invalid NSU TX VC configuration (instance %m)");
    end
    wire                r_is_data = s_r_i.header[AXI_CH_LSB +: AXI_CH_WIDTH] == AXI_CH_WIDTH'(AXI_CH_DataR);
    wire [VC_IDX_W-1:0] r_vc = VC_IDX_W'(RD_VC_BASE +
        ((int'(s_r_i.header[DST_ID_LSB +: DST_ID_WIDTH]) ^
          int'(s_r_i.payload[DATA_R_RID_LSB +: DATA_R_RID_WIDTH])) % NUM_RD_VC));
    wire                  rsp_flit_t [NUM_RSP_CH-1:0] rsp_data;
    wire [NUM_RSP_CH-1:0] rsp_valid, rsp_ready;
    wire                  rsp_flit_t selected_rsp;
    wire                  selected_rsp_valid;
    dat_flit_t dat;
    assign rsp_data[0]   = s_b_i;
    assign rsp_data[1]   = '{header: s_r_i.header, payload: (ni_params_pkg::NOC_RSP_FLIT_WIDTH-HEADER_WIDTH)'(s_r_i.payload)};
    assign rsp_valid     = {s_r_valid_i && !r_is_data, s_b_valid_i} & {NUM_RSP_CH{rst_n_i}};
    assign s_b_ready_o   = rst_n_i && rsp_ready[0];
    assign s_r_ready_o   = rst_n_i && (r_is_data ? dat_ready_i[r_vc] : rsp_ready[1]);
    assign m_rsp_valid_o = rst_n_i && selected_rsp_valid;
    assign m_rsp_o       = m_rsp_valid_o ? selected_rsp : '0;
    assign m_dat_valid_o = rst_n_i && s_r_valid_i && r_is_data && dat_ready_i[r_vc];
    assign m_dat_o       = m_dat_valid_o ? dat : '0;
    always_comb begin
        dat = s_r_i;
        dat.header[VC_ID_LSB +: VC_ID_WIDTH] = VC_ID_WIDTH'(r_vc);
        dat.header[FIXED_VC_LSB] = 1'b1;
    end
    rr_arb_tree #(
        .NumIn     (NUM_RSP_CH),
        .DataType  (rsp_flit_t),
        .AxiVldRdy (1'b1      ),
        .LockIn    (1'b1      ),
        .FairArb   (1'b1      )
    ) i_rsp_arb (
        .clk_i   (clk_i                   ),
        .rst_ni  (rst_n_i                 ),
        .flush_i (1'b0                    ),
        .rr_i    ('0                      ),
        .req_i   (rsp_valid               ),
        .gnt_o   (rsp_ready               ),
        .data_i  (rsp_data                ),
        .req_o   (selected_rsp_valid      ),
        .gnt_i   (rst_n_i && m_rsp_ready_i),
        .data_o  (selected_rsp            ),
        .idx_o   (                        )
    );
endmodule

`resetall
