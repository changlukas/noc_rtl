// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nsu_response_packetize #(
    parameter int unsigned B_REG_TYPE = 0,
    parameter int unsigned R_REG_TYPE = 0,

    parameter logic [ni_types_pkg::NODE_ID_W-1:0]      SRC_ID      = '0,
    parameter logic [noc_header_pkg::PORT_ID_WIDTH-1:0] SRC_PORT_ID = '0
) (
    input  wire logic                           clk_i,
    input  wire logic                           rst_n_i,
    input  wire ni_types_pkg::nsu_b_response_t  s_b_i,
    input  wire logic                           s_b_valid_i,
    output wire logic                           s_b_ready_o,
    input  wire ni_types_pkg::nsu_r_response_t  s_r_i,
    input  wire logic                           s_r_valid_i,
    output wire logic                           s_r_ready_o,
    output wire noc_payload_pkg::rsp_flit_t         m_b_o,
    output wire logic                           m_b_valid_o,
    input  wire logic                           m_b_ready_i,
    output wire noc_payload_pkg::dat_flit_t         m_r_o,
    output wire logic                           m_r_valid_o,
    input  wire logic                           m_r_ready_i
);
    localparam int unsigned LANE_W = $clog2(noc_payload_pkg::DATA_WIDTH/noc_payload_pkg::NARROW_DATA_WIDTH);
    noc_payload_pkg::rsp_flit_t b;
    noc_payload_pkg::dat_flit_t r;
    axi_pkg::largest_addr_t r_addr;
    logic [LANE_W-1:0] r_lane;
    logic [noc_payload_pkg::DATA_WIDTH-1:0] r_data;
    int unsigned r_lower_byte;
    int unsigned r_upper_byte;
    function automatic noc_header_pkg::header_t make_header(
        input ni_types_pkg::nsu_context_t response
    );
        noc_header_pkg::header_t header;
        header             = '0;
        header.packet_type = response.packet_type;
        header.src_id      = noc_header_pkg::endpoint_id_t'({SRC_PORT_ID, SRC_ID});
        header.dst_id      = noc_header_pkg::endpoint_id_t'({response.src_port_id, response.src_id});
        header.flit_tail   = 1'b1;
        header.ord_req     = response.ordering_req;
        header.ord_tag     = response.ordering_tag;
        header.coll_op     = noc_header_pkg::collective_op_t'(response.collective_op);
        header.coll_mask   = response.collective_mask;
        return header;
    endfunction
    always_comb begin
        b = '0;
        r = '0;
        r_addr = axi_pkg::beat_addr(axi_pkg::largest_addr_t'(s_r_i.response.local_addr),
            s_r_i.response.size, s_r_i.response.len, s_r_i.response.burst, 16'(s_r_i.beat_index));
        r_lane = LANE_W'(r_addr >> $clog2(noc_payload_pkg::NARROW_DATA_WIDTH/8));
        r_lower_byte = int'(axi_pkg::beat_lower_byte(
            axi_pkg::largest_addr_t'(s_r_i.response.local_addr),
            s_r_i.response.size, s_r_i.response.len, s_r_i.response.burst,
            16'(noc_payload_pkg::DATA_WIDTH/8), 16'(s_r_i.beat_index)));
        r_upper_byte = int'(axi_pkg::beat_upper_byte(
            axi_pkg::largest_addr_t'(s_r_i.response.local_addr),
            s_r_i.response.size, s_r_i.response.len, s_r_i.response.burst,
            16'(noc_payload_pkg::DATA_WIDTH/8), 16'(s_r_i.beat_index)));
        // AXI leaves bytes outside the transfer unspecified.
        r_data = '0;
        for (int byte_idx = 0; byte_idx < noc_payload_pkg::DATA_WIDTH/8; byte_idx++) begin
            if (s_r_valid_i && byte_idx >= r_lower_byte && byte_idx <= r_upper_byte) begin
                r_data[byte_idx*8 +: 8] = s_r_i.axi.rdata[byte_idx*8 +: 8];
            end
        end
        if (s_b_valid_i) begin
            b.header = make_header(s_b_i.response);
            b.payload[noc_payload_pkg::B_BID_LSB +: noc_payload_pkg::B_BID_WIDTH] = s_b_i.axi.bid;
            b.payload[noc_payload_pkg::B_BRESP_LSB +: noc_payload_pkg::B_BRESP_WIDTH] = s_b_i.axi.bresp;
            b.payload[noc_payload_pkg::B_BUSER_LSB +: noc_payload_pkg::B_BUSER_WIDTH] = s_b_i.axi.buser;
        end
        if (s_r_valid_i) begin
            r.header = make_header(s_r_i.response);
            if (s_r_i.response.packet_type == noc_header_pkg::PKT_DATA_R) begin
                r.payload[noc_payload_pkg::DATA_R_RID_LSB +: noc_payload_pkg::DATA_R_RID_WIDTH] = s_r_i.axi.rid;
                r.payload[noc_payload_pkg::DATA_R_RRESP_LSB +: noc_payload_pkg::DATA_R_RRESP_WIDTH] = s_r_i.axi.rresp;
                r.payload[noc_payload_pkg::DATA_R_RLAST_LSB] = s_r_i.axi.rlast;
                r.payload[noc_payload_pkg::DATA_R_RUSER_LSB +: noc_payload_pkg::DATA_R_RUSER_WIDTH] = s_r_i.axi.ruser;
                r.payload[noc_payload_pkg::DATA_R_RDATA_LSB +: noc_payload_pkg::DATA_R_RDATA_WIDTH] = r_data;
            end else begin
                r.payload[noc_payload_pkg::NARROW_R_RID_LSB +: noc_payload_pkg::NARROW_R_RID_WIDTH] = s_r_i.axi.rid;
                r.payload[noc_payload_pkg::NARROW_R_RRESP_LSB +: noc_payload_pkg::NARROW_R_RRESP_WIDTH] = s_r_i.axi.rresp;
                r.payload[noc_payload_pkg::NARROW_R_RLAST_LSB] = s_r_i.axi.rlast;
                r.payload[noc_payload_pkg::NARROW_R_RUSER_LSB +: noc_payload_pkg::NARROW_R_RUSER_WIDTH] = s_r_i.axi.ruser;
                r.payload[noc_payload_pkg::NARROW_R_RDATA_LSB +: noc_payload_pkg::NARROW_R_RDATA_WIDTH] =
                    r_data[int'(r_lane)*noc_payload_pkg::NARROW_DATA_WIDTH +: noc_payload_pkg::NARROW_DATA_WIDTH];
            end
        end
    end
    stream_register #(
        .REG_TYPE (B_REG_TYPE),
        .data_t   (noc_payload_pkg::rsp_flit_t)
    ) i_b_reg (
        .clk_i     (clk_i      ),
        .rst_n_i   (rst_n_i    ),
        .s_data_i  (b          ),
        .s_valid_i (s_b_valid_i),
        .s_ready_o (s_b_ready_o),
        .m_data_o  (m_b_o      ),
        .m_valid_o (m_b_valid_o),
        .m_ready_i (m_b_ready_i)
    );
    stream_register #(
        .REG_TYPE (R_REG_TYPE),
        .data_t   (noc_payload_pkg::dat_flit_t)
    ) i_r_reg (
        .clk_i     (clk_i      ),
        .rst_n_i   (rst_n_i    ),
        .s_data_i  (r          ),
        .s_valid_i (s_r_valid_i),
        .s_ready_o (s_r_ready_o),
        .m_data_o  (m_r_o      ),
        .m_valid_o (m_r_valid_o),
        .m_ready_i (m_r_ready_i)
    );
endmodule

`resetall
