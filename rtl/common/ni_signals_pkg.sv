// SPDX-License-Identifier: Apache-2.0

`resetall
`timescale 1ns / 1ps
`default_nettype none

// AXI channel records at the NI boundary. Widths come from native configuration.
package ni_signals_pkg;

    // External AWUSER includes {address mask, collective operation, opaque USER}.
    // Packet AW carries only the opaque USER; collective metadata is in the header.
    typedef struct packed {
        logic     [noc_payload_pkg::AXI_ID_WIDTH-1:0] awid;
        logic   [noc_payload_pkg::AXI_ADDR_WIDTH-1:0] awaddr;
        logic    [noc_payload_pkg::AXI_LEN_WIDTH-1:0] awlen;
        logic   [noc_payload_pkg::AXI_SIZE_WIDTH-1:0] awsize;
        logic  [noc_payload_pkg::AXI_BURST_WIDTH-1:0] awburst;
        logic   [noc_payload_pkg::AXI_LOCK_WIDTH-1:0] awlock;
        logic  [noc_payload_pkg::AXI_CACHE_WIDTH-1:0] awcache;
        logic   [noc_payload_pkg::AXI_PROT_WIDTH-1:0] awprot;
        logic    [noc_payload_pkg::AXI_QOS_WIDTH-1:0] awqos;
        logic [noc_payload_pkg::AXI_REGION_WIDTH-1:0] awregion;
        logic [noc_payload_pkg::AXI_AWUSER_WIDTH-1:0] awuser;
    } noc_axi_aw_t;

    typedef struct packed {
        logic     [noc_payload_pkg::DATA_WIDTH-1:0] wdata;
        logic    [noc_payload_pkg::WSTRB_WIDTH-1:0] wstrb;
        logic [noc_payload_pkg::AXI_LAST_WIDTH-1:0] wlast;
        logic    [noc_payload_pkg::WUSER_WIDTH-1:0] wuser;
    } noc_axi_w_t;

    typedef struct packed {
        logic   [noc_payload_pkg::AXI_ID_WIDTH-1:0] bid;
        logic [noc_payload_pkg::AXI_RESP_WIDTH-1:0] bresp;
        logic    [noc_payload_pkg::BUSER_WIDTH-1:0] buser;
    } noc_axi_b_t;

    typedef struct packed {
        logic     [noc_payload_pkg::AXI_ID_WIDTH-1:0] arid;
        logic   [noc_payload_pkg::AXI_ADDR_WIDTH-1:0] araddr;
        logic    [noc_payload_pkg::AXI_LEN_WIDTH-1:0] arlen;
        logic   [noc_payload_pkg::AXI_SIZE_WIDTH-1:0] arsize;
        logic  [noc_payload_pkg::AXI_BURST_WIDTH-1:0] arburst;
        logic   [noc_payload_pkg::AXI_LOCK_WIDTH-1:0] arlock;
        logic  [noc_payload_pkg::AXI_CACHE_WIDTH-1:0] arcache;
        logic   [noc_payload_pkg::AXI_PROT_WIDTH-1:0] arprot;
        logic    [noc_payload_pkg::AXI_QOS_WIDTH-1:0] arqos;
        logic [noc_payload_pkg::AXI_REGION_WIDTH-1:0] arregion;
        logic     [noc_payload_pkg::ARUSER_WIDTH-1:0] aruser;
    } noc_axi_ar_t;

    typedef struct packed {
        logic   [noc_payload_pkg::AXI_ID_WIDTH-1:0] rid;
        logic     [noc_payload_pkg::DATA_WIDTH-1:0] rdata;
        logic [noc_payload_pkg::AXI_RESP_WIDTH-1:0] rresp;
        logic [noc_payload_pkg::AXI_LAST_WIDTH-1:0] rlast;
        logic    [noc_payload_pkg::RUSER_WIDTH-1:0] ruser;
    } noc_axi_r_t;

endpackage

`resetall
