// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module rx_channel_assign (
    input  wire logic                    rst_n_i,
    input  wire ni_flit_pkg::rsp_flit_t  s_rsp_i,
    input  wire logic                    s_rsp_valid_i,
    output wire logic                    s_rsp_ready_o,
    input  wire ni_flit_pkg::dat_flit_t  s_dat_i,
    input  wire logic                    s_dat_valid_i,
    output wire logic                    s_dat_ready_o,
    output wire ni_flit_pkg::rsp_flit_t  m_b_o,
    output wire logic                    m_b_valid_o,
    input  wire logic                    m_b_ready_i,
    output wire ni_flit_pkg::dat_flit_t  m_r_o,
    output wire logic                    m_r_valid_o,
    input  wire logic                    m_r_ready_i
);
    import ni_flit_pkg::*;
    wire [AXI_CH_WIDTH-1:0] channel = s_rsp_i.header[AXI_CH_LSB +: AXI_CH_WIDTH];
    wire is_b = channel == AXI_CH_WIDTH'(AXI_CH_NarrowB) ||
                channel == AXI_CH_WIDTH'(AXI_CH_DataB);
    assign m_b_valid_o   = rst_n_i && s_rsp_valid_i && is_b;
    assign m_b_o         = m_b_valid_o ? s_rsp_i : '0;
    assign s_rsp_ready_o = rst_n_i && is_b && m_b_ready_i;
    assign m_r_valid_o   = rst_n_i && s_dat_valid_i;
    assign m_r_o         = m_r_valid_o ? s_dat_i : '0;
    assign s_dat_ready_o = rst_n_i && m_r_ready_i;

endmodule
`resetall
