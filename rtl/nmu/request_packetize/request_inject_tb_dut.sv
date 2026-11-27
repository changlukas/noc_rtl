// SPDX-License-Identifier: Apache-2.0

`resetall
`timescale 1ns / 1ps
`default_nettype none

// Packetize REQ/DAT independently; accepted AW order determines W ownership.
module nmu_request_inject_tb_dut #(
    parameter int unsigned REQ_AW_REG_TYPE                               = 0,
    parameter int unsigned REQ_W_REG_TYPE                                = 0,
    parameter int unsigned REQ_AR_REG_TYPE                               = 0,
    parameter int unsigned DAT_AW_REG_TYPE                               = 0,
    parameter int unsigned DAT_W_REG_TYPE                                = 0,
    parameter logic [ni_types_pkg::NODE_ID_W-1:0]      SRC_ID          = '0,
    parameter logic [noc_header_pkg::PORT_ID_WIDTH-1:0] SRC_PORT_ID     = '0
) (
    input  wire logic                                           clk_i,
    input  wire logic                                           rst_n_i,
    input  wire ni_types_pkg::nmu_aw_request_t                  s_aw_i,
    input  wire logic                                           s_aw_valid_i,
    output wire logic                                           s_aw_ready_o,
    input  wire ni_signals_pkg::noc_axi_w_t                     s_w_i,
    input  wire logic                                           s_w_valid_i,
    output wire logic                                           s_w_ready_o,
    input  wire ni_types_pkg::nmu_ar_request_t                  s_ar_i,
    input  wire logic                                           s_ar_valid_i,
    output wire logic                                           s_ar_ready_o,
    output wire noc_payload_pkg::req_flit_t                         m_req_o,
    output wire logic                                           m_req_valid_o,
    input  wire logic                                           m_req_ready_i,
    output wire noc_payload_pkg::dat_flit_t                         m_dat_o,
    output wire logic                                           m_dat_valid_o,
    input  wire logic                                           m_dat_ready_i
);
    import ni_types_pkg::*;

    wire noc_payload_pkg::req_flit_t [NUM_NMU_REQ_CH-1:0] req_flit;
    wire noc_payload_pkg::dat_flit_t [NUM_NMU_DAT_CH-1:0] dat_flit;
    wire                         [NUM_NMU_REQ_CH-1:0] req_valid, req_ready;
    wire                         [NUM_NMU_DAT_CH-1:0] dat_valid, dat_ready;
    wire ni_types_pkg::nmu_aw_request_t packet_aw, packet_w_aw;
    wire ni_signals_pkg::noc_axi_w_t packet_w;
    wire logic packet_aw_valid, packet_aw_ready, packet_w_valid, packet_w_ready;
    wire logic [noc_payload_pkg::AXI_LEN_WIDTH-1:0] packet_w_beat;
    nmu_write_context i_write_context (
        .clk_i        (clk_i          ),
        .rst_n_i      (rst_n_i        ),
        .s_aw_i       (s_aw_i         ),
        .s_aw_valid_i (s_aw_valid_i   ),
        .s_aw_ready_o (s_aw_ready_o   ),
        .m_aw_o       (packet_aw      ),
        .m_aw_valid_o (packet_aw_valid),
        .m_aw_ready_i (packet_aw_ready),
        .s_w_i        (s_w_i          ),
        .s_w_valid_i  (s_w_valid_i    ),
        .s_w_ready_o  (s_w_ready_o    ),
        .m_w_o        (packet_w       ),
        .m_w_valid_o  (packet_w_valid ),
        .m_w_ready_i  (packet_w_ready ),
        .m_w_aw_o     (packet_w_aw    ),
        .m_w_beat_o   (packet_w_beat  )
    );
    nmu_request_packetize #(
        .REQ_AW_REG_TYPE (REQ_AW_REG_TYPE),
        .REQ_W_REG_TYPE  (REQ_W_REG_TYPE ),
        .REQ_AR_REG_TYPE (REQ_AR_REG_TYPE),
        .DAT_AW_REG_TYPE (DAT_AW_REG_TYPE),
        .DAT_W_REG_TYPE  (DAT_W_REG_TYPE ),
        .SRC_ID          (SRC_ID         ),
        .SRC_PORT_ID     (SRC_PORT_ID    )
    ) i_packetize (
        .clk_i         (clk_i          ),
        .rst_n_i       (rst_n_i        ),
        .s_aw_i        (packet_aw      ),
        .s_aw_valid_i  (packet_aw_valid),
        .s_aw_ready_o  (packet_aw_ready),
        .s_w_aw_i      (packet_w_aw    ),
        .s_w_beat_i    (packet_w_beat  ),
        .s_w_i         (packet_w       ),
        .s_w_valid_i   (packet_w_valid ),
        .s_w_ready_o   (packet_w_ready ),
        .s_ar_i        (s_ar_i         ),
        .s_ar_valid_i  (s_ar_valid_i   ),
        .s_ar_ready_o  (s_ar_ready_o   ),
        .m_req_o       (req_flit       ),
        .m_req_valid_o (req_valid      ),
        .m_req_ready_i (req_ready      ),
        .m_dat_o       (dat_flit       ),
        .m_dat_valid_o (dat_valid      ),
        .m_dat_ready_i (dat_ready      )
    );
    nmu_request_dispatch i_request_dispatch (
        .clk_i         (clk_i             ),
        .rst_n_i       (rst_n_i           ),
        .s_req_i       (req_flit          ),
        .s_req_valid_i (req_valid         ),
        .s_req_ready_o (req_ready         ),
        .s_dat_i       (dat_flit          ),
        .s_dat_valid_i (dat_valid         ),
        .s_dat_ready_o (dat_ready         ),
        .m_req_o       (m_req_o      ),
        .m_req_valid_o (m_req_valid_o),
        .m_req_ready_i (m_req_ready_i),
        .m_dat_o       (m_dat_o      ),
        .m_dat_valid_o (m_dat_valid_o),
        .m_dat_ready_i (m_dat_ready_i)
    );
endmodule
`resetall
