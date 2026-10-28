// Native default SAM: the mesh_4x4 address map, without YAML generation.
// Compile after noc_header_pkg.sv, noc_payload_pkg.sv and noc_unit_params_pkg.sv.
`timescale 1ns/1ps

package noc_sam_pkg;
    import noc_header_pkg::*;
    import noc_payload_pkg::*;
    import noc_unit_params_pkg::*;

    typedef logic [AXI_ADDR_WIDTH-1:0] sam_addr_t;

    // The first displayed rule has highest priority in the existing decoder.
    // This explicit default table is for 4x4. Update its rows when changing topology.
    localparam int SAM_NUM_RULES = 32;
    localparam int SAM_MASK_SEL_WIDTH = $clog2(AXI_ADDR_WIDTH + 1);
    localparam bit NARROW = 1'b0;
    localparam bit DATA = 1'b1;

    // Default tile-address coordinates occupy X=[33:32], Y=[35:34].
    localparam sam_addr_t TILE_ADDR_STRIDE = sam_addr_t'(64'h0001_0000_0000);
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

    //                       START (included)         END (excluded)           X  Y  PORT  DOMAIN
    // All default rows enable multicast. PORT=0 is the tile's local endpoint.
    localparam sam_table_t SAM = '{
        sam_rule(64'h0000_0000_0000, 64'h0000_0200_0000, 0, 0, 0, DATA),
        sam_rule(64'h0001_0000_0000, 64'h0001_0200_0000, 1, 0, 0, DATA),
        sam_rule(64'h0002_0000_0000, 64'h0002_0200_0000, 2, 0, 0, DATA),
        sam_rule(64'h0003_0000_0000, 64'h0003_0200_0000, 3, 0, 0, DATA),
        sam_rule(64'h0004_0000_0000, 64'h0004_0200_0000, 0, 1, 0, DATA),
        sam_rule(64'h0005_0000_0000, 64'h0005_0200_0000, 1, 1, 0, DATA),
        sam_rule(64'h0006_0000_0000, 64'h0006_0200_0000, 2, 1, 0, DATA),
        sam_rule(64'h0007_0000_0000, 64'h0007_0200_0000, 3, 1, 0, DATA),
        sam_rule(64'h0008_0000_0000, 64'h0008_0200_0000, 0, 2, 0, DATA),
        sam_rule(64'h0009_0000_0000, 64'h0009_0200_0000, 1, 2, 0, DATA),
        sam_rule(64'h000A_0000_0000, 64'h000A_0200_0000, 2, 2, 0, DATA),
        sam_rule(64'h000B_0000_0000, 64'h000B_0200_0000, 3, 2, 0, DATA),
        sam_rule(64'h000C_0000_0000, 64'h000C_0200_0000, 0, 3, 0, DATA),
        sam_rule(64'h000D_0000_0000, 64'h000D_0200_0000, 1, 3, 0, DATA),
        sam_rule(64'h000E_0000_0000, 64'h000E_0200_0000, 2, 3, 0, DATA),
        sam_rule(64'h000F_0000_0000, 64'h000F_0200_0000, 3, 3, 0, DATA),
        sam_rule(64'h0000_0200_0000, 64'h0000_0200_1000, 0, 0, 0, NARROW),
        sam_rule(64'h0001_0200_0000, 64'h0001_0200_1000, 1, 0, 0, NARROW),
        sam_rule(64'h0002_0200_0000, 64'h0002_0200_1000, 2, 0, 0, NARROW),
        sam_rule(64'h0003_0200_0000, 64'h0003_0200_1000, 3, 0, 0, NARROW),
        sam_rule(64'h0004_0200_0000, 64'h0004_0200_1000, 0, 1, 0, NARROW),
        sam_rule(64'h0005_0200_0000, 64'h0005_0200_1000, 1, 1, 0, NARROW),
        sam_rule(64'h0006_0200_0000, 64'h0006_0200_1000, 2, 1, 0, NARROW),
        sam_rule(64'h0007_0200_0000, 64'h0007_0200_1000, 3, 1, 0, NARROW),
        sam_rule(64'h0008_0200_0000, 64'h0008_0200_1000, 0, 2, 0, NARROW),
        sam_rule(64'h0009_0200_0000, 64'h0009_0200_1000, 1, 2, 0, NARROW),
        sam_rule(64'h000A_0200_0000, 64'h000A_0200_1000, 2, 2, 0, NARROW),
        sam_rule(64'h000B_0200_0000, 64'h000B_0200_1000, 3, 2, 0, NARROW),
        sam_rule(64'h000C_0200_0000, 64'h000C_0200_1000, 0, 3, 0, NARROW),
        sam_rule(64'h000D_0200_0000, 64'h000D_0200_1000, 1, 3, 0, NARROW),
        sam_rule(64'h000E_0200_0000, 64'h000E_0200_1000, 2, 3, 0, NARROW),
        sam_rule(64'h000F_0200_0000, 64'h000F_0200_1000, 3, 3, 0, NARROW)
    };
endpackage
