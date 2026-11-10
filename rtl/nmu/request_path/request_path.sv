// SPDX-License-Identifier: Apache-2.0

`resetall
`timescale 1ns / 1ps
`default_nettype none

// Original-ID request transport. Ordering is supplied by the response path.
module nmu_request_path #(
    // 0: synchronous FIFO (common clock), 1: asynchronous FIFO.
    parameter int unsigned FIFO_TYPE         = 1,
    parameter int unsigned INPUT_ID_WIDTH    = noc_payload_pkg::AXI_ID_WIDTH,
    parameter int unsigned OUTPUT_ID_WIDTH   = noc_payload_pkg::NOC_ID_WIDTH,
    parameter int unsigned AXI_ADDR_WIDTH    = noc_payload_pkg::AXI_ADDR_WIDTH,
    parameter int unsigned AXI_DATA_WIDTH    = noc_payload_pkg::DATA_WIDTH,
    parameter int unsigned AXI_AWUSER_WIDTH  = noc_payload_pkg::AXI_AWUSER_WIDTH,
    parameter int unsigned AXI_FIFO_DEPTH    = 32,
    parameter int unsigned REQ_REG_TYPE      = 1,
    parameter int unsigned DAT_REG_TYPE      = 1,
    parameter int unsigned AW_FIFO_DEPTH     = AXI_FIFO_DEPTH,
    parameter int unsigned W_FIFO_DEPTH      = AXI_FIFO_DEPTH,
    parameter int unsigned AR_FIFO_DEPTH     = AXI_FIFO_DEPTH,
    parameter int unsigned REQ_AW_REG_TYPE   = 0,
    parameter int unsigned REQ_W_REG_TYPE    = 0,
    parameter int unsigned REQ_AR_REG_TYPE   = 0,
    parameter int unsigned DAT_AW_REG_TYPE   = 0,
    parameter int unsigned DAT_W_REG_TYPE    = 0,
    parameter int unsigned AW_SAM_REG_TYPE   = 0,
    parameter int unsigned AR_SAM_REG_TYPE   = 0,
    parameter int unsigned SAM_NUM_RULES,
    parameter type addr_t,
    parameter type sam_mask_sel_t,
    parameter type sam_result_t,
    parameter type sam_rule_t,
    parameter sam_rule_t [SAM_NUM_RULES-1:0] SAM,
    parameter logic [ni_types_pkg::NODE_ID_W-1:0]      SRC_ID      = '0,
    parameter logic [noc_header_pkg::PORT_ID_WIDTH-1:0] SRC_PORT_ID = '0
) (
    input  wire logic  axi_clk_i,
    input  wire logic  axi_rst_n_i,
    input  wire logic  noc_clk_i,
    input  wire logic  noc_rst_n_i,
    axi_if.wr_slv                                                                         axi_wr_i,
    axi_if.rd_slv                                                                         axi_rd_i,
    output wire ni_types_pkg::nmu_sam_aw_result_t                                       m_aw_o,
    output wire logic                                                                   m_aw_valid_o,
    input  wire logic                                                                   m_aw_ready_i,
    output wire ni_signals_pkg::noc_axi_w_t                                             m_w_o,
    output wire logic                                                                   m_w_valid_o,
    input  wire logic                                                                   m_w_ready_i,
    output wire ni_types_pkg::nmu_sam_ar_result_t                                       m_ar_o,
    output wire logic                                                                   m_ar_valid_o,
    input  wire logic                                                                   m_ar_ready_i,
    input  wire ni_types_pkg::nmu_aw_request_t                                          s_ordered_aw_i,
    input  wire logic                                                                   s_ordered_aw_valid_i,
    output wire logic                                                                   s_ordered_aw_ready_o,
    input  wire ni_signals_pkg::noc_axi_w_t                                             s_ordered_w_i,
    input  wire logic                                                                   s_ordered_w_valid_i,
    output wire logic                                                                   s_ordered_w_ready_o,
    input  wire ni_types_pkg::nmu_ar_request_t                                          s_ordered_ar_i,
    input  wire logic                                                                   s_ordered_ar_valid_i,
    output wire logic                                                                   s_ordered_ar_ready_o,
    input  wire ni_signals_pkg::noc_axi_b_t                                             s_b_i,
    input  wire logic                                                                   s_b_valid_i,
    output wire logic                                                                   s_b_ready_o,
    input  wire ni_signals_pkg::noc_axi_r_t                                             s_r_i,
    input  wire logic                                                                   s_r_valid_i,
    output wire logic                                                                   s_r_ready_o,
    output wire logic                                                                   tx_req_valid_o,
    output wire logic                             [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] tx_req_flit_o,
    input  wire logic                                                                   tx_req_ready_i,
    output wire logic                                                                   tx_dat_valid_o,
    input  wire logic                                                                   tx_dat_ready_i,
    output wire logic                             [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] tx_dat_flit_o
);
    import ni_types_pkg::*;

    if (INPUT_ID_WIDTH > OUTPUT_ID_WIDTH) begin : gen_invalid_id_width
        initial $fatal(0, "Error: NoC ID width must preserve the source AXI ID (instance %m)");
    end

    ni_signals_pkg::noc_axi_aw_t axi_aw;
    ni_signals_pkg::noc_axi_w_t  axi_w;
    ni_signals_pkg::noc_axi_ar_t axi_ar;
    wire                     axi_aw_ready, axi_w_ready, axi_ar_ready;
    noc_payload_pkg::req_flit_t  tx_req;
    noc_payload_pkg::dat_flit_t  tx_dat;

    wire ni_signals_pkg::noc_axi_aw_t fifo_aw;
    wire logic                    fifo_aw_valid;
    wire logic                    fifo_aw_ready;
    wire ni_signals_pkg::noc_axi_ar_t fifo_ar;
    wire logic                    fifo_ar_valid;
    wire logic                    fifo_ar_ready;

    always_comb begin
        axi_aw          = '0;
        axi_ar          = '0;
        axi_w           = '0;
        axi_aw.awid     = $bits(axi_aw.awid)'(axi_wr_i.awid);
        axi_aw.awaddr   = $bits(axi_aw.awaddr)'(axi_wr_i.awaddr);
        axi_aw.awlen    = $bits(axi_aw.awlen)'(axi_wr_i.awlen);
        axi_aw.awsize   = $bits(axi_aw.awsize)'(axi_wr_i.awsize);
        axi_aw.awburst  = $bits(axi_aw.awburst)'(axi_wr_i.awburst);
        axi_aw.awlock   = $bits(axi_aw.awlock)'(axi_wr_i.awlock);
        axi_aw.awcache  = $bits(axi_aw.awcache)'(axi_wr_i.awcache);
        axi_aw.awprot   = $bits(axi_aw.awprot)'(axi_wr_i.awprot);
        axi_aw.awqos    = $bits(axi_aw.awqos)'(axi_wr_i.awqos);
        axi_aw.awregion = $bits(axi_aw.awregion)'(axi_wr_i.awregion);
        axi_aw.awuser   = $bits(axi_aw.awuser)'(axi_wr_i.awuser);
        axi_ar.arid     = $bits(axi_ar.arid)'(axi_rd_i.arid);
        axi_ar.araddr   = $bits(axi_ar.araddr)'(axi_rd_i.araddr);
        axi_ar.arlen    = $bits(axi_ar.arlen)'(axi_rd_i.arlen);
        axi_ar.arsize   = $bits(axi_ar.arsize)'(axi_rd_i.arsize);
        axi_ar.arburst  = $bits(axi_ar.arburst)'(axi_rd_i.arburst);
        axi_ar.arlock   = $bits(axi_ar.arlock)'(axi_rd_i.arlock);
        axi_ar.arcache  = $bits(axi_ar.arcache)'(axi_rd_i.arcache);
        axi_ar.arprot   = $bits(axi_ar.arprot)'(axi_rd_i.arprot);
        axi_ar.arqos    = $bits(axi_ar.arqos)'(axi_rd_i.arqos);
        axi_ar.arregion = $bits(axi_ar.arregion)'(axi_rd_i.arregion);
        axi_ar.aruser   = axi_rd_i.ARUSER_EN ? $bits(axi_ar.aruser)'(axi_rd_i.aruser) : '0;
        axi_w.wdata     = axi_wr_i.wdata;
        axi_w.wstrb     = axi_wr_i.wstrb;
        axi_w.wlast     = axi_wr_i.wlast;
        axi_w.wuser     = axi_wr_i.WUSER_EN ? $bits(axi_w.wuser)'(axi_wr_i.wuser) : '0;
    end
    assign axi_wr_i.awready = axi_aw_ready;
    assign axi_wr_i.wready  = axi_w_ready;
    assign axi_rd_i.arready = axi_ar_ready;
    assign axi_wr_i.bid     = s_b_valid_i ? INPUT_ID_WIDTH'(s_b_i.bid) : '0;
    assign axi_wr_i.bresp   = s_b_valid_i ? s_b_i.bresp : '0;
    assign axi_wr_i.buser   = axi_wr_i.BUSER_EN && s_b_valid_i ? $bits(axi_wr_i.buser)'(s_b_i.buser) : '0;
    assign axi_wr_i.bvalid  = s_b_valid_i;
    assign s_b_ready_o      = axi_wr_i.bready;
    assign axi_rd_i.rid     = s_r_valid_i ? INPUT_ID_WIDTH'(s_r_i.rid) : '0;
    assign axi_rd_i.rdata   = s_r_valid_i ? s_r_i.rdata : '0;
    assign axi_rd_i.rresp   = s_r_valid_i ? s_r_i.rresp : '0;
    assign axi_rd_i.rlast   = s_r_valid_i && s_r_i.rlast;
    assign axi_rd_i.ruser   = axi_rd_i.RUSER_EN && s_r_valid_i ? $bits(axi_rd_i.ruser)'(s_r_i.ruser) : '0;
    assign axi_rd_i.rvalid  = s_r_valid_i;
    assign s_r_ready_o      = axi_rd_i.rready;
    nmu_request_fifo #(
        .FIFO_TYPE      (FIFO_TYPE),
        .AXI_FIFO_DEPTH (AXI_FIFO_DEPTH              ),
        .AXI_ID_WIDTH   (OUTPUT_ID_WIDTH             ),
        .aw_t           (ni_signals_pkg::noc_axi_aw_t),
        .w_t            (ni_signals_pkg::noc_axi_w_t ),
        .ar_t           (ni_signals_pkg::noc_axi_ar_t),
        .AW_FIFO_DEPTH  (AW_FIFO_DEPTH               ),
        .W_FIFO_DEPTH   (W_FIFO_DEPTH                ),
        .AR_FIFO_DEPTH  (AR_FIFO_DEPTH               )
    ) i_request_fifo (
        .axi_clk_i    (axi_clk_i       ),
        .axi_rst_n_i  (axi_rst_n_i     ),
        .noc_clk_i    (noc_clk_i       ),
        .noc_rst_n_i  (noc_rst_n_i     ),
        .s_aw_valid_i (axi_wr_i.awvalid),
        .s_aw_ready_o (axi_aw_ready    ),
        .s_aw_data_i  (axi_aw          ),
        .m_aw_valid_o (fifo_aw_valid   ),
        .m_aw_ready_i (fifo_aw_ready   ),
        .m_aw_data_o  (fifo_aw         ),
        .s_w_valid_i  (axi_wr_i.wvalid ),
        .s_w_ready_o  (axi_w_ready     ),
        .s_w_data_i   (axi_w           ),
        .m_w_valid_o  (m_w_valid_o     ),
        .m_w_ready_i  (m_w_ready_i     ),
        .m_w_data_o   (m_w_o           ),
        .s_ar_valid_i (axi_rd_i.arvalid),
        .s_ar_ready_o (axi_ar_ready    ),
        .s_ar_data_i  (axi_ar          ),
        .m_ar_valid_o (fifo_ar_valid   ),
        .m_ar_ready_i (fifo_ar_ready   ),
        .m_ar_data_o  (fifo_ar         )
    );

    nmu_sam #(
        .AW_SAM_REG_TYPE (AW_SAM_REG_TYPE),
        .AR_SAM_REG_TYPE (AR_SAM_REG_TYPE),
        .SAM_NUM_RULES   (SAM_NUM_RULES  ),
        .addr_t          (addr_t         ),
        .sam_mask_sel_t  (sam_mask_sel_t ),
        .sam_result_t    (sam_result_t   ),
        .sam_rule_t      (sam_rule_t     ),
        .SAM             (SAM            )
    ) i_sam (
        .noc_clk_i    (noc_clk_i    ),
        .noc_rst_n_i  (noc_rst_n_i  ),
        .s_aw_valid_i (fifo_aw_valid),
        .s_aw_ready_o (fifo_aw_ready),
        .s_aw_i       (fifo_aw      ),
        .m_aw_valid_o (m_aw_valid_o ),
        .m_aw_ready_i (m_aw_ready_i ),
        .m_aw_o       (m_aw_o       ),
        .s_ar_valid_i (fifo_ar_valid),
        .s_ar_ready_o (fifo_ar_ready),
        .s_ar_i       (fifo_ar      ),
        .m_ar_valid_o (m_ar_valid_o ),
        .m_ar_ready_i (m_ar_ready_i ),
        .m_ar_o       (m_ar_o       )
    );

    wire noc_payload_pkg::req_flit_t [NUM_NMU_REQ_CH-1:0] req_flit;
    wire noc_payload_pkg::dat_flit_t [NUM_NMU_DAT_CH-1:0] dat_flit;
    wire                         [NUM_NMU_REQ_CH-1:0] req_valid, req_ready;
    wire                         [NUM_NMU_DAT_CH-1:0] dat_valid, dat_ready;
    wire ni_types_pkg::nmu_aw_request_t packet_aw, packet_w_aw;
    wire ni_signals_pkg::noc_axi_w_t packet_w;
    wire logic packet_aw_valid, packet_aw_ready, packet_w_valid, packet_w_ready;
    wire logic [noc_payload_pkg::AXI_LEN_WIDTH-1:0] packet_w_beat;
    nmu_write_context i_write_context (
        .clk_i        (noc_clk_i           ),
        .rst_n_i      (noc_rst_n_i         ),
        .s_aw_i       (s_ordered_aw_i      ),
        .s_aw_valid_i (s_ordered_aw_valid_i),
        .s_aw_ready_o (s_ordered_aw_ready_o),
        .m_aw_o       (packet_aw           ),
        .m_aw_valid_o (packet_aw_valid     ),
        .m_aw_ready_i (packet_aw_ready     ),
        .s_w_i        (s_ordered_w_i       ),
        .s_w_valid_i  (s_ordered_w_valid_i ),
        .s_w_ready_o  (s_ordered_w_ready_o ),
        .m_w_o        (packet_w            ),
        .m_w_valid_o  (packet_w_valid      ),
        .m_w_ready_i  (packet_w_ready      ),
        .m_w_aw_o     (packet_w_aw         ),
        .m_w_beat_o   (packet_w_beat       )
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
        .clk_i         (noc_clk_i           ),
        .rst_n_i       (noc_rst_n_i         ),
        .s_aw_i        (packet_aw           ),
        .s_aw_valid_i  (packet_aw_valid     ),
        .s_aw_ready_o  (packet_aw_ready     ),
        .s_w_aw_i      (packet_w_aw         ),
        .s_w_beat_i    (packet_w_beat       ),
        .s_w_i         (packet_w            ),
        .s_w_valid_i   (packet_w_valid      ),
        .s_w_ready_o   (packet_w_ready      ),
        .s_ar_i        (s_ordered_ar_i      ),
        .s_ar_valid_i  (s_ordered_ar_valid_i),
        .s_ar_ready_o  (s_ordered_ar_ready_o),
        .m_req_o       (req_flit            ),
        .m_req_valid_o (req_valid           ),
        .m_req_ready_i (req_ready           ),
        .m_dat_o       (dat_flit            ),
        .m_dat_valid_o (dat_valid           ),
        .m_dat_ready_i (dat_ready           )
    );
    wire noc_payload_pkg::req_flit_t assigned_req;
    wire noc_payload_pkg::dat_flit_t assigned_dat;
    wire assigned_req_valid, assigned_req_ready, assigned_dat_valid;
    wire assigned_dat_ready;
    nmu_request_dispatch i_request_dispatch (
        .clk_i         (noc_clk_i         ),
        .rst_n_i       (noc_rst_n_i       ),
        .s_req_i       (req_flit          ),
        .s_req_valid_i (req_valid         ),
        .s_req_ready_o (req_ready         ),
        .s_dat_i       (dat_flit          ),
        .s_dat_valid_i (dat_valid         ),
        .s_dat_ready_o (dat_ready         ),
        .m_req_o       (assigned_req      ),
        .m_req_valid_o (assigned_req_valid),
        .m_req_ready_i (assigned_req_ready),
        .m_dat_o       (assigned_dat      ),
        .m_dat_valid_o (assigned_dat_valid),
        .m_dat_ready_i (assigned_dat_ready)
    );
    stream_register #(
        .REG_TYPE (REQ_REG_TYPE),
        .data_t   (noc_payload_pkg::req_flit_t)
    ) i_req_register (
        .clk_i     (noc_clk_i         ),
        .rst_n_i   (noc_rst_n_i       ),
        .s_valid_i (assigned_req_valid),
        .s_ready_o (assigned_req_ready),
        .s_data_i  (assigned_req      ),
        .m_valid_o (tx_req_valid_o    ),
        .m_ready_i (tx_req_ready_i    ),
        .m_data_o  (tx_req            )
    );
    stream_register #(
        .REG_TYPE (DAT_REG_TYPE),
        .data_t   (noc_payload_pkg::dat_flit_t)
    ) i_dat_register (
        .clk_i     (noc_clk_i         ),
        .rst_n_i   (noc_rst_n_i       ),
        .s_valid_i (assigned_dat_valid),
        .s_ready_o (assigned_dat_ready),
        .s_data_i  (assigned_dat      ),
        .m_valid_o (tx_dat_valid_o    ),
        .m_ready_i (tx_dat_ready_i    ),
        .m_data_o  (tx_dat            )
    );
    assign tx_req_flit_o = tx_req_valid_o ? tx_req : '0;
    assign tx_dat_flit_o = tx_dat_valid_o ? tx_dat : '0;

endmodule

`resetall
