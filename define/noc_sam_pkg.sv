// Native default SAM: the mesh_4x4 address map, without YAML generation.
// Compile after noc_header_pkg.sv, noc_payload_pkg.sv and noc_unit_params_pkg.sv.
`timescale 1ns/1ps

package noc_sam_pkg;
    import noc_header_pkg::*;
    import noc_payload_pkg::*;
    import noc_unit_params_pkg::*;

    typedef logic [AXI_ADDR_WIDTH-1:0] sam_addr_t;

    // Editable address-map settings. Endpoint coordinates use the shared mesh size.
    localparam sam_addr_t TILE_ADDR_STRIDE = 48'h0001_0000_0000; // 4 GiB
    localparam sam_addr_t MEMORY_BASE      = 48'h0000_0000_0000;
    localparam sam_addr_t MEMORY_SIZE      = 48'h0000_0200_0000; // 32 MiB
    localparam sam_addr_t CONFIG_BASE      = 48'h0000_0200_0000;
    localparam sam_addr_t CONFIG_SIZE      = 48'h0000_0000_1000; // 4 KiB

    // Each tile has two ranges. Table contents are elaboration-time constants.
    localparam int TILE_COUNT = MESH_X_DIM * MESH_Y_DIM;
    localparam int SAM_NUM_RULES = 2 * TILE_COUNT;
    localparam int SAM_MASK_SEL_WIDTH = $clog2(AXI_ADDR_WIDTH + 1);
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

    // Default layout requires power-of-two mesh dimensions and tile stride.
    // Address-mask positions must fit AXI_ADDR_WIDTH and coordinate widths.
    function automatic sam_table_t build_sam();
        sam_table_t table_value;
        sam_result_t destination;
        sam_addr_t tile_base;
        table_value = '0;
        for (int tile = 0; tile < TILE_COUNT; tile++) begin
            tile_base = sam_addr_t'(tile) * TILE_ADDR_STRIDE;
            destination = '{
                dst_id: '{port_id: '0, y: Y_WIDTH'(tile / MESH_X_DIM),
                          x: X_WIDTH'(tile % MESH_X_DIM)},
                is_data: 1'b1,
                collective_en: 1'b1,
                mask_x: '{offset: SAM_MASK_SEL_WIDTH'(X_ADDR_OFFSET),
                          len: SAM_MASK_SEL_WIDTH'(X_ADDR_BITS)},
                mask_y: '{offset: SAM_MASK_SEL_WIDTH'(Y_ADDR_OFFSET),
                          len: SAM_MASK_SEL_WIDTH'(Y_ADDR_BITS)}
            };
            // Preserve authored order: memory tiles first, then config tiles.
            // The existing decoder gives higher packed-array indices priority.
            table_value[SAM_NUM_RULES-1-tile] = '{
                idx: destination,
                start_addr: tile_base + MEMORY_BASE,
                end_addr: tile_base + MEMORY_BASE + MEMORY_SIZE
            };
            destination.is_data = 1'b0;
            table_value[TILE_COUNT-1-tile] = '{
                idx: destination,
                start_addr: tile_base + CONFIG_BASE,
                end_addr: tile_base + CONFIG_BASE + CONFIG_SIZE
            };
        end
        return table_value;
    endfunction

    // Default examples (tile = y*4+x; PORT_ID=0):
    // SAM[31]: tile (0,0), memory [0x000000000000, 0x000002000000), is_data=1
    // SAM[15]: tile (0,0), config [0x000002000000, 0x000002001000), is_data=0
    // SAM[16]: tile (3,3), memory [0x000F00000000, 0x000F02000000), is_data=1
    // SAM[ 0]: tile (3,3), config [0x000F02000000, 0x000F02001000), is_data=0
    localparam sam_table_t SAM = build_sam();
endpackage
