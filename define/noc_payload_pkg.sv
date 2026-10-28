// AXI payload configuration and packet containers. Compile after noc_header_pkg.sv.
`timescale 1ns/1ps

package noc_payload_pkg;
    localparam int AXI_ID_WIDTH = 3;
    localparam int AXI_ADDR_WIDTH = 48;
    localparam int DATA_WIDTH = 512;
    localparam int NARROW_DATA_WIDTH = 64;
    localparam int AWUSER_WIDTH = 8;
    localparam int ARUSER_WIDTH = 8;
    localparam int WUSER_WIDTH = 8;
    localparam int BUSER_WIDTH = 8;
    localparam int RUSER_WIDTH = 8;

    import noc_header_pkg::*;

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
    localparam int WSTRB_WIDTH = DATA_WIDTH / 8;
    localparam int NARROW_WSTRB_WIDTH = NARROW_DATA_WIDTH / 8;
    localparam int NOC_ID_WIDTH = AXI_ID_WIDTH;

    // External AWUSER carries collective metadata in addition to opaque USER.
    localparam int AXI_AWUSER_USER_LSB = 0;
    localparam int AXI_AWUSER_COLL_OP_LSB = AWUSER_WIDTH;
    localparam int AXI_AWUSER_ADDR_MASK_LSB = AWUSER_WIDTH + COLL_OP_WIDTH;
    localparam int AXI_AWUSER_WIDTH = AWUSER_WIDTH + COLL_OP_WIDTH + AXI_ADDR_WIDTH;

    // Payloads use packed vectors so a zero-width USER field occupies no bits.
    // Field ranges are [LSB + WIDTH - 1 : LSB]; do not slice a WIDTH=0 field.
    // AW payload: widths, bit positions and packed vector type.
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

    // AR payload: widths, bit positions and packed vector type.
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

    // NARROW_W payload: widths, bit positions and packed vector type.
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

    // DATA_W payload: widths, bit positions and packed vector type.
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

    // B payload: widths, bit positions and packed vector type.
    localparam int B_BID_WIDTH = AXI_ID_WIDTH;
    localparam int B_BID_LSB = 0;
    localparam int B_BRESP_WIDTH = AXI_RESP_WIDTH;
    localparam int B_BRESP_LSB = B_BID_LSB + B_BID_WIDTH;
    localparam int B_BUSER_WIDTH = BUSER_WIDTH;
    localparam int B_BUSER_LSB = B_BRESP_LSB + B_BRESP_WIDTH;
    localparam int B_WIDTH = B_BUSER_LSB + B_BUSER_WIDTH;
    typedef logic [B_WIDTH-1:0] b_payload_t;

    // NARROW_R payload: widths, bit positions and packed vector type.
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

    // DATA_R payload: widths, bit positions and packed vector type.
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


    // Network payload budgets and flit containers (header at the LSBs).
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
endpackage
