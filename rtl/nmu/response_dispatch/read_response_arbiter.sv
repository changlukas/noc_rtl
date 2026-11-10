// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nmu_read_response_arbiter (
    input  wire logic                        clk_i,
    input  wire logic                        rst_n_i,
    input  wire noc_payload_pkg::rsp_flit_t  s_rsp_i,
    input  wire logic                        s_rsp_valid_i,
    output wire logic                        s_rsp_ready_o,
    output wire noc_payload_pkg::rsp_flit_t  m_rsp_o,
    output wire logic                        m_rsp_valid_o,
    input  wire logic                        m_rsp_ready_i,
    input  wire noc_payload_pkg::dat_flit_t  s_dat_i,
    input  wire logic                        s_dat_valid_i,
    output wire logic                        s_dat_ready_o,
    output wire noc_payload_pkg::dat_flit_t  m_dat_o,
    output wire logic                        m_dat_valid_o,
    input  wire logic                        m_dat_ready_i
);
    localparam int unsigned NUM_INPUTS = 2;
    wire [noc_header_pkg::PACKET_TYPE_WIDTH-1:0] channel = s_rsp_i.header.packet_type;
    wire is_r = channel == noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_NARROW_R);
    wire [NUM_INPUTS-1:0] r_valid, r_ready;
    wire noc_payload_pkg::dat_flit_t [NUM_INPUTS-1:0] r_data;

    assign r_data[0]     = '{header: s_rsp_i.header, payload: noc_payload_pkg::DAT_PAYLOAD_WIDTH'(s_rsp_i.payload)};
    assign r_valid[0]    = s_rsp_valid_i && is_r;
    assign r_data[1]     = s_dat_i;
    assign r_valid[1]    = s_dat_valid_i;
    assign s_dat_ready_o = r_ready[1];
    assign s_rsp_ready_o = (is_r ? r_ready[0] : m_rsp_ready_i);
    assign m_rsp_valid_o = s_rsp_valid_i && !is_r;
    assign m_rsp_o       = m_rsp_valid_o ? s_rsp_i : '0;

    wire noc_payload_pkg::dat_flit_t selected_dat;
    wire selected_valid;
    rr_arb_tree #(
        .NumIn     (NUM_INPUTS             ),
        .DataType  (noc_payload_pkg::dat_flit_t),
        .AxiVldRdy (1'b1                   ),
        .LockIn    (1'b1                   ),
        .FairArb   (1'b1                   )
    ) i_arb (
        .clk_i   (clk_i         ),
        .rst_ni  (rst_n_i       ),
        .flush_i (1'b0          ),
        .rr_i    ('0            ),
        .req_i   (r_valid       ),
        .gnt_o   (r_ready       ),
        .data_i  (r_data        ),
        .req_o   (selected_valid),
        .gnt_i   (m_dat_ready_i ),
        .data_o  (selected_dat  ),
        .idx_o   (              )
    );
    assign m_dat_valid_o = selected_valid;
    assign m_dat_o       = m_dat_valid_o ? selected_dat : '0;
endmodule
`resetall
