// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nsu_response_dispatch (
    input  wire logic                        clk_i,
    input  wire logic                        rst_n_i,
    input  wire noc_payload_pkg::rsp_flit_t  s_b_i,
    input  wire logic                        s_b_valid_i,
    output wire logic                        s_b_ready_o,
    input  wire noc_payload_pkg::dat_flit_t  s_r_i,
    input  wire logic                        s_r_valid_i,
    output wire logic                        s_r_ready_o,
    output wire noc_payload_pkg::rsp_flit_t  m_rsp_o,
    output wire logic                        m_rsp_valid_o,
    input  wire logic                        m_rsp_ready_i,
    output wire noc_payload_pkg::dat_flit_t  m_dat_o,
    output wire logic                        m_dat_valid_o,
    input  wire logic                        m_dat_ready_i
);
    localparam int unsigned NUM_RSP_CH = 2;
    wire r_is_data = s_r_i.header.packet_type == noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_DATA_R);
    wire                  noc_payload_pkg::rsp_flit_t [NUM_RSP_CH-1:0] rsp_data;
    wire [NUM_RSP_CH-1:0] rsp_valid, rsp_ready;
    wire                  noc_payload_pkg::rsp_flit_t selected_rsp;
    wire                  selected_rsp_valid;
    assign rsp_data[0]   = s_b_i;
    assign rsp_data[1]   = '{header: s_r_i.header, payload: (noc_payload_pkg::RSP_FLIT_WIDTH-noc_header_pkg::HEADER_WIDTH)'(s_r_i.payload)};
    assign rsp_valid     = {s_r_valid_i && !r_is_data, s_b_valid_i};
    assign s_b_ready_o   = rsp_ready[0];
    assign s_r_ready_o   = (r_is_data ? m_dat_ready_i : rsp_ready[1]);
    assign m_rsp_valid_o = selected_rsp_valid;
    assign m_rsp_o       = m_rsp_valid_o ? selected_rsp : '0;
    assign m_dat_valid_o = s_r_valid_i && r_is_data;
    assign m_dat_o       = m_dat_valid_o ? s_r_i : '0;
    rr_arb_tree #(
        .NumIn     (NUM_RSP_CH),
        .DataType  (noc_payload_pkg::rsp_flit_t),
        .AxiVldRdy (1'b1      ),
        .LockIn    (1'b1      ),
        .FairArb   (1'b1      )
    ) i_rsp_arb (
        .clk_i   (clk_i             ),
        .rst_ni  (rst_n_i           ),
        .flush_i (1'b0              ),
        .rr_i    ('0                ),
        .req_i   (rsp_valid         ),
        .gnt_o   (rsp_ready         ),
        .data_i  (rsp_data          ),
        .req_o   (selected_rsp_valid),
        .gnt_i   (m_rsp_ready_i     ),
        .data_o  (selected_rsp      ),
        .idx_o   (                  )
    );
endmodule

`resetall
