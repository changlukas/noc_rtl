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
    localparam int SAM_NUM_RULES = 52;
    localparam int SAM_MASK_SEL_WIDTH = $clog2(AXI_ADDR_WIDTH + 1);
    localparam bit NARROW = 1'b0;
    localparam bit DATA = 1'b1;

    // Node base = (4*Y + X)*2 MiB, beginning at address zero.
    // Multicast address-mask selectors: X=[22:21], Y=[24:23].
    localparam sam_addr_t TILE_ADDR_STRIDE = sam_addr_t'(48'h0000_0020_0000);
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
    // Mask selectors describe address-mask encoding; no per-region enable flag.
    function automatic sam_rule_t sam_rule(
        input sam_addr_t start_addr,
        input sam_addr_t end_addr,
        input int x, y, port_id,
        input bit is_data,
        input sam_mask_sel_t mask_x = '{offset: SAM_MASK_SEL_WIDTH'(X_ADDR_OFFSET), len: SAM_MASK_SEL_WIDTH'(X_ADDR_BITS)},
        input sam_mask_sel_t mask_y = '{offset: SAM_MASK_SEL_WIDTH'(Y_ADDR_OFFSET), len: SAM_MASK_SEL_WIDTH'(Y_ADDR_BITS)}
    );
        sam_result_t result;
        result = '0;
        result.dst_id = '{port_id: PORT_ID_WIDTH'(port_id), y: Y_WIDTH'(y), x: X_WIDTH'(x)};
        result.is_data = is_data;
        result.mask_x = mask_x;
        result.mask_y = mask_y;
        return '{idx: result, start_addr: sam_addr_t'(start_addr), end_addr: sam_addr_t'(end_addr)};
    endfunction

    // Each node: 1 MiB SRAM, 4 KiB NPU control, then 4 KiB DMA control.
    // Control subwindows (node-relative): NPU [0x0010_0000, 0x0010_1000),
    // DMA [0x0010_1000, 0x0010_2000). Each control block has its own rule.
    // The remaining 1016 KiB of each 2 MiB slot is unmapped.
    // PORT=0: Local. PORT=1: X-boundary (West at X=0, East at X=3).
    // PORT=2: Y-boundary (South at Y=0, North at Y=3).
    // Node rows use X/Y selectors. External address-mask selectors are unspecified (zero).
    //                       START (included)         END (excluded)           X  Y  PORT  DOMAIN
    localparam sam_table_t SAM = '{
        // Node 0: (0,0).
        sam_rule(48'h0000_0000_0000, 48'h0000_0010_0000, 0, 0, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_0010_0000, 48'h0000_0010_1000, 0, 0, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_0010_1000, 48'h0000_0010_2000, 0, 0, 0, NARROW), // DMA control, 4 KiB
        // Node 1: (1,0).
        sam_rule(48'h0000_0020_0000, 48'h0000_0030_0000, 1, 0, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_0030_0000, 48'h0000_0030_1000, 1, 0, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_0030_1000, 48'h0000_0030_2000, 1, 0, 0, NARROW), // DMA control, 4 KiB
        // Node 2: (2,0).
        sam_rule(48'h0000_0040_0000, 48'h0000_0050_0000, 2, 0, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_0050_0000, 48'h0000_0050_1000, 2, 0, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_0050_1000, 48'h0000_0050_2000, 2, 0, 0, NARROW), // DMA control, 4 KiB
        // Node 3: (3,0).
        sam_rule(48'h0000_0060_0000, 48'h0000_0070_0000, 3, 0, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_0070_0000, 48'h0000_0070_1000, 3, 0, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_0070_1000, 48'h0000_0070_2000, 3, 0, 0, NARROW), // DMA control, 4 KiB
        // Node 4: (0,1).
        sam_rule(48'h0000_0080_0000, 48'h0000_0090_0000, 0, 1, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_0090_0000, 48'h0000_0090_1000, 0, 1, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_0090_1000, 48'h0000_0090_2000, 0, 1, 0, NARROW), // DMA control, 4 KiB
        // Node 5: (1,1).
        sam_rule(48'h0000_00A0_0000, 48'h0000_00B0_0000, 1, 1, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_00B0_0000, 48'h0000_00B0_1000, 1, 1, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_00B0_1000, 48'h0000_00B0_2000, 1, 1, 0, NARROW), // DMA control, 4 KiB
        // Node 6: (2,1).
        sam_rule(48'h0000_00C0_0000, 48'h0000_00D0_0000, 2, 1, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_00D0_0000, 48'h0000_00D0_1000, 2, 1, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_00D0_1000, 48'h0000_00D0_2000, 2, 1, 0, NARROW), // DMA control, 4 KiB
        // Node 7: (3,1).
        sam_rule(48'h0000_00E0_0000, 48'h0000_00F0_0000, 3, 1, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_00F0_0000, 48'h0000_00F0_1000, 3, 1, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_00F0_1000, 48'h0000_00F0_2000, 3, 1, 0, NARROW), // DMA control, 4 KiB
        // Node 8: (0,2).
        sam_rule(48'h0000_0100_0000, 48'h0000_0110_0000, 0, 2, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_0110_0000, 48'h0000_0110_1000, 0, 2, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_0110_1000, 48'h0000_0110_2000, 0, 2, 0, NARROW), // DMA control, 4 KiB
        // Node 9: (1,2).
        sam_rule(48'h0000_0120_0000, 48'h0000_0130_0000, 1, 2, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_0130_0000, 48'h0000_0130_1000, 1, 2, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_0130_1000, 48'h0000_0130_2000, 1, 2, 0, NARROW), // DMA control, 4 KiB
        // Node 10: (2,2).
        sam_rule(48'h0000_0140_0000, 48'h0000_0150_0000, 2, 2, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_0150_0000, 48'h0000_0150_1000, 2, 2, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_0150_1000, 48'h0000_0150_2000, 2, 2, 0, NARROW), // DMA control, 4 KiB
        // Node 11: (3,2).
        sam_rule(48'h0000_0160_0000, 48'h0000_0170_0000, 3, 2, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_0170_0000, 48'h0000_0170_1000, 3, 2, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_0170_1000, 48'h0000_0170_2000, 3, 2, 0, NARROW), // DMA control, 4 KiB
        // Node 12: (0,3).
        sam_rule(48'h0000_0180_0000, 48'h0000_0190_0000, 0, 3, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_0190_0000, 48'h0000_0190_1000, 0, 3, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_0190_1000, 48'h0000_0190_2000, 0, 3, 0, NARROW), // DMA control, 4 KiB
        // Node 13: (1,3).
        sam_rule(48'h0000_01A0_0000, 48'h0000_01B0_0000, 1, 3, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_01B0_0000, 48'h0000_01B0_1000, 1, 3, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_01B0_1000, 48'h0000_01B0_2000, 1, 3, 0, NARROW), // DMA control, 4 KiB
        // Node 14: (2,3).
        sam_rule(48'h0000_01C0_0000, 48'h0000_01D0_0000, 2, 3, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_01D0_0000, 48'h0000_01D0_1000, 2, 3, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_01D0_1000, 48'h0000_01D0_2000, 2, 3, 0, NARROW), // DMA control, 4 KiB
        // Node 15: (3,3).
        sam_rule(48'h0000_01E0_0000, 48'h0000_01F0_0000, 3, 3, 0, DATA), // Local SRAM, 1 MiB
        sam_rule(48'h0000_01F0_0000, 48'h0000_01F0_1000, 3, 3, 0, NARROW), // NPU control, 4 KiB
        sam_rule(48'h0000_01F0_1000, 48'h0000_01F0_2000, 3, 3, 0, NARROW), // DMA control, 4 KiB
        // External Memory starts immediately after the 16 node slots.
        // 512 GiB total: four separate 128 GiB ranges.
        // External Memory 0: (X=0, Y=0), South endpoint, PORT=2.
        sam_rule(48'h0000_0200_0000, 48'h0020_0200_0000, 0, 0, 2, DATA, '0, '0),
        // External Memory 1: (X=1, Y=0), South endpoint, PORT=2.
        sam_rule(48'h0020_0200_0000, 48'h0040_0200_0000, 1, 0, 2, DATA, '0, '0),
        // External Memory 2: (X=2, Y=0), South endpoint, PORT=2.
        sam_rule(48'h0040_0200_0000, 48'h0060_0200_0000, 2, 0, 2, DATA, '0, '0),
        // External Memory 3: (X=3, Y=0), South endpoint, PORT=2.
        sam_rule(48'h0060_0200_0000, 48'h0080_0200_0000, 3, 0, 2, DATA, '0, '0)
    };
endpackage
