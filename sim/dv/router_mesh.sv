// SPDX-License-Identifier: Apache-2.0
`timescale 1ps/1ps
module router_mesh #(
    parameter int unsigned MESH_X = 4,
    parameter int unsigned MESH_Y = 4,
    parameter int unsigned NUM_ENDPOINTS = MESH_X*MESH_Y,
    parameter int unsigned NUM_VC = ni_params_pkg::NUM_DAT_VC
) (
    input wire logic clk_i,
    input wire logic rst_n_i,
    input wire logic [NUM_ENDPOINTS-1:0] rx_req_valid_i,
    input wire logic [ni_params_pkg::NOC_REQ_FLIT_WIDTH-1:0] rx_req_flit_i [NUM_ENDPOINTS],
    output wire logic [NUM_ENDPOINTS-1:0] rx_req_ready_o,
    output wire logic [NUM_ENDPOINTS-1:0] tx_req_valid_o,
    output wire logic [ni_params_pkg::NOC_REQ_FLIT_WIDTH-1:0] tx_req_flit_o [NUM_ENDPOINTS],
    input wire logic [NUM_ENDPOINTS-1:0] tx_req_ready_i,
    input wire logic [NUM_ENDPOINTS-1:0] rx_rsp_valid_i,
    input wire logic [ni_params_pkg::NOC_RSP_FLIT_WIDTH-1:0] rx_rsp_flit_i [NUM_ENDPOINTS],
    output wire logic [NUM_ENDPOINTS-1:0] rx_rsp_ready_o,
    output wire logic [NUM_ENDPOINTS-1:0] tx_rsp_valid_o,
    output wire logic [ni_params_pkg::NOC_RSP_FLIT_WIDTH-1:0] tx_rsp_flit_o [NUM_ENDPOINTS],
    input wire logic [NUM_ENDPOINTS-1:0] tx_rsp_ready_i,
    input wire logic [NUM_VC-1:0] rx_dat_valid_i [NUM_ENDPOINTS],
    input wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] rx_dat_flit_i [NUM_ENDPOINTS],
    output wire logic [NUM_VC-1:0] rx_dat_ready_o [NUM_ENDPOINTS],
    output wire logic [NUM_VC-1:0] tx_dat_valid_o [NUM_ENDPOINTS],
    output wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] tx_dat_flit_o [NUM_ENDPOINTS],
    input wire logic [NUM_VC-1:0] tx_dat_ready_i [NUM_ENDPOINTS],
    input wire logic [NUM_VC-1:0] credit_i [NUM_ENDPOINTS],
    output wire logic [NUM_VC-1:0] credit_o [NUM_ENDPOINTS]
);
    localparam int NUM_ROUTERS = MESH_X*MESH_Y;
    wire logic [4:0] rx_req_valid [NUM_ROUTERS];
    wire logic [4:0] rx_req_ready [NUM_ROUTERS];
    wire logic [ni_params_pkg::NOC_REQ_FLIT_WIDTH-1:0] rx_req_flit [NUM_ROUTERS][5];
    wire logic [4:0] tx_req_valid [NUM_ROUTERS];
    wire logic [4:0] tx_req_ready [NUM_ROUTERS];
    wire logic [ni_params_pkg::NOC_REQ_FLIT_WIDTH-1:0] tx_req_flit [NUM_ROUTERS][5];
    wire logic [4:0] rx_rsp_valid [NUM_ROUTERS];
    wire logic [4:0] rx_rsp_ready [NUM_ROUTERS];
    wire logic [ni_params_pkg::NOC_RSP_FLIT_WIDTH-1:0] rx_rsp_flit [NUM_ROUTERS][5];
    wire logic [4:0] tx_rsp_valid [NUM_ROUTERS];
    wire logic [4:0] tx_rsp_ready [NUM_ROUTERS];
    wire logic [ni_params_pkg::NOC_RSP_FLIT_WIDTH-1:0] tx_rsp_flit [NUM_ROUTERS][5];
    wire logic [NUM_VC-1:0] rx_dat_valid [NUM_ROUTERS][5];
    wire logic [NUM_VC-1:0] rx_dat_ready [NUM_ROUTERS][5];
    wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] rx_dat_flit [NUM_ROUTERS][5];
    wire logic [NUM_VC-1:0] tx_dat_valid [NUM_ROUTERS][5];
    wire logic [NUM_VC-1:0] tx_dat_ready [NUM_ROUTERS][5];
    wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] tx_dat_flit [NUM_ROUTERS][5];
    wire [NUM_VC-1:0] rx_credit [NUM_ROUTERS][5], tx_credit [NUM_ROUTERS][5];
    for (genvar n = 0; n < NUM_ROUTERS; n++) begin : gen_router
        router #(
            .ROUTER_X (n%MESH_X),
            .ROUTER_Y (n/MESH_X),
            .MESH_X (MESH_X),
            .MESH_Y (MESH_Y),
            .NUM_DAT_VC (NUM_VC)
        ) i_router (
            .clk_i (clk_i),
            .rst_n_i (rst_n_i),
            .rx_req_valid_i (rx_req_valid[n]),
            .rx_req_flit_i (rx_req_flit[n]),
            .rx_req_ready_o (rx_req_ready[n]),
            .tx_req_valid_o (tx_req_valid[n]),
            .tx_req_flit_o (tx_req_flit[n]),
            .tx_req_ready_i (tx_req_ready[n]),
            .rx_rsp_valid_i (rx_rsp_valid[n]),
            .rx_rsp_flit_i (rx_rsp_flit[n]),
            .rx_rsp_ready_o (rx_rsp_ready[n]),
            .tx_rsp_valid_o (tx_rsp_valid[n]),
            .tx_rsp_flit_o (tx_rsp_flit[n]),
            .tx_rsp_ready_i (tx_rsp_ready[n]),
            .rx_dat_valid_i (rx_dat_valid[n]),
            .rx_dat_flit_i (rx_dat_flit[n]),
            .rx_dat_ready_o (rx_dat_ready[n]),
            .tx_dat_valid_o (tx_dat_valid[n]),
            .tx_dat_flit_o (tx_dat_flit[n]),
            .tx_dat_ready_i (tx_dat_ready[n]),
            .credit_i (tx_credit[n]),
            .credit_o (rx_credit[n])
        );
        for (genvar port = 0; port < 5; port++) begin : gen_port
            localparam int X = n%MESH_X;
            localparam int Y = n/MESH_X;
            localparam int OTHER = port == 1 ? n+MESH_X : port == 2 ? n+1 :
                                   port == 3 ? n-MESH_X : n-1;
            localparam int OPPOSITE = port == 1 ? 3 : port == 2 ? 4 : port == 3 ? 1 : 2;
            localparam bit CONNECTED = (port == 1 && Y < MESH_Y-1) ||
                (port == 2 && X < MESH_X-1) || (port == 3 && Y > 0) || (port == 4 && X > 0);
            if (port == 0) begin : gen_endpoint
                localparam int E = n;
                assign rx_req_valid[n][port] = rx_req_valid_i[E];
                assign tx_req_valid_o[E] = tx_req_valid[n][port];
                assign rx_req_flit[n][port] = rx_req_flit_i[E];
                assign tx_req_flit_o[E] = tx_req_flit[n][port];
                assign rx_req_ready_o[E] = rx_req_ready[n][port];
                assign tx_req_ready[n][port] = tx_req_ready_i[E];
                assign rx_rsp_valid[n][port] = rx_rsp_valid_i[E];
                assign tx_rsp_valid_o[E] = tx_rsp_valid[n][port];
                assign rx_rsp_flit[n][port] = rx_rsp_flit_i[E];
                assign tx_rsp_flit_o[E] = tx_rsp_flit[n][port];
                assign rx_rsp_ready_o[E] = rx_rsp_ready[n][port];
                assign tx_rsp_ready[n][port] = tx_rsp_ready_i[E];
                assign rx_dat_valid[n][port] = rx_dat_valid_i[E];
                assign tx_dat_valid_o[E] = tx_dat_valid[n][port];
                assign rx_dat_flit[n][port] = rx_dat_flit_i[E];
                assign tx_dat_flit_o[E] = tx_dat_flit[n][port];
                assign rx_dat_ready_o[E] = rx_dat_ready[n][port];
                assign tx_dat_ready[n][port] = tx_dat_ready_i[E];
                assign credit_o[E] = rx_credit[n][port];
                assign tx_credit[n][port] = credit_i[E];
            end else if (CONNECTED) begin : gen_link
                assign rx_req_valid[n][port] = tx_req_valid[OTHER][OPPOSITE];
                assign rx_req_flit[n][port] = tx_req_flit[OTHER][OPPOSITE];
                assign tx_req_ready[n][port] = rx_req_ready[OTHER][OPPOSITE];
                assign rx_rsp_valid[n][port] = tx_rsp_valid[OTHER][OPPOSITE];
                assign rx_rsp_flit[n][port] = tx_rsp_flit[OTHER][OPPOSITE];
                assign tx_rsp_ready[n][port] = rx_rsp_ready[OTHER][OPPOSITE];
                assign rx_dat_valid[n][port] = tx_dat_valid[OTHER][OPPOSITE];
                assign rx_dat_flit[n][port] = tx_dat_flit[OTHER][OPPOSITE];
                assign tx_dat_ready[n][port] = rx_dat_ready[OTHER][OPPOSITE];
                assign tx_credit[n][port] = rx_credit[OTHER][OPPOSITE];
            end else begin : gen_boundary
                assign rx_req_valid[n][port] = '0;
                assign rx_req_flit[n][port] = '0;
                assign tx_req_ready[n][port] = '0;
                assign rx_rsp_valid[n][port] = '0;
                assign rx_rsp_flit[n][port] = '0;
                assign tx_rsp_ready[n][port] = '0;
                assign rx_dat_valid[n][port] = '0;
                assign rx_dat_flit[n][port] = '0;
                assign tx_dat_ready[n][port] = '0;
                assign tx_credit[n][port] = '0;
            end
        end
    end
    initial begin
        if (NUM_ENDPOINTS != NUM_ROUTERS)
            $fatal(1, "Each mesh node requires one NI endpoint");
    end
endmodule
