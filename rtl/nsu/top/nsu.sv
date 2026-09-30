// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nsu #(
    parameter int unsigned INPUT_ID_WIDTH   = ni_params_pkg::NOC_ID_WIDTH,
    parameter int unsigned OUTPUT_ID_WIDTH  = ni_params_pkg::NSU_AXI_ID_WIDTH,
    parameter int unsigned AXI_FIFO_DEPTH   = 32,
    parameter int unsigned AW_FIFO_DEPTH    = AXI_FIFO_DEPTH,
    parameter int unsigned W_FIFO_DEPTH     = AXI_FIFO_DEPTH,
    parameter int unsigned AR_FIFO_DEPTH    = AXI_FIFO_DEPTH,
    parameter int unsigned B_FIFO_DEPTH     = AXI_FIFO_DEPTH,
    parameter int unsigned R_FIFO_DEPTH     = AXI_FIFO_DEPTH,
    parameter int unsigned AW_CONTEXT_DEPTH = ni_params_pkg::NSU_MAX_OUTSTANDING,
    parameter int unsigned AR_CONTEXT_DEPTH = ni_params_pkg::NSU_MAX_OUTSTANDING,
    parameter int unsigned REQ_FIFO_DEPTH   = 32,
    parameter int unsigned RSP_FIFO_DEPTH   = 32,
    parameter int unsigned NUM_DAT_VC       = ni_params_pkg::NUM_DAT_VC,
    parameter int unsigned NOC_DAT_VC_MODE  = ni_params_pkg::NOC_DAT_VC_MODE,
    parameter int unsigned CREDIT_DEPTH     = ni_params_pkg::CREDIT_DEPTH,
    parameter int unsigned AW_REG_TYPE      = 0,
    parameter int unsigned W_REG_TYPE       = 0,
    parameter int unsigned AR_REG_TYPE      = 0,
    parameter int unsigned B_REG_TYPE       = 0,
    parameter int unsigned R_REG_TYPE       = 0,
    parameter int unsigned AXI_AWUSER_WIDTH = ni_flit_pkg::AXI_USER_WIDTH,
    parameter int unsigned SAM_NUM_RULES    = topology_pkg::SAM_NUM_RULES,

    parameter type addr_t         = topology_pkg::sam_addr_t,
    parameter type sam_mask_sel_t = topology_pkg::sam_mask_sel_t,
    parameter type sam_result_t   = topology_pkg::sam_result_t,
    parameter type sam_rule_t     = topology_pkg::sam_rule_t,

    parameter sam_rule_t [SAM_NUM_RULES-1:0]             SAM         = topology_pkg::SAM,
    parameter logic [ni_flit_pkg::SRC_ID_WIDTH-1:0]      SRC_ID      = '0,
    parameter logic [ni_flit_pkg::SRC_PORT_ID_WIDTH-1:0] SRC_PORT_ID = '0
) (
    input  wire logic                                         ACLK,
    input  wire logic                                         ARESETn,
    input  wire logic                                         noc_clk,
    input  wire logic                                         noc_rst_n,
    input  wire logic                                         rx_req_valid_i,
    input  wire logic [ni_params_pkg::NOC_REQ_FLIT_WIDTH-1:0] rx_req_flit_i,
    output wire logic                                         rx_req_ready_o,
    input  wire logic                                         rx_dat_valid_i,
    input  wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] rx_dat_flit_i,
    output wire logic                        [NUM_DAT_VC-1:0] rx_dat_crdvalid_o,
    output wire logic                                         tx_rsp_valid_o,
    output wire logic [ni_params_pkg::NOC_RSP_FLIT_WIDTH-1:0] tx_rsp_flit_o,
    input  wire logic                                         tx_rsp_ready_i,
    output wire logic                                         tx_dat_valid_o,
    output wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] tx_dat_flit_o,
    input  wire logic                        [NUM_DAT_VC-1:0] tx_dat_crdvalid_i,
    axi_if.wr_mst axi_wr_o,
    axi_if.rd_mst axi_rd_o
);
    if (INPUT_ID_WIDTH != ni_params_pkg::NOC_ID_WIDTH ||
            OUTPUT_ID_WIDTH < 1 || OUTPUT_ID_WIDTH > 8) begin : gen_invalid_id_width
        initial $fatal(0, "Error: NSU ID widths do not match the interface contract (instance %m)");
    end
    if ($bits(axi_wr_o.awid) != OUTPUT_ID_WIDTH || $bits(axi_rd_o.arid) != OUTPUT_ID_WIDTH ||
            $bits(axi_wr_o.wdata) != ni_params_pkg::AXI_DATA_WIDTH ||
            $bits(axi_rd_o.rdata) != ni_params_pkg::AXI_DATA_WIDTH ||
            $bits(axi_wr_o.awaddr) != ni_params_pkg::AXI_ADDR_WIDTH ||
            $bits(axi_rd_o.araddr) != ni_params_pkg::AXI_ADDR_WIDTH ||
            $bits(axi_wr_o.awuser) != AXI_AWUSER_WIDTH ||
            AXI_AWUSER_WIDTH < ni_flit_pkg::AXI_USER_WIDTH) begin : gen_invalid_axi_width
        initial $fatal(0, "Error: NSU AXI interface width mismatch (instance %m)");
    end
    typedef struct packed {
        logic              [AXI_AWUSER_WIDTH-1:0] awuser;
        logic                               [3:0] awqos;
        logic                               [3:0] awregion;
        logic                               [2:0] awprot;
        logic                                     awlock;
        logic                               [3:0] awcache;
        logic                               [1:0] awburst;
        logic                               [2:0] awsize;
        logic                               [7:0] awlen;
        logic [ni_params_pkg::AXI_ADDR_WIDTH-1:0] awaddr;
        logic               [OUTPUT_ID_WIDTH-1:0] awid;
    } aw_t;
    typedef struct packed {
        logic                               [3:0] arqos;
        logic                               [3:0] arregion;
        logic                               [2:0] arprot;
        logic                                     arlock;
        logic                               [3:0] arcache;
        logic                               [1:0] arburst;
        logic                               [2:0] arsize;
        logic                               [7:0] arlen;
        logic [ni_params_pkg::AXI_ADDR_WIDTH-1:0] araddr;
        logic               [OUTPUT_ID_WIDTH-1:0] arid;
    } ar_t;
    typedef struct packed {
        logic                 [1:0] bresp;
        logic [OUTPUT_ID_WIDTH-1:0] bid;
    } b_t;
    typedef struct packed {
        logic [ni_params_pkg::AXI_DATA_WIDTH-1:0] rdata;
        logic                               [1:0] rresp;
        logic               [OUTPUT_ID_WIDTH-1:0] rid;
        logic                                     rlast;
    } r_t;
    wire ni_types_pkg::nsu_aw_request_t                                  aw_context;
    wire ni_types_pkg::nsu_ar_request_t                                  ar_context;
    wire ni_types_pkg::nsu_w_context_t                                   w_context;
    wire                                                                 aw_context_valid, aw_context_ready, ar_context_valid, ar_context_ready;
    wire                                                                 w_context_valid, w_accept, w_last;
    wire                                           [OUTPUT_ID_WIDTH-1:0] awid, arid;
    wire                                [ni_flit_pkg::AXI_LEN_WIDTH-1:0] w_beat;
    nsu_request_path #(
        .OUTPUT_ID_WIDTH (OUTPUT_ID_WIDTH),
        .AXI_FIFO_DEPTH  (AXI_FIFO_DEPTH ),
        .AW_FIFO_DEPTH   (AW_FIFO_DEPTH  ),
        .W_FIFO_DEPTH    (W_FIFO_DEPTH   ),
        .AR_FIFO_DEPTH   (AR_FIFO_DEPTH  ),
        .REQ_FIFO_DEPTH  (REQ_FIFO_DEPTH ),
        .NUM_DAT_VC      (NUM_DAT_VC     ),
        .NOC_DAT_VC_MODE (NOC_DAT_VC_MODE),
        .CREDIT_DEPTH    (CREDIT_DEPTH   ),
        .AW_REG_TYPE     (AW_REG_TYPE    ),
        .W_REG_TYPE      (W_REG_TYPE     ),
        .AR_REG_TYPE     (AR_REG_TYPE    ),
        .aw_t            (aw_t           ),
        .ar_t            (ar_t           ),
        .SAM_NUM_RULES   (SAM_NUM_RULES  ),
        .addr_t          (addr_t         ),
        .sam_mask_sel_t  (sam_mask_sel_t ),
        .sam_result_t    (sam_result_t   ),
        .sam_rule_t      (sam_rule_t     ),
        .SAM             (SAM            ),
        .SRC_ID          (SRC_ID         )
    ) i_request_path (
        .axi_clk_i            (ACLK             ),
        .axi_rst_n_i          (ARESETn          ),
        .noc_clk_i            (noc_clk          ),
        .noc_rst_n_i          (noc_rst_n        ),
        .axi_wr_o             (axi_wr_o         ),
        .axi_rd_o             (axi_rd_o         ),
        .rx_req_valid_i       (rx_req_valid_i   ),
        .rx_req_flit_i        (rx_req_flit_i    ),
        .rx_req_ready_o       (rx_req_ready_o   ),
        .rx_dat_valid_i       (rx_dat_valid_i   ),
        .rx_dat_flit_i        (rx_dat_flit_i    ),
        .rx_dat_crdvalid_o    (rx_dat_crdvalid_o),
        .m_aw_context_o       (aw_context       ),
        .m_aw_context_valid_o (aw_context_valid ),
        .m_aw_context_ready_i (aw_context_ready ),
        .awid_i               (awid             ),
        .m_ar_context_o       (ar_context       ),
        .m_ar_context_valid_o (ar_context_valid ),
        .m_ar_context_ready_i (ar_context_ready ),
        .arid_i               (arid             ),
        .w_context_i          (w_context        ),
        .w_context_valid_i    (w_context_valid  ),
        .w_beat_i             (w_beat           ),
        .w_accept_o           (w_accept         ),
        .w_last_o             (w_last           )
    );
    nsu_response_path #(
        .OUTPUT_ID_WIDTH  (OUTPUT_ID_WIDTH ),
        .AXI_FIFO_DEPTH   (AXI_FIFO_DEPTH  ),
        .B_FIFO_DEPTH     (B_FIFO_DEPTH    ),
        .R_FIFO_DEPTH     (R_FIFO_DEPTH    ),
        .AW_CONTEXT_DEPTH (AW_CONTEXT_DEPTH),
        .AR_CONTEXT_DEPTH (AR_CONTEXT_DEPTH),
        .RSP_FIFO_DEPTH   (RSP_FIFO_DEPTH  ),
        .NUM_DAT_VC       (NUM_DAT_VC      ),
        .NOC_DAT_VC_MODE  (NOC_DAT_VC_MODE ),
        .CREDIT_DEPTH     (CREDIT_DEPTH    ),
        .B_REG_TYPE       (B_REG_TYPE      ),
        .R_REG_TYPE       (R_REG_TYPE      ),
        .b_t              (b_t             ),
        .r_t              (r_t             ),
        .SRC_ID           (SRC_ID          ),
        .SRC_PORT_ID      (SRC_PORT_ID     )
    ) i_response_path (
        .axi_clk_i            (ACLK             ),
        .axi_rst_n_i          (ARESETn          ),
        .noc_clk_i            (noc_clk          ),
        .noc_rst_n_i          (noc_rst_n        ),
        .axi_wr_o             (axi_wr_o         ),
        .axi_rd_o             (axi_rd_o         ),
        .tx_rsp_valid_o       (tx_rsp_valid_o   ),
        .tx_rsp_flit_o        (tx_rsp_flit_o    ),
        .tx_rsp_ready_i       (tx_rsp_ready_i   ),
        .tx_dat_valid_o       (tx_dat_valid_o   ),
        .tx_dat_flit_o        (tx_dat_flit_o    ),
        .tx_dat_crdvalid_i    (tx_dat_crdvalid_i),
        .s_aw_context_i       (aw_context       ),
        .s_aw_context_valid_i (aw_context_valid ),
        .s_aw_context_ready_o (aw_context_ready ),
        .awid_o               (awid             ),
        .s_ar_context_i       (ar_context       ),
        .s_ar_context_valid_i (ar_context_valid ),
        .s_ar_context_ready_o (ar_context_ready ),
        .arid_o               (arid             ),
        .w_context_o          (w_context        ),
        .w_context_valid_o    (w_context_valid  ),
        .w_beat_o             (w_beat           ),
        .w_accept_i           (w_accept         ),
        .w_last_i             (w_last           )
    );
endmodule

`resetall
