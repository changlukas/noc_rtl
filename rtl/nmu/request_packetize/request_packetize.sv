// SPDX-License-Identifier: Apache-2.0

`resetall
`timescale 1ns / 1ps
`default_nettype none

// Combinational flit encoding with optional per-channel output registers.
module nmu_request_packetize #(
    parameter int unsigned REQ_AW_REG_TYPE                           = 0,
    parameter int unsigned REQ_W_REG_TYPE                            = 0,
    parameter int unsigned REQ_AR_REG_TYPE                           = 0,
    parameter int unsigned DAT_AW_REG_TYPE                           = 0,
    parameter int unsigned DAT_W_REG_TYPE                            = 0,
    parameter logic [ni_types_pkg::NODE_ID_W-1:0]      SRC_ID      = '0,
    parameter logic [noc_header_pkg::PORT_ID_WIDTH-1:0] SRC_PORT_ID = '0
) (
    input  wire logic                                                             clk_i,
    input  wire logic                                                             rst_n_i,
    input  wire ni_types_pkg::nmu_aw_request_t                                    s_aw_i,
    input  wire logic                                                             s_aw_valid_i,
    output wire logic                                                             s_aw_ready_o,
    input  wire ni_types_pkg::nmu_aw_request_t                                    s_w_aw_i,
    input  wire logic                            [noc_payload_pkg::AXI_LEN_WIDTH-1:0] s_w_beat_i,
    input  wire ni_signals_pkg::noc_axi_w_t                                       s_w_i,
    input  wire logic                                                             s_w_valid_i,
    output wire logic                                                             s_w_ready_o,
    input  wire ni_types_pkg::nmu_ar_request_t                                    s_ar_i,
    input  wire logic                                                             s_ar_valid_i,
    output wire logic                                                             s_ar_ready_o,
    output wire noc_payload_pkg::req_flit_t        [ni_types_pkg::NUM_NMU_REQ_CH-1:0] m_req_o,
    output wire logic                          [ni_types_pkg::NUM_NMU_REQ_CH-1:0] m_req_valid_o,
    input  wire logic                          [ni_types_pkg::NUM_NMU_REQ_CH-1:0] m_req_ready_i,
    output wire noc_payload_pkg::dat_flit_t        [ni_types_pkg::NUM_NMU_DAT_CH-1:0] m_dat_o,
    output wire logic                          [ni_types_pkg::NUM_NMU_DAT_CH-1:0] m_dat_valid_o,
    input  wire logic                          [ni_types_pkg::NUM_NMU_DAT_CH-1:0] m_dat_ready_i
);
    import ni_types_pkg::*;

    localparam logic [noc_payload_pkg::AXI_BURST_WIDTH-1:0] AXI_BURST_INCR = 2'b01;
    localparam logic [noc_payload_pkg::AXI_BURST_WIDTH-1:0] AXI_BURST_WRAP = 2'b10;
    typedef struct packed {
        ni_signals_pkg::noc_axi_w_t                                         axi;
        ni_types_pkg::nmu_aw_request_t                                  owner;
        logic                          [noc_payload_pkg::AXI_LEN_WIDTH-1:0] beat_index;
    } write_beat_t;

    wire write_beat_t write_beat = '{axi: s_w_i, owner: s_w_aw_i, beat_index: s_w_beat_i};
    wire aw_uses_dat = (s_aw_i.packet_info.route.domain.packet_type == noc_header_pkg::PKT_DATA_AW);
    wire w_uses_dat = (s_w_aw_i.packet_info.route.domain.packet_type == noc_header_pkg::PKT_DATA_AW);
    function automatic noc_header_pkg::header_t make_header(
        input noc_header_pkg::packet_type_t packet_type,
        input ni_types_pkg::request_packet_info_t packet_info,
        input logic [noc_header_pkg::COLL_OP_WIDTH-1:0] collective_op,
        input logic [noc_header_pkg::COLL_MASK_WIDTH-1:0] collective_mask,
        input logic tail
    );
        noc_header_pkg::header_t header;
        header              = '0;
        header.packet_type = packet_type;
        header.src_id      = noc_header_pkg::endpoint_id_t'({SRC_PORT_ID, SRC_ID});
        header.dst_id      = noc_header_pkg::endpoint_id_t'({
            packet_info.route.domain.dst_port_id, packet_info.route.domain.dst_id});
        header.flit_tail = tail;
        header.ord_req   = packet_info.ordering_req;
        header.ord_tag   = packet_info.ordering_tag;
        header.coll_op   = noc_header_pkg::collective_op_t'(collective_op);
        header.coll_mask = collective_mask;
        return header;
    endfunction

    function automatic noc_payload_pkg::aw_payload_t pack_aw(
        input ni_types_pkg::nmu_aw_request_t request
    );
        noc_payload_pkg::aw_payload_t value;
        value                                                                         = '0;
        value[noc_payload_pkg::AW_AWID_LSB +: noc_payload_pkg::AW_AWID_WIDTH]         = request.axi.awid;
        value[noc_payload_pkg::AW_AWADDR_LSB +: noc_payload_pkg::AW_AWADDR_WIDTH]     = request.axi.awaddr;
        value[noc_payload_pkg::AW_AWLEN_LSB +: noc_payload_pkg::AW_AWLEN_WIDTH]       = request.axi.awlen;
        value[noc_payload_pkg::AW_AWSIZE_LSB +: noc_payload_pkg::AW_AWSIZE_WIDTH]     = request.axi.awsize;
        value[noc_payload_pkg::AW_AWBURST_LSB +: noc_payload_pkg::AW_AWBURST_WIDTH]   = request.axi.awburst;
        value[noc_payload_pkg::AW_AWCACHE_LSB +: noc_payload_pkg::AW_AWCACHE_WIDTH]   = request.axi.awcache;
        value[noc_payload_pkg::AW_AWLOCK_LSB]                                         = request.axi.awlock;
        value[noc_payload_pkg::AW_AWPROT_LSB +: noc_payload_pkg::AW_AWPROT_WIDTH]     = request.axi.awprot;
        value[noc_payload_pkg::AW_AWREGION_LSB +: noc_payload_pkg::AW_AWREGION_WIDTH] = request.axi.awregion;
        value[noc_payload_pkg::AW_AWQOS_LSB +: noc_payload_pkg::AW_AWQOS_WIDTH]       = request.axi.awqos;
        value[noc_payload_pkg::AW_AWUSER_LSB +: noc_payload_pkg::AW_AWUSER_WIDTH]     = request.user;
        return value;
    endfunction

    function automatic noc_payload_pkg::ar_payload_t pack_ar(
        input ni_types_pkg::nmu_ar_request_t request
    );
        noc_payload_pkg::ar_payload_t value;
        value                                                                         = '0;
        value[noc_payload_pkg::AR_ARID_LSB +: noc_payload_pkg::AR_ARID_WIDTH]         = request.axi.arid;
        value[noc_payload_pkg::AR_ARADDR_LSB +: noc_payload_pkg::AR_ARADDR_WIDTH]     = request.axi.araddr;
        value[noc_payload_pkg::AR_ARLEN_LSB +: noc_payload_pkg::AR_ARLEN_WIDTH]       = request.axi.arlen;
        value[noc_payload_pkg::AR_ARSIZE_LSB +: noc_payload_pkg::AR_ARSIZE_WIDTH]     = request.axi.arsize;
        value[noc_payload_pkg::AR_ARBURST_LSB +: noc_payload_pkg::AR_ARBURST_WIDTH]   = request.axi.arburst;
        value[noc_payload_pkg::AR_ARCACHE_LSB +: noc_payload_pkg::AR_ARCACHE_WIDTH]   = request.axi.arcache;
        value[noc_payload_pkg::AR_ARLOCK_LSB]                                         = request.axi.arlock;
        value[noc_payload_pkg::AR_ARPROT_LSB +: noc_payload_pkg::AR_ARPROT_WIDTH]     = request.axi.arprot;
        value[noc_payload_pkg::AR_ARREGION_LSB +: noc_payload_pkg::AR_ARREGION_WIDTH] = request.axi.arregion;
        value[noc_payload_pkg::AR_ARQOS_LSB +: noc_payload_pkg::AR_ARQOS_WIDTH]       = request.axi.arqos;
        value[noc_payload_pkg::AR_ARUSER_LSB +: noc_payload_pkg::AR_ARUSER_WIDTH]     = request.axi.aruser;
        return value;
    endfunction

    function automatic logic [noc_payload_pkg::DAT_PAYLOAD_WIDTH-1:0] pack_w(
        input write_beat_t beat,
        input logic narrow
    );
        logic [noc_payload_pkg::DAT_PAYLOAD_WIDTH-1:0] value;
        logic [noc_payload_pkg::AXI_ADDR_WIDTH-1:0] beat_addr;
        logic   [noc_payload_pkg::AXI_ADDR_WIDTH:0] beat_bytes, wrap_bytes;
        logic [noc_payload_pkg::AXI_ADDR_WIDTH-1:0] wrap_base;
        logic      [noc_payload_pkg::AXI_LEN_WIDTH:0] burst_beats;
        logic [$clog2(noc_payload_pkg::DATA_WIDTH /
                      noc_payload_pkg::NARROW_DATA_WIDTH)-1:0] lane;
        value = '0;
        if (narrow) begin
            beat_bytes = (noc_payload_pkg::AXI_ADDR_WIDTH+1)'(1) << beat.owner.axi.awsize;
            burst_beats = (noc_payload_pkg::AXI_LEN_WIDTH+1)'(beat.owner.axi.awlen) +
                (noc_payload_pkg::AXI_LEN_WIDTH+1)'(1);
            wrap_bytes = beat_bytes * burst_beats;
            beat_addr  = beat.owner.axi.awaddr;
            if (beat.owner.axi.awburst == AXI_BURST_INCR) begin
                beat_addr = noc_payload_pkg::AXI_ADDR_WIDTH'({1'b0, beat.owner.axi.awaddr} + beat.beat_index * beat_bytes);
            end else if (beat.owner.axi.awburst == AXI_BURST_WRAP) begin
                wrap_base = noc_payload_pkg::AXI_ADDR_WIDTH'({1'b0, beat.owner.axi.awaddr} & ~(wrap_bytes-1'b1));
                beat_addr = noc_payload_pkg::AXI_ADDR_WIDTH'({1'b0, wrap_base} +
                    (({1'b0, beat.owner.axi.awaddr} - {1'b0, wrap_base} + beat.beat_index * beat_bytes) &
                     (wrap_bytes-1'b1)));
            end
            lane = beat_addr[$clog2(noc_payload_pkg::DATA_WIDTH/8)-1:
                             $clog2(noc_payload_pkg::NARROW_DATA_WIDTH/8)];
            value[noc_payload_pkg::NARROW_W_WLAST_LSB]                                          = beat.axi.wlast;
            value[noc_payload_pkg::NARROW_W_WUSER_LSB +: noc_payload_pkg::NARROW_W_WUSER_WIDTH] = beat.axi.wuser;
            value[noc_payload_pkg::NARROW_W_WSTRB_LSB +: noc_payload_pkg::NARROW_W_WSTRB_WIDTH] =                 beat.axi.wstrb[lane*noc_payload_pkg::NARROW_WSTRB_WIDTH +:
                               noc_payload_pkg::NARROW_WSTRB_WIDTH];
            value[noc_payload_pkg::NARROW_W_WDATA_LSB +: noc_payload_pkg::NARROW_W_WDATA_WIDTH] =
                beat.axi.wdata[lane*noc_payload_pkg::NARROW_DATA_WIDTH +:
                               noc_payload_pkg::NARROW_DATA_WIDTH];
        end else begin
            value[noc_payload_pkg::DATA_W_WLAST_LSB]                                        = beat.axi.wlast;
            value[noc_payload_pkg::DATA_W_WUSER_LSB +: noc_payload_pkg::DATA_W_WUSER_WIDTH] = beat.axi.wuser;
            value[noc_payload_pkg::DATA_W_WSTRB_LSB +: noc_payload_pkg::DATA_W_WSTRB_WIDTH] = beat.axi.wstrb;
            value[noc_payload_pkg::DATA_W_WDATA_LSB +: noc_payload_pkg::DATA_W_WDATA_WIDTH] = beat.axi.wdata;
        end
        return value;
    endfunction

    noc_payload_pkg::req_flit_t [NUM_NMU_REQ_CH-1:0] req_flit;
    noc_payload_pkg::dat_flit_t [NUM_NMU_DAT_CH-1:0] dat_flit;
    wire noc_payload_pkg::req_flit_t [NUM_NMU_REQ_CH-1:0] req_output;
    wire noc_payload_pkg::dat_flit_t [NUM_NMU_DAT_CH-1:0] dat_output;
    for (genvar n = 0; n < NUM_NMU_REQ_CH; n++) begin : gen_req_output
        assign m_req_o[n] = m_req_valid_o[n] ? req_output[n] : '0;
    end
    for (genvar n = 0; n < NUM_NMU_DAT_CH; n++) begin : gen_dat_output
        assign m_dat_o[n] = m_dat_valid_o[n] ? dat_output[n] : '0;
    end
    wire [NUM_NMU_REQ_CH-1:0] req_valid, req_ready;
    wire [NUM_NMU_DAT_CH-1:0] dat_valid, dat_ready;
    assign req_valid[NMU_REQ_AW_IDX] = s_aw_valid_i && !aw_uses_dat;
    assign req_valid[NMU_REQ_W_IDX]  = s_w_valid_i && !w_uses_dat;
    assign req_valid[NMU_REQ_AR_IDX] = s_ar_valid_i;
    assign dat_valid[NMU_DAT_AW_IDX] = s_aw_valid_i && aw_uses_dat;
    assign dat_valid[NMU_DAT_W_IDX]  = s_w_valid_i && w_uses_dat;
    assign s_aw_ready_o              = (aw_uses_dat ? dat_ready[NMU_DAT_AW_IDX] : req_ready[NMU_REQ_AW_IDX]);
    assign s_w_ready_o               = (w_uses_dat ? dat_ready[NMU_DAT_W_IDX] : req_ready[NMU_REQ_W_IDX]);
    assign s_ar_ready_o              = req_ready[NMU_REQ_AR_IDX];
    always_comb begin
        req_flit = '0;
        dat_flit = '0;
        req_flit[NMU_REQ_AW_IDX].header = make_header(noc_header_pkg::PKT_NARROW_AW,
            s_aw_i.packet_info, s_aw_i.collective_op, s_aw_i.collective_mask,
            1'b0);
        req_flit[NMU_REQ_AW_IDX].payload = noc_payload_pkg::REQ_PAYLOAD_WIDTH'(pack_aw(s_aw_i));
        req_flit[NMU_REQ_W_IDX].header   = make_header(noc_header_pkg::PKT_NARROW_W,
            write_beat.owner.packet_info, write_beat.owner.collective_op, write_beat.owner.collective_mask,
            write_beat.axi.wlast);
        req_flit[NMU_REQ_W_IDX].payload = noc_payload_pkg::REQ_PAYLOAD_WIDTH'(pack_w(write_beat, 1'b1));
        req_flit[NMU_REQ_AR_IDX].header = make_header(s_ar_i.packet_info.route.domain.packet_type,
            s_ar_i.packet_info, '0, '0, 1'b1);
        req_flit[NMU_REQ_AR_IDX].payload = noc_payload_pkg::REQ_PAYLOAD_WIDTH'(pack_ar(s_ar_i));
        dat_flit[NMU_DAT_AW_IDX].header  = make_header(noc_header_pkg::PKT_DATA_AW,
            s_aw_i.packet_info, s_aw_i.collective_op, s_aw_i.collective_mask,
            1'b0);
        dat_flit[NMU_DAT_AW_IDX].payload = noc_payload_pkg::DAT_PAYLOAD_WIDTH'(pack_aw(s_aw_i));
        dat_flit[NMU_DAT_W_IDX].header   = make_header(noc_header_pkg::PKT_DATA_W,
            write_beat.owner.packet_info, write_beat.owner.collective_op, write_beat.owner.collective_mask,
            write_beat.axi.wlast);
        dat_flit[NMU_DAT_W_IDX].payload = pack_w(write_beat, 1'b0);
    end
    stream_register #(
        .REG_TYPE (REQ_AW_REG_TYPE        ),
        .data_t   (noc_payload_pkg::req_flit_t)
    ) i_req_aw_reg (
        .clk_i     (clk_i                                                    ),
        .rst_n_i   (rst_n_i                                                  ),
        .s_data_i  (req_valid[NMU_REQ_AW_IDX] ? req_flit[NMU_REQ_AW_IDX] : '0),
        .s_valid_i (req_valid[NMU_REQ_AW_IDX]                                ),
        .s_ready_o (req_ready[NMU_REQ_AW_IDX]                                ),
        .m_data_o  (req_output[NMU_REQ_AW_IDX]                               ),
        .m_valid_o (m_req_valid_o[NMU_REQ_AW_IDX]                            ),
        .m_ready_i (m_req_ready_i[NMU_REQ_AW_IDX]                            )
    );
    stream_register #(
        .REG_TYPE (REQ_W_REG_TYPE         ),
        .data_t   (noc_payload_pkg::req_flit_t)
    ) i_req_w_reg (
        .clk_i     (clk_i                                                  ),
        .rst_n_i   (rst_n_i                                                ),
        .s_data_i  (req_valid[NMU_REQ_W_IDX] ? req_flit[NMU_REQ_W_IDX] : '0),
        .s_valid_i (req_valid[NMU_REQ_W_IDX]                               ),
        .s_ready_o (req_ready[NMU_REQ_W_IDX]                               ),
        .m_data_o  (req_output[NMU_REQ_W_IDX]                              ),
        .m_valid_o (m_req_valid_o[NMU_REQ_W_IDX]                           ),
        .m_ready_i (m_req_ready_i[NMU_REQ_W_IDX]                           )
    );
    stream_register #(
        .REG_TYPE (REQ_AR_REG_TYPE        ),
        .data_t   (noc_payload_pkg::req_flit_t)
    ) i_req_ar_reg (
        .clk_i     (clk_i                                                    ),
        .rst_n_i   (rst_n_i                                                  ),
        .s_data_i  (req_valid[NMU_REQ_AR_IDX] ? req_flit[NMU_REQ_AR_IDX] : '0),
        .s_valid_i (req_valid[NMU_REQ_AR_IDX]                                ),
        .s_ready_o (req_ready[NMU_REQ_AR_IDX]                                ),
        .m_data_o  (req_output[NMU_REQ_AR_IDX]                               ),
        .m_valid_o (m_req_valid_o[NMU_REQ_AR_IDX]                            ),
        .m_ready_i (m_req_ready_i[NMU_REQ_AR_IDX]                            )
    );
    stream_register #(
        .REG_TYPE (DAT_AW_REG_TYPE        ),
        .data_t   (noc_payload_pkg::dat_flit_t)
    ) i_dat_aw_reg (
        .clk_i     (clk_i                                                    ),
        .rst_n_i   (rst_n_i                                                  ),
        .s_data_i  (dat_valid[NMU_DAT_AW_IDX] ? dat_flit[NMU_DAT_AW_IDX] : '0),
        .s_valid_i (dat_valid[NMU_DAT_AW_IDX]                                ),
        .s_ready_o (dat_ready[NMU_DAT_AW_IDX]                                ),
        .m_data_o  (dat_output[NMU_DAT_AW_IDX]                               ),
        .m_valid_o (m_dat_valid_o[NMU_DAT_AW_IDX]                            ),
        .m_ready_i (m_dat_ready_i[NMU_DAT_AW_IDX]                            )
    );
    stream_register #(
        .REG_TYPE (DAT_W_REG_TYPE         ),
        .data_t   (noc_payload_pkg::dat_flit_t)
    ) i_dat_w_reg (
        .clk_i     (clk_i                                                  ),
        .rst_n_i   (rst_n_i                                                ),
        .s_data_i  (dat_valid[NMU_DAT_W_IDX] ? dat_flit[NMU_DAT_W_IDX] : '0),
        .s_valid_i (dat_valid[NMU_DAT_W_IDX]                               ),
        .s_ready_o (dat_ready[NMU_DAT_W_IDX]                               ),
        .m_data_o  (dat_output[NMU_DAT_W_IDX]                              ),
        .m_valid_o (m_dat_valid_o[NMU_DAT_W_IDX]                           ),
        .m_ready_i (m_dat_ready_i[NMU_DAT_W_IDX]                           )
    );
endmodule
`resetall
