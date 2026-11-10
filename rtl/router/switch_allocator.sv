// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module switch_allocator #(
    parameter int unsigned NUM_INPUTS = 5
) (
    input  wire logic                  clk_i,
    input  wire logic                  rst_n_i,
    input  wire logic [NUM_INPUTS-1:0] req_i,
    input  wire logic [NUM_INPUTS-1:0] last_i,
    output wire logic [NUM_INPUTS-1:0] select_o,
    output wire logic [NUM_INPUTS-1:0] grant_o,
    output wire logic                  valid_o,
    input  wire logic                  ready_i
);
    packet_rr_arbiter #(
        .NUM_INPUTS (NUM_INPUTS)
    ) i_packet_rr_arbiter (
        .clk_i    (clk_i   ),
        .rst_n_i  (rst_n_i ),
        .req_i    (req_i   ),
        .last_i   (last_i  ),
        .select_o (select_o),
        .grant_o  (grant_o ),
        .valid_o  (valid_o ),
        .ready_i  (ready_i )
    );
endmodule

`resetall
