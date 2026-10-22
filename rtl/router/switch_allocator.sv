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
    localparam int unsigned INPUT_W = NUM_INPUTS > 1 ? $clog2(NUM_INPUTS) : 1;
    logic [NUM_INPUTS-1:0] lock_reg = '0, lock_next;
    wire [NUM_INPUTS-1:0] req = req_i & ((|lock_reg) ? lock_reg : '1);
    wire [INPUT_W-1:0] selected_input;
    wire [NUM_INPUTS-1:0] ready;
    assign grant_o = ready & req;
    rr_arb_tree #(
        .NumIn     (NUM_INPUTS),
        .DataType  (logic),
        .AxiVldRdy (1'b1),
        .LockIn    (1'b1),
        .FairArb   (1'b1)
    ) i_arb (
        .clk_i   (clk_i),
        .rst_ni  (rst_n_i),
        .flush_i (1'b0),
        .rr_i    ('0),
        .req_i   (req),
        .gnt_o   (ready),
        .data_i  ('0),
        .req_o   (valid_o),
        .gnt_i   (ready_i),
        .data_o  (),
        .idx_o   (selected_input)
    );
    assign select_o = valid_o ? (NUM_INPUTS'(1) << selected_input) : '0;
    always_comb begin
        lock_next = lock_reg;
        if (valid_o && ready_i)
            lock_next = last_i[selected_input] ? '0 : select_o;
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            lock_reg <= '0;
        end else begin
            lock_reg <= lock_next;
        end
    end
endmodule

`resetall
