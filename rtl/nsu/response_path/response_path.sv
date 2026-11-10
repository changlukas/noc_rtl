// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nsu_response_path #(
    // 0: synchronous FIFO (common clock), 1: asynchronous FIFO.
    parameter int unsigned FIFO_TYPE         = 1,
    parameter int unsigned OUTPUT_ID_WIDTH   = noc_unit_params_pkg::NSU_AXI_ID_WIDTH,
    parameter int unsigned AXI_FIFO_DEPTH    = 32,
    parameter int unsigned B_FIFO_DEPTH      = AXI_FIFO_DEPTH,
    parameter int unsigned R_FIFO_DEPTH      = AXI_FIFO_DEPTH,
    parameter int unsigned AW_CONTEXT_DEPTH  = noc_unit_params_pkg::NSU_MAX_OUTSTANDING,
    parameter int unsigned AR_CONTEXT_DEPTH  = noc_unit_params_pkg::NSU_MAX_OUTSTANDING,
    parameter int unsigned RSP_REG_TYPE      = 1,
    parameter int unsigned DAT_REG_TYPE      = 1,
    parameter int unsigned B_REG_TYPE        = 0,
    parameter int unsigned R_REG_TYPE        = 0,

    parameter type b_t = ni_signals_pkg::noc_axi_b_t,
    parameter type r_t = ni_signals_pkg::noc_axi_r_t,

    parameter logic [ni_types_pkg::NODE_ID_W-1:0]      SRC_ID      = '0,
    parameter logic [noc_header_pkg::PORT_ID_WIDTH-1:0] SRC_PORT_ID = '0
) (
    input  wire logic                                                                axi_clk_i,
    input  wire logic                                                                axi_rst_n_i,
    input  wire logic                                                                noc_clk_i,
    input  wire logic                                                                noc_rst_n_i,
    input  wire ni_types_pkg::nsu_aw_request_t                                       s_aw_context_i,
    input  wire logic                                                                s_aw_context_valid_i,
    output wire logic                                                                s_aw_context_ready_o,
    output wire logic                                          [OUTPUT_ID_WIDTH-1:0] awid_o,
    input  wire ni_types_pkg::nsu_ar_request_t                                       s_ar_context_i,
    input  wire logic                                                                s_ar_context_valid_i,
    output wire logic                                                                s_ar_context_ready_o,
    output wire logic                                          [OUTPUT_ID_WIDTH-1:0] arid_o,
    output wire ni_types_pkg::nsu_w_context_t                                        w_context_o,
    output wire logic                                                                w_context_valid_o,
    output wire logic                           [noc_payload_pkg::AXI_LEN_WIDTH-1:0] w_beat_o,
    input  wire logic                                                                w_accept_i,
    input  wire logic                                                                w_last_i,
    output wire logic                                                                tx_rsp_valid_o,
    output wire logic                          [noc_payload_pkg::RSP_FLIT_WIDTH-1:0] tx_rsp_flit_o,
    input  wire logic                                                                tx_rsp_ready_i,
    output wire logic                                                                tx_dat_valid_o,
    input  wire logic                                                                tx_dat_ready_i,
    output wire logic                          [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] tx_dat_flit_o,
    axi_if.wr_mst axi_wr_o,
    axi_if.rd_mst axi_rd_o
);
    import ni_types_pkg::*;
    wire b_t axi_b = '{
        bid: axi_wr_o.bid,
        bresp: axi_wr_o.bresp,
        buser: axi_wr_o.BUSER_EN ? $bits(axi_b.buser)'(axi_wr_o.buser) : '0
    };
    wire r_t axi_r = '{
        rid: axi_rd_o.rid,
        rdata: axi_rd_o.rdata,
        rresp: axi_rd_o.rresp,
        rlast: axi_rd_o.rlast,
        ruser: axi_rd_o.RUSER_EN ? $bits(axi_r.ruser)'(axi_rd_o.ruser) : '0
    };
    wire                  b_t fifo_b;
    wire                  r_t fifo_r;
    wire                  fifo_b_valid, fifo_b_ready, fifo_r_valid, fifo_r_ready;
    wire                  nsu_b_response_t decoded_b;
    wire                  nsu_r_response_t decoded_r;
    wire                  decoded_b_valid, decoded_b_ready, decoded_r_valid, decoded_r_ready;
    wire                  noc_payload_pkg::rsp_flit_t packet_b, assigned_rsp, tx_rsp;
    wire                  noc_payload_pkg::dat_flit_t packet_r, assigned_dat, tx_dat;
    wire                  packet_b_valid, packet_b_ready, packet_r_valid, packet_r_ready;
    wire                  assigned_rsp_valid, assigned_rsp_ready, assigned_dat_valid;
    wire assigned_dat_ready;
    assign tx_rsp_flit_o = tx_rsp_valid_o ? tx_rsp : '0;
    assign tx_dat_flit_o = tx_dat_valid_o ? tx_dat : '0;
    nsu_response_fifo #(
        .FIFO_TYPE      (FIFO_TYPE),
        .AXI_FIFO_DEPTH (AXI_FIFO_DEPTH),
        .B_FIFO_DEPTH   (B_FIFO_DEPTH  ),
        .R_FIFO_DEPTH   (R_FIFO_DEPTH  ),
        .b_t            (b_t           ),
        .r_t            (r_t           )
    ) i_response_fifo (
        .axi_clk_i   (axi_clk_i      ),
        .axi_rst_n_i (axi_rst_n_i    ),
        .noc_clk_i   (noc_clk_i      ),
        .noc_rst_n_i (noc_rst_n_i    ),
        .s_b_data_i  (axi_b          ),
        .s_b_valid_i (axi_wr_o.bvalid),
        .s_b_ready_o (axi_wr_o.bready),
        .m_b_data_o  (fifo_b         ),
        .m_b_valid_o (fifo_b_valid   ),
        .m_b_ready_i (fifo_b_ready   ),
        .s_r_data_i  (axi_r          ),
        .s_r_valid_i (axi_rd_o.rvalid),
        .s_r_ready_o (axi_rd_o.rready),
        .m_r_data_o  (fifo_r         ),
        .m_r_valid_o (fifo_r_valid   ),
        .m_r_ready_i (fifo_r_ready   )
    );
    nsu_context_buffer #(
        .OUTPUT_ID_WIDTH  (OUTPUT_ID_WIDTH ),
        .AW_CONTEXT_DEPTH (AW_CONTEXT_DEPTH),
        .AR_CONTEXT_DEPTH (AR_CONTEXT_DEPTH),
        .b_t              (b_t             ),
        .r_t              (r_t             )
    ) i_context_buffer (
        .clk_i               (noc_clk_i           ),
        .rst_n_i             (noc_rst_n_i         ),
        .s_aw_i              (s_aw_context_i      ),
        .s_aw_valid_i        (s_aw_context_valid_i),
        .s_aw_ready_o        (s_aw_context_ready_o),
        .m_awid_o            (awid_o              ),
        .s_ar_i              (s_ar_context_i      ),
        .s_ar_valid_i        (s_ar_context_valid_i),
        .s_ar_ready_o        (s_ar_context_ready_o),
        .m_arid_o            (arid_o              ),
        .m_w_context_o       (w_context_o         ),
        .m_w_context_valid_o (w_context_valid_o   ),
        .m_w_beat_o          (w_beat_o            ),
        .w_accept_i          (w_accept_i          ),
        .w_last_i            (w_last_i            ),
        .s_b_i               (fifo_b              ),
        .s_b_valid_i         (fifo_b_valid        ),
        .s_b_ready_o         (fifo_b_ready        ),
        .s_r_i               (fifo_r              ),
        .s_r_valid_i         (fifo_r_valid        ),
        .s_r_ready_o         (fifo_r_ready        ),
        .m_b_o               (decoded_b           ),
        .m_b_valid_o         (decoded_b_valid     ),
        .m_b_ready_i         (decoded_b_ready     ),
        .m_r_o               (decoded_r           ),
        .m_r_valid_o         (decoded_r_valid     ),
        .m_r_ready_i         (decoded_r_ready     )
    );
    nsu_response_packetize #(
        .B_REG_TYPE  (B_REG_TYPE ),
        .R_REG_TYPE  (R_REG_TYPE ),
        .SRC_ID      (SRC_ID     ),
        .SRC_PORT_ID (SRC_PORT_ID)
    ) i_packetize (
        .clk_i       (noc_clk_i      ),
        .rst_n_i     (noc_rst_n_i    ),
        .s_b_i       (decoded_b      ),
        .s_b_valid_i (decoded_b_valid),
        .s_b_ready_o (decoded_b_ready),
        .s_r_i       (decoded_r      ),
        .s_r_valid_i (decoded_r_valid),
        .s_r_ready_o (decoded_r_ready),
        .m_b_o       (packet_b       ),
        .m_b_valid_o (packet_b_valid ),
        .m_b_ready_i (packet_b_ready ),
        .m_r_o       (packet_r       ),
        .m_r_valid_o (packet_r_valid ),
        .m_r_ready_i (packet_r_ready )
    );
    nsu_response_dispatch i_response_dispatch (
        .clk_i         (noc_clk_i         ),
        .rst_n_i       (noc_rst_n_i       ),
        .s_b_i         (packet_b          ),
        .s_b_valid_i   (packet_b_valid    ),
        .s_b_ready_o   (packet_b_ready    ),
        .s_r_i         (packet_r          ),
        .s_r_valid_i   (packet_r_valid    ),
        .s_r_ready_o   (packet_r_ready    ),
        .m_rsp_o       (assigned_rsp      ),
        .m_rsp_valid_o (assigned_rsp_valid),
        .m_rsp_ready_i (assigned_rsp_ready),
        .m_dat_o       (assigned_dat      ),
        .m_dat_valid_o (assigned_dat_valid),
        .m_dat_ready_i (assigned_dat_ready)
    );
    stream_register #(
        .REG_TYPE (RSP_REG_TYPE),
        .data_t   (noc_payload_pkg::rsp_flit_t)
    ) i_rsp_register (
        .clk_i     (noc_clk_i),
        .rst_n_i   (noc_rst_n_i),
        .s_valid_i (assigned_rsp_valid),
        .s_ready_o (assigned_rsp_ready),
        .s_data_i  (assigned_rsp),
        .m_valid_o (tx_rsp_valid_o),
        .m_ready_i (tx_rsp_ready_i),
        .m_data_o  (tx_rsp)
    );
    stream_register #(
        .REG_TYPE (DAT_REG_TYPE),
        .data_t   (noc_payload_pkg::dat_flit_t)
    ) i_dat_register (
        .clk_i     (noc_clk_i),
        .rst_n_i   (noc_rst_n_i),
        .s_valid_i (assigned_dat_valid),
        .s_ready_o (assigned_dat_ready),
        .s_data_i  (assigned_dat),
        .m_valid_o (tx_dat_valid_o),
        .m_ready_i (tx_dat_ready_i),
        .m_data_o  (tx_dat)
    );

endmodule

`resetall
