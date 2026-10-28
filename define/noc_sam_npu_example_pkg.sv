// Provenance: Google Coral NPU default memory layout, fixed source revision below.
// https://github.com/google-coral/coralnpu/blob/cb2b75f4e38a2a4c0fd5c5888eec9df10fefa11f/hdl/chisel/src/coralnpu/Parameters.scala
// https://developers.google.com/coral/guides/hardware/integration
// Official local offsets: ITCM 0x0+0x2000, DTCM 0x10000+0x8000, CSR 0x30000+0x1000.
// The integration guide leaves CSR size TBD; the pinned source fixes it at 4 KiB.
// Base 0 follows the official integration example; real SoC relocation is not specified.
// Review-only adaptation: all regions -> (0,0), PORT=0; SRAM uses DATA, CSR uses NARROW.
// These are OUR NoC placement/traffic policies, not properties of the original design.
// The source AXI port is 128 bits; width adaptation to our transport is not implemented.
// Not an active profile; no endpoint, SRAM, CSR or bus adapter is added.
`timescale 1ns/1ps

package noc_sam_npu_example_pkg;
    import noc_sam_pkg::sam_rule_t;
    import noc_sam_pkg::sam_addr_t;
    import noc_sam_pkg::sam_rule;
    import noc_sam_pkg::NARROW;
    import noc_sam_pkg::DATA;

    localparam int SAM_NUM_RULES = 3;
    //                       START (included)                   END (excluded)                     X  Y  PORT DOMAIN   MC
    localparam sam_rule_t [SAM_NUM_RULES-1:0] SAM = '{
        sam_rule(64'h0000_0000_0000, 64'h0000_0000_2000, 0, 0, 0, DATA,   1'b0), // ITCM, 8 KiB
        sam_rule(64'h0000_0001_0000, 64'h0000_0001_8000, 0, 0, 0, DATA,   1'b0), // DTCM, 32 KiB
        sam_rule(64'h0000_0003_0000, 64'h0000_0003_1000, 0, 0, 0, NARROW, 1'b0)  // CSR, 4 KiB aperture
    };
endpackage
