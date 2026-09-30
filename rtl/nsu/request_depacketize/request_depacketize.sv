// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nsu_request_depacketize #(
    parameter int unsigned AW_REG_TYPE   = 0,
    parameter int unsigned W_REG_TYPE    = 0,
    parameter int unsigned AR_REG_TYPE   = 0,
    parameter int unsigned SAM_NUM_RULES = topology_pkg::SAM_NUM_RULES,

    parameter type addr_t         = topology_pkg::sam_addr_t,
    parameter type sam_mask_sel_t = topology_pkg::sam_mask_sel_t,
    parameter type sam_result_t   = topology_pkg::sam_result_t,
    parameter type sam_rule_t     = topology_pkg::sam_rule_t,

    parameter sam_rule_t [SAM_NUM_RULES-1:0]        SAM    = topology_pkg::SAM,
    parameter logic [ni_flit_pkg::SRC_ID_WIDTH-1:0] SRC_ID = '0
) (
    input  wire logic                                                           clk_i,
    input  wire logic                                                           rst_n_i,
    input  wire ni_flit_pkg::dat_flit_t                                         s_aw_i,
    input  wire logic                                                           s_aw_valid_i,
    output wire logic                                                           s_aw_ready_o,
    input  wire ni_flit_pkg::dat_flit_t                                         s_w_i,
    input  wire logic                                                           s_w_valid_i,
    output wire logic                                                           s_w_ready_o,
    input  wire ni_types_pkg::nsu_w_context_t                                   w_context_i,
    input  wire logic                          [ni_flit_pkg::AXI_LEN_WIDTH-1:0] w_beat_i,
    input  wire ni_flit_pkg::req_flit_t                                         s_ar_i,
    input  wire logic                                                           s_ar_valid_i,
    output wire logic                                                           s_ar_ready_o,
    output wire ni_types_pkg::nsu_aw_request_t                                  m_aw_o,
    output wire logic                                                           m_aw_valid_o,
    input  wire logic                                                           m_aw_ready_i,
    output wire ni_signals_pkg::noc_axi_w_t                                     m_w_o,
    output wire logic                                                           m_w_valid_o,
    input  wire logic                                                           m_w_ready_i,
    output wire ni_types_pkg::nsu_ar_request_t                                  m_ar_o,
    output wire logic                                                           m_ar_valid_o,
    input  wire logic                                                           m_ar_ready_i,
    output wire logic                                                           w_accept_o,
    output wire logic                                                           w_last_o
);
    import ni_flit_pkg::*;
    import ni_types_pkg::*;
    localparam int unsigned DATA_W = ni_params_pkg::AXI_DATA_WIDTH;
    localparam int unsigned STRB_W = DATA_W/8;
    localparam int unsigned LANE_W = $clog2(DATA_W/NOC_NARROW_DATA_WIDTH);
    nsu_aw_request_t aw;
    nsu_ar_request_t ar;
    ni_signals_pkg::noc_axi_w_t w;
    sam_result_t aw_sam;
    wire                                     aw_lookup_valid, aw_lookup_error;
    wire [ni_params_pkg::AXI_ADDR_WIDTH-1:0] aw_addr = s_aw_i.payload[AW_AWADDR_LSB +: AW_AWADDR_WIDTH];
    wire           [COLLECTIVE_OP_WIDTH-1:0] collective_op = s_aw_i.header[COLLECTIVE_OP_LSB +: COLLECTIVE_OP_WIDTH];
    axi_pkg::largest_addr_t w_addr;
    logic [LANE_W-1:0] w_lane;

    function automatic nsu_context_t decode_context(input logic [HEADER_WIDTH-1:0] header);
        nsu_context_t value;
        value              = '0;
        value.src_id       = header[SRC_ID_LSB +: SRC_ID_WIDTH];
        value.src_port_id  = header[SRC_PORT_ID_LSB +: SRC_PORT_ID_WIDTH];
        value.ordering_req = header[ORDERING_REQ_LSB];
        value.ordering_tag = header[ORDERING_TAG_LSB +: ORDERING_TAG_WIDTH];
        value.is_data      = header[AXI_CH_LSB +: AXI_CH_WIDTH] == AXI_CH_WIDTH'(AXI_CH_DataAw) ||
            header[AXI_CH_LSB +: AXI_CH_WIDTH] == AXI_CH_WIDTH'(AXI_CH_DataAr);
        return value;
    endfunction

    function automatic addr_t replace_coords(input addr_t addr, input sam_result_t rule);
        addr_t x_mask, y_mask, value;
        x_mask = (addr_t'('1) >> (ni_params_pkg::AXI_ADDR_WIDTH-int'(rule.mask_x.len))) << rule.mask_x.offset;
        y_mask = (addr_t'('1) >> (ni_params_pkg::AXI_ADDR_WIDTH-int'(rule.mask_y.len))) << rule.mask_y.offset;
        value  = addr & ~(x_mask | y_mask);
        value |= (addr_t'(SRC_ID[X_WIDTH-1:0]) << rule.mask_x.offset) & x_mask;
        value |= (addr_t'(SRC_ID[X_WIDTH +: Y_WIDTH]) << rule.mask_y.offset) & y_mask;
        return value;
    endfunction
    ni_sam #(
        .SAM_NUM_RULES  (SAM_NUM_RULES ),
        .addr_t         (addr_t        ),
        .sam_mask_sel_t (sam_mask_sel_t),
        .sam_result_t   (sam_result_t  ),
        .sam_rule_t     (sam_rule_t    ),
        .SAM            (SAM           )
    ) i_aw_sam (
        .addr_i         (aw_addr                                       ),
        .lookup_en_i    (rst_n_i && s_aw_valid_i && collective_op != '0),
        .sam_idx_o      (aw_sam                                        ),
        .lookup_valid_o (aw_lookup_valid                               ),
        .lookup_error_o (aw_lookup_error                               )
    );

    always_comb begin
        aw = '0;
        ar = '0;
        w  = '0;
        w_addr = axi_pkg::beat_addr(axi_pkg::largest_addr_t'(w_context_i.response.local_addr),
            w_context_i.response.size, w_context_i.response.len, w_context_i.response.burst,
            16'(w_beat_i));
        w_lane = LANE_W'(w_addr >> $clog2(NOC_NARROW_DATA_WIDTH/8));
        if (s_aw_valid_i) begin
            aw.axi.awid     = $bits(aw.axi.awid)'(s_aw_i.payload[AW_AWID_LSB +: AW_AWID_WIDTH]);
            aw.axi.awaddr   = $bits(aw.axi.awaddr)'(s_aw_i.payload[AW_AWADDR_LSB +: AW_AWADDR_WIDTH]);
            aw.axi.awlen    = $bits(aw.axi.awlen)'(s_aw_i.payload[AW_AWLEN_LSB +: AW_AWLEN_WIDTH]);
            aw.axi.awsize   = $bits(aw.axi.awsize)'(s_aw_i.payload[AW_AWSIZE_LSB +: AW_AWSIZE_WIDTH]);
            aw.axi.awburst  = $bits(aw.axi.awburst)'(s_aw_i.payload[AW_AWBURST_LSB +: AW_AWBURST_WIDTH]);
            aw.axi.awcache  = $bits(aw.axi.awcache)'(s_aw_i.payload[AW_AWCACHE_LSB +: AW_AWCACHE_WIDTH]);
            aw.axi.awlock   = $bits(aw.axi.awlock)'(s_aw_i.payload[AW_AWLOCK_LSB +: AW_AWLOCK_WIDTH]);
            aw.axi.awprot   = $bits(aw.axi.awprot)'(s_aw_i.payload[AW_AWPROT_LSB +: AW_AWPROT_WIDTH]);
            aw.axi.awregion = $bits(aw.axi.awregion)'(s_aw_i.payload[AW_AWREGION_LSB +: AW_AWREGION_WIDTH]);
            aw.axi.awqos    = $bits(aw.axi.awqos)'(s_aw_i.payload[AW_AWQOS_LSB +: AW_AWQOS_WIDTH]);
            aw.axi.awuser   = $bits(aw.axi.awuser)'(s_aw_i.payload[AW_AWUSER_LSB +: AW_AWUSER_WIDTH]);
            if (collective_op != '0) aw.axi.awaddr = replace_coords(aw_addr, aw_sam);
            aw.response                 = decode_context(s_aw_i.header);
            aw.response.noc_id          = aw.axi.awid;
            aw.response.local_addr      = aw.axi.awaddr;
            aw.response.len             = aw.axi.awlen;
            aw.response.size            = aw.axi.awsize;
            aw.response.burst           = aw.axi.awburst;
            aw.response.collective_op   = collective_op;
            aw.response.collective_mask = s_aw_i.header[COLLECTIVE_MASK_LSB +: COLLECTIVE_MASK_WIDTH];
            aw.vc_id                    = s_aw_i.header[VC_ID_LSB +: VC_ID_WIDTH];
        end
        if (s_ar_valid_i) begin
            ar.axi.arid            = $bits(ar.axi.arid)'(s_ar_i.payload[AR_ARID_LSB +: AR_ARID_WIDTH]);
            ar.axi.araddr          = $bits(ar.axi.araddr)'(s_ar_i.payload[AR_ARADDR_LSB +: AR_ARADDR_WIDTH]);
            ar.axi.arlen           = $bits(ar.axi.arlen)'(s_ar_i.payload[AR_ARLEN_LSB +: AR_ARLEN_WIDTH]);
            ar.axi.arsize          = $bits(ar.axi.arsize)'(s_ar_i.payload[AR_ARSIZE_LSB +: AR_ARSIZE_WIDTH]);
            ar.axi.arburst         = $bits(ar.axi.arburst)'(s_ar_i.payload[AR_ARBURST_LSB +: AR_ARBURST_WIDTH]);
            ar.axi.arcache         = $bits(ar.axi.arcache)'(s_ar_i.payload[AR_ARCACHE_LSB +: AR_ARCACHE_WIDTH]);
            ar.axi.arlock          = $bits(ar.axi.arlock)'(s_ar_i.payload[AR_ARLOCK_LSB +: AR_ARLOCK_WIDTH]);
            ar.axi.arprot          = $bits(ar.axi.arprot)'(s_ar_i.payload[AR_ARPROT_LSB +: AR_ARPROT_WIDTH]);
            ar.axi.arregion        = $bits(ar.axi.arregion)'(s_ar_i.payload[AR_ARREGION_LSB +: AR_ARREGION_WIDTH]);
            ar.axi.arqos           = $bits(ar.axi.arqos)'(s_ar_i.payload[AR_ARQOS_LSB +: AR_ARQOS_WIDTH]);
            ar.response            = decode_context(s_ar_i.header);
            ar.response.noc_id     = ar.axi.arid;
            ar.response.local_addr = ar.axi.araddr;
            ar.response.len        = ar.axi.arlen;
            ar.response.size       = ar.axi.arsize;
            ar.response.burst      = ar.axi.arburst;
        end
        if (s_w_valid_i) begin
            if (w_context_i.response.is_data) begin
                w.wdata = s_w_i.payload[DATA_W_WDATA_LSB +: DATA_W_WDATA_WIDTH];
                w.wstrb = s_w_i.payload[DATA_W_WSTRB_LSB +: DATA_W_WSTRB_WIDTH];
                w.wlast = s_w_i.payload[DATA_W_WLAST_LSB];
            end else begin
                w.wdata = DATA_W'(s_w_i.payload[NARROW_W_WDATA_LSB +: NARROW_W_WDATA_WIDTH]) << (int'(w_lane)*NOC_NARROW_DATA_WIDTH);
                w.wstrb = STRB_W'(s_w_i.payload[NARROW_W_WSTRB_LSB +: NARROW_W_WSTRB_WIDTH]) << (int'(w_lane)*NARROW_WSTRB_WIDTH);
                w.wlast = s_w_i.payload[NARROW_W_WLAST_LSB];
            end
        end
    end
    assign w_accept_o = rst_n_i && s_w_valid_i && s_w_ready_o;
    assign w_last_o   = w.wlast;
    stream_register #(
        .REG_TYPE (AW_REG_TYPE     ),
        .data_t   (nsu_aw_request_t)
    ) i_aw_reg (
        .clk_i     (clk_i                  ),
        .rst_n_i   (rst_n_i                ),
        .s_data_i  (aw                     ),
        .s_valid_i (rst_n_i && s_aw_valid_i),
        .s_ready_o (s_aw_ready_o           ),
        .m_data_o  (m_aw_o                 ),
        .m_valid_o (m_aw_valid_o           ),
        .m_ready_i (m_aw_ready_i           )
    );
    stream_register #(
        .REG_TYPE (W_REG_TYPE                 ),
        .data_t   (ni_signals_pkg::noc_axi_w_t)
    ) i_w_reg (
        .clk_i     (clk_i                 ),
        .rst_n_i   (rst_n_i               ),
        .s_data_i  (w                     ),
        .s_valid_i (rst_n_i && s_w_valid_i),
        .s_ready_o (s_w_ready_o           ),
        .m_data_o  (m_w_o                 ),
        .m_valid_o (m_w_valid_o           ),
        .m_ready_i (m_w_ready_i           )
    );
    stream_register #(
        .REG_TYPE (AR_REG_TYPE     ),
        .data_t   (nsu_ar_request_t)
    ) i_ar_reg (
        .clk_i     (clk_i                  ),
        .rst_n_i   (rst_n_i                ),
        .s_data_i  (ar                     ),
        .s_valid_i (rst_n_i && s_ar_valid_i),
        .s_ready_o (s_ar_ready_o           ),
        .m_data_o  (m_ar_o                 ),
        .m_valid_o (m_ar_valid_o           ),
        .m_ready_i (m_ar_ready_i           )
    );

    // synthesis translate_off
    always @(posedge clk_i) begin
        if (rst_n_i && s_aw_valid_i && collective_op != '0 &&
                (!aw_lookup_valid || aw_lookup_error || !aw_sam.collective_en))
            $fatal(1, "Invalid collective address mapping (instance %m)");
    end
    // synthesis translate_on
endmodule

`resetall
