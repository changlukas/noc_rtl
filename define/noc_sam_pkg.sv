// Native default SAM: integrated 4x4 accelerator mesh and external resources.
// Compile after noc_header_pkg.sv, noc_payload_pkg.sv and noc_unit_params_pkg.sv.
`timescale 1ns/1ps

package noc_sam_pkg;
    import noc_header_pkg::*;
    import noc_payload_pkg::*;
    import noc_unit_params_pkg::*;

    typedef logic [AXI_ADDR_WIDTH-1:0] sam_addr_t;

    // The first displayed rule has highest priority in the existing decoder.
    // This explicit default table is for 4x4. Update its rows when changing topology.
    localparam int SAM_NUM_RULES = 35;
    localparam int SAM_MASK_SEL_WIDTH = $clog2(AXI_ADDR_WIDTH + 1);
    localparam bit NARROW = 1'b0;
    localparam bit DATA = 1'b1;

    // Node base = 0x1000_0000 + (4*Y + X)*2 MiB.
    // Multicast address-mask selectors: X=[22:21], Y=[24:23].
    localparam sam_addr_t TILE_ADDR_STRIDE = sam_addr_t'(64'h0000_0020_0000);
    localparam int X_ADDR_OFFSET = $clog2(TILE_ADDR_STRIDE);
    localparam int X_ADDR_BITS = $clog2(MESH_X_DIM);
    localparam int Y_ADDR_OFFSET = X_ADDR_OFFSET + X_ADDR_BITS;
    localparam int Y_ADDR_BITS = $clog2(MESH_Y_DIM);

    typedef struct packed {
        logic [SAM_MASK_SEL_WIDTH-1:0] offset;
        logic [SAM_MASK_SEL_WIDTH-1:0] len;
    } sam_mask_sel_t;

    typedef struct packed {
        endpoint_id_t dst_id; // Combined {PORT_ID, Y, X}, as in the new header.
        logic is_data;
        logic collective_en;
        sam_mask_sel_t mask_x;
        sam_mask_sel_t mask_y;
    } sam_result_t;

    typedef struct packed {
        sam_result_t idx;
        sam_addr_t start_addr; // Included.
        sam_addr_t end_addr;   // Excluded.
    } sam_rule_t;
    typedef sam_rule_t [SAM_NUM_RULES-1:0] sam_table_t;

    // Constant record constructor only: no address expansion or runtime hardware.
    // MC-enabled rows use this default map's X/Y selectors. Other examples disable MC.
    function automatic sam_rule_t sam_rule(
        input logic [63:0] start_addr,
        input logic [63:0] end_addr,
        input int x, y, port_id,
        input bit is_data,
        input bit collective_en = 1'b1
    );
        sam_result_t result;
        result = '0;
        result.dst_id = '{port_id: PORT_ID_WIDTH'(port_id), y: Y_WIDTH'(y), x: X_WIDTH'(x)};
        result.is_data = is_data;
        result.collective_en = collective_en;
        if (collective_en) begin
            result.mask_x = '{offset: SAM_MASK_SEL_WIDTH'(X_ADDR_OFFSET), len: SAM_MASK_SEL_WIDTH'(X_ADDR_BITS)};
            result.mask_y = '{offset: SAM_MASK_SEL_WIDTH'(Y_ADDR_OFFSET), len: SAM_MASK_SEL_WIDTH'(Y_ADDR_BITS)};
        end
        return '{idx: result, start_addr: sam_addr_t'(start_addr), end_addr: sam_addr_t'(end_addr)};
    endfunction

    // Each node: 1 MiB SRAM followed immediately by an 8 KiB control window.
    // Control subwindows (node-relative): AI [0x0010_0000, 0x0010_1000),
    // DMA [0x0010_1000, 0x0010_2000). The endpoint performs local decode.
    // The remaining 1016 KiB of each 2 MiB slot is unmapped.
    // PORT=0: Local. PORT=1: X-boundary (West at X=0, East at X=3).
    // Node rows preserve multicast; external rows are unicast-only.
    //                       START (included)         END (excluded)           X  Y  PORT  DOMAIN
    localparam sam_table_t SAM = '{
        // Node 0: (0,0).
        sam_rule(64'h0000_1000_0000, 64'h0000_1010_0000, 0, 0, 0, DATA),
        sam_rule(64'h0000_1010_0000, 64'h0000_1010_2000, 0, 0, 0, NARROW),
        // Node 1: (1,0).
        sam_rule(64'h0000_1020_0000, 64'h0000_1030_0000, 1, 0, 0, DATA),
        sam_rule(64'h0000_1030_0000, 64'h0000_1030_2000, 1, 0, 0, NARROW),
        // Node 2: (2,0).
        sam_rule(64'h0000_1040_0000, 64'h0000_1050_0000, 2, 0, 0, DATA),
        sam_rule(64'h0000_1050_0000, 64'h0000_1050_2000, 2, 0, 0, NARROW),
        // Node 3: (3,0).
        sam_rule(64'h0000_1060_0000, 64'h0000_1070_0000, 3, 0, 0, DATA),
        sam_rule(64'h0000_1070_0000, 64'h0000_1070_2000, 3, 0, 0, NARROW),
        // Node 4: (0,1).
        sam_rule(64'h0000_1080_0000, 64'h0000_1090_0000, 0, 1, 0, DATA),
        sam_rule(64'h0000_1090_0000, 64'h0000_1090_2000, 0, 1, 0, NARROW),
        // Node 5: (1,1).
        sam_rule(64'h0000_10A0_0000, 64'h0000_10B0_0000, 1, 1, 0, DATA),
        sam_rule(64'h0000_10B0_0000, 64'h0000_10B0_2000, 1, 1, 0, NARROW),
        // Node 6: (2,1).
        sam_rule(64'h0000_10C0_0000, 64'h0000_10D0_0000, 2, 1, 0, DATA),
        sam_rule(64'h0000_10D0_0000, 64'h0000_10D0_2000, 2, 1, 0, NARROW),
        // Node 7: (3,1).
        sam_rule(64'h0000_10E0_0000, 64'h0000_10F0_0000, 3, 1, 0, DATA),
        sam_rule(64'h0000_10F0_0000, 64'h0000_10F0_2000, 3, 1, 0, NARROW),
        // Node 8: (0,2).
        sam_rule(64'h0000_1100_0000, 64'h0000_1110_0000, 0, 2, 0, DATA),
        sam_rule(64'h0000_1110_0000, 64'h0000_1110_2000, 0, 2, 0, NARROW),
        // Node 9: (1,2).
        sam_rule(64'h0000_1120_0000, 64'h0000_1130_0000, 1, 2, 0, DATA),
        sam_rule(64'h0000_1130_0000, 64'h0000_1130_2000, 1, 2, 0, NARROW),
        // Node 10: (2,2).
        sam_rule(64'h0000_1140_0000, 64'h0000_1150_0000, 2, 2, 0, DATA),
        sam_rule(64'h0000_1150_0000, 64'h0000_1150_2000, 2, 2, 0, NARROW),
        // Node 11: (3,2).
        sam_rule(64'h0000_1160_0000, 64'h0000_1170_0000, 3, 2, 0, DATA),
        sam_rule(64'h0000_1170_0000, 64'h0000_1170_2000, 3, 2, 0, NARROW),
        // Node 12: (0,3).
        sam_rule(64'h0000_1180_0000, 64'h0000_1190_0000, 0, 3, 0, DATA),
        sam_rule(64'h0000_1190_0000, 64'h0000_1190_2000, 0, 3, 0, NARROW),
        // Node 13: (1,3).
        sam_rule(64'h0000_11A0_0000, 64'h0000_11B0_0000, 1, 3, 0, DATA),
        sam_rule(64'h0000_11B0_0000, 64'h0000_11B0_2000, 1, 3, 0, NARROW),
        // Node 14: (2,3).
        sam_rule(64'h0000_11C0_0000, 64'h0000_11D0_0000, 2, 3, 0, DATA),
        sam_rule(64'h0000_11D0_0000, 64'h0000_11D0_2000, 2, 3, 0, NARROW),
        // Node 15: (3,3).
        sam_rule(64'h0000_11E0_0000, 64'h0000_11F0_0000, 3, 3, 0, DATA),
        sam_rule(64'h0000_11F0_0000, 64'h0000_11F0_2000, 3, 3, 0, NARROW),
        // Boot ROM: 64 KiB, external West endpoint of (0,0).
        sam_rule(64'h0000_0000_0000, 64'h0000_0001_0000, 0, 0, 1, NARROW, 1'b0),
        // I/O: four 4 KiB subwindows, decoded at the external West endpoint.
        // UART 0x4000_0000; GPIO 0x4000_1000; Timer 0x4000_2000; System 0x4000_3000.
        sam_rule(64'h0000_4000_0000, 64'h0000_4000_4000, 0, 0, 1, NARROW, 1'b0),
        // Shared DRAM: 1 GiB, external East endpoint of (3,1).
        sam_rule(64'h0000_8000_0000, 64'h0000_C000_0000, 3, 1, 1, DATA, 1'b0)
    };
endpackage
