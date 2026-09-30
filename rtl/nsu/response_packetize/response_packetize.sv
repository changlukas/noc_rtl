// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nsu_response_packetize #(
    parameter int unsigned B_REG_TYPE = 0,
    parameter int unsigned R_REG_TYPE = 0,

    parameter logic [ni_flit_pkg::SRC_ID_WIDTH-1:0]      SRC_ID      = '0,
    parameter logic [ni_flit_pkg::SRC_PORT_ID_WIDTH-1:0] SRC_PORT_ID = '0
) (
    input  wire logic                           clk_i,
    input  wire logic                           rst_n_i,
    input  wire ni_types_pkg::nsu_b_response_t  s_b_i,
    input  wire logic                           s_b_valid_i,
    output wire logic                           s_b_ready_o,
    input  wire ni_types_pkg::nsu_r_response_t  s_r_i,
    input  wire logic                           s_r_valid_i,
    output wire logic                           s_r_ready_o,
    output wire ni_flit_pkg::rsp_flit_t         m_b_o,
    output wire logic                           m_b_valid_o,
    input  wire logic                           m_b_ready_i,
    output wire ni_flit_pkg::dat_flit_t         m_r_o,
    output wire logic                           m_r_valid_o,
    input  wire logic                           m_r_ready_i
);
    import ni_flit_pkg::*;
    localparam int unsigned LANE_W = $clog2(ni_params_pkg::AXI_DATA_WIDTH/NOC_NARROW_DATA_WIDTH);
    rsp_flit_t b;
    dat_flit_t r;
    axi_pkg::largest_addr_t r_addr;
    logic [LANE_W-1:0] r_lane;
    function automatic logic [HEADER_WIDTH-1:0] make_header(
        input ni_types_pkg::nsu_context_t response,
        input logic [AXI_CH_WIDTH-1:0] channel
    );
        logic [HEADER_WIDTH-1:0] header;
        header = '0;
        header[AXI_CH_LSB +: AXI_CH_WIDTH] = channel;
        header[SRC_ID_LSB +: SRC_ID_WIDTH] = SRC_ID;
        header[SRC_PORT_ID_LSB +: SRC_PORT_ID_WIDTH] = SRC_PORT_ID;
        header[DST_ID_LSB +: DST_ID_WIDTH] = response.src_id;
        header[DST_PORT_ID_LSB +: DST_PORT_ID_WIDTH] = response.src_port_id;
        header[FLIT_TAIL_LSB]    = 1'b1;
        header[ORDERING_REQ_LSB] = response.ordering_req;
        header[ORDERING_TAG_LSB +: ORDERING_TAG_WIDTH] = response.ordering_tag;
        header[COLLECTIVE_OP_LSB +: COLLECTIVE_OP_WIDTH] = response.collective_op;
        header[COLLECTIVE_MASK_LSB +: COLLECTIVE_MASK_WIDTH] = response.collective_mask;
        return header;
    endfunction
    always_comb begin
        b = '0;
        r = '0;
        r_addr = axi_pkg::beat_addr(axi_pkg::largest_addr_t'(s_r_i.response.local_addr),
            s_r_i.response.size, s_r_i.response.len, s_r_i.response.burst, 16'(s_r_i.beat_index));
        r_lane = LANE_W'(r_addr >> $clog2(NOC_NARROW_DATA_WIDTH/8));
        if (s_b_valid_i) begin
            b.header = make_header(s_b_i.response, AXI_CH_WIDTH'(s_b_i.response.is_data ? AXI_CH_DataB : AXI_CH_NarrowB));
            b.payload[B_BID_LSB +: B_BID_WIDTH] = s_b_i.axi.bid;
            b.payload[B_BRESP_LSB +: B_BRESP_WIDTH] = s_b_i.axi.bresp;
        end
        if (s_r_valid_i) begin
            r.header = make_header(s_r_i.response, AXI_CH_WIDTH'(s_r_i.response.is_data ? AXI_CH_DataR : AXI_CH_NarrowR));
            if (s_r_i.response.is_data) begin
                r.payload[DATA_R_RID_LSB +: DATA_R_RID_WIDTH] = s_r_i.axi.rid;
                r.payload[DATA_R_RRESP_LSB +: DATA_R_RRESP_WIDTH] = s_r_i.axi.rresp;
                r.payload[DATA_R_RLAST_LSB] = s_r_i.axi.rlast;
                r.payload[DATA_R_RDATA_LSB +: DATA_R_RDATA_WIDTH] = s_r_i.axi.rdata;
            end else begin
                r.payload[NARROW_R_RID_LSB +: NARROW_R_RID_WIDTH] = s_r_i.axi.rid;
                r.payload[NARROW_R_RRESP_LSB +: NARROW_R_RRESP_WIDTH] = s_r_i.axi.rresp;
                r.payload[NARROW_R_RLAST_LSB] = s_r_i.axi.rlast;
                r.payload[NARROW_R_RDATA_LSB +: NARROW_R_RDATA_WIDTH] =
                    s_r_i.axi.rdata[int'(r_lane)*NOC_NARROW_DATA_WIDTH +: NOC_NARROW_DATA_WIDTH];
            end
        end
    end
    stream_register #(
        .REG_TYPE (B_REG_TYPE),
        .data_t   (rsp_flit_t)
    ) i_b_reg (
        .clk_i     (clk_i                 ),
        .rst_n_i   (rst_n_i               ),
        .s_data_i  (b                     ),
        .s_valid_i (rst_n_i && s_b_valid_i),
        .s_ready_o (s_b_ready_o           ),
        .m_data_o  (m_b_o                 ),
        .m_valid_o (m_b_valid_o           ),
        .m_ready_i (m_b_ready_i           )
    );
    stream_register #(
        .REG_TYPE (R_REG_TYPE),
        .data_t   (dat_flit_t)
    ) i_r_reg (
        .clk_i     (clk_i                 ),
        .rst_n_i   (rst_n_i               ),
        .s_data_i  (r                     ),
        .s_valid_i (rst_n_i && s_r_valid_i),
        .s_ready_o (s_r_ready_o           ),
        .m_data_o  (m_r_o                 ),
        .m_valid_o (m_r_valid_o           ),
        .m_ready_i (m_r_ready_i           )
    );
endmodule

`resetall
