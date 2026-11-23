`timescale 1ns/1ps

package noc_sam_pkg;
    import noc_header_pkg::*;
    import noc_payload_pkg::*;

    typedef logic [AXI_ADDR_WIDTH-1:0] sam_addr_t;

    localparam int SAM_MASK_SEL_WIDTH = $clog2(AXI_ADDR_WIDTH + 1);
    localparam bit NARROW = 1'b0;
    localparam bit DATA = 1'b1;

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

    // Constant record constructor only: no address expansion or runtime hardware.
    // Mask selectors describe address-mask encoding; no per-region enable flag.
    function automatic sam_rule_t sam_rule(
        input sam_addr_t start_addr,
        input sam_addr_t end_addr,
        input int x, y, port_id,
        input bit is_data,
        input sam_mask_sel_t mask_x,
        input sam_mask_sel_t mask_y
    );
        sam_result_t result;
        result = '0;
        result.dst_id = '{port_id: PORT_ID_WIDTH'(port_id), y: Y_WIDTH'(y), x: X_WIDTH'(x)};
        result.is_data = is_data;
        result.mask_x = mask_x;
        result.mask_y = mask_y;
        return '{idx: result, start_addr: sam_addr_t'(start_addr), end_addr: sam_addr_t'(end_addr)};
    endfunction

endpackage
