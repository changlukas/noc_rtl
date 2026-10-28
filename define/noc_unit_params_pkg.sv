// Hardware parameters grouped by shared resources, Router, NMU and NSU.
`timescale 1ns/1ps

package noc_unit_params_pkg;
    // Shared interface and NoC buffering.
    localparam int AXI_FIFO_DEPTH = 8;
    localparam int NOC_FIFO_DEPTH = 8;
    localparam int CREDIT_DEPTH = 8;

    // Router topology, output buffering and fixed VC traffic classes.
    localparam int MESH_X_DIM = 4;
    localparam int MESH_Y_DIM = 4;
    localparam int ROUTER_OUTPUT_FIFO_DEPTH = 8;
    typedef enum int {NORTH = 0, EAST = 1, SOUTH = 2, WEST = 3, LOCAL = 4} direction_t;
    // Fixed traffic classes, not an allocator: one write VC and one read VC.
    localparam int DAT_WRITE_VC = 0;
    localparam int DAT_READ_VC = 1;
    localparam int DAT_NUM_VC = 2;
    localparam int REQ_NUM_VC = 1;
    localparam int RSP_NUM_VC = 1;


    // NMU ordering and queue capacities.
    localparam bit NMU_R_ROB_EN = 1'b1;
    localparam int NMU_ROB_B_DEPTH = 128;
    localparam int NMU_ROB_R_DEPTH = 128;
    localparam int NMU_MAX_OUTSTANDING_PER_ID = 32;
    localparam int NMU_QUEUE_DEPTH = 16;
    localparam int NMU_DEPKT_Q_DEPTH = 16;
    localparam int NMU_ARBITER_FIFO_DEPTH = 4;

    // NSU downstream AXI ID and context/queue capacities.
    localparam int NSU_AXI_ID_WIDTH = 3;
    localparam int NSU_MAX_ACTIVE_IDS = 8;
    localparam int NSU_MAX_OUTSTANDING = 32;
    localparam int NSU_QUEUE_DEPTH = 16;
    localparam int NSU_ARBITER_FIFO_DEPTH = 4;
endpackage
