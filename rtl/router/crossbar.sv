// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module crossbar #(
    parameter int unsigned NUM_INPUTS  = 5,
    parameter int unsigned NUM_OUTPUTS = 5,
    parameter type         flit_t      = ni_flit_pkg::req_flit_t
) (
    input  wire flit_t                  [NUM_INPUTS-1:0] data_i,
    input  wire logic  [NUM_OUTPUTS-1:0][NUM_INPUTS-1:0] select_i,
    output wire flit_t                 [NUM_OUTPUTS-1:0] data_o
);
    for (genvar o = 0; o < NUM_OUTPUTS; o++) begin : gen_output
        flit_t data;
        always_comb begin
            data = '0;
            for (int i = 0; i < NUM_INPUTS; i++)
                data = data | (data_i[i] & {$bits(flit_t){select_i[o][i]}});
        end
        assign data_o[o] = data;
    end
endmodule

`resetall
