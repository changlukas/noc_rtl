// Header configuration, encodings, packed types and field positions.
`timescale 1ns/1ps

package noc_header_pkg;
    localparam int X_WIDTH = 4;
    localparam int Y_WIDTH = 4;
    localparam int PORT_ID_WIDTH = 2;
    localparam int ORD_TAG_WIDTH = 8;

    // Packet kinds and collective operation encodings.
    typedef enum logic [3:0] {
        PKT_NARROW_AW = 4'h0, PKT_NARROW_W = 4'h1,
        PKT_NARROW_AR = 4'h2, PKT_NARROW_B = 4'h3,
        PKT_NARROW_R = 4'h4, PKT_DATA_AW = 4'h5,
        PKT_DATA_W = 4'h6, PKT_DATA_AR = 4'h7,
        PKT_DATA_B = 4'h8, PKT_DATA_R = 4'h9
    } packet_type_t;

    typedef enum logic [1:0] {
        COLL_UNICAST = 2'd0, COLL_MULTICAST = 2'd1
    } collective_op_t;

    typedef enum logic [1:0] {
        NETWORK_REQ, NETWORK_RSP, NETWORK_DAT, NETWORK_INVALID
    } network_t;

    // Derived header widths.
    localparam int PACKET_TYPE_WIDTH = $bits(packet_type_t);
    localparam int COLL_OP_WIDTH = $bits(collective_op_t);
    localparam int COLL_MASK_WIDTH = X_WIDTH + Y_WIDTH;

    // Endpoint ID packs {PORT_ID, Y, X}; the port occupies the MSBs.
    typedef struct packed {
        logic [PORT_ID_WIDTH-1:0] port_id;
        logic [Y_WIDTH-1:0] y;
        logic [X_WIDTH-1:0] x;
    } endpoint_id_t;
    localparam int ENDPOINT_ID_WIDTH = $bits(endpoint_id_t);
    localparam int EP_X_LSB = 0;
    localparam int EP_Y_LSB = X_WIDTH;
    localparam int EP_PORT_ID_LSB = X_WIDTH + Y_WIDTH;

    typedef struct packed {
        logic [COLL_MASK_WIDTH-1:0] coll_mask;
        collective_op_t coll_op;
        logic [ORD_TAG_WIDTH-1:0] ord_tag;
        logic ord_req;
        logic flit_tail;
        endpoint_id_t dst_id;
        endpoint_id_t src_id;
        packet_type_t packet_type;
    } header_t;
    localparam int HEADER_WIDTH = $bits(header_t);
    localparam int PACKET_TYPE_LSB = 0;
    localparam int SRC_ID_LSB = PACKET_TYPE_LSB + PACKET_TYPE_WIDTH;
    localparam int DST_ID_LSB = SRC_ID_LSB + ENDPOINT_ID_WIDTH;
    localparam int FLIT_TAIL_LSB = DST_ID_LSB + ENDPOINT_ID_WIDTH;
    localparam int ORD_REQ_LSB = FLIT_TAIL_LSB + 1;
    localparam int ORD_TAG_LSB = ORD_REQ_LSB + 1;
    localparam int COLL_OP_LSB = ORD_TAG_LSB + ORD_TAG_WIDTH;
    localparam int COLL_MASK_LSB = COLL_OP_LSB + COLL_OP_WIDTH;
endpackage
