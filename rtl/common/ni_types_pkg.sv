`timescale 1ns/1ps

`ifndef NI_TYPES_PKG_SVH
`define NI_TYPES_PKG_SVH

package ni_types_pkg;

    // Internal coordinate and port metadata stay separate; the wire header packs them.
    localparam int DAT_VC_IDX_W = noc_unit_params_pkg::DAT_NUM_VC > 1 ?
        $clog2(noc_unit_params_pkg::DAT_NUM_VC) : 1;

    localparam int NODE_ID_W = noc_header_pkg::X_WIDTH + noc_header_pkg::Y_WIDTH;
    localparam int NARROW_LANE_W = $clog2(noc_payload_pkg::DATA_WIDTH /
        noc_payload_pkg::NARROW_DATA_WIDTH);

    // Fixed packetizer slots, not configurable VC or source counts.
    localparam int NMU_REQ_AW_IDX = 0;
    localparam int NMU_REQ_W_IDX  = 1;
    localparam int NMU_REQ_AR_IDX = 2;
    localparam int NUM_NMU_REQ_CH = 3;
    localparam int NMU_DAT_AW_IDX = 0;
    localparam int NMU_DAT_W_IDX  = 1;
    localparam int NUM_NMU_DAT_CH = 2;

    // NMU request ordering-domain key. PACKET_TYPE identifies the AXI channel/class.
    typedef struct packed {
        logic                                             [NODE_ID_W-1:0] dst_id;
        logic                         [noc_header_pkg::PORT_ID_WIDTH-1:0] dst_port_id;
        noc_header_pkg::packet_type_t                                     packet_type;
    } nmu_ordering_domain_t;

    typedef struct packed {
        nmu_ordering_domain_t  domain;
    } nmu_route_t;

    // AW-only collective state. AR opaque USER stays in its AXI channel record.
    typedef struct packed {
        nmu_route_t                                       route;
        logic         [noc_payload_pkg::AWUSER_WIDTH-1:0] user;
        logic         [noc_header_pkg::COLL_OP_WIDTH-1:0] collective_op;
        logic       [noc_header_pkg::COLL_MASK_WIDTH-1:0] collective_mask;
    } nmu_aw_route_t;

    typedef struct packed {
        nmu_route_t                                     route;
        logic                                           ordering_req;
        logic       [noc_header_pkg::ORD_TAG_WIDTH-1:0] ordering_tag;
    } request_packet_info_t;

    typedef struct packed {
        noc_header_pkg::packet_type_t                                     packet_type;
        logic                                                             ordering_req;
        logic                         [noc_header_pkg::ORD_TAG_WIDTH-1:0] ordering_tag;
    } response_packet_info_t;

    typedef struct packed {
        ni_signals_pkg::noc_axi_aw_t  axi;
        nmu_aw_route_t                route;
    } nmu_sam_aw_result_t;

    typedef struct packed {
        ni_signals_pkg::noc_axi_ar_t  axi;
        nmu_route_t                   route;
    } nmu_sam_ar_result_t;

    typedef struct packed {
        ni_signals_pkg::noc_axi_aw_t                                       axi;
        request_packet_info_t                                                      packet_info;
        logic                          [noc_payload_pkg::AWUSER_WIDTH-1:0] user;
        logic                          [noc_header_pkg::COLL_OP_WIDTH-1:0] collective_op;
        logic                        [noc_header_pkg::COLL_MASK_WIDTH-1:0] collective_mask;
    } nmu_aw_request_t;

    typedef struct packed {
        ni_signals_pkg::noc_axi_ar_t  axi;
        request_packet_info_t                 packet_info;
    } nmu_ar_request_t;

    typedef struct packed {
        ni_signals_pkg::noc_axi_b_t  axi;
        response_packet_info_t               packet_info;
    } nmu_b_response_t;

    typedef struct packed {
        ni_signals_pkg::noc_axi_r_t  axi;
        response_packet_info_t               packet_info;
    } nmu_r_response_t;

    // Per-ID issue-order record.  beat_count represents one through 256 beats.
    typedef struct packed {
        logic [noc_header_pkg::ORD_TAG_WIDTH-1:0] base;
        logic  [noc_payload_pkg::AXI_LEN_WIDTH:0] beat_count;
        logic                                     ordering_req;
        logic                                     collective;
    } nmu_rob_order_entry_t;

    // Enabled-mode B and R slot records.  Allocation and completion are
    // separate bits because an allocated response may not have arrived yet.
    typedef struct packed {
        logic                        occupied;
        logic                        complete;
        ni_signals_pkg::noc_axi_b_t  beat;
    } nmu_b_rob_entry_t;

    typedef struct packed {
        logic                                           occupied;
        logic                                           complete;
        logic                       [NARROW_LANE_W-1:0] narrow_lane;
        ni_signals_pkg::noc_axi_r_t                     beat;
    } nmu_r_rob_entry_t;

    // Narrow-read address basis shared by enabled bypass and structural
    // R_ROB_EN=0 paths.  beat_index advances on each accepted R beat.
    typedef struct packed {
        logic  [noc_payload_pkg::AXI_ADDR_WIDTH-1:0] local_addr;
        logic   [noc_payload_pkg::AXI_LEN_WIDTH-1:0] len;
        logic  [noc_payload_pkg::AXI_SIZE_WIDTH-1:0] size;
        logic [noc_payload_pkg::AXI_BURST_WIDTH-1:0] burst;
        logic   [noc_payload_pkg::AXI_LEN_WIDTH-1:0] beat_index;
    } nmu_read_context_t;

    // Response routing and original transaction identity. packet_type is the return B/R kind.
    typedef struct packed {
        logic                                                [NODE_ID_W-1:0] src_id;
        logic                            [noc_header_pkg::PORT_ID_WIDTH-1:0] src_port_id;
        logic                            [noc_payload_pkg::NOC_ID_WIDTH-1:0] noc_id;
        logic                                                                ordering_req;
        logic                            [noc_header_pkg::ORD_TAG_WIDTH-1:0] ordering_tag;
        noc_header_pkg::packet_type_t                                        packet_type;
        logic                          [noc_payload_pkg::AXI_ADDR_WIDTH-1:0] local_addr;
        logic                           [noc_payload_pkg::AXI_LEN_WIDTH-1:0] len;
        logic                          [noc_payload_pkg::AXI_SIZE_WIDTH-1:0] size;
        logic                         [noc_payload_pkg::AXI_BURST_WIDTH-1:0] burst;
        logic                            [noc_header_pkg::COLL_OP_WIDTH-1:0] collective_op;
        logic                          [noc_header_pkg::COLL_MASK_WIDTH-1:0] collective_mask;
    } nsu_context_t;

    typedef struct packed {
        ni_signals_pkg::noc_axi_aw_t                    axi;
        nsu_context_t                                   response;
    } nsu_aw_request_t;

    typedef struct packed {
        ni_signals_pkg::noc_axi_ar_t  axi;
        nsu_context_t                 response;
    } nsu_ar_request_t;

    typedef struct packed {
        ni_signals_pkg::noc_axi_b_t  axi;
        nsu_context_t                response;
    } nsu_b_response_t;

    typedef struct packed {
        ni_signals_pkg::noc_axi_r_t                                      axi;
        nsu_context_t                                                    response;
        logic                       [noc_payload_pkg::AXI_LEN_WIDTH-1:0] beat_index;
    } nsu_r_response_t;

    typedef struct packed {
        nsu_context_t                    response;
    } nsu_w_context_t;

endpackage

`endif // NI_TYPES_PKG_SVH
