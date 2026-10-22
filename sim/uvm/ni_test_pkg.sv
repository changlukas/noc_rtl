`timescale 1ps/1ps
`include "axi/typedef.svh"
package ni_test_pkg;
    import uvm_pkg::*;
    import tue_pkg::*;
    import tvip_axi_types_pkg::*;
    import tvip_axi_pkg::*;
    `include "uvm_macros.svh"
    `include "ni_tb_params.svh"
    import ni_params_pkg::*;
    localparam int NI_NUM_NSUS = NI_DIRECT_LINK ? 4 : NOC_MESH_X_DIM*NOC_MESH_Y_DIM;
    localparam int NI_NUM_LINKS = NI_DIRECT_LINK ? NI_NUM_NSUS+1 : NI_NUM_NSUS;
    localparam int NI_NUM_SOURCES = NI_DIRECT_LINK ? 1 : NI_NUM_NSUS;
    localparam int NI_CHECK_ID_WIDTH = NI_MON_ID_WIDTH + $clog2(NI_NUM_SOURCES);
    localparam int NI_CHECK_IDS = 1 << NI_CHECK_ID_WIDTH;
    localparam int NI_NUM_IDS = 1 << NI_INPUT_ID_WIDTH;
    typedef logic [AXI_ADDR_WIDTH-1:0] ni_mon_addr_t;
    typedef logic [NI_CHECK_ID_WIDTH-1:0] ni_mon_id_t;
    typedef logic [AXI_DATA_WIDTH-1:0] ni_mon_data_t;
    typedef logic [AXI_DATA_WIDTH/8-1:0] ni_mon_strb_t;
    typedef logic [AXI_AWUSER_WIDTH-1:0] ni_mon_user_t;
    `AXI_TYPEDEF_ALL(ni_mon, ni_mon_addr_t, ni_mon_id_t, ni_mon_data_t, ni_mon_strb_t, ni_mon_user_t)
    typedef struct packed {
        int unsigned idx;
        ni_mon_addr_t start_addr;
        ni_mon_addr_t end_addr;
    } ni_mon_rule_t;
    function automatic int ni_nsu_id(int port);
        if (!NI_DIRECT_LINK) return (((port-1)/NOC_MESH_X_DIM) << ni_flit_pkg::X_WIDTH) | ((port-1)%NOC_MESH_X_DIM);
        case (port)
            1: return (2 << ni_flit_pkg::X_WIDTH) | 1;
            2: return (1 << ni_flit_pkg::X_WIDTH) | 2;
            3: return 1;
            4: return (1 << ni_flit_pkg::X_WIDTH);
            default: return -1;
        endcase
    endfunction
    function automatic ni_mon_rule_t [topology_pkg::SAM_NUM_RULES-1:0] ni_monitor_rules();
        for (int r = 0; r < topology_pkg::SAM_NUM_RULES; r++) begin
            ni_monitor_rules[r].start_addr = topology_pkg::SAM[r].start_addr;
            ni_monitor_rules[r].end_addr = topology_pkg::SAM[r].end_addr;
            for (int n = 0; n < NI_NUM_NSUS; n++)
                if (topology_pkg::SAM[r].idx.dst_id == ni_nsu_id(n+1)) ni_monitor_rules[r].idx = n;
        end
    endfunction
    localparam ni_mon_rule_t [topology_pkg::SAM_NUM_RULES-1:0] NI_MON_RULES = ni_monitor_rules();
    `include "axi_reorder_compare.svh"
    `include "ni_noc_monitor.svh"
    `include "ni_axi_monitor.svh"
    `include "ni_data_checker.svh"
    `include "ni_scoreboard.svh"
    `include "ni_axi_coverage.svh"
    `include "ni_pattern_sequence.svh"
    `include "ni_slave_sequence.svh"
    `include "ni_env.svh"
    `include "ni_test.svh"
endpackage
