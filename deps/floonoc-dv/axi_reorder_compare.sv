// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Tim Fischer <fischeti@iis.ee.ethz.ch>

/// A AXI4 Bus Monitor for verifying the order of AXI transactions with the same ID
module axi_reorder_compare #(
  parameter int unsigned NumSlaves = 4,
  parameter int unsigned AxiIdWidth = 4,
  parameter int unsigned NumAddrRegions  = 1,
  parameter type addr_t = logic,
  parameter type rule_t = logic,
  parameter rule_t [NumAddrRegions-1:0] AddrRegions = '0,
  parameter bit Verbose = 0,
  parameter type aw_chan_t = logic,
  parameter type w_chan_t = logic,
  parameter type b_chan_t = logic,
  parameter type ar_chan_t = logic,
  parameter type r_chan_t = logic,
  parameter type req_t = logic,
  parameter type rsp_t = logic,
  // Derived parameters, do not change
  localparam type id_t = logic [AxiIdWidth-1:0],
  localparam int unsigned NumAxiIds = 2**AxiIdWidth
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  req_t mon_mst_req_i,
  input  rsp_t mon_mst_rsp_i,
  input  req_t [NumSlaves-1:0] mon_slv_req_i,
  input  rsp_t [NumSlaves-1:0] mon_slv_rsp_i,
  output logic end_of_sim_o
);
  `include "axi_reorder_compare.svh"
  axi_reorder_compare_core #(
    NumSlaves, AxiIdWidth, NumAddrRegions, addr_t, rule_t, AddrRegions, Verbose,
    aw_chan_t, w_chan_t, b_chan_t, ar_chan_t, r_chan_t, req_t, rsp_t
  ) checker_core = new();
  always @(negedge rst_ni) checker_core.reset();
  always @(posedge clk_i) begin
    if (rst_ni) begin
      checker_core.source_request(mon_mst_req_i, mon_mst_rsp_i);
      for (int i = 0; i < NumSlaves; i++)
        checker_core.device_request(i, mon_slv_req_i[i], mon_slv_rsp_i[i]);
      for (int i = 0; i < NumSlaves; i++)
        checker_core.device_response(i, mon_slv_req_i[i], mon_slv_rsp_i[i]);
      checker_core.source_response(mon_mst_req_i, mon_mst_rsp_i);
    end
  end
  always @(negedge clk_i) end_of_sim_o = checker_core.drained();
endmodule
