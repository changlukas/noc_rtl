// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nsu_request_path #(
    // 0: synchronous FIFO (common clock), 1: asynchronous FIFO.
    parameter int unsigned FIFO_TYPE         = 1,
    parameter int unsigned OUTPUT_ID_WIDTH   = noc_unit_params_pkg::NSU_AXI_ID_WIDTH,
    parameter int unsigned AXI_FIFO_DEPTH    = 32,
    parameter int unsigned AW_FIFO_DEPTH     = AXI_FIFO_DEPTH,
    parameter int unsigned W_FIFO_DEPTH      = AXI_FIFO_DEPTH,
    parameter int unsigned AR_FIFO_DEPTH     = AXI_FIFO_DEPTH,
    parameter int unsigned REQ_REG_TYPE      = 1,
    parameter int unsigned DAT_REG_TYPE      = 1,
    parameter int unsigned AW_REG_TYPE       = 0,
    parameter int unsigned W_REG_TYPE        = 0,
    parameter int unsigned AR_REG_TYPE       = 0,

    parameter type aw_t = ni_signals_pkg::noc_axi_aw_t,
    parameter type ar_t = ni_signals_pkg::noc_axi_ar_t,

    parameter int unsigned SAM_NUM_RULES     = topology_pkg::SAM_NUM_RULES,

    parameter type addr_t         = topology_pkg::sam_addr_t,
    parameter type sam_mask_sel_t = topology_pkg::sam_mask_sel_t,
    parameter type sam_result_t   = topology_pkg::sam_result_t,
    parameter type sam_rule_t     = topology_pkg::sam_rule_t,

    parameter sam_rule_t [SAM_NUM_RULES-1:0]        SAM    = topology_pkg::SAM,
    parameter logic [ni_types_pkg::NODE_ID_W-1:0] SRC_ID = '0
) (
    input  wire logic                                                                axi_clk_i,
    input  wire logic                                                                axi_rst_n_i,
    input  wire logic                                                                noc_clk_i,
    input  wire logic                                                                noc_rst_n_i,
    output wire ni_types_pkg::nsu_aw_request_t                                       m_aw_context_o,
    output wire logic                                                                m_aw_context_valid_o,
    input  wire logic                                                                m_aw_context_ready_i,
    input  wire logic                                          [OUTPUT_ID_WIDTH-1:0] awid_i,
    output wire ni_types_pkg::nsu_ar_request_t                                       m_ar_context_o,
    output wire logic                                                                m_ar_context_valid_o,
    input  wire logic                                                                m_ar_context_ready_i,
    input  wire logic                                          [OUTPUT_ID_WIDTH-1:0] arid_i,
    input  wire ni_types_pkg::nsu_w_context_t                                        w_context_i,
    input  wire logic                                                                w_context_valid_i,
    input  wire logic                           [noc_payload_pkg::AXI_LEN_WIDTH-1:0] w_beat_i,
    output wire logic                                                                w_accept_o,
    output wire logic                                                                w_last_o,
    input  wire logic                                                                rx_req_valid_i,
    input  wire logic                          [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] rx_req_flit_i,
    output wire logic                                                                rx_req_ready_o,
    input  wire logic                                                                rx_dat_valid_i,
    output wire logic                                                                rx_dat_ready_o,
    input  wire logic                          [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] rx_dat_flit_i,
    axi_if.wr_mst axi_wr_o,
    axi_if.rd_mst axi_rd_o
);

    // DAT valid is ready-qualified; bypass would feed dispatch ready back to valid.
    if (DAT_REG_TYPE < 1 || DAT_REG_TYPE > 2) begin : gen_invalid_dat_reg_type
        initial $fatal(0, "DAT RX requires register type 1 or 2 (instance %m)");
    end
    import ni_types_pkg::*;
    wire                                              noc_payload_pkg::req_flit_t rx_req_head;
    wire                                              noc_payload_pkg::dat_flit_t rx_dat_head;
    wire                                              rx_req_valid, rx_req_ready;
    wire                                               rx_dat_valid, rx_dat_ready;
    wire                                              noc_payload_pkg::dat_flit_t selected_aw, selected_w;
    wire                                              noc_payload_pkg::req_flit_t selected_ar;
    wire                                              selected_aw_valid, selected_aw_ready, selected_w_valid, selected_w_ready;
    wire                                              selected_ar_valid, selected_ar_ready;
    wire                                              nsu_aw_request_t decoded_aw;
    wire                                              nsu_ar_request_t decoded_ar;
    wire ni_signals_pkg::noc_axi_w_t                  decoded_w;
    wire                                              decoded_aw_valid, decoded_aw_ready, decoded_ar_valid, decoded_ar_ready;
    wire                                              decoded_w_valid, decoded_w_ready;
    aw_t axi_aw;
    ar_t axi_ar;
    wire                              aw_t fifo_aw;
    wire                              ar_t fifo_ar;
    wire ni_signals_pkg::noc_axi_w_t  fifo_w;
    wire                              axi_aw_ready, axi_ar_ready, fifo_aw_valid, fifo_w_valid, fifo_ar_valid;
    assign m_aw_context_o       = decoded_aw;
    assign m_aw_context_valid_o = decoded_aw_valid && axi_aw_ready;
    assign decoded_aw_ready     = m_aw_context_ready_i && axi_aw_ready;
    assign m_ar_context_o       = decoded_ar;
    assign m_ar_context_valid_o = decoded_ar_valid && axi_ar_ready;
    assign decoded_ar_ready     = m_ar_context_ready_i && axi_ar_ready;
    always_comb begin
        axi_aw          = '0;
        axi_ar          = '0;
        axi_aw.awid     = awid_i;
        axi_aw.awaddr   = $bits(axi_aw.awaddr)'(decoded_aw.axi.awaddr);
        axi_aw.awlen    = $bits(axi_aw.awlen)'(decoded_aw.axi.awlen);
        axi_aw.awsize   = $bits(axi_aw.awsize)'(decoded_aw.axi.awsize);
        axi_aw.awburst  = $bits(axi_aw.awburst)'(decoded_aw.axi.awburst);
        axi_aw.awcache  = $bits(axi_aw.awcache)'(decoded_aw.axi.awcache);
        axi_aw.awlock   = $bits(axi_aw.awlock)'(decoded_aw.axi.awlock);
        axi_aw.awprot   = $bits(axi_aw.awprot)'(decoded_aw.axi.awprot);
        axi_aw.awregion = $bits(axi_aw.awregion)'(decoded_aw.axi.awregion);
        axi_aw.awqos    = $bits(axi_aw.awqos)'(decoded_aw.axi.awqos);
        axi_aw.awuser   = $bits(axi_aw.awuser)'(decoded_aw.axi.awuser);
        axi_ar.arid     = arid_i;
        axi_ar.araddr   = $bits(axi_ar.araddr)'(decoded_ar.axi.araddr);
        axi_ar.arlen    = $bits(axi_ar.arlen)'(decoded_ar.axi.arlen);
        axi_ar.arsize   = $bits(axi_ar.arsize)'(decoded_ar.axi.arsize);
        axi_ar.arburst  = $bits(axi_ar.arburst)'(decoded_ar.axi.arburst);
        axi_ar.arcache  = $bits(axi_ar.arcache)'(decoded_ar.axi.arcache);
        axi_ar.arlock   = $bits(axi_ar.arlock)'(decoded_ar.axi.arlock);
        axi_ar.arprot   = $bits(axi_ar.arprot)'(decoded_ar.axi.arprot);
        axi_ar.arregion = $bits(axi_ar.arregion)'(decoded_ar.axi.arregion);
        axi_ar.arqos    = $bits(axi_ar.arqos)'(decoded_ar.axi.arqos);
        axi_ar.aruser   = $bits(axi_ar.aruser)'(decoded_ar.axi.aruser);
    end
    assign axi_wr_o.awid     = fifo_aw_valid ? fifo_aw.awid : '0;
    assign axi_wr_o.awaddr   = fifo_aw_valid ? fifo_aw.awaddr : '0;
    assign axi_wr_o.awlen    = fifo_aw_valid ? fifo_aw.awlen : '0;
    assign axi_wr_o.awsize   = fifo_aw_valid ? fifo_aw.awsize : '0;
    assign axi_wr_o.awburst  = fifo_aw_valid ? fifo_aw.awburst : '0;
    assign axi_wr_o.awcache  = fifo_aw_valid ? fifo_aw.awcache : '0;
    assign axi_wr_o.awlock   = fifo_aw_valid ? fifo_aw.awlock : '0;
    assign axi_wr_o.awprot   = fifo_aw_valid ? fifo_aw.awprot : '0;
    assign axi_wr_o.awregion = fifo_aw_valid ? fifo_aw.awregion : '0;
    assign axi_wr_o.awqos    = fifo_aw_valid ? fifo_aw.awqos : '0;
    assign axi_wr_o.awuser   = fifo_aw_valid ? fifo_aw.awuser : '0;
    assign axi_wr_o.awvalid  = fifo_aw_valid;
    assign axi_rd_o.arid     = fifo_ar_valid ? fifo_ar.arid : '0;
    assign axi_rd_o.araddr   = fifo_ar_valid ? fifo_ar.araddr : '0;
    assign axi_rd_o.arlen    = fifo_ar_valid ? fifo_ar.arlen : '0;
    assign axi_rd_o.arsize   = fifo_ar_valid ? fifo_ar.arsize : '0;
    assign axi_rd_o.arburst  = fifo_ar_valid ? fifo_ar.arburst : '0;
    assign axi_rd_o.arcache  = fifo_ar_valid ? fifo_ar.arcache : '0;
    assign axi_rd_o.arlock   = fifo_ar_valid ? fifo_ar.arlock : '0;
    assign axi_rd_o.arprot   = fifo_ar_valid ? fifo_ar.arprot : '0;
    assign axi_rd_o.arregion = fifo_ar_valid ? fifo_ar.arregion : '0;
    assign axi_rd_o.arqos    = fifo_ar_valid ? fifo_ar.arqos : '0;
    assign axi_rd_o.arvalid  = fifo_ar_valid;
    assign axi_rd_o.aruser   = axi_rd_o.ARUSER_EN && fifo_ar_valid ? $bits(axi_rd_o.aruser)'(fifo_ar.aruser) : '0;
    assign axi_wr_o.wdata    = fifo_w_valid ? fifo_w.wdata : '0;
    assign axi_wr_o.wstrb    = fifo_w_valid ? fifo_w.wstrb : '0;
    assign axi_wr_o.wlast    = fifo_w_valid && fifo_w.wlast;
    assign axi_wr_o.wuser    = axi_wr_o.WUSER_EN && fifo_w_valid ? $bits(axi_wr_o.wuser)'(fifo_w.wuser) : '0;
    assign axi_wr_o.wvalid   = fifo_w_valid;
    stream_register #(
        .REG_TYPE (REQ_REG_TYPE),
        .data_t   (noc_payload_pkg::req_flit_t)
    ) i_req_register (
        .clk_i     (noc_clk_i),
        .rst_n_i   (noc_rst_n_i),
        .s_valid_i (rx_req_valid_i),
        .s_ready_o (rx_req_ready_o),
        .s_data_i  (rx_req_flit_i),
        .m_valid_o (rx_req_valid),
        .m_ready_i (rx_req_ready),
        .m_data_o  (rx_req_head)
    );
    stream_register #(
        .REG_TYPE (DAT_REG_TYPE),
        .data_t   (noc_payload_pkg::dat_flit_t)
    ) i_dat_register (
        .clk_i     (noc_clk_i),
        .rst_n_i   (noc_rst_n_i),
        .s_valid_i (rx_dat_valid_i),
        .s_ready_o (rx_dat_ready_o),
        .s_data_i  (rx_dat_flit_i),
        .m_valid_o (rx_dat_valid),
        .m_ready_i (rx_dat_ready),
        .m_data_o  (rx_dat_head)
    );
    // synthesis translate_off
    rx_dat_stall: cover property (@(posedge noc_clk_i) disable iff (!noc_rst_n_i)
        rx_dat_valid && !rx_dat_ready);
    // synthesis translate_on
    nsu_request_dispatch i_request_dispatch (
        .clk_i             (noc_clk_i),
        .rst_n_i           (noc_rst_n_i),
        .s_req_i           (rx_req_head),
        .s_req_valid_i     (rx_req_valid),
        .s_req_ready_o     (rx_req_ready),
        .s_dat_i           (rx_dat_head),
        .s_dat_valid_i     (rx_dat_valid),
        .s_dat_ready_o     (rx_dat_ready),
        .w_context_i       (w_context_i),
        .w_context_valid_i (w_context_valid_i),
        .m_aw_o            (selected_aw),
        .m_aw_valid_o      (selected_aw_valid),
        .m_aw_ready_i      (selected_aw_ready),
        .m_w_o             (selected_w),
        .m_w_valid_o       (selected_w_valid),
        .m_w_ready_i       (selected_w_ready),
        .m_ar_o            (selected_ar),
        .m_ar_valid_o      (selected_ar_valid),
        .m_ar_ready_i      (selected_ar_ready)
    );
    nsu_request_depacketize #(
        .AW_REG_TYPE    (AW_REG_TYPE   ),
        .W_REG_TYPE     (W_REG_TYPE    ),
        .AR_REG_TYPE    (AR_REG_TYPE   ),
        .SAM_NUM_RULES  (SAM_NUM_RULES ),
        .addr_t         (addr_t        ),
        .sam_mask_sel_t (sam_mask_sel_t),
        .sam_result_t   (sam_result_t  ),
        .sam_rule_t     (sam_rule_t    ),
        .SAM            (SAM           ),
        .SRC_ID         (SRC_ID        )
    ) i_depacketize (
        .clk_i        (noc_clk_i        ),
        .rst_n_i      (noc_rst_n_i      ),
        .s_aw_i       (selected_aw      ),
        .s_aw_valid_i (selected_aw_valid),
        .s_aw_ready_o (selected_aw_ready),
        .s_w_i        (selected_w       ),
        .s_w_valid_i  (selected_w_valid ),
        .s_w_ready_o  (selected_w_ready ),
        .s_ar_i       (selected_ar      ),
        .s_ar_valid_i (selected_ar_valid),
        .s_ar_ready_o (selected_ar_ready),
        .w_context_i  (w_context_i      ),
        .w_beat_i     (w_beat_i         ),
        .w_accept_o   (w_accept_o       ),
        .w_last_o     (w_last_o         ),
        .m_aw_o       (decoded_aw       ),
        .m_aw_valid_o (decoded_aw_valid ),
        .m_aw_ready_i (decoded_aw_ready ),
        .m_w_o        (decoded_w        ),
        .m_w_valid_o  (decoded_w_valid  ),
        .m_w_ready_i  (decoded_w_ready  ),
        .m_ar_o       (decoded_ar       ),
        .m_ar_valid_o (decoded_ar_valid ),
        .m_ar_ready_i (decoded_ar_ready )
    );
    nsu_request_fifo #(
        .FIFO_TYPE      (FIFO_TYPE),
        .AXI_FIFO_DEPTH (AXI_FIFO_DEPTH             ),
        .AXI_ID_WIDTH   (OUTPUT_ID_WIDTH            ),
        .AW_FIFO_DEPTH  (AW_FIFO_DEPTH              ),
        .W_FIFO_DEPTH   (W_FIFO_DEPTH               ),
        .AR_FIFO_DEPTH  (AR_FIFO_DEPTH              ),
        .aw_t           (aw_t                       ),
        .w_t            (ni_signals_pkg::noc_axi_w_t),
        .ar_t           (ar_t                       )
    ) i_request_fifo (
        .axi_clk_i    (axi_clk_i                               ),
        .axi_rst_n_i  (axi_rst_n_i                             ),
        .noc_clk_i    (noc_clk_i                               ),
        .noc_rst_n_i  (noc_rst_n_i                             ),
        .s_aw_data_i  (axi_aw                                  ),
        .s_aw_valid_i (decoded_aw_valid && m_aw_context_ready_i),
        .s_aw_ready_o (axi_aw_ready                            ),
        .m_aw_data_o  (fifo_aw                                 ),
        .m_aw_valid_o (fifo_aw_valid                           ),
        .m_aw_ready_i (axi_wr_o.awready                        ),
        .s_w_data_i   (decoded_w                               ),
        .s_w_valid_i  (decoded_w_valid                         ),
        .s_w_ready_o  (decoded_w_ready                         ),
        .m_w_data_o   (fifo_w                                  ),
        .m_w_valid_o  (fifo_w_valid                            ),
        .m_w_ready_i  (axi_wr_o.wready                         ),
        .s_ar_data_i  (axi_ar                                  ),
        .s_ar_valid_i (decoded_ar_valid && m_ar_context_ready_i),
        .s_ar_ready_o (axi_ar_ready                            ),
        .m_ar_data_o  (fifo_ar                                 ),
        .m_ar_valid_o (fifo_ar_valid                           ),
        .m_ar_ready_i (axi_rd_o.arready                        )
    );
endmodule

`resetall
