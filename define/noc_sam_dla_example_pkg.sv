// Provenance: NVIDIA DRIVE OS 6.0.8, Tegra234 DLA device-tree sample.
// https://developer.nvidia.com/docs/drive/drive-os/6.0.8/public/drive-os-linux-sdk/common/topics/util_setup/dla_device_tree.html
// Published apertures: DLA0 base 0x15880000, DLA1 base 0x158C0000, size 0x40000 each.
// This is the controller aperture map, NOT a DRAM map or open NVDLA CSB register layout.
// Review-only adaptation: X/Y/PORT and NARROW are our illustrative placement/policy.
// Not an active profile; no endpoint, register implementation or bus adapter is added.
`timescale 1ns/1ps

package noc_sam_dla_example_pkg;
    import noc_sam_pkg::sam_rule_t;
    import noc_sam_pkg::sam_addr_t;
    import noc_sam_pkg::sam_rule;
    import noc_sam_pkg::NARROW;

    localparam int SAM_NUM_RULES = 2;
    // The source does not define mesh coordinates. Proposed placement only:
    // DLA0 -> tile (0,0) local port 0; DLA1 -> tile (1,0) local port 0.
    //                       START (included)                   END (excluded)                     X  Y  PORT DOMAIN   MC
    localparam sam_rule_t [SAM_NUM_RULES-1:0] SAM = '{
        sam_rule(48'h0000_1588_0000, 48'h0000_158C_0000, 0, 0, 0, NARROW, 1'b0), // DLA0, 256 KiB
        sam_rule(48'h0000_158C_0000, 48'h0000_1590_0000, 1, 0, 0, NARROW, 1'b0)  // DLA1, 256 KiB
    };
endpackage
