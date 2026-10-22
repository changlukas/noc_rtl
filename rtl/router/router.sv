// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module router #(
    parameter int unsigned ROUTER_X       = 0,
    parameter int unsigned ROUTER_Y       = 0,
    parameter int unsigned MESH_X         = ni_params_pkg::NOC_MESH_X_DIM,
    parameter int unsigned MESH_Y         = ni_params_pkg::NOC_MESH_Y_DIM,
    parameter int unsigned NUM_DAT_VC     = ni_params_pkg::NUM_DAT_VC,
    localparam int unsigned DAT_VC_MODE    = (NUM_DAT_VC > 1),
    parameter int unsigned CREDIT_DEPTH   = ni_params_pkg::CREDIT_DEPTH,
    parameter int unsigned REQ_FIFO_DEPTH = 32,
    parameter int unsigned RSP_FIFO_DEPTH = 32,
    parameter int unsigned REQ_REG_TYPE   = 0,
    parameter int unsigned RSP_REG_TYPE   = 0,
    parameter int unsigned DAT_FIFO_DEPTH = ni_params_pkg::NOC_ROUTER_OUTPUT_FIFO_DEPTH
) (
    input  wire logic                                         clk_i,
    input  wire logic                                         rst_n_i,
    input  wire logic                                   [4:0] rx_req_valid_i,
    input  wire logic [ni_params_pkg::NOC_REQ_FLIT_WIDTH-1:0] rx_req_flit_i [5],
    output wire logic                                   [4:0] rx_req_ready_o,
    output wire logic                                   [4:0] tx_req_valid_o,
    output wire logic [ni_params_pkg::NOC_REQ_FLIT_WIDTH-1:0] tx_req_flit_o [5],
    input  wire logic                                   [4:0] tx_req_ready_i,
    input  wire logic                                   [4:0] rx_rsp_valid_i,
    input  wire logic [ni_params_pkg::NOC_RSP_FLIT_WIDTH-1:0] rx_rsp_flit_i [5],
    output wire logic                                   [4:0] rx_rsp_ready_o,
    output wire logic                                   [4:0] tx_rsp_valid_o,
    output wire logic [ni_params_pkg::NOC_RSP_FLIT_WIDTH-1:0] tx_rsp_flit_o [5],
    input  wire logic                                   [4:0] tx_rsp_ready_i,
    input  wire logic                        [NUM_DAT_VC-1:0] rx_dat_valid_i [5],
    input  wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] rx_dat_flit_i [5],
    output wire logic                        [NUM_DAT_VC-1:0] rx_dat_ready_o [5],
    output wire logic                        [NUM_DAT_VC-1:0] tx_dat_valid_o [5],
    output wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] tx_dat_flit_o [5],
    input  wire logic                        [NUM_DAT_VC-1:0] tx_dat_ready_i [5],
    input  wire logic                        [NUM_DAT_VC-1:0] credit_i [5],
    output wire logic                        [NUM_DAT_VC-1:0] credit_o [5]
);
    import ni_flit_pkg::*;
    wire req_flit_t [4:0] req_in, req_out;
    wire rsp_flit_t [4:0] rsp_in, rsp_out;
    wire dat_flit_t [4:0] dat_in, dat_out;
    wire [4:0][NUM_DAT_VC-1:0] dat_valid_in, dat_valid_out, dat_ready_in, dat_ready_out;
    wire [4:0][NUM_DAT_VC-1:0] credit_in, credit_out;
    for (genvar p = 0; p < 5; p++) begin : gen_port
        assign req_in[p] = rx_req_flit_i[p];
        assign tx_req_flit_o[p] = req_out[p];
        assign rsp_in[p] = rx_rsp_flit_i[p];
        assign tx_rsp_flit_o[p] = rsp_out[p];
        assign dat_in[p] = rx_dat_flit_i[p];
        assign tx_dat_flit_o[p] = dat_out[p];
        assign dat_valid_in[p] = rx_dat_valid_i[p];
        assign tx_dat_valid_o[p] = dat_valid_out[p];
        assign dat_ready_in[p] = tx_dat_ready_i[p];
        assign rx_dat_ready_o[p] = dat_ready_out[p];
        assign credit_in[p] = credit_i[p];
        assign credit_o[p] = credit_out[p];
    end
    // synthesis translate_off
    for (genvar p = 0; p < 5; p++) begin : gen_checks
        req_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            tx_req_valid_o[p] && !tx_req_ready_i[p] |=>
            tx_req_valid_o[p] && $stable(tx_req_flit_o[p]));
        rsp_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            tx_rsp_valid_o[p] && !tx_rsp_ready_i[p] |=>
            tx_rsp_valid_o[p] && $stable(tx_rsp_flit_o[p]));
        dat_onehot: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            $onehot0(tx_dat_valid_o[p]) && $onehot0(rx_dat_valid_i[p]));
        dat_stable: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            (|(tx_dat_valid_o[p] & ~tx_dat_ready_i[p])) |=>
            $stable(tx_dat_valid_o[p]) && $stable(tx_dat_flit_o[p]));
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
        .s_flit_i  (req_in),
        .s_valid_i (rx_req_valid_i),
        .s_ready_o (rx_req_ready_o),
        .m_flit_o  (req_out),
        .m_valid_o (tx_req_valid_o),
        .m_ready_i (tx_req_ready_i)
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
        .s_flit_i  (rsp_in),
        .s_valid_i (rx_rsp_valid_i),
        .s_ready_o (rx_rsp_ready_o),
        .m_flit_o  (rsp_out),
        .m_valid_o (tx_rsp_valid_o),
        .m_ready_i (tx_rsp_ready_i)
    );
    dat_router #(
        .ROUTER_X       (ROUTER_X),
        .ROUTER_Y       (ROUTER_Y),
        .MESH_X         (MESH_X),
        .MESH_Y         (MESH_Y),
        .NUM_VC         (NUM_DAT_VC),
        .CREDIT_DEPTH   (CREDIT_DEPTH),
        .OUT_FIFO_DEPTH (DAT_FIFO_DEPTH)
    ) i_dat_router (
        .clk_i     (clk_i),
        .rst_n_i   (rst_n_i),
        .s_flit_i  (dat_in),
        .s_valid_i (dat_valid_in),
        .s_ready_o (dat_ready_out),
        .credit_o  (credit_out),
        .m_flit_o  (dat_out),
        .m_valid_o (dat_valid_out),
        .m_ready_i (dat_ready_in),
        .credit_i  (credit_in)
    );
endmodule
`resetall
