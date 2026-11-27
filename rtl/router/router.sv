// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module router #(
    parameter int unsigned ROUTER_X          = 0,
    parameter int unsigned ROUTER_Y          = 0,
    parameter int unsigned MESH_X            = noc_unit_params_pkg::MESH_X_DIM,
    parameter int unsigned MESH_Y            = noc_unit_params_pkg::MESH_Y_DIM,
    parameter int unsigned NUM_DAT_VC        = noc_unit_params_pkg::DAT_NUM_VC,
    parameter int unsigned DAT_RX_FIFO_DEPTH = noc_unit_params_pkg::DAT_RX_FIFO_DEPTH,
    parameter int unsigned REQ_FIFO_DEPTH    = 32,
    parameter int unsigned RSP_FIFO_DEPTH    = 32,
    parameter int unsigned REQ_REG_TYPE      = 0,
    parameter int unsigned RSP_REG_TYPE      = 0,
    parameter int unsigned DAT_FIFO_DEPTH    = noc_unit_params_pkg::ROUTER_OUTPUT_FIFO_DEPTH
) (
    input  wire logic                                         clk_i,
    input  wire logic                                         rst_n_i,
    input  wire logic                                   [4:0] RXREQVLD,
    input  wire logic [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] RXREQ [5],
    output wire logic                                   [4:0] RXREQRDY,
    output wire logic                                   [4:0] TXREQVLD,
    output wire logic [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] TXREQ [5],
    input  wire logic                                   [4:0] TXREQRDY,
    input  wire logic                                   [4:0] RXRSPVLD,
    input  wire logic [noc_payload_pkg::RSP_FLIT_WIDTH-1:0] RXRSP [5],
    output wire logic                                   [4:0] RXRSPRDY,
    output wire logic                                   [4:0] TXRSPVLD,
    output wire logic [noc_payload_pkg::RSP_FLIT_WIDTH-1:0] TXRSP [5],
    input  wire logic                                   [4:0] TXRSPRDY,
    input  wire logic                        [NUM_DAT_VC-1:0] RXDATVLD [5],
    input  wire logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] RXDAT [5],
    output wire logic                        [NUM_DAT_VC-1:0] RXDATRDY [5],
    output wire logic                        [NUM_DAT_VC-1:0] TXDATVLD [5],
    output wire logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] TXDAT [5],
    input  wire logic                        [NUM_DAT_VC-1:0] TXDATRDY [5]
);
    wire noc_payload_pkg::req_flit_t [4:0] req_in, req_out;
    wire noc_payload_pkg::rsp_flit_t [4:0] rsp_in, rsp_out;
    wire noc_payload_pkg::dat_flit_t [4:0] dat_in, dat_out;
    wire [4:0][NUM_DAT_VC-1:0] dat_valid_in, dat_valid_out, dat_ready_in, dat_ready_out;
    for (genvar p = 0; p < 5; p++) begin : gen_port
        assign req_in[p] = RXREQ[p];
        assign TXREQ[p] = req_out[p];
        assign rsp_in[p] = RXRSP[p];
        assign TXRSP[p] = rsp_out[p];
        assign dat_in[p] = RXDAT[p];
        assign TXDAT[p] = dat_out[p];
        assign dat_valid_in[p] = RXDATVLD[p];
        assign TXDATVLD[p] = dat_valid_out[p];
        assign dat_ready_in[p] = TXDATRDY[p];
        assign RXDATRDY[p] = dat_ready_out[p];
    end
    // synthesis translate_off
    for (genvar p = 0; p < 5; p++) begin : gen_checks
        req_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            TXREQVLD[p] && !TXREQRDY[p] |=>
            TXREQVLD[p] && $stable(TXREQ[p]));
        rsp_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            TXRSPVLD[p] && !TXRSPRDY[p] |=>
            TXRSPVLD[p] && $stable(TXRSP[p]));
        dat_onehot: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            $onehot0(TXDATVLD[p]) && $onehot0(RXDATVLD[p]));
        dat_ready: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            (TXDATVLD[p] & ~TXDATRDY[p]) == '0 &&
            (RXDATVLD[p] & ~RXDATRDY[p]) == '0);
    end
    // synthesis translate_on
    req_router #(
        .ROUTER_X     (ROUTER_X),
        .ROUTER_Y     (ROUTER_Y),
        .MESH_X       (MESH_X),
        .MESH_Y       (MESH_Y),
        .FIFO_DEPTH   (REQ_FIFO_DEPTH),
        .OUT_REG_TYPE (REQ_REG_TYPE)
    ) i_req_router (
        .clk_i     (clk_i),
        .rst_n_i   (rst_n_i),
        .RXREQ  (req_in),
        .RXREQVLD (RXREQVLD),
        .RXREQRDY (RXREQRDY),
        .TXREQ  (req_out),
        .TXREQVLD (TXREQVLD),
        .TXREQRDY (TXREQRDY)
    );
    rsp_router #(
        .ROUTER_X     (ROUTER_X),
        .ROUTER_Y     (ROUTER_Y),
        .MESH_X       (MESH_X),
        .MESH_Y       (MESH_Y),
        .FIFO_DEPTH   (RSP_FIFO_DEPTH),
        .OUT_REG_TYPE (RSP_REG_TYPE)
    ) i_rsp_router (
        .clk_i     (clk_i),
        .rst_n_i   (rst_n_i),
        .RXRSP  (rsp_in),
        .RXRSPVLD (RXRSPVLD),
        .RXRSPRDY (RXRSPRDY),
        .TXRSP  (rsp_out),
        .TXRSPVLD (TXRSPVLD),
        .TXRSPRDY (TXRSPRDY)
    );
    dat_router #(
        .ROUTER_X       (ROUTER_X),
        .ROUTER_Y       (ROUTER_Y),
        .MESH_X         (MESH_X),
        .MESH_Y         (MESH_Y),
        .NUM_VC         (NUM_DAT_VC),
        .FIFO_DEPTH     (DAT_RX_FIFO_DEPTH),
        .OUT_FIFO_DEPTH (DAT_FIFO_DEPTH)
    ) i_dat_router (
        .clk_i     (clk_i),
        .rst_n_i   (rst_n_i),
        .RXDAT  (dat_in),
        .RXDATVLD (dat_valid_in),
        .RXDATRDY (dat_ready_out),
        .TXDAT  (dat_out),
        .TXDATVLD (dat_valid_out),
        .TXDATRDY (dat_ready_in)
    );
endmodule
`resetall
