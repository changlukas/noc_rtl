// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

// Merge REQ and DAT writes without interleaving their AW/W packets.
module nsu_request_dispatch (
    input  wire logic                          clk_i,
    input  wire logic                          rst_n_i,
    input  wire noc_payload_pkg::req_flit_t    s_req_i,
    input  wire logic                          s_req_valid_i,
    output wire logic                          s_req_ready_o,
    input  wire noc_payload_pkg::dat_flit_t    s_dat_i,
    input  wire logic                          s_dat_valid_i,
    output wire logic                          s_dat_ready_o,
    input  wire ni_types_pkg::nsu_w_context_t  w_context_i,
    input  wire logic                          w_context_valid_i,
    output wire noc_payload_pkg::dat_flit_t    m_aw_o,
    output wire logic                          m_aw_valid_o,
    input  wire logic                          m_aw_ready_i,
    output wire noc_payload_pkg::dat_flit_t    m_w_o,
    output wire logic                          m_w_valid_o,
    input  wire logic                          m_w_ready_i,
    output wire noc_payload_pkg::req_flit_t    m_ar_o,
    output wire logic                          m_ar_valid_o,
    input  wire logic                          m_ar_ready_i
);
    wire [1:0] select, grant;
    wire valid, ready;
    wire noc_payload_pkg::dat_flit_t req_flit = '{
        header: s_req_i.header,
        payload: noc_payload_pkg::DAT_PAYLOAD_WIDTH'(s_req_i.payload)
    };
    wire noc_payload_pkg::dat_flit_t flit = select[1] ? s_dat_i : req_flit;
    wire is_aw = flit.header.packet_type == noc_header_pkg::PKT_NARROW_AW ||
        flit.header.packet_type == noc_header_pkg::PKT_DATA_AW;
    wire is_ar = flit.header.packet_type == noc_header_pkg::PKT_NARROW_AR ||
        flit.header.packet_type == noc_header_pkg::PKT_DATA_AR;
    wire is_w = flit.header.packet_type == noc_header_pkg::PKT_NARROW_W ||
        flit.header.packet_type == noc_header_pkg::PKT_DATA_W;
    wire w_owner = w_context_valid_i &&
        ((w_context_i.response.packet_type == noc_header_pkg::PKT_DATA_B) == select[1]);

    packet_rr_arbiter #(
        .NUM_INPUTS (2)
    ) i_packet_arbiter (
        .clk_i    (clk_i),
        .rst_n_i  (rst_n_i),
        .req_i    ({s_dat_valid_i, s_req_valid_i}),
        .last_i   ({s_dat_i.header.flit_tail, s_req_i.header.flit_tail}),
        .select_o (select),
        .grant_o  (grant),
        .valid_o  (valid),
        .ready_i  (ready)
    );
    assign ready = (is_aw && m_aw_ready_i) || (is_ar && m_ar_ready_i) ||
        (is_w && w_owner && m_w_ready_i);
    assign s_req_ready_o = grant[0];
    assign s_dat_ready_o = grant[1];
    assign m_aw_valid_o = valid && is_aw;
    assign m_aw_o = m_aw_valid_o ? flit : '0;
    assign m_ar_valid_o = valid && is_ar;
    assign m_ar_o = m_ar_valid_o ? '{header: flit.header,
        payload: flit.payload[noc_payload_pkg::REQ_PAYLOAD_WIDTH-1:0]} : '0;
    assign m_w_valid_o = valid && is_w && w_owner;
    assign m_w_o = m_w_valid_o ? flit : '0;
endmodule

`resetall
