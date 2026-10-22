// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module vc_allocator #(
    parameter int unsigned NUM_VC     = ni_params_pkg::NUM_DAT_VC,
    localparam int unsigned VC_MODE    = (NUM_VC > 1),
    parameter int unsigned NUM_INPUTS = 5*NUM_VC,
    parameter int unsigned ROUTER_X   = 0,
    parameter int unsigned ROUTER_Y   = 0,
    parameter int unsigned OUTPUT_PORT = 0
) (
    input  wire logic                                                clk_i,
    input  wire logic                                                rst_n_i,
    input  wire ni_flit_pkg::dat_flit_t             [NUM_INPUTS-1:0] data_i,
    input  wire logic                               [NUM_INPUTS-1:0] req_i,
    input  wire logic                                   [NUM_VC-1:0] credit_available_i,
    input  wire logic                                   [NUM_VC-1:0] release_i,
    output wire logic                   [NUM_VC-1:0][NUM_INPUTS-1:0] select_o
);
    import ni_flit_pkg::*;
    logic [NUM_VC-1:0][NUM_INPUTS-1:0] allocation_reg = '0, allocation_next;
    wire [NUM_INPUTS-1:0] assigned;
    logic [NUM_INPUTS-1:0] assigned_mask;
    logic [NUM_VC-1:0][NUM_INPUTS-1:0] request;
    wire [NUM_VC-1:0][NUM_INPUTS-1:0] grant;
    wire [NUM_VC-1:0] selected_valid;
    for (genvar v = 0; v < NUM_VC; v++) begin : gen_selection
        assign select_o[v] = (|allocation_reg[v]) ? allocation_reg[v] : grant[v];
    end
    assign assigned = assigned_mask;
    always_comb begin
        assigned_mask = '0;
        for (int v = 0; v < NUM_VC; v++) assigned_mask |= allocation_reg[v];
    end
    // Fixed flows retain their injection VC at every hop.
    always_comb begin
        request = '0;
        for (int i = 0; i < NUM_INPUTS; i++) begin
            int base_vc, num_vc, preferred, selected, next_x, next_y, dst_x, dst_y;
            int next_port;
            base_vc = 0;
            num_vc = NUM_VC;
            if (VC_MODE == 1) begin
                num_vc = NUM_VC/2;
                if (data_i[i].header[AXI_CH_LSB +: AXI_CH_WIDTH] == AXI_CH_WIDTH'(AXI_CH_DataR))
                    base_vc = NUM_VC/2;
            end
            next_x = ROUTER_X + (OUTPUT_PORT == 2 ? 1 : 0) - (OUTPUT_PORT == 4 ? 1 : 0);
            next_y = ROUTER_Y + (OUTPUT_PORT == 1 ? 1 : 0) - (OUTPUT_PORT == 3 ? 1 : 0);
            dst_x = int'(data_i[i].header[DST_ID_LSB +: X_WIDTH]);
            dst_y = int'(data_i[i].header[DST_ID_LSB+X_WIDTH +: Y_WIDTH]);
            next_port = dst_x != next_x ? (dst_x > next_x ? 2 : 4) :
                        dst_y != next_y ? (dst_y > next_y ? 1 : 3) : 0;
            if (OUTPUT_PORT == 0) preferred = 0;
            else if (next_port == 0) preferred = (OUTPUT_PORT == 1 || OUTPUT_PORT == 3) ? 1 : 3;
            else if (OUTPUT_PORT == 1 || OUTPUT_PORT == 3 || next_port == 1) preferred = 0;
            else if (next_port == 3) preferred = OUTPUT_PORT == 2 ? 2 : 1;
            else preferred = OUTPUT_PORT == 2 ? 1 : 2;
            preferred = base_vc + preferred % num_vc;
            if (data_i[i].header[FIXED_VC_LSB])
                preferred = int'(data_i[i].header[VC_ID_LSB +: VC_ID_WIDTH]);
            selected = -1;
            for (int v = 0; v < NUM_VC; v++) begin
                if (v >= base_vc && v < base_vc+num_vc && !(|allocation_reg[v]) && credit_available_i[v]) begin
                    if (v == preferred) selected = v;
                    else if (selected != preferred && data_i[i].header[FLIT_TAIL_LSB] &&
                             !data_i[i].header[FIXED_VC_LSB] &&
                             data_i[i].header[AXI_CH_LSB +: AXI_CH_WIDTH] == AXI_CH_WIDTH'(AXI_CH_DataR)) selected = v;
                end
            end
            if (req_i[i] && !assigned[i] && selected >= 0) request[selected][i] = 1'b1;
        end
    end
    for (genvar v = 0; v < NUM_VC; v++) begin : gen_vc
        rr_arb_tree #(
            .NumIn     (NUM_INPUTS),
            .DataType  (logic),
            .AxiVldRdy (1'b0),
            .LockIn    (1'b0),
            .FairArb   (1'b1)
        ) i_arb (
            .clk_i   (clk_i),
            .rst_ni  (rst_n_i),
            .flush_i (1'b0),
            .rr_i    ('0),
            .req_i   (request[v]),
            .gnt_o   (grant[v]),
            .data_i  ('0),
            .req_o   (selected_valid[v]),
            .gnt_i   (1'b1),
            .data_o  (),
            .idx_o   ()
        );
    end
    always_comb begin
        allocation_next = allocation_reg;
        for (int v = 0; v < NUM_VC; v++) begin
            if (!(|allocation_reg[v]) && selected_valid[v]) allocation_next[v] = grant[v];
            if (release_i[v]) allocation_next[v] = '0;
        end
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            allocation_reg <= '0;
        end else begin
            allocation_reg <= allocation_next;
        end
    end
endmodule
`resetall
