// SPDX-License-Identifier: Apache-2.0
`timescale 1ps/1ps
module router_mesh #(
    parameter int unsigned MESH_X = topology_pkg::X_DIM,
    parameter int unsigned MESH_Y = topology_pkg::Y_DIM,
    parameter int unsigned NUM_ENDPOINTS = topology_pkg::NUM_ENDPOINTS,
    parameter logic [NUM_ENDPOINTS-1:0][31:0] ENDPOINT_NODE = topology_pkg::ENDPOINT_NODE,
    parameter logic [NUM_ENDPOINTS-1:0][31:0] ENDPOINT_PORT = topology_pkg::ENDPOINT_PORT,
    parameter int unsigned NUM_VC = noc_unit_params_pkg::DAT_NUM_VC
) (
    input wire logic clk_i,
    input wire logic rst_n_i,
    input wire logic [NUM_ENDPOINTS-1:0] RXREQVLD,
    input wire logic [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] RXREQ [NUM_ENDPOINTS],
    output wire logic [NUM_ENDPOINTS-1:0] RXREQRDY,
    output wire logic [NUM_ENDPOINTS-1:0] TXREQVLD,
    output wire logic [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] TXREQ [NUM_ENDPOINTS],
    input wire logic [NUM_ENDPOINTS-1:0] TXREQRDY,
    input wire logic [NUM_ENDPOINTS-1:0] RXRSPVLD,
    input wire logic [noc_payload_pkg::RSP_FLIT_WIDTH-1:0] RXRSP [NUM_ENDPOINTS],
    output wire logic [NUM_ENDPOINTS-1:0] RXRSPRDY,
    output wire logic [NUM_ENDPOINTS-1:0] TXRSPVLD,
    output wire logic [noc_payload_pkg::RSP_FLIT_WIDTH-1:0] TXRSP [NUM_ENDPOINTS],
    input wire logic [NUM_ENDPOINTS-1:0] TXRSPRDY,
    input wire logic [NUM_VC-1:0] RXDATVLD [NUM_ENDPOINTS],
    input wire logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] RXDAT [NUM_ENDPOINTS],
    output wire logic [NUM_VC-1:0] RXDATRDY [NUM_ENDPOINTS],
    output wire logic [NUM_VC-1:0] TXDATVLD [NUM_ENDPOINTS],
    output wire logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] TXDAT [NUM_ENDPOINTS],
    input wire logic [NUM_VC-1:0] TXDATRDY [NUM_ENDPOINTS]
);
    localparam int NUM_ROUTERS = MESH_X*MESH_Y;
    localparam int LOCAL = noc_unit_params_pkg::router_port(noc_unit_params_pkg::LOCAL);
    localparam int NORTH = noc_unit_params_pkg::router_port(noc_unit_params_pkg::NORTH);
    localparam int EAST  = noc_unit_params_pkg::router_port(noc_unit_params_pkg::EAST);
    localparam int SOUTH = noc_unit_params_pkg::router_port(noc_unit_params_pkg::SOUTH);
    localparam int WEST  = noc_unit_params_pkg::router_port(noc_unit_params_pkg::WEST);
    // Explicit fixture capacities keep DUT and passive observers on the same values.
    localparam int REQ_FIFO_DEPTH = 32;
    localparam int RSP_FIFO_DEPTH = 32;
    localparam int DAT_RX_FIFO_DEPTH = noc_unit_params_pkg::CREDIT_DEPTH;
    localparam int DAT_FIFO_DEPTH = noc_unit_params_pkg::ROUTER_OUTPUT_FIFO_DEPTH;
    wire logic [4:0] rx_req_valid [NUM_ROUTERS];
    wire logic [4:0] rx_req_ready [NUM_ROUTERS];
    wire logic [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] rx_req_flit [NUM_ROUTERS][5];
    wire logic [4:0] tx_req_valid [NUM_ROUTERS];
    wire logic [4:0] tx_req_ready [NUM_ROUTERS];
    wire logic [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] tx_req_flit [NUM_ROUTERS][5];
    wire logic [4:0] rx_rsp_valid [NUM_ROUTERS];
    wire logic [4:0] rx_rsp_ready [NUM_ROUTERS];
    wire logic [noc_payload_pkg::RSP_FLIT_WIDTH-1:0] rx_rsp_flit [NUM_ROUTERS][5];
    wire logic [4:0] tx_rsp_valid [NUM_ROUTERS];
    wire logic [4:0] tx_rsp_ready [NUM_ROUTERS];
    wire logic [noc_payload_pkg::RSP_FLIT_WIDTH-1:0] tx_rsp_flit [NUM_ROUTERS][5];
    wire logic [NUM_VC-1:0] rx_dat_valid [NUM_ROUTERS][5];
    wire logic [NUM_VC-1:0] rx_dat_ready [NUM_ROUTERS][5];
    wire logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] rx_dat_flit [NUM_ROUTERS][5];
    wire logic [NUM_VC-1:0] tx_dat_valid [NUM_ROUTERS][5];
    wire logic [NUM_VC-1:0] tx_dat_ready [NUM_ROUTERS][5];
    wire logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] tx_dat_flit [NUM_ROUTERS][5];
    // Optional finite stalls exercise DAT VC independence without changing traffic.
    // Public DAT valid is ready-qualified, so gate only the ready seen by the sender.
    int dat_stall_cycles = 0;
    int unsigned dat_cycle = 0;
    initial begin
        void'($value$plusargs("router_dat_stall_cycles=%d", dat_stall_cycles));
        if (dat_stall_cycles < 0) $fatal(1, "Negative DAT stall interval");
        if (dat_stall_cycles != 0)
            $display("ROUTER_DAT_STALL cycles=%0d phases=write_blocked,open,read_blocked,open", dat_stall_cycles);
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) dat_cycle <= 0;
        else dat_cycle <= dat_cycle + 1;
    end
    function automatic int endpoint(int node, int port);
        for (int e = 0; e < NUM_ENDPOINTS; e++)
            if (ENDPOINT_NODE[e] == node && ENDPOINT_PORT[e] == port) return e;
        return -1;
    endfunction

    for (genvar n = 0; n < NUM_ROUTERS; n++) begin : gen_router
        router #(
            .ROUTER_X (n%MESH_X),
            .ROUTER_Y (n/MESH_X),
            .MESH_X (MESH_X),
            .MESH_Y (MESH_Y),
            .NUM_DAT_VC (NUM_VC),
            .REQ_FIFO_DEPTH (REQ_FIFO_DEPTH),
            .RSP_FIFO_DEPTH (RSP_FIFO_DEPTH),
            .DAT_RX_FIFO_DEPTH (DAT_RX_FIFO_DEPTH),
            .DAT_FIFO_DEPTH (DAT_FIFO_DEPTH)
        ) i_router (
            .clk_i (clk_i),
            .rst_n_i (rst_n_i),
            .RXREQVLD (rx_req_valid[n]),
            .RXREQ (rx_req_flit[n]),
            .RXREQRDY (rx_req_ready[n]),
            .TXREQVLD (tx_req_valid[n]),
            .TXREQ (tx_req_flit[n]),
            .TXREQRDY (tx_req_ready[n]),
            .RXRSPVLD (rx_rsp_valid[n]),
            .RXRSP (rx_rsp_flit[n]),
            .RXRSPRDY (rx_rsp_ready[n]),
            .TXRSPVLD (tx_rsp_valid[n]),
            .TXRSP (tx_rsp_flit[n]),
            .TXRSPRDY (tx_rsp_ready[n]),
            .RXDATVLD (rx_dat_valid[n]),
            .RXDAT (rx_dat_flit[n]),
            .RXDATRDY (rx_dat_ready[n]),
            .TXDATVLD (tx_dat_valid[n]),
            .TXDAT (tx_dat_flit[n]),
            .TXDATRDY (tx_dat_ready[n])
        );
        `include "router_coverage.svh"
        for (genvar port = 0; port < 5; port++) begin : gen_port
            localparam int X = n%MESH_X;
            localparam int Y = n/MESH_X;
            localparam int OTHER = port == NORTH ? n+MESH_X : port == EAST ? n+1 :
                                   port == SOUTH ? n-MESH_X : n-1;
            localparam int OPPOSITE = port == NORTH ? SOUTH : port == EAST ? WEST :
                                      port == SOUTH ? NORTH : EAST;
            localparam bit CONNECTED = (port == NORTH && Y < MESH_Y-1) ||
                (port == EAST && X < MESH_X-1) || (port == SOUTH && Y > 0) || (port == WEST && X > 0);
            localparam int E = endpoint(n, port);
            logic [NUM_VC-1:0] dat_gate;
            always_comb begin
                dat_gate = '1;
                if (dat_stall_cycles > 0) begin
                    case ((dat_cycle / dat_stall_cycles + n + port) % 4)
                        0: dat_gate[0] = 1'b0;
                        2: dat_gate[1] = 1'b0;
                        default: dat_gate = '1;
                    endcase
                end
            end
            if (E >= 0) begin : gen_endpoint
                assign rx_req_valid[n][port] = RXREQVLD[E];
                assign TXREQVLD[E] = tx_req_valid[n][port];
                assign rx_req_flit[n][port] = RXREQ[E];
                assign TXREQ[E] = tx_req_flit[n][port];
                assign RXREQRDY[E] = rx_req_ready[n][port];
                assign tx_req_ready[n][port] = TXREQRDY[E];
                assign rx_rsp_valid[n][port] = RXRSPVLD[E];
                assign TXRSPVLD[E] = tx_rsp_valid[n][port];
                assign rx_rsp_flit[n][port] = RXRSP[E];
                assign TXRSP[E] = tx_rsp_flit[n][port];
                assign RXRSPRDY[E] = rx_rsp_ready[n][port];
                assign tx_rsp_ready[n][port] = TXRSPRDY[E];
                assign rx_dat_valid[n][port] = RXDATVLD[E];
                assign TXDATVLD[E] = tx_dat_valid[n][port];
                assign rx_dat_flit[n][port] = RXDAT[E];
                assign TXDAT[E] = tx_dat_flit[n][port];
                assign RXDATRDY[E] = rx_dat_ready[n][port];
                assign tx_dat_ready[n][port] = TXDATRDY[E] & dat_gate;
            end else if (CONNECTED) begin : gen_link
                assign rx_req_valid[n][port] = tx_req_valid[OTHER][OPPOSITE];
                assign rx_req_flit[n][port] = tx_req_flit[OTHER][OPPOSITE];
                assign tx_req_ready[n][port] = rx_req_ready[OTHER][OPPOSITE];
                assign rx_rsp_valid[n][port] = tx_rsp_valid[OTHER][OPPOSITE];
                assign rx_rsp_flit[n][port] = tx_rsp_flit[OTHER][OPPOSITE];
                assign tx_rsp_ready[n][port] = rx_rsp_ready[OTHER][OPPOSITE];
                assign rx_dat_valid[n][port] = tx_dat_valid[OTHER][OPPOSITE];
                assign rx_dat_flit[n][port] = tx_dat_flit[OTHER][OPPOSITE];
                assign tx_dat_ready[n][port] = rx_dat_ready[OTHER][OPPOSITE] & dat_gate;
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
            end
        end
    end
    initial begin
        for (int n = 0; n < NUM_ROUTERS; n++)
            if (endpoint(n, LOCAL) < 0)
                $fatal(1, "Each mesh node requires one local NI endpoint");
        for (int e = 0; e < NUM_ENDPOINTS; e++) begin
            if (ENDPOINT_NODE[e] >= NUM_ROUTERS || ENDPOINT_PORT[e] > 4)
                $fatal(1, "Invalid mesh endpoint attachment");
            if ((ENDPOINT_PORT[e] == NORTH && ENDPOINT_NODE[e]/MESH_X != MESH_Y-1) ||
                    (ENDPOINT_PORT[e] == EAST && ENDPOINT_NODE[e]%MESH_X != MESH_X-1) ||
                    (ENDPOINT_PORT[e] == SOUTH && ENDPOINT_NODE[e]/MESH_X != 0) ||
                    (ENDPOINT_PORT[e] == WEST && ENDPOINT_NODE[e]%MESH_X != 0))
                $fatal(1, "Boundary endpoint cannot replace an inter-router link");
            for (int j = 0; j < e; j++)
                if (ENDPOINT_NODE[e] == ENDPOINT_NODE[j] && ENDPOINT_PORT[e] == ENDPOINT_PORT[j])
                    $fatal(1, "Duplicate mesh endpoint attachment");
        end
    end
endmodule
