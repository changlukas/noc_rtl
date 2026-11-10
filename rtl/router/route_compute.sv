// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module route_compute #(
    parameter int unsigned ROUTER_X = 0,
    parameter int unsigned ROUTER_Y = 0,
    parameter int unsigned MESH_X   = noc_unit_params_pkg::MESH_X_DIM,
    parameter int unsigned MESH_Y   = noc_unit_params_pkg::MESH_Y_DIM
) (
    input  wire noc_header_pkg::header_t               header_i,
    input  wire logic                                 multicast_i,
    output wire logic                           [4:0] route_mask_o,
    output wire logic                           [4:0] merge_mask_o
);
    localparam int LOCAL = noc_unit_params_pkg::router_port(noc_unit_params_pkg::LOCAL);
    localparam int NORTH = noc_unit_params_pkg::router_port(noc_unit_params_pkg::NORTH);
    localparam int EAST  = noc_unit_params_pkg::router_port(noc_unit_params_pkg::EAST);
    localparam int SOUTH = noc_unit_params_pkg::router_port(noc_unit_params_pkg::SOUTH);
    localparam int WEST  = noc_unit_params_pkg::router_port(noc_unit_params_pkg::WEST);
    wire [noc_header_pkg::X_WIDTH-1:0] dst_x = header_i.dst_id.x;
    wire [noc_header_pkg::Y_WIDTH-1:0] dst_y = header_i.dst_id.y;
    wire [noc_header_pkg::X_WIDTH-1:0] src_x = header_i.src_id.x;
    wire [noc_header_pkg::Y_WIDTH-1:0] src_y = header_i.src_id.y;
    wire [noc_header_pkg::X_WIDTH-1:0] mask_x = header_i.coll_mask[0 +: noc_header_pkg::X_WIDTH];
    wire [noc_header_pkg::Y_WIDTH-1:0] mask_y = header_i.coll_mask[noc_header_pkg::X_WIDTH +: noc_header_pkg::Y_WIDTH];
    wire [noc_header_pkg::PORT_ID_WIDTH-1:0] dst_port = header_i.dst_id.port_id;
    logic [4:0] route_mask, merge_mask;
    assign route_mask_o = route_mask;
    assign merge_mask_o = merge_mask;
    always_comb begin
        route_mask = '0;
        merge_mask = '0;
        if (multicast_i) begin
            route_mask[LOCAL] = (((noc_header_pkg::X_WIDTH'(ROUTER_X) ^ dst_x) & ~mask_x) == 0) &&
                                (((noc_header_pkg::Y_WIDTH'(ROUTER_Y) ^ dst_y) & ~mask_y) == 0);
            if (ROUTER_Y == int'(src_y)) begin
                route_mask[EAST] = ROUTER_X >= int'(src_x) && ROUTER_X < int'(dst_x | mask_x);
                route_mask[WEST] = ROUTER_X <= int'(src_x) && ROUTER_X > int'(dst_x & ~mask_x);
            end
            if (((noc_header_pkg::X_WIDTH'(ROUTER_X) ^ dst_x) & ~mask_x) == 0) begin
                route_mask[NORTH] = ROUTER_Y >= int'(src_y) && ROUTER_Y < int'(dst_y | mask_y);
                route_mask[SOUTH] = ROUTER_Y <= int'(src_y) && ROUTER_Y > int'(dst_y & ~mask_y);
            end
        end else if (int'(dst_x) != ROUTER_X) begin
            route_mask[int'(dst_x) > ROUTER_X ? EAST : WEST] = 1'b1;
        end else if (int'(dst_y) != ROUTER_Y) begin
            route_mask[int'(dst_y) > ROUTER_Y ? NORTH : SOUTH] = 1'b1;
        end else begin
            // Endpoint ports select local, X-boundary or Y-boundary ejection.
            case (dst_port)
                0: route_mask[LOCAL] = 1'b1;
                1: begin
                    if (ROUTER_X == 0) route_mask[WEST] = 1'b1;
                    else if (ROUTER_X == MESH_X-1) route_mask[EAST] = 1'b1;
                end
                2: begin
                    if (ROUTER_Y == 0) route_mask[SOUTH] = 1'b1;
                    else if (ROUTER_Y == MESH_Y-1) route_mask[NORTH] = 1'b1;
                end
                default: route_mask = '0;
            endcase
        end
        merge_mask[LOCAL] = (((noc_header_pkg::X_WIDTH'(ROUTER_X) ^ src_x) & ~mask_x) == 0) &&
                            (((noc_header_pkg::Y_WIDTH'(ROUTER_Y) ^ src_y) & ~mask_y) == 0);
        if (ROUTER_X == int'(dst_x)) begin
            merge_mask[NORTH] = ROUTER_Y >= int'(dst_y) && ROUTER_Y < int'(src_y | mask_y);
            merge_mask[SOUTH] = ROUTER_Y <= int'(dst_y) && ROUTER_Y > int'(src_y & ~mask_y);
        end
        if (((noc_header_pkg::Y_WIDTH'(ROUTER_Y) ^ src_y) & ~mask_y) == 0) begin
            merge_mask[EAST] = ROUTER_X >= int'(dst_x) && ROUTER_X < int'(src_x | mask_x);
            merge_mask[WEST] = ROUTER_X <= int'(dst_x) && ROUTER_X > int'(src_x & ~mask_x);
        end
    end
    initial begin
        if (MESH_X < 2 || MESH_Y < 2 || ROUTER_X >= MESH_X || ROUTER_Y >= MESH_Y)
            $fatal(1, "Invalid router coordinate (instance %m)");
    end
endmodule

`resetall
