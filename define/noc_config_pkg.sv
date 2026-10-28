// Global NoC configuration and packet contract. Compile this file first.
// Edit only the USER CONFIGURATION section to select a build profile.
`timescale 1ns/1ps

package noc_config_pkg;

    typedef enum logic {READY_VALID, CREDIT_BASED} flow_control_t;

    // USER CONFIGURATION: one global profile for the complete network.
    // Defaults match head_format.jpg and payload_format.jpg (3-bit AXI IDs).
    localparam int AXI_ID_WIDTH = 3;
    localparam int NSU_AXI_ID_WIDTH = 3;
    localparam int AXI_ADDR_WIDTH = 48;
    localparam int DATA_WIDTH = 512;
    localparam int NARROW_DATA_WIDTH = 64;
    // These widths describe opaque transported USER bits; zero omits the field.
    localparam int AWUSER_WIDTH = 8;
    localparam int ARUSER_WIDTH = 8;
    localparam int WUSER_WIDTH = 8;
    localparam int BUSER_WIDTH = 8;
    localparam int RUSER_WIDTH = 8;
    localparam int X_WIDTH = 4;
    localparam int Y_WIDTH = 4;
    localparam int PORT_ID_WIDTH = 2;
    localparam int ORD_TAG_WIDTH = 8;
    localparam int MESH_X_DIM = 4;
    localparam int MESH_Y_DIM = 4;
    localparam flow_control_t FLOW_CONTROL = CREDIT_BASED;
    localparam int AXI_FIFO_DEPTH = 8;
    localparam int NOC_FIFO_DEPTH = 8;
    localparam int CREDIT_DEPTH = 8;
    localparam int ROUTER_OUTPUT_FIFO_DEPTH = 8;
    localparam bit NMU_R_ROB_EN = 1'b1;
    localparam int NMU_ROB_B_DEPTH = 128;
    localparam int NMU_ROB_R_DEPTH = 128;
    localparam int NMU_MAX_OUTSTANDING_PER_ID = 32;
    localparam int NMU_QUEUE_DEPTH = 16;
    localparam int NMU_DEPKT_Q_DEPTH = 16;
    localparam int NMU_ARBITER_FIFO_DEPTH = 4;
    localparam int NSU_MAX_ACTIVE_IDS = 8;
    localparam int NSU_MAX_OUTSTANDING = 32;
    localparam int NSU_QUEUE_DEPTH = 16;
    localparam int NSU_ARBITER_FIFO_DEPTH = 4;
    // END USER CONFIGURATION. Everything below is fixed or derived.

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

    typedef enum int {NORTH = 0, EAST = 1, SOUTH = 2, WEST = 3, LOCAL = 4} direction_t;
    // Fixed traffic classes, not an allocator: one write VC and one read VC.
    localparam int DAT_WRITE_VC = 0;
    localparam int DAT_READ_VC = 1;
    localparam int DAT_NUM_VC = 2;
    localparam int REQ_NUM_VC = 1;
    localparam int RSP_NUM_VC = 1;

    // AXI4 protocol widths; these are not user configuration knobs.
    localparam int AXI_LEN_WIDTH = 8;
    localparam int AXI_SIZE_WIDTH = 3;
    localparam int AXI_BURST_WIDTH = 2;
    localparam int AXI_CACHE_WIDTH = 4;
    localparam int AXI_LOCK_WIDTH = 1;
    localparam int AXI_PROT_WIDTH = 3;
    localparam int AXI_REGION_WIDTH = 4;
    localparam int AXI_QOS_WIDTH = 4;
    localparam int AXI_RESP_WIDTH = 2;
    localparam int AXI_LAST_WIDTH = 1;
    localparam int PACKET_TYPE_WIDTH = $bits(packet_type_t);
    localparam int COLL_OP_WIDTH = $bits(collective_op_t);
    localparam int COLL_MASK_WIDTH = X_WIDTH + Y_WIDTH;
    localparam int WSTRB_WIDTH = DATA_WIDTH / 8;
    localparam int NARROW_WSTRB_WIDTH = NARROW_DATA_WIDTH / 8;
    localparam int NOC_ID_WIDTH = AXI_ID_WIDTH;
    // External AWUSER carries collective metadata in addition to opaque USER.
    localparam int AXI_AWUSER_USER_LSB = 0;
    localparam int AXI_AWUSER_COLL_OP_LSB = AWUSER_WIDTH;
    localparam int AXI_AWUSER_ADDR_MASK_LSB = AWUSER_WIDTH + COLL_OP_WIDTH;
    localparam int AXI_AWUSER_WIDTH = AWUSER_WIDTH + COLL_OP_WIDTH + AXI_ADDR_WIDTH;

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

    // Payloads use packed vectors so a zero-width USER field occupies no bits.
    // Field ranges are [LSB + WIDTH - 1 : LSB]; do not slice a WIDTH=0 field.
    localparam int AW_AWID_WIDTH = AXI_ID_WIDTH;
    localparam int AW_AWID_LSB = 0;
    localparam int AW_AWADDR_WIDTH = AXI_ADDR_WIDTH;
    localparam int AW_AWADDR_LSB = AW_AWID_LSB + AW_AWID_WIDTH;
    localparam int AW_AWLEN_WIDTH = AXI_LEN_WIDTH;
    localparam int AW_AWLEN_LSB = AW_AWADDR_LSB + AW_AWADDR_WIDTH;
    localparam int AW_AWSIZE_WIDTH = AXI_SIZE_WIDTH;
    localparam int AW_AWSIZE_LSB = AW_AWLEN_LSB + AW_AWLEN_WIDTH;
    localparam int AW_AWBURST_WIDTH = AXI_BURST_WIDTH;
    localparam int AW_AWBURST_LSB = AW_AWSIZE_LSB + AW_AWSIZE_WIDTH;
    localparam int AW_AWCACHE_WIDTH = AXI_CACHE_WIDTH;
    localparam int AW_AWCACHE_LSB = AW_AWBURST_LSB + AW_AWBURST_WIDTH;
    localparam int AW_AWLOCK_WIDTH = AXI_LOCK_WIDTH;
    localparam int AW_AWLOCK_LSB = AW_AWCACHE_LSB + AW_AWCACHE_WIDTH;
    localparam int AW_AWPROT_WIDTH = AXI_PROT_WIDTH;
    localparam int AW_AWPROT_LSB = AW_AWLOCK_LSB + AW_AWLOCK_WIDTH;
    localparam int AW_AWREGION_WIDTH = AXI_REGION_WIDTH;
    localparam int AW_AWREGION_LSB = AW_AWPROT_LSB + AW_AWPROT_WIDTH;
    localparam int AW_AWQOS_WIDTH = AXI_QOS_WIDTH;
    localparam int AW_AWQOS_LSB = AW_AWREGION_LSB + AW_AWREGION_WIDTH;
    localparam int AW_AWUSER_WIDTH = AWUSER_WIDTH;
    localparam int AW_AWUSER_LSB = AW_AWQOS_LSB + AW_AWQOS_WIDTH;
    localparam int AW_WIDTH = AW_AWUSER_LSB + AW_AWUSER_WIDTH;
    typedef logic [AW_WIDTH-1:0] aw_payload_t;

    localparam int AR_ARID_WIDTH = AXI_ID_WIDTH;
    localparam int AR_ARID_LSB = 0;
    localparam int AR_ARADDR_WIDTH = AXI_ADDR_WIDTH;
    localparam int AR_ARADDR_LSB = AR_ARID_LSB + AR_ARID_WIDTH;
    localparam int AR_ARLEN_WIDTH = AXI_LEN_WIDTH;
    localparam int AR_ARLEN_LSB = AR_ARADDR_LSB + AR_ARADDR_WIDTH;
    localparam int AR_ARSIZE_WIDTH = AXI_SIZE_WIDTH;
    localparam int AR_ARSIZE_LSB = AR_ARLEN_LSB + AR_ARLEN_WIDTH;
    localparam int AR_ARBURST_WIDTH = AXI_BURST_WIDTH;
    localparam int AR_ARBURST_LSB = AR_ARSIZE_LSB + AR_ARSIZE_WIDTH;
    localparam int AR_ARCACHE_WIDTH = AXI_CACHE_WIDTH;
    localparam int AR_ARCACHE_LSB = AR_ARBURST_LSB + AR_ARBURST_WIDTH;
    localparam int AR_ARLOCK_WIDTH = AXI_LOCK_WIDTH;
    localparam int AR_ARLOCK_LSB = AR_ARCACHE_LSB + AR_ARCACHE_WIDTH;
    localparam int AR_ARPROT_WIDTH = AXI_PROT_WIDTH;
    localparam int AR_ARPROT_LSB = AR_ARLOCK_LSB + AR_ARLOCK_WIDTH;
    localparam int AR_ARREGION_WIDTH = AXI_REGION_WIDTH;
    localparam int AR_ARREGION_LSB = AR_ARPROT_LSB + AR_ARPROT_WIDTH;
    localparam int AR_ARQOS_WIDTH = AXI_QOS_WIDTH;
    localparam int AR_ARQOS_LSB = AR_ARREGION_LSB + AR_ARREGION_WIDTH;
    localparam int AR_ARUSER_WIDTH = ARUSER_WIDTH;
    localparam int AR_ARUSER_LSB = AR_ARQOS_LSB + AR_ARQOS_WIDTH;
    localparam int AR_WIDTH = AR_ARUSER_LSB + AR_ARUSER_WIDTH;
    typedef logic [AR_WIDTH-1:0] ar_payload_t;

    localparam int NARROW_W_WLAST_WIDTH = AXI_LAST_WIDTH;
    localparam int NARROW_W_WLAST_LSB = 0;
    localparam int NARROW_W_WUSER_WIDTH = WUSER_WIDTH;
    localparam int NARROW_W_WUSER_LSB = NARROW_W_WLAST_LSB + NARROW_W_WLAST_WIDTH;
    localparam int NARROW_W_WSTRB_WIDTH = NARROW_WSTRB_WIDTH;
    localparam int NARROW_W_WSTRB_LSB = NARROW_W_WUSER_LSB + NARROW_W_WUSER_WIDTH;
    localparam int NARROW_W_WDATA_WIDTH = NARROW_DATA_WIDTH;
    localparam int NARROW_W_WDATA_LSB = NARROW_W_WSTRB_LSB + NARROW_W_WSTRB_WIDTH;
    localparam int NARROW_W_WIDTH = NARROW_W_WDATA_LSB + NARROW_W_WDATA_WIDTH;
    typedef logic [NARROW_W_WIDTH-1:0] narrow_w_payload_t;

    localparam int DATA_W_WLAST_WIDTH = AXI_LAST_WIDTH;
    localparam int DATA_W_WLAST_LSB = 0;
    localparam int DATA_W_WUSER_WIDTH = WUSER_WIDTH;
    localparam int DATA_W_WUSER_LSB = DATA_W_WLAST_LSB + DATA_W_WLAST_WIDTH;
    localparam int DATA_W_WSTRB_WIDTH = WSTRB_WIDTH;
    localparam int DATA_W_WSTRB_LSB = DATA_W_WUSER_LSB + DATA_W_WUSER_WIDTH;
    localparam int DATA_W_WDATA_WIDTH = DATA_WIDTH;
    localparam int DATA_W_WDATA_LSB = DATA_W_WSTRB_LSB + DATA_W_WSTRB_WIDTH;
    localparam int DATA_W_WIDTH = DATA_W_WDATA_LSB + DATA_W_WDATA_WIDTH;
    typedef logic [DATA_W_WIDTH-1:0] data_w_payload_t;

    localparam int B_BID_WIDTH = AXI_ID_WIDTH;
    localparam int B_BID_LSB = 0;
    localparam int B_BRESP_WIDTH = AXI_RESP_WIDTH;
    localparam int B_BRESP_LSB = B_BID_LSB + B_BID_WIDTH;
    localparam int B_BUSER_WIDTH = BUSER_WIDTH;
    localparam int B_BUSER_LSB = B_BRESP_LSB + B_BRESP_WIDTH;
    localparam int B_WIDTH = B_BUSER_LSB + B_BUSER_WIDTH;
    typedef logic [B_WIDTH-1:0] b_payload_t;

    localparam int NARROW_R_RLAST_WIDTH = AXI_LAST_WIDTH;
    localparam int NARROW_R_RLAST_LSB = 0;
    localparam int NARROW_R_RID_WIDTH = AXI_ID_WIDTH;
    localparam int NARROW_R_RID_LSB = NARROW_R_RLAST_LSB + NARROW_R_RLAST_WIDTH;
    localparam int NARROW_R_RRESP_WIDTH = AXI_RESP_WIDTH;
    localparam int NARROW_R_RRESP_LSB = NARROW_R_RID_LSB + NARROW_R_RID_WIDTH;
    localparam int NARROW_R_RUSER_WIDTH = RUSER_WIDTH;
    localparam int NARROW_R_RUSER_LSB = NARROW_R_RRESP_LSB + NARROW_R_RRESP_WIDTH;
    localparam int NARROW_R_RDATA_WIDTH = NARROW_DATA_WIDTH;
    localparam int NARROW_R_RDATA_LSB = NARROW_R_RUSER_LSB + NARROW_R_RUSER_WIDTH;
    localparam int NARROW_R_WIDTH = NARROW_R_RDATA_LSB + NARROW_R_RDATA_WIDTH;
    typedef logic [NARROW_R_WIDTH-1:0] narrow_r_payload_t;

    localparam int DATA_R_RLAST_WIDTH = AXI_LAST_WIDTH;
    localparam int DATA_R_RLAST_LSB = 0;
    localparam int DATA_R_RID_WIDTH = AXI_ID_WIDTH;
    localparam int DATA_R_RID_LSB = DATA_R_RLAST_LSB + DATA_R_RLAST_WIDTH;
    localparam int DATA_R_RRESP_WIDTH = AXI_RESP_WIDTH;
    localparam int DATA_R_RRESP_LSB = DATA_R_RID_LSB + DATA_R_RID_WIDTH;
    localparam int DATA_R_RUSER_WIDTH = RUSER_WIDTH;
    localparam int DATA_R_RUSER_LSB = DATA_R_RRESP_LSB + DATA_R_RRESP_WIDTH;
    localparam int DATA_R_RDATA_WIDTH = DATA_WIDTH;
    localparam int DATA_R_RDATA_LSB = DATA_R_RUSER_LSB + DATA_R_RUSER_WIDTH;
    localparam int DATA_R_WIDTH = DATA_R_RDATA_LSB + DATA_R_RDATA_WIDTH;
    typedef logic [DATA_R_WIDTH-1:0] data_r_payload_t;


    function automatic int max2(input int a, input int b);
        return a > b ? a : b;
    endfunction

    localparam int REQ_PAYLOAD_WIDTH = max2(max2(AW_WIDTH, AR_WIDTH), NARROW_W_WIDTH);
    localparam int RSP_PAYLOAD_WIDTH = max2(B_WIDTH, NARROW_R_WIDTH);
    localparam int DAT_PAYLOAD_WIDTH = max2(max2(AW_WIDTH, DATA_W_WIDTH), DATA_R_WIDTH);
    typedef struct packed {logic [REQ_PAYLOAD_WIDTH-1:0] payload; header_t header;} req_flit_t;
    typedef struct packed {logic [RSP_PAYLOAD_WIDTH-1:0] payload; header_t header;} rsp_flit_t;
    typedef struct packed {logic [DAT_PAYLOAD_WIDTH-1:0] payload; header_t header;} dat_flit_t;
    localparam int REQ_FLIT_WIDTH = $bits(req_flit_t);
    localparam int RSP_FLIT_WIDTH = $bits(rsp_flit_t);
    localparam int DAT_FLIT_WIDTH = $bits(dat_flit_t);

    function automatic network_t packet_network(input packet_type_t kind);
        case (kind)
            PKT_NARROW_AW, PKT_NARROW_W, PKT_NARROW_AR, PKT_DATA_AR: return NETWORK_REQ;
            PKT_NARROW_B, PKT_NARROW_R, PKT_DATA_B: return NETWORK_RSP;
            PKT_DATA_AW, PKT_DATA_W, PKT_DATA_R: return NETWORK_DAT;
            default: return NETWORK_INVALID;
        endcase
    endfunction

    function automatic int payload_width(input packet_type_t kind);
        case (kind)
            PKT_NARROW_AW, PKT_DATA_AW: return AW_WIDTH;
            PKT_NARROW_AR, PKT_DATA_AR: return AR_WIDTH;
            PKT_NARROW_W: return NARROW_W_WIDTH;
            PKT_NARROW_B, PKT_DATA_B: return B_WIDTH;
            PKT_NARROW_R: return NARROW_R_WIDTH;
            PKT_DATA_W: return DATA_W_WIDTH;
            PKT_DATA_R: return DATA_R_WIDTH;
            default: return 0;
        endcase
    endfunction

    function automatic bit valid_data_width(input int width);
        return width >= 8 && width <= 1024 && (width & (width-1)) == 0;
    endfunction

    function automatic bit config_valid();
        return AXI_ID_WIDTH >= 1 && AXI_ID_WIDTH <= 8 &&
            NSU_AXI_ID_WIDTH >= 1 && NSU_AXI_ID_WIDTH <= 8 &&
            AXI_ADDR_WIDTH >= 1 && AXI_ADDR_WIDTH <= 64 &&
            valid_data_width(DATA_WIDTH) && valid_data_width(NARROW_DATA_WIDTH) &&
            DATA_WIDTH >= NARROW_DATA_WIDTH &&
            AWUSER_WIDTH >= 0 && ARUSER_WIDTH >= 0 && WUSER_WIDTH >= 0 &&
            BUSER_WIDTH >= 0 && RUSER_WIDTH >= 0 &&
            X_WIDTH >= 1 && X_WIDTH <= 16 && Y_WIDTH >= 1 && Y_WIDTH <= 16 &&
            PORT_ID_WIDTH >= 1 && PORT_ID_WIDTH <= 8 && ORD_TAG_WIDTH >= 1 &&
            MESH_X_DIM >= 1 && MESH_X_DIM <= 2**X_WIDTH &&
            MESH_Y_DIM >= 1 && MESH_Y_DIM <= 2**Y_WIDTH &&
            (FLOW_CONTROL == READY_VALID || FLOW_CONTROL == CREDIT_BASED) &&
            AXI_FIFO_DEPTH >= 2 && (AXI_FIFO_DEPTH & (AXI_FIFO_DEPTH-1)) == 0 &&
            NOC_FIFO_DEPTH >= 1 && (NOC_FIFO_DEPTH & (NOC_FIFO_DEPTH-1)) == 0 &&
            CREDIT_DEPTH >= 2 && (CREDIT_DEPTH & (CREDIT_DEPTH-1)) == 0 &&
            ROUTER_OUTPUT_FIFO_DEPTH >= 0 &&
            NMU_ROB_B_DEPTH >= 1 && NMU_ROB_R_DEPTH >= 1 &&
            NMU_MAX_OUTSTANDING_PER_ID >= 1 && NMU_QUEUE_DEPTH >= 1 &&
            NMU_DEPKT_Q_DEPTH >= 1 && NMU_ARBITER_FIFO_DEPTH >= 1 &&
            NSU_MAX_ACTIVE_IDS >= 1 && NSU_MAX_ACTIVE_IDS <= 2**NSU_AXI_ID_WIDTH &&
            NSU_MAX_OUTSTANDING >= NSU_MAX_ACTIVE_IDS &&
            NSU_QUEUE_DEPTH >= 1 && NSU_ARBITER_FIFO_DEPTH >= 1;
    endfunction
endpackage

// Instantiate once in the future integration top (or use make check-config now).
module noc_config_check;
    initial begin
        if (!noc_config_pkg::config_valid()) begin
            $fatal(1, "Invalid global NoC configuration; check noc_config_pkg.sv");
        end
    end
endmodule
