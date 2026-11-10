// SPDX-License-Identifier: Apache-2.0

`resetall
`timescale 1ns / 1ps
`default_nettype none

// Network Master Unit production top-level interface and parameter contract.
module nmu #(
    // 0: synchronous FIFO (common clock), 1: asynchronous FIFO.
    parameter int unsigned FIFO_TYPE              = noc_unit_params_pkg::FIFO_TYPE,
    parameter int unsigned INPUT_ID_WIDTH         = noc_payload_pkg::AXI_ID_WIDTH,
    parameter int unsigned OUTPUT_ID_WIDTH        = noc_payload_pkg::NOC_ID_WIDTH,
    parameter int unsigned AXI_ADDR_WIDTH         = noc_payload_pkg::AXI_ADDR_WIDTH,
    parameter int unsigned AXI_DATA_WIDTH         = noc_payload_pkg::DATA_WIDTH,
    parameter int unsigned AXI_AWUSER_WIDTH       = noc_payload_pkg::AXI_AWUSER_WIDTH,
    parameter int unsigned AXI_FIFO_DEPTH         = 32,
    parameter int unsigned REQ_REG_TYPE           = 1,
    parameter int unsigned DAT_REG_TYPE           = 1,
    parameter int unsigned AW_FIFO_DEPTH          = AXI_FIFO_DEPTH,
    parameter int unsigned W_FIFO_DEPTH           = AXI_FIFO_DEPTH,
    parameter int unsigned AR_FIFO_DEPTH          = AXI_FIFO_DEPTH,
    parameter int unsigned RX_DAT_REG_TYPE        = 1,
    parameter int unsigned REQ_AW_REG_TYPE        = 0,
    parameter int unsigned REQ_W_REG_TYPE         = 0,
    parameter int unsigned REQ_AR_REG_TYPE        = 0,
    parameter int unsigned DAT_AW_REG_TYPE        = 0,
    parameter int unsigned DAT_W_REG_TYPE         = 0,
    parameter int unsigned RSP_REG_TYPE           = 1,
    parameter int unsigned B_FIFO_DEPTH           = AXI_FIFO_DEPTH,
    parameter int unsigned R_FIFO_DEPTH           = AXI_FIFO_DEPTH,
    parameter int unsigned B_REG_TYPE             = 0,
    parameter int unsigned R_REG_TYPE             = 0,
    parameter int unsigned B_ROB_DEPTH            = noc_unit_params_pkg::NMU_ROB_B_DEPTH,
    parameter int unsigned R_ROB_DEPTH            = noc_unit_params_pkg::NMU_ROB_R_DEPTH,
    parameter bit          R_ROB_EN               = bit'(noc_unit_params_pkg::NMU_R_ROB_EN),
    parameter int unsigned MAX_OUTSTANDING_PER_ID = noc_unit_params_pkg::NMU_MAX_OUTSTANDING_PER_ID,
    parameter int unsigned AW_SAM_REG_TYPE        = 0,
    parameter int unsigned AR_SAM_REG_TYPE        = 0,
    // Generated address map, shared with the simulation topology.
    parameter int unsigned                               SAM_NUM_RULES  = topology_pkg::SAM_NUM_RULES,
    parameter type                                       addr_t         = topology_pkg::sam_addr_t,
    parameter type                                       sam_mask_sel_t = topology_pkg::sam_mask_sel_t,
    parameter type                                       sam_result_t   = topology_pkg::sam_result_t,
    parameter type                                       sam_rule_t     = topology_pkg::sam_rule_t,
    parameter sam_rule_t [SAM_NUM_RULES-1:0]             SAM            = topology_pkg::SAM,
    parameter logic [ni_types_pkg::NODE_ID_W-1:0]      SRC_ID         = '0,
    parameter logic [noc_header_pkg::PORT_ID_WIDTH-1:0] SRC_PORT_ID    = '0
) (
    input  wire logic  ACLK,
    input  wire logic  ARESETn,
    input  wire logic  noc_clk,
    input  wire logic  noc_rst_n,

    axi_if.wr_slv                                             axi_wr_i,
    axi_if.rd_slv                                             axi_rd_i,

    output wire logic                                       TXREQVLD,
    output wire logic [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] TXREQ,
    input  wire logic                                       TXREQRDY,

    input  wire logic                                       RXRSPVLD,
    input  wire logic [noc_payload_pkg::RSP_FLIT_WIDTH-1:0] RXRSP,
    output wire logic                                       RXRSPRDY,

    output wire logic                                       TXDATVLD,
    input  wire logic                                       TXDATRDY,
    output wire logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] TXDAT,
    input  wire logic                                       RXDATVLD,
    output wire logic                                       RXDATRDY,
    input  wire logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] RXDAT
);

    localparam int unsigned NUM_IDS =
        1 << INPUT_ID_WIDTH;

    localparam int unsigned REQ_FLIT_W = $bits(noc_payload_pkg::req_flit_t);
    localparam int unsigned RSP_FLIT_W = $bits(noc_payload_pkg::rsp_flit_t);
    localparam int unsigned DAT_FLIT_W = $bits(noc_payload_pkg::dat_flit_t);

    if (INPUT_ID_WIDTH < 1 || INPUT_ID_WIDTH > 8) begin : gen_invalid_axi_id_width
        initial $fatal(0, "Error: INPUT_ID_WIDTH must be in [1, 8] (instance %m)");
    end

    if (OUTPUT_ID_WIDTH != noc_payload_pkg::NOC_ID_WIDTH || OUTPUT_ID_WIDTH < INPUT_ID_WIDTH) begin : gen_invalid_noc_id_width
        initial $fatal(0, "Error: OUTPUT_ID_WIDTH must match the generated fixed width (instance %m)");
    end

    if (AXI_ADDR_WIDTH != noc_payload_pkg::AXI_ADDR_WIDTH ||
            AXI_DATA_WIDTH != noc_payload_pkg::DATA_WIDTH ||
            AXI_AWUSER_WIDTH != noc_payload_pkg::AXI_AWUSER_WIDTH) begin : gen_invalid_axi_widths
        initial $fatal(0, "Error: AXI address/data/user widths must match the generated package (instance %m)");
    end

    if ((axi_rd_i.ARUSER_EN && $bits(axi_rd_i.aruser) != noc_payload_pkg::ARUSER_WIDTH) ||
            (axi_wr_i.WUSER_EN && $bits(axi_wr_i.wuser) != noc_payload_pkg::WUSER_WIDTH) ||
            (axi_wr_i.BUSER_EN && $bits(axi_wr_i.buser) != noc_payload_pkg::BUSER_WIDTH) ||
            (axi_rd_i.RUSER_EN && $bits(axi_rd_i.ruser) != noc_payload_pkg::RUSER_WIDTH)) begin : gen_invalid_user_width
        initial $fatal(0, "Error: enabled opaque USER widths must match native configuration (instance %m)");
    end

    if (AXI_FIFO_DEPTH < 2 || (AXI_FIFO_DEPTH & (AXI_FIFO_DEPTH - 1)) != 0) begin : gen_invalid_axi_fifo_depth
        initial $fatal(0, "Error: AXI_FIFO_DEPTH must be a power of two and at least 2 (instance %m)");
    end

    if (B_ROB_DEPTH < 1 || B_ROB_DEPTH > 256) begin : gen_invalid_rob_b_depth
        initial $fatal(0, "Error: B_ROB_DEPTH must be in [1, 256] (instance %m)");
    end

    if (R_ROB_DEPTH < 1 || R_ROB_DEPTH > 256) begin : gen_invalid_rob_r_depth
        initial $fatal(0, "Error: R_ROB_DEPTH must be in [1, 256] (instance %m)");
    end

    if (MAX_OUTSTANDING_PER_ID < 1 || MAX_OUTSTANDING_PER_ID > 256) begin : gen_invalid_max_txns_per_id
        initial $fatal(0, "Error: MAX_OUTSTANDING_PER_ID must be in [1, 256] (instance %m)");
    end

    if (AW_SAM_REG_TYPE > 2) begin : gen_invalid_aw_sam_reg_type
        initial $fatal(0, "Error: AW_SAM_REG_TYPE must be 0, 1, or 2 (instance %m)");
    end

    if (AR_SAM_REG_TYPE > 2) begin : gen_invalid_ar_sam_reg_type
        initial $fatal(0, "Error: AR_SAM_REG_TYPE must be 0, 1, or 2 (instance %m)");
    end

    if (REQ_FLIT_W != noc_payload_pkg::REQ_FLIT_WIDTH ||
            RSP_FLIT_W != noc_payload_pkg::RSP_FLIT_WIDTH ||
            DAT_FLIT_W != noc_payload_pkg::DAT_FLIT_WIDTH) begin : gen_invalid_flit_width
        initial $fatal(0, "Error: generated flit widths do not match the parameter package (instance %m)");
    end

    wire ni_types_pkg::nmu_sam_aw_result_t path_aw;
    wire logic                             path_aw_valid;
    wire logic                             path_aw_ready;
    wire ni_signals_pkg::noc_axi_w_t           path_w;
    wire logic                             path_w_valid;
    wire logic                             path_w_ready;
    wire ni_types_pkg::nmu_sam_ar_result_t path_ar;
    wire logic                             path_ar_valid;
    wire logic                             path_ar_ready;
    wire ni_types_pkg::nmu_aw_request_t    ordered_aw;
    wire logic                             ordered_aw_valid;
    wire logic                             ordered_aw_ready;
    wire ni_signals_pkg::noc_axi_w_t           ordered_w;
    wire logic                             ordered_w_valid;
    wire logic                             ordered_w_ready;
    wire ni_types_pkg::nmu_ar_request_t    ordered_ar;
    wire logic                             ordered_ar_valid;
    wire logic                             ordered_ar_ready;
    wire ni_signals_pkg::noc_axi_b_t           axi_b;
    wire logic                             axi_b_valid;
    wire logic                             axi_b_ready;
    wire ni_signals_pkg::noc_axi_r_t           axi_r;
    wire logic                             axi_r_valid;
    wire logic                             axi_r_ready;

    nmu_request_path #(
        .FIFO_TYPE         (FIFO_TYPE),
        .INPUT_ID_WIDTH    (INPUT_ID_WIDTH   ),
        .OUTPUT_ID_WIDTH   (OUTPUT_ID_WIDTH  ),
        .AXI_ADDR_WIDTH    (AXI_ADDR_WIDTH   ),
        .AXI_DATA_WIDTH    (AXI_DATA_WIDTH   ),
        .AXI_AWUSER_WIDTH  (AXI_AWUSER_WIDTH ),
        .AXI_FIFO_DEPTH    (AXI_FIFO_DEPTH   ),
        .REQ_REG_TYPE      (REQ_REG_TYPE     ),
        .DAT_REG_TYPE      (DAT_REG_TYPE     ),
        .AW_SAM_REG_TYPE   (AW_SAM_REG_TYPE  ),
        .AR_SAM_REG_TYPE   (AR_SAM_REG_TYPE  ),
        .SAM_NUM_RULES     (SAM_NUM_RULES    ),
        .addr_t            (addr_t           ),
        .sam_mask_sel_t    (sam_mask_sel_t   ),
        .sam_result_t      (sam_result_t     ),
        .sam_rule_t        (sam_rule_t       ),
        .SAM               (SAM              ),
        .SRC_ID            (SRC_ID           ),
        .SRC_PORT_ID       (SRC_PORT_ID      ),
        .AW_FIFO_DEPTH     (AW_FIFO_DEPTH    ),
        .W_FIFO_DEPTH      (W_FIFO_DEPTH     ),
        .AR_FIFO_DEPTH     (AR_FIFO_DEPTH    ),
        .REQ_AW_REG_TYPE   (REQ_AW_REG_TYPE  ),
        .REQ_W_REG_TYPE    (REQ_W_REG_TYPE   ),
        .REQ_AR_REG_TYPE   (REQ_AR_REG_TYPE  ),
        .DAT_AW_REG_TYPE   (DAT_AW_REG_TYPE  ),
        .DAT_W_REG_TYPE    (DAT_W_REG_TYPE   )
    ) i_request_path (
        .axi_clk_i            (ACLK             ),
        .axi_rst_n_i          (ARESETn          ),
        .noc_clk_i            (noc_clk          ),
        .noc_rst_n_i          (noc_rst_n        ),
        .m_aw_o               (path_aw          ),
        .m_aw_valid_o         (path_aw_valid    ),
        .m_aw_ready_i         (path_aw_ready    ),
        .m_w_o                (path_w           ),
        .m_w_valid_o          (path_w_valid     ),
        .m_w_ready_i          (path_w_ready     ),
        .m_ar_o               (path_ar          ),
        .m_ar_valid_o         (path_ar_valid    ),
        .m_ar_ready_i         (path_ar_ready    ),
        .s_ordered_aw_i       (ordered_aw       ),
        .s_ordered_aw_valid_i (ordered_aw_valid ),
        .s_ordered_aw_ready_o (ordered_aw_ready ),
        .s_ordered_w_i        (ordered_w        ),
        .s_ordered_w_valid_i  (ordered_w_valid  ),
        .s_ordered_w_ready_o  (ordered_w_ready  ),
        .s_ordered_ar_i       (ordered_ar       ),
        .s_ordered_ar_valid_i (ordered_ar_valid ),
        .s_ordered_ar_ready_o (ordered_ar_ready ),
        .s_b_i                (axi_b            ),
        .s_b_valid_i          (axi_b_valid      ),
        .s_b_ready_o          (axi_b_ready      ),
        .s_r_i                (axi_r            ),
        .s_r_valid_i          (axi_r_valid      ),
        .s_r_ready_o          (axi_r_ready      ),
        .axi_wr_i             (axi_wr_i         ),
        .axi_rd_i             (axi_rd_i         ),
        .tx_req_valid_o       (TXREQVLD   ),
        .tx_req_flit_o        (TXREQ    ),
        .tx_req_ready_i       (TXREQRDY   ),
        .tx_dat_valid_o       (TXDATVLD   ),
        .tx_dat_ready_i       (TXDATRDY   ),
        .tx_dat_flit_o        (TXDAT    )
    );
    nmu_response_path #(
        .FIFO_TYPE              (FIFO_TYPE),
        .DAT_REG_TYPE           (RX_DAT_REG_TYPE       ),
        .AXI_FIFO_DEPTH         (AXI_FIFO_DEPTH        ),
        .B_ROB_DEPTH            (B_ROB_DEPTH           ),
        .R_ROB_DEPTH            (R_ROB_DEPTH           ),
        .R_ROB_EN               (R_ROB_EN              ),
        .NUM_IDS                (NUM_IDS               ),
        .MAX_OUTSTANDING_PER_ID (MAX_OUTSTANDING_PER_ID),
        .RSP_REG_TYPE           (RSP_REG_TYPE          ),
        .B_FIFO_DEPTH           (B_FIFO_DEPTH          ),
        .R_FIFO_DEPTH           (R_FIFO_DEPTH          ),
        .B_REG_TYPE             (B_REG_TYPE            ),
        .R_REG_TYPE             (R_REG_TYPE            )
    ) i_response_path (
        .axi_clk_i            (ACLK             ),
        .axi_rst_n_i          (ARESETn          ),
        .noc_clk_i            (noc_clk          ),
        .noc_rst_n_i          (noc_rst_n        ),
        .s_aw_i               (path_aw          ),
        .s_aw_valid_i         (path_aw_valid    ),
        .s_aw_ready_o         (path_aw_ready    ),
        .s_w_i                (path_w           ),
        .s_w_valid_i          (path_w_valid     ),
        .s_w_ready_o          (path_w_ready     ),
        .s_ar_i               (path_ar          ),
        .s_ar_valid_i         (path_ar_valid    ),
        .s_ar_ready_o         (path_ar_ready    ),
        .m_ordered_aw_o       (ordered_aw       ),
        .m_ordered_aw_valid_o (ordered_aw_valid ),
        .m_ordered_aw_ready_i (ordered_aw_ready ),
        .m_ordered_w_o        (ordered_w        ),
        .m_ordered_w_valid_o  (ordered_w_valid  ),
        .m_ordered_w_ready_i  (ordered_w_ready  ),
        .m_ordered_ar_o       (ordered_ar       ),
        .m_ordered_ar_valid_o (ordered_ar_valid ),
        .m_ordered_ar_ready_i (ordered_ar_ready ),
        .m_b_o                (axi_b            ),
        .m_b_valid_o          (axi_b_valid      ),
        .m_b_ready_i          (axi_b_ready      ),
        .m_r_o                (axi_r            ),
        .m_r_valid_o          (axi_r_valid      ),
        .m_r_ready_i          (axi_r_ready      ),
        .rx_rsp_valid_i       (RXRSPVLD   ),
        .rx_rsp_flit_i        (RXRSP    ),
        .rx_rsp_ready_o       (RXRSPRDY   ),
        .rx_dat_valid_i       (RXDATVLD   ),
        .rx_dat_ready_o       (RXDATRDY   ),
        .rx_dat_flit_i        (RXDAT    )
    );

endmodule

`resetall
