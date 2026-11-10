// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nmu_response_dispatch (
    input  wire noc_payload_pkg::rsp_flit_t  s_rsp_i,
    input  wire logic                        s_rsp_valid_i,
    output wire logic                        s_rsp_ready_o,
    input  wire noc_payload_pkg::dat_flit_t  s_dat_i,
    input  wire logic                        s_dat_valid_i,
    output wire logic                        s_dat_ready_o,
    output wire noc_payload_pkg::rsp_flit_t  m_b_o,
    output wire logic                        m_b_valid_o,
    input  wire logic                        m_b_ready_i,
    output wire noc_payload_pkg::dat_flit_t  m_r_o,
    output wire logic                        m_r_valid_o,
    input  wire logic                        m_r_ready_i
);
    wire [noc_header_pkg::PACKET_TYPE_WIDTH-1:0] channel = s_rsp_i.header.packet_type;
    wire is_b = channel == noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_NARROW_B) ||
                channel == noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_DATA_B);
    assign m_b_valid_o   = s_rsp_valid_i && is_b;
    assign m_b_o         = m_b_valid_o ? s_rsp_i : '0;
    assign s_rsp_ready_o = is_b && m_b_ready_i;
    assign m_r_valid_o   = s_dat_valid_i;
    assign m_r_o         = m_r_valid_o ? s_dat_i : '0;
    assign s_dat_ready_o = m_r_ready_i;

endmodule
`resetall
