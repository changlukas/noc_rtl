// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

// Hold the selected source through bubbles and stalls until an accepted tail.
module packet_rr_arbiter #(
    parameter int unsigned NUM_INPUTS = 5
) (
    input  wire logic                    clk_i,
    input  wire logic                    rst_n_i,
    input  wire logic [NUM_INPUTS-1:0]    req_i,
    input  wire logic [NUM_INPUTS-1:0]    last_i,
    output wire logic [NUM_INPUTS-1:0]    select_o,
    output wire logic [NUM_INPUTS-1:0]    grant_o,
    output wire logic                    valid_o,
    input  wire logic                    ready_i
);
    localparam int INPUT_W = NUM_INPUTS > 1 ? $clog2(NUM_INPUTS) : 1;

    if (NUM_INPUTS < 1) begin : gen_invalid_inputs
        initial $fatal(0, "Error: NUM_INPUTS must be positive (instance %m)");
    end

    logic [NUM_INPUTS-1:0] req_reg = '0, req_next;
    logic                 tail_reg = 1'b0, tail_next;
    wire [INPUT_W-1:0]    selected_input;
    wire                  selected_valid;

    // The tree's locked requests remain asserted even when the owner bubbles.
    // Re-sample contenders only when idle or after accepting the packet tail.
    always_comb begin
        req_next = req_reg;
        if (!(|req_reg) || tail_reg) begin
            req_next = req_i;
        end
        tail_next = valid_o && ready_i && last_i[selected_input];
    end

    rr_arb_tree #(
        .NumIn     (NUM_INPUTS),
        .DataType  (logic     ),
        .AxiVldRdy (1'b1      ),
        .LockIn    (1'b1      ),
        .FairArb   (1'b1      )
    ) i_arb (
        .clk_i   (clk_i         ),
        .rst_ni  (rst_n_i       ),
        .flush_i (1'b0          ),
        .rr_i    ('0            ),
        .req_i   (req_next      ),
        .gnt_o   (              ),
        .data_i  ('0            ),
        .req_o   (selected_valid),
        .gnt_i   (tail_next     ),
        .data_o  (              ),
        .idx_o   (selected_input)
    );

    assign valid_o  = selected_valid && req_i[selected_input];
    assign select_o = valid_o ? (NUM_INPUTS'(1) << selected_input) : '0;
    assign grant_o  = select_o & {NUM_INPUTS{ready_i}};

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            req_reg  <= '0;
            tail_reg <= 1'b0;
        end else begin
            req_reg  <= req_next;
            tail_reg <= tail_next;
        end
    end
endmodule

`resetall
