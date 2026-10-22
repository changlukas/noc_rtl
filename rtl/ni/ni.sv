// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module ni #(
    parameter int unsigned                               NMU_INPUT_ID_WIDTH         = ni_params_pkg::AXI_ID_WIDTH,
    parameter int unsigned                               NMU_OUTPUT_ID_WIDTH        = ni_params_pkg::NOC_ID_WIDTH,
    parameter int unsigned                               NMU_AXI_ADDR_WIDTH         = ni_params_pkg::AXI_ADDR_WIDTH,
    parameter int unsigned                               NMU_AXI_DATA_WIDTH         = ni_params_pkg::AXI_DATA_WIDTH,
    parameter int unsigned                               NMU_AXI_AWUSER_WIDTH       = ni_params_pkg::AXI_AWUSER_WIDTH,
    parameter int unsigned                               NMU_AXI_FIFO_DEPTH         = 32,
    parameter int unsigned                               NUM_DAT_VC                 = ni_params_pkg::NUM_DAT_VC,
    localparam int unsigned                               NOC_DAT_VC_MODE            = (NUM_DAT_VC > 1),
    parameter int unsigned                               NMU_REQ_FIFO_DEPTH         = 32,
    parameter int unsigned                               NMU_AW_FIFO_DEPTH          = NMU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NMU_W_FIFO_DEPTH           = NMU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NMU_AR_FIFO_DEPTH          = NMU_AXI_FIFO_DEPTH,
    parameter int unsigned                               CREDIT_DEPTH               = ni_params_pkg::CREDIT_DEPTH,
    parameter int unsigned                               NMU_REQ_AW_REG_TYPE        = 0,
    parameter int unsigned                               NMU_REQ_W_REG_TYPE         = 0,
    parameter int unsigned                               NMU_REQ_AR_REG_TYPE        = 0,
    parameter int unsigned                               NMU_DAT_AW_REG_TYPE        = 0,
    parameter int unsigned                               NMU_DAT_W_REG_TYPE         = 0,
    parameter int unsigned                               NMU_RSP_FIFO_DEPTH         = 32,
    parameter int unsigned                               NMU_B_FIFO_DEPTH           = NMU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NMU_R_FIFO_DEPTH           = NMU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NMU_B_REG_TYPE             = 0,
    parameter int unsigned                               NMU_R_REG_TYPE             = 0,
    parameter int unsigned                               NMU_B_ROB_DEPTH            = ni_params_pkg::NMU_ROB_B_DEPTH,
    parameter int unsigned                               NMU_R_ROB_DEPTH            = ni_params_pkg::NMU_ROB_R_DEPTH,
    parameter bit                                        NMU_R_ROB_EN               = bit'(ni_params_pkg::NMU_R_ROB_EN),
    parameter int unsigned                               NMU_MAX_OUTSTANDING_PER_ID = ni_params_pkg::NMU_MAX_OUTSTANDING_PER_ID,
    parameter int unsigned                               NMU_AW_SAM_REG_TYPE        = 0,
    parameter int unsigned                               NMU_AR_SAM_REG_TYPE        = 0,
    parameter int unsigned                               SAM_NUM_RULES              = topology_pkg::SAM_NUM_RULES,
    parameter type                                       addr_t                     = topology_pkg::sam_addr_t,
    parameter type                                       sam_mask_sel_t             = topology_pkg::sam_mask_sel_t,
    parameter type                                       sam_result_t               = topology_pkg::sam_result_t,
    parameter type                                       sam_rule_t                 = topology_pkg::sam_rule_t,
    parameter sam_rule_t [SAM_NUM_RULES-1:0]             SAM                        = topology_pkg::SAM,
    parameter logic [ni_flit_pkg::SRC_ID_WIDTH-1:0]      SRC_ID                     = '0,
    parameter logic [ni_flit_pkg::SRC_PORT_ID_WIDTH-1:0] SRC_PORT_ID                = '0,
    parameter int unsigned                               NSU_INPUT_ID_WIDTH         = ni_params_pkg::NOC_ID_WIDTH,
    parameter int unsigned                               NSU_OUTPUT_ID_WIDTH        = ni_params_pkg::NSU_AXI_ID_WIDTH,
    parameter int unsigned                               NSU_AXI_FIFO_DEPTH         = 32,
    parameter int unsigned                               NSU_AW_FIFO_DEPTH          = NSU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NSU_W_FIFO_DEPTH           = NSU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NSU_AR_FIFO_DEPTH          = NSU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NSU_B_FIFO_DEPTH           = NSU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NSU_R_FIFO_DEPTH           = NSU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NSU_AW_CONTEXT_DEPTH       = ni_params_pkg::NSU_MAX_OUTSTANDING,
    parameter int unsigned                               NSU_AR_CONTEXT_DEPTH       = ni_params_pkg::NSU_MAX_OUTSTANDING,
    parameter int unsigned                               NSU_REQ_FIFO_DEPTH         = 32,
    parameter int unsigned                               NSU_RSP_FIFO_DEPTH         = 32,
    parameter int unsigned                               NSU_AW_REG_TYPE            = 0,
    parameter int unsigned                               NSU_W_REG_TYPE             = 0,
    parameter int unsigned                               NSU_AR_REG_TYPE            = 0,
    parameter int unsigned                               NSU_B_REG_TYPE             = 0,
    parameter int unsigned                               NSU_R_REG_TYPE             = 0,
    parameter int unsigned                               NSU_AXI_AWUSER_WIDTH       = ni_flit_pkg::AXI_USER_WIDTH
) (
    input  wire logic  ACLK,
    input  wire logic  ARESETn,
    input  wire logic  noc_clk,
    input  wire logic  noc_rst_n,
    axi_if.wr_slv axi_wr_i,
    axi_if.rd_slv axi_rd_i,
    axi_if.wr_mst axi_wr_o,
    axi_if.rd_mst axi_rd_o,
    output wire logic                                         tx_req_valid_o,
    output wire logic [ni_params_pkg::NOC_REQ_FLIT_WIDTH-1:0] tx_req_flit_o,
    input  wire logic                                         tx_req_ready_i,
    input  wire logic                                         rx_rsp_valid_i,
    input  wire logic [ni_params_pkg::NOC_RSP_FLIT_WIDTH-1:0] rx_rsp_flit_i,
    output wire logic                                         rx_rsp_ready_o,
    output wire logic                        [NUM_DAT_VC-1:0] tx_dat_valid_o,
    input  wire logic                        [NUM_DAT_VC-1:0] tx_dat_ready_i,
    output wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] tx_dat_flit_o,
    input  wire logic                        [NUM_DAT_VC-1:0] credit_i,
    input  wire logic                        [NUM_DAT_VC-1:0] rx_dat_valid_i,
    output wire logic                        [NUM_DAT_VC-1:0] rx_dat_ready_o,
    input  wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] rx_dat_flit_i,
    output wire logic                        [NUM_DAT_VC-1:0] credit_o,
    input  wire logic                                         rx_req_valid_i,
    input  wire logic [ni_params_pkg::NOC_REQ_FLIT_WIDTH-1:0] rx_req_flit_i,
    output wire logic                                         rx_req_ready_o,
    output wire logic                                         tx_rsp_valid_o,
    output wire logic [ni_params_pkg::NOC_RSP_FLIT_WIDTH-1:0] tx_rsp_flit_o,
    input  wire logic                                         tx_rsp_ready_i
);
    import ni_flit_pkg::*;
    wire dat_flit_t [1:0][NUM_DAT_VC-1:0] tx_dat;
    wire [1:0][NUM_DAT_VC-1:0] tx_valid, tx_ready;
    wire dat_flit_t [NUM_DAT_VC-1:0] rx_dat;
    wire [NUM_DAT_VC-1:0] rx_valid, rx_ready;
    wire [1:0][NUM_DAT_VC-1:0] rx_path_valid, rx_path_ready;
    for (genvar vc = 0; vc < NUM_DAT_VC; vc++) begin : gen_rx_demux
        wire is_read = rx_dat[vc].header[AXI_CH_LSB +: AXI_CH_WIDTH] == AXI_CH_WIDTH'(AXI_CH_DataR);
        assign rx_path_valid[0][vc] = rx_valid[vc] && is_read;
        assign rx_path_valid[1][vc] = rx_valid[vc] && !is_read;
        assign rx_ready[vc] = is_read ? rx_path_ready[0][vc] : rx_path_ready[1][vc];
    end

    nmu #(
        .EXTERNAL_DAT_LINK      (1'b1                      ),
        .INPUT_ID_WIDTH         (NMU_INPUT_ID_WIDTH        ),
        .OUTPUT_ID_WIDTH        (NMU_OUTPUT_ID_WIDTH       ),
        .AXI_ADDR_WIDTH         (NMU_AXI_ADDR_WIDTH        ),
        .AXI_DATA_WIDTH         (NMU_AXI_DATA_WIDTH        ),
        .AXI_AWUSER_WIDTH       (NMU_AXI_AWUSER_WIDTH      ),
        .AXI_FIFO_DEPTH         (NMU_AXI_FIFO_DEPTH        ),
        .NUM_DAT_VC             (NUM_DAT_VC                ),
        .REQ_FIFO_DEPTH         (NMU_REQ_FIFO_DEPTH        ),
        .AW_FIFO_DEPTH          (NMU_AW_FIFO_DEPTH         ),
        .W_FIFO_DEPTH           (NMU_W_FIFO_DEPTH          ),
        .AR_FIFO_DEPTH          (NMU_AR_FIFO_DEPTH         ),
        .CREDIT_DEPTH           (CREDIT_DEPTH              ),
        .REQ_AW_REG_TYPE        (NMU_REQ_AW_REG_TYPE       ),
        .REQ_W_REG_TYPE         (NMU_REQ_W_REG_TYPE        ),
        .REQ_AR_REG_TYPE        (NMU_REQ_AR_REG_TYPE       ),
        .DAT_AW_REG_TYPE        (NMU_DAT_AW_REG_TYPE       ),
        .DAT_W_REG_TYPE         (NMU_DAT_W_REG_TYPE        ),
        .RSP_FIFO_DEPTH         (NMU_RSP_FIFO_DEPTH        ),
        .B_FIFO_DEPTH           (NMU_B_FIFO_DEPTH          ),
        .R_FIFO_DEPTH           (NMU_R_FIFO_DEPTH          ),
        .B_REG_TYPE             (NMU_B_REG_TYPE            ),
        .R_REG_TYPE             (NMU_R_REG_TYPE            ),
        .B_ROB_DEPTH            (NMU_B_ROB_DEPTH           ),
        .R_ROB_DEPTH            (NMU_R_ROB_DEPTH           ),
        .R_ROB_EN               (NMU_R_ROB_EN              ),
        .MAX_OUTSTANDING_PER_ID (NMU_MAX_OUTSTANDING_PER_ID),
        .AW_SAM_REG_TYPE        (NMU_AW_SAM_REG_TYPE       ),
        .AR_SAM_REG_TYPE        (NMU_AR_SAM_REG_TYPE       ),
        .SAM_NUM_RULES          (SAM_NUM_RULES             ),
        .addr_t                 (addr_t                    ),
        .sam_mask_sel_t         (sam_mask_sel_t            ),
        .sam_result_t           (sam_result_t              ),
        .sam_rule_t             (sam_rule_t                ),
        .SAM                    (SAM                       ),
        .SRC_ID                 (SRC_ID                    ),
        .SRC_PORT_ID            (SRC_PORT_ID               )
    ) i_nmu (
        .tx_dat_vc_o       (tx_dat[0]       ),
        .tx_dat_vc_valid_o (tx_valid[0]     ),
        .tx_dat_vc_ready_i (tx_ready[0]     ),
        .rx_dat_vc_i       (rx_dat          ),
        .rx_dat_vc_valid_i (rx_path_valid[0]),
        .rx_dat_vc_ready_o (rx_path_ready[0]),
        .ACLK              (ACLK            ),
        .ARESETn           (ARESETn         ),
        .noc_clk           (noc_clk         ),
        .noc_rst_n         (noc_rst_n       ),
        .axi_wr_i          (axi_wr_i        ),
        .axi_rd_i          (axi_rd_i        ),
        .tx_req_valid_o    (tx_req_valid_o  ),
        .tx_req_flit_o     (tx_req_flit_o   ),
        .tx_req_ready_i    (tx_req_ready_i  ),
        .rx_rsp_valid_i    (rx_rsp_valid_i  ),
        .rx_rsp_flit_i     (rx_rsp_flit_i   ),
        .rx_rsp_ready_o    (rx_rsp_ready_o  ),
        .tx_dat_valid_o    (                ),
        .tx_dat_ready_i    ('0              ),
        .tx_dat_flit_o     (                ),
        .credit_i          ('0              ),
        .rx_dat_valid_i    ('0              ),
        .rx_dat_ready_o    (                ),
        .rx_dat_flit_i     ('0              ),
        .credit_o          (                )
    );

    nsu #(
        .EXTERNAL_DAT_LINK (1'b1                ),
        .INPUT_ID_WIDTH    (NSU_INPUT_ID_WIDTH  ),
        .OUTPUT_ID_WIDTH   (NSU_OUTPUT_ID_WIDTH ),
        .AXI_FIFO_DEPTH    (NSU_AXI_FIFO_DEPTH  ),
        .AW_FIFO_DEPTH     (NSU_AW_FIFO_DEPTH   ),
        .W_FIFO_DEPTH      (NSU_W_FIFO_DEPTH    ),
        .AR_FIFO_DEPTH     (NSU_AR_FIFO_DEPTH   ),
        .B_FIFO_DEPTH      (NSU_B_FIFO_DEPTH    ),
        .R_FIFO_DEPTH      (NSU_R_FIFO_DEPTH    ),
        .AW_CONTEXT_DEPTH  (NSU_AW_CONTEXT_DEPTH),
        .AR_CONTEXT_DEPTH  (NSU_AR_CONTEXT_DEPTH),
        .REQ_FIFO_DEPTH    (NSU_REQ_FIFO_DEPTH  ),
        .RSP_FIFO_DEPTH    (NSU_RSP_FIFO_DEPTH  ),
        .NUM_DAT_VC        (NUM_DAT_VC          ),
        .CREDIT_DEPTH      (CREDIT_DEPTH        ),
        .AW_REG_TYPE       (NSU_AW_REG_TYPE     ),
        .W_REG_TYPE        (NSU_W_REG_TYPE      ),
        .AR_REG_TYPE       (NSU_AR_REG_TYPE     ),
        .B_REG_TYPE        (NSU_B_REG_TYPE      ),
        .R_REG_TYPE        (NSU_R_REG_TYPE      ),
        .AXI_AWUSER_WIDTH  (NSU_AXI_AWUSER_WIDTH),
        .SAM_NUM_RULES     (SAM_NUM_RULES       ),
        .addr_t            (addr_t              ),
        .sam_mask_sel_t    (sam_mask_sel_t      ),
        .sam_result_t      (sam_result_t        ),
        .sam_rule_t        (sam_rule_t          ),
        .SAM               (SAM                 ),
        .SRC_ID            (SRC_ID              ),
        .SRC_PORT_ID       (SRC_PORT_ID         )
    ) i_nsu (
        .tx_dat_vc_o       (tx_dat[1]       ),
        .tx_dat_vc_valid_o (tx_valid[1]     ),
        .tx_dat_vc_ready_i (tx_ready[1]     ),
        .rx_dat_vc_i       (rx_dat          ),
        .rx_dat_vc_valid_i (rx_path_valid[1]),
        .rx_dat_vc_ready_o (rx_path_ready[1]),
        .ACLK              (ACLK            ),
        .ARESETn           (ARESETn         ),
        .noc_clk           (noc_clk         ),
        .noc_rst_n         (noc_rst_n       ),
        .rx_req_valid_i    (rx_req_valid_i  ),
        .rx_req_flit_i     (rx_req_flit_i   ),
        .rx_req_ready_o    (rx_req_ready_o  ),
        .rx_dat_valid_i    ('0              ),
        .rx_dat_ready_o    (                ),
        .rx_dat_flit_i     ('0              ),
        .credit_o          (                ),
        .tx_rsp_valid_o    (tx_rsp_valid_o  ),
        .tx_rsp_flit_o     (tx_rsp_flit_o   ),
        .tx_rsp_ready_i    (tx_rsp_ready_i  ),
        .tx_dat_valid_o    (                ),
        .tx_dat_ready_i    ('0              ),
        .tx_dat_flit_o     (                ),
        .credit_i          ('0              ),
        .axi_wr_o          (axi_wr_o        ),
        .axi_rd_o          (axi_rd_o        )
    );

    ni_dat_tx #(
        .NUM_DAT_VC   (NUM_DAT_VC  ),
        .CREDIT_DEPTH (CREDIT_DEPTH)
    ) i_dat_tx (
        .clk_i     (noc_clk       ),
        .rst_n_i   (noc_rst_n     ),
        .s_dat_i   (tx_dat        ),
        .s_valid_i (tx_valid      ),
        .s_ready_o (tx_ready      ),
        .m_dat_o   (tx_dat_flit_o ),
        .m_valid_o (tx_dat_valid_o),
        .m_ready_i (tx_dat_ready_i),
        .credit_i  (credit_i      )
    );
    // Only the DAT bank is used here; unused control storage is eliminated.
    rx_credit_buffer #(
        .CTRL_FIFO_DEPTH (1),
        .NUM_DAT_VC      (NUM_DAT_VC),
        .CREDIT_DEPTH    (CREDIT_DEPTH),
        .DAT_VC_MASK     ('1),
        .DAT_CH_MASK     ((1 << AXI_CH_DataAw) | (1 << AXI_CH_DataW) | (1 << AXI_CH_DataR))
    ) i_dat_rx (
        .clk_i          (noc_clk                   ),
        .rst_n_i        (noc_rst_n                 ),
        .s_ctrl_i       ('0                        ),
        .s_ctrl_valid_i (1'b0                      ),
        .s_ctrl_ready_o (                          ),
        .m_ctrl_o       (                          ),
        .m_ctrl_valid_o (                          ),
        .m_ctrl_ready_i (1'b0                      ),
        .s_dat_i        (dat_flit_t'(rx_dat_flit_i)),
        .s_dat_valid_i  (rx_dat_valid_i            ),
        .s_dat_ready_o  (rx_dat_ready_o            ),
        .credit_o       (credit_o                  ),
        .m_dat_o        (rx_dat                    ),
        .m_dat_valid_o  (rx_valid                  ),
        .m_dat_ready_i  (rx_ready                  )
    );
    // synthesis translate_off
    if (NOC_DAT_VC_MODE == 1) begin : gen_rx_vc_check
        wire dat_flit_t rx_flit = dat_flit_t'(rx_dat_flit_i);
        wire [AXI_CH_WIDTH-1:0] channel = rx_flit.header[AXI_CH_LSB +: AXI_CH_WIDTH];
        always @(posedge noc_clk) begin
            if (noc_rst_n && (|rx_dat_valid_i)) begin
                if (channel == AXI_CH_WIDTH'(AXI_CH_DataR)) begin
                    assert (!(|rx_dat_valid_i[NUM_DAT_VC/2-1:0])) else $fatal(1, "Read response on write VC");
                end else begin
                    assert (!(|rx_dat_valid_i[NUM_DAT_VC-1:NUM_DAT_VC/2])) else $fatal(1, "Write request on read VC");
                end
            end
        end
    end
    // synthesis translate_on

endmodule
`resetall
