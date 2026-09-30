// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nsu_rx_channel_assign #(
    parameter int unsigned NUM_DAT_VC = ni_params_pkg::NUM_DAT_VC
) (
    input  wire logic                                          clk_i,
    input  wire logic                                          rst_n_i,
    input  wire ni_flit_pkg::req_flit_t                        s_req_i,
    input  wire logic                                          s_req_valid_i,
    output wire logic                                          s_req_ready_o,
    input  wire ni_flit_pkg::dat_flit_t       [NUM_DAT_VC-1:0] s_dat_i,
    input  wire logic                         [NUM_DAT_VC-1:0] s_dat_valid_i,
    output wire logic                         [NUM_DAT_VC-1:0] s_dat_ready_o,
    input  wire ni_types_pkg::nsu_w_context_t                  w_context_i,
    input  wire logic                                          w_context_valid_i,
    output wire ni_flit_pkg::dat_flit_t                        m_aw_o,
    output wire logic                                          m_aw_valid_o,
    input  wire logic                                          m_aw_ready_i,
    output wire ni_flit_pkg::dat_flit_t                        m_w_o,
    output wire logic                                          m_w_valid_o,
    input  wire logic                                          m_w_ready_i,
    output wire ni_flit_pkg::req_flit_t                        m_ar_o,
    output wire logic                                          m_ar_valid_o,
    input  wire logic                                          m_ar_ready_i
);
    import ni_flit_pkg::*;
    localparam int unsigned NUM_AW_CH = NUM_DAT_VC + 1;
    localparam int unsigned VC_IDX_W  = NUM_DAT_VC > 1 ? $clog2(NUM_DAT_VC) : 1;
    if (NUM_DAT_VC < 1 || NUM_DAT_VC > (1 << VC_ID_WIDTH)) begin : gen_invalid_vc
        initial $fatal(0, "Error: invalid NSU RX VC count (instance %m)");
    end
    wire [AXI_CH_WIDTH-1:0] req_channel = s_req_i.header[AXI_CH_LSB +: AXI_CH_WIDTH];
    wire                    req_is_aw = req_channel == AXI_CH_WIDTH'(AXI_CH_NarrowAw);
    wire                    req_is_ar = req_channel == AXI_CH_WIDTH'(AXI_CH_NarrowAr) ||
        req_channel == AXI_CH_WIDTH'(AXI_CH_DataAr);
    wire                 req_is_w = req_channel == AXI_CH_WIDTH'(AXI_CH_NarrowW);
    wire                 dat_flit_t [NUM_AW_CH-1:0] aw_data;
    wire [NUM_AW_CH-1:0] aw_valid, aw_ready;
    wire                 dat_flit_t selected_aw;
    wire                 selected_aw_valid;
    wire  [VC_IDX_W-1:0] w_vc = VC_IDX_W'(w_context_i.vc_id);
    wire                 dat_flit_t w_flit = w_context_i.response.is_data ? s_dat_i[w_vc] : aw_data[0];
    wire                 w_valid = w_context_valid_i && (w_context_i.response.is_data ?
        (s_dat_valid_i[w_vc] && s_dat_i[w_vc].header[AXI_CH_LSB +: AXI_CH_WIDTH] == AXI_CH_WIDTH'(AXI_CH_DataW)) :
        (s_req_valid_i && req_is_w));
    assign aw_data[0]  = '{header: s_req_i.header, payload: PAYLOAD_WIDTH'(s_req_i.payload)};
    assign aw_valid[0] = rst_n_i && s_req_valid_i && req_is_aw;
    for (genvar vc = 0; vc < NUM_DAT_VC; vc++) begin : gen_aw
        assign aw_data[vc+1]  = s_dat_i[vc];
        assign aw_valid[vc+1] = rst_n_i && s_dat_valid_i[vc] &&
            s_dat_i[vc].header[AXI_CH_LSB +: AXI_CH_WIDTH] == AXI_CH_WIDTH'(AXI_CH_DataAw);
        assign s_dat_ready_o[vc] = (aw_valid[vc+1] && aw_ready[vc+1]) ||
            (m_w_valid_o && m_w_ready_i && w_context_i.response.is_data && w_vc == VC_IDX_W'(vc));
    end
    assign s_req_ready_o = rst_n_i && ((aw_valid[0] && aw_ready[0]) ||
        (m_ar_valid_o && m_ar_ready_i) ||
        (m_w_valid_o && m_w_ready_i && !w_context_i.response.is_data));
    assign m_aw_valid_o = rst_n_i && selected_aw_valid;
    assign m_aw_o       = m_aw_valid_o ? selected_aw : '0;
    assign m_ar_valid_o = rst_n_i && s_req_valid_i && req_is_ar;
    assign m_ar_o       = m_ar_valid_o ? s_req_i : '0;
    assign m_w_valid_o  = rst_n_i && w_valid;
    assign m_w_o        = m_w_valid_o ? w_flit : '0;
    rr_arb_tree #(
        .NumIn     (NUM_AW_CH ),
        .DataType  (dat_flit_t),
        .AxiVldRdy (1'b1      ),
        .LockIn    (1'b1      ),
        .FairArb   (1'b1      )
    ) i_aw_arb (
        .clk_i   (clk_i                  ),
        .rst_ni  (rst_n_i                ),
        .flush_i (1'b0                   ),
        .rr_i    ('0                     ),
        .req_i   (aw_valid               ),
        .gnt_o   (aw_ready               ),
        .data_i  (aw_data                ),
        .req_o   (selected_aw_valid      ),
        .gnt_i   (rst_n_i && m_aw_ready_i),
        .data_o  (selected_aw            ),
        .idx_o   (                       )
    );
endmodule

`resetall
