// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module ni #(
    // 0: synchronous FIFO (common clock), 1: asynchronous FIFO.
    parameter int unsigned FIFO_TYPE                                                = noc_unit_params_pkg::FIFO_TYPE,
    parameter int unsigned                               NMU_INPUT_ID_WIDTH         = noc_payload_pkg::AXI_ID_WIDTH,
    parameter int unsigned                               NMU_OUTPUT_ID_WIDTH        = noc_payload_pkg::NOC_ID_WIDTH,
    parameter int unsigned                               NMU_AXI_ADDR_WIDTH         = noc_payload_pkg::AXI_ADDR_WIDTH,
    parameter int unsigned                               NMU_AXI_DATA_WIDTH         = noc_payload_pkg::DATA_WIDTH,
    parameter int unsigned                               NMU_AXI_AWUSER_WIDTH       = noc_payload_pkg::AXI_AWUSER_WIDTH,
    parameter int unsigned                               NMU_AXI_FIFO_DEPTH         = 32,
    parameter int unsigned                               NUM_DAT_VC                 = noc_unit_params_pkg::DAT_NUM_VC,
    parameter int unsigned                               NMU_REQ_REG_TYPE           = 1,
    parameter int unsigned                               NMU_DAT_REG_TYPE           = 1,
    parameter int unsigned                               NMU_AW_FIFO_DEPTH          = NMU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NMU_W_FIFO_DEPTH           = NMU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NMU_AR_FIFO_DEPTH          = NMU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NMU_RX_DAT_REG_TYPE        = 1,
    parameter int unsigned                               NSU_RX_DAT_REG_TYPE        = 1,
    parameter int unsigned                               NMU_REQ_AW_REG_TYPE        = 0,
    parameter int unsigned                               NMU_REQ_W_REG_TYPE         = 0,
    parameter int unsigned                               NMU_REQ_AR_REG_TYPE        = 0,
    parameter int unsigned                               NMU_DAT_AW_REG_TYPE        = 0,
    parameter int unsigned                               NMU_DAT_W_REG_TYPE         = 0,
    parameter int unsigned                               NMU_RSP_REG_TYPE           = 1,
    parameter int unsigned                               NMU_B_FIFO_DEPTH           = NMU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NMU_R_FIFO_DEPTH           = NMU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NMU_B_REG_TYPE             = 0,
    parameter int unsigned                               NMU_R_REG_TYPE             = 0,
    parameter int unsigned                               NMU_B_ROB_DEPTH            = noc_unit_params_pkg::NMU_ROB_B_DEPTH,
    parameter int unsigned                               NMU_R_ROB_DEPTH            = noc_unit_params_pkg::NMU_ROB_R_DEPTH,
    parameter bit                                        NMU_R_ROB_EN               = bit'(noc_unit_params_pkg::NMU_R_ROB_EN),
    parameter int unsigned                               NMU_MAX_OUTSTANDING_PER_ID = noc_unit_params_pkg::NMU_MAX_OUTSTANDING_PER_ID,
    parameter int unsigned                               NMU_AW_SAM_REG_TYPE        = 0,
    parameter int unsigned                               NMU_AR_SAM_REG_TYPE        = 0,
    parameter int unsigned                               SAM_NUM_RULES              = topology_pkg::SAM_NUM_RULES,
    parameter type                                       addr_t                     = topology_pkg::sam_addr_t,
    parameter type                                       sam_mask_sel_t             = topology_pkg::sam_mask_sel_t,
    parameter type                                       sam_result_t               = topology_pkg::sam_result_t,
    parameter type                                       sam_rule_t                 = topology_pkg::sam_rule_t,
    parameter sam_rule_t [SAM_NUM_RULES-1:0]             SAM                        = topology_pkg::SAM,
    parameter logic [ni_types_pkg::NODE_ID_W-1:0]      SRC_ID                     = '0,
    parameter logic [noc_header_pkg::PORT_ID_WIDTH-1:0] SRC_PORT_ID                = '0,
    parameter int unsigned                               NSU_INPUT_ID_WIDTH         = noc_payload_pkg::NOC_ID_WIDTH,
    parameter int unsigned                               NSU_OUTPUT_ID_WIDTH        = noc_unit_params_pkg::NSU_AXI_ID_WIDTH,
    parameter int unsigned                               NSU_AXI_FIFO_DEPTH         = 32,
    parameter int unsigned                               NSU_AW_FIFO_DEPTH          = NSU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NSU_W_FIFO_DEPTH           = NSU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NSU_AR_FIFO_DEPTH          = NSU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NSU_B_FIFO_DEPTH           = NSU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NSU_R_FIFO_DEPTH           = NSU_AXI_FIFO_DEPTH,
    parameter int unsigned                               NSU_AW_CONTEXT_DEPTH       = noc_unit_params_pkg::NSU_MAX_OUTSTANDING,
    parameter int unsigned                               NSU_AR_CONTEXT_DEPTH       = noc_unit_params_pkg::NSU_MAX_OUTSTANDING,
    parameter int unsigned                               NSU_REQ_REG_TYPE           = 1,
    parameter int unsigned                               NSU_RSP_REG_TYPE           = 1,
    parameter int unsigned                               NSU_DAT_REG_TYPE           = 1,
    parameter int unsigned                               NSU_AW_REG_TYPE            = 0,
    parameter int unsigned                               NSU_W_REG_TYPE             = 0,
    parameter int unsigned                               NSU_AR_REG_TYPE            = 0,
    parameter int unsigned                               NSU_B_REG_TYPE             = 0,
    parameter int unsigned                               NSU_R_REG_TYPE             = 0,
    parameter int unsigned                               NSU_AXI_AWUSER_WIDTH       = noc_payload_pkg::AWUSER_WIDTH
) (
    input  wire logic  ACLK,
    input  wire logic  ARESETn,
    input  wire logic  noc_clk,
    input  wire logic  noc_rst_n,
    axi_if.wr_slv axi_wr_i,
    axi_if.rd_slv axi_rd_i,
    axi_if.wr_mst axi_wr_o,
    axi_if.rd_mst axi_rd_o,
    output wire logic                                         TXREQVLD,
    output wire logic [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] TXREQ,
    input  wire logic                                         TXREQRDY,
    input  wire logic                                         RXRSPVLD,
    input  wire logic [noc_payload_pkg::RSP_FLIT_WIDTH-1:0] RXRSP,
    output wire logic                                         RXRSPRDY,
    output wire logic                        [NUM_DAT_VC-1:0] TXDATVLD,
    input  wire logic                        [NUM_DAT_VC-1:0] TXDATRDY,
    output wire logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] TXDAT,
    input  wire logic                        [NUM_DAT_VC-1:0] RXDATVLD,
    output wire logic                        [NUM_DAT_VC-1:0] RXDATRDY,
    input  wire logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] RXDAT,
    input  wire logic                                         RXREQVLD,
    input  wire logic [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] RXREQ,
    output wire logic                                         RXREQRDY,
    output wire logic                                         TXRSPVLD,
    output wire logic [noc_payload_pkg::RSP_FLIT_WIDTH-1:0] TXRSP,
    input  wire logic                                         TXRSPRDY
);
    initial begin
        if (NUM_DAT_VC != noc_unit_params_pkg::DAT_NUM_VC || NUM_DAT_VC != 2)
            $fatal(1, "NI requires the native two DAT classes (instance %m)");
    end

    // TX source 0 is NMU write; source 1 is NSU read.
    wire noc_payload_pkg::dat_flit_t [1:0] tx_dat;
    wire [1:0] tx_valid, tx_ready;

    nmu #(
        .FIFO_TYPE              (FIFO_TYPE),
        .INPUT_ID_WIDTH         (NMU_INPUT_ID_WIDTH        ),
        .OUTPUT_ID_WIDTH        (NMU_OUTPUT_ID_WIDTH       ),
        .AXI_ADDR_WIDTH         (NMU_AXI_ADDR_WIDTH        ),
        .AXI_DATA_WIDTH         (NMU_AXI_DATA_WIDTH        ),
        .AXI_AWUSER_WIDTH       (NMU_AXI_AWUSER_WIDTH      ),
        .AXI_FIFO_DEPTH         (NMU_AXI_FIFO_DEPTH        ),
        .REQ_REG_TYPE           (NMU_REQ_REG_TYPE          ),
        .DAT_REG_TYPE           (NMU_DAT_REG_TYPE          ),
        .AW_FIFO_DEPTH          (NMU_AW_FIFO_DEPTH         ),
        .W_FIFO_DEPTH           (NMU_W_FIFO_DEPTH          ),
        .AR_FIFO_DEPTH          (NMU_AR_FIFO_DEPTH         ),
        .RX_DAT_REG_TYPE        (NMU_RX_DAT_REG_TYPE       ),
        .REQ_AW_REG_TYPE        (NMU_REQ_AW_REG_TYPE       ),
        .REQ_W_REG_TYPE         (NMU_REQ_W_REG_TYPE        ),
        .REQ_AR_REG_TYPE        (NMU_REQ_AR_REG_TYPE       ),
        .DAT_AW_REG_TYPE        (NMU_DAT_AW_REG_TYPE       ),
        .DAT_W_REG_TYPE         (NMU_DAT_W_REG_TYPE        ),
        .RSP_REG_TYPE           (NMU_RSP_REG_TYPE          ),
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
        .ACLK              (ACLK            ),
        .ARESETn           (ARESETn         ),
        .noc_clk           (noc_clk         ),
        .noc_rst_n         (noc_rst_n       ),
        .axi_wr_i          (axi_wr_i        ),
        .axi_rd_i          (axi_rd_i        ),
        .TXREQVLD    (TXREQVLD  ),
        .TXREQ     (TXREQ   ),
        .TXREQRDY    (TXREQRDY  ),
        .RXRSPVLD    (RXRSPVLD  ),
        .RXRSP     (RXRSP   ),
        .RXRSPRDY    (RXRSPRDY  ),
        .TXDATVLD    (tx_valid[0]),
        .TXDATRDY    (tx_ready[0]),
        .TXDAT     (tx_dat[0]),
        .RXDATVLD    (RXDATVLD[noc_unit_params_pkg::DAT_READ_VC]),
        .RXDATRDY    (RXDATRDY[noc_unit_params_pkg::DAT_READ_VC]),
        .RXDAT     (RXDAT)
    );

    nsu #(
        .FIFO_TYPE         (FIFO_TYPE),
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
        .REQ_REG_TYPE      (NSU_REQ_REG_TYPE    ),
        .RSP_REG_TYPE      (NSU_RSP_REG_TYPE    ),
        .DAT_REG_TYPE      (NSU_DAT_REG_TYPE    ),
        .RX_DAT_REG_TYPE   (NSU_RX_DAT_REG_TYPE  ),
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
        .ACLK              (ACLK            ),
        .ARESETn           (ARESETn         ),
        .noc_clk           (noc_clk         ),
        .noc_rst_n         (noc_rst_n       ),
        .RXREQVLD    (RXREQVLD  ),
        .RXREQ     (RXREQ   ),
        .RXREQRDY    (RXREQRDY  ),
        .RXDATVLD    (RXDATVLD[noc_unit_params_pkg::DAT_WRITE_VC]),
        .RXDATRDY    (RXDATRDY[noc_unit_params_pkg::DAT_WRITE_VC]),
        .RXDAT     (RXDAT),
        .TXRSPVLD    (TXRSPVLD  ),
        .TXRSP     (TXRSP   ),
        .TXRSPRDY    (TXRSPRDY  ),
        .TXDATVLD    (tx_valid[1]),
        .TXDATRDY    (tx_ready[1]),
        .TXDAT     (tx_dat[1]),
        .axi_wr_o          (axi_wr_o        ),
        .axi_rd_o          (axi_rd_o        )
    );

    ni_txdat #(
        .NUM_DAT_VC   (NUM_DAT_VC  )
    ) i_dat_tx (
        .clk_i     (noc_clk       ),
        .rst_n_i   (noc_rst_n     ),
        .s_dat_i   (tx_dat        ),
        .s_valid_i (tx_valid      ),
        .s_ready_o (tx_ready      ),
        .m_dat_o   (TXDAT ),
        .m_valid_o (TXDATVLD),
        .m_ready_i (TXDATRDY)
    );
    // The two class lanes connect directly to the units' independent RX cuts.
    // synthesis translate_off
    for (genvar vc = 0; vc < NUM_DAT_VC; vc++) begin : gen_rx_checks
        rx_independent: cover property (@(posedge noc_clk) disable iff (!noc_rst_n)
            !RXDATRDY[1-vc] && RXDATVLD[vc] && RXDATRDY[vc]);
    end
    // synthesis translate_on
    // synthesis translate_off
    wire noc_payload_pkg::dat_flit_t rx_flit = RXDAT;
    always @(posedge noc_clk) begin
        if (noc_rst_n && (|RXDATVLD)) begin
            if ($isunknown(rx_flit.header.packet_type) ||
                    noc_unit_params_pkg::dat_class(rx_flit.header.packet_type) < 0 ||
                    !$onehot(RXDATVLD) ||
                    !RXDATVLD[noc_unit_params_pkg::dat_class(rx_flit.header.packet_type)])
                $fatal(1, "DAT valid vector does not match packet class");
        end
    end
    // synthesis translate_on

endmodule
`resetall
