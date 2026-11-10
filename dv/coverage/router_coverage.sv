// SPDX-License-Identifier: Apache-2.0
`timescale 1ps/1ps

// Passive observations only. Existing assertions and scoreboards check correctness.
`ifdef NI_COVERAGE
module router_link_coverage #(
    parameter int TYPE0 = 0,
    parameter int TYPE1 = TYPE0,
    parameter int TYPE2 = TYPE0,
    parameter int TYPE3 = TYPE0
) (
    input wire clk_i,
    input wire rst_n_i,
    input wire rx_valid_i,
    input wire rx_ready_i,
    input wire noc_header_pkg::header_t rx_header_i,
    input wire tx_valid_i,
    input wire tx_ready_i,
    input wire noc_header_pkg::header_t tx_header_i
);
    function automatic bit has_body(int packet_type);
        case (packet_type)
            noc_header_pkg::PKT_NARROW_AW, noc_header_pkg::PKT_NARROW_W,
            noc_header_pkg::PKT_DATA_AW, noc_header_pkg::PKT_DATA_W: return 1;
            default: return 0;
        endcase
    endfunction
    localparam bit HAS_BODY = has_body(TYPE0) || has_body(TYPE1) || has_body(TYPE2) || has_body(TYPE3);
    localparam logic [(1 << noc_header_pkg::PACKET_TYPE_WIDTH)-1:0] TYPES =
        (1 << TYPE0) | (1 << TYPE1) | (1 << TYPE2) | (1 << TYPE3);
    covergroup router_link_cg with function sample(bit tx, int packet_type, bit tail);
        option.per_instance = 1;
        cp_direction: coverpoint tx { bins rx = {0}; bins tx = {1}; }
        cp_type: coverpoint packet_type {
            bins packet[] = {[noc_header_pkg::PKT_NARROW_AW:noc_header_pkg::PKT_DATA_R]};
            ignore_bins other_type = {
                TYPES[0] ? -1 : 0, TYPES[1] ? -1 : 1, TYPES[2] ? -1 : 2,
                TYPES[3] ? -1 : 3, TYPES[4] ? -1 : 4, TYPES[5] ? -1 : 5,
                TYPES[6] ? -1 : 6, TYPES[7] ? -1 : 7, TYPES[8] ? -1 : 8, TYPES[9] ? -1 : 9
            };
        }
        cp_tail: coverpoint int'(tail) {
            bins form[] = {[0:1]};
            ignore_bins single_body = {HAS_BODY ? -1 : 0};
        }
        direction_type: cross cp_direction, cp_type;
        type_tail: cross cp_type, cp_tail {
            ignore_bins aw_tail = binsof(cp_type) intersect
                {noc_header_pkg::PKT_NARROW_AW, noc_header_pkg::PKT_DATA_AW} && binsof(cp_tail) intersect {1};
            ignore_bins single_body = binsof(cp_type) intersect
                {noc_header_pkg::PKT_NARROW_AR, noc_header_pkg::PKT_NARROW_B, noc_header_pkg::PKT_NARROW_R,
                 noc_header_pkg::PKT_DATA_AR, noc_header_pkg::PKT_DATA_B, noc_header_pkg::PKT_DATA_R} &&
                binsof(cp_tail) intersect {0};
        }
    endgroup
    router_link_cg link_coverage = new();
    initial link_coverage.set_inst_name($sformatf("%m.link"));

    always @(posedge clk_i) begin
        if (rst_n_i) begin
            if (rx_valid_i && rx_ready_i)
                link_coverage.sample(0, int'(rx_header_i.packet_type), rx_header_i.flit_tail);
            if (tx_valid_i && tx_ready_i)
                link_coverage.sample(1, int'(tx_header_i.packet_type), tx_header_i.flit_tail);
        end
    end
endmodule

// One instance per output and traffic class. Bit 5 denotes the RSP merge requester.
module router_switch_coverage #(
    parameter int NUM_INPUTS = 5,
    parameter logic [NUM_INPUTS-1:0] UNICAST_INPUTS = '1,
    parameter logic [NUM_INPUTS-1:0] MULTICAST_INPUTS = '0,
    parameter bit MULTI_FLIT = 1,
    parameter int MAX_CONTENDERS = $countones(UNICAST_INPUTS | MULTICAST_INPUTS)
) (
    input wire clk_i,
    input wire rst_n_i,
    input wire [NUM_INPUTS-1:0] request_i,
    input wire [NUM_INPUTS-1:0] eligible_i,
    input wire [NUM_INPUTS-1:0] grant_i,
    input wire [NUM_INPUTS-1:0] tail_i,
    input wire noc_header_pkg::header_t header_i,
    input wire owner_valid_i,
    input wire [$clog2(NUM_INPUTS)-1:0] owner_i
);
    covergroup router_route_cg(int input_mask) with function sample(int source);
        option.per_instance = 1;
        cp_input: coverpoint source {
            bins input_port[] = {[0:NUM_INPUTS-1]};
            ignore_bins disconnected = {
                input_mask[0] ? -1 : 0, input_mask[1] ? -1 : 1, input_mask[2] ? -1 : 2,
                input_mask[3] ? -1 : 3, input_mask[4] ? -1 : 4, input_mask[5] ? -1 : 5
            };
        }
    endgroup
    router_route_cg unicast_coverage, multicast_coverage;

    localparam int INPUTS = int'(UNICAST_INPUTS | MULTICAST_INPUTS);
    covergroup router_arb_cg with function sample(int winner, int contenders);
        option.per_instance = 1;
        cp_winner: coverpoint winner {
            bins input_port[] = {[0:NUM_INPUTS-1]};
            ignore_bins disconnected = {
                INPUTS[0] ? -1 : 0, INPUTS[1] ? -1 : 1, INPUTS[2] ? -1 : 2,
                INPUTS[3] ? -1 : 3, INPUTS[4] ? -1 : 4, INPUTS[5] ? -1 : 5
            };
        }
        cp_contenders: coverpoint (contenders > 2 ? 3 : contenders) {
            bins one = {1}; bins two = {2}; bins many = {3};
            ignore_bins unreachable = {MAX_CONTENDERS >= 2 ? -1 : 2, MAX_CONTENDERS >= 3 ? -1 : 3};
        }
        winner_contention: cross cp_winner, cp_contenders;
    endgroup
    router_arb_cg arb_coverage = new();

    // Events are sampled on resumption, never merely because a stall occurred.
    covergroup router_packet_cg with function sample(int event_kind);
        option.per_instance = 1;
        cp_event: coverpoint event_kind {
            bins body = {0}; bins request_gap_resume = {1}; bins body_stall_resume = {2};
            bins tail_stall_resume = {3}; bins handoff = {4};
            ignore_bins unreachable = {MULTI_FLIT ? -1 : 0, MULTI_FLIT ? -1 : 1,
                MULTI_FLIT ? -1 : 2, MAX_CONTENDERS >= 2 ? -1 : 4};
        }
    endgroup
    router_packet_cg packet_coverage = new();
    bit active = 0, request_gap = 0, body_stall = 0, tail_stall = 0;
    int owner = -1, stalled_owner = -1;
    logic [NUM_INPUTS-1:0] waiting = '0;

    initial begin
        if (|UNICAST_INPUTS) begin
            unicast_coverage = new(int'(UNICAST_INPUTS));
            unicast_coverage.set_inst_name($sformatf("%m.unicast"));
        end
        if (|MULTICAST_INPUTS) begin
            multicast_coverage = new(int'(MULTICAST_INPUTS));
            multicast_coverage.set_inst_name($sformatf("%m.multicast"));
        end
        arb_coverage.set_inst_name($sformatf("%m.arbitration"));
        packet_coverage.set_inst_name($sformatf("%m.packet"));
    end

    always @(posedge clk_i or negedge rst_n_i) begin : sample_switch
        int winner, contenders;
        if (!rst_n_i) begin
            active = 0;
            request_gap = 0;
            body_stall = 0;
            tail_stall = 0;
            owner = -1;
            stalled_owner = -1;
            waiting = '0;
        end else begin
            winner = -1;
            contenders = $countones(eligible_i);
            for (int i = 0; i < NUM_INPUTS; i++)
                if (grant_i[i] && request_i[i]) winner = i;
            if (MULTI_FLIT && active && owner_valid_i && int'(owner_i) == owner) begin
                // This includes gaps while other multicast branches complete.
                if (!request_i[owner]) request_gap = 1;
            end
            if (owner_valid_i && request_i[owner_i] && !grant_i[owner_i]) begin
                if (stalled_owner != int'(owner_i)) begin
                    body_stall = 0;
                    tail_stall = 0;
                end
                stalled_owner = int'(owner_i);
                if (tail_i[owner_i]) tail_stall = 1;
                else body_stall = 1;
            end
            if (winner >= 0) begin
                if (header_i.coll_op == noc_header_pkg::COLL_UNICAST) begin
                    if (|UNICAST_INPUTS) unicast_coverage.sample(winner);
                end else if (header_i.coll_op == noc_header_pkg::COLL_MULTICAST) begin
                    if (|MULTICAST_INPUTS) multicast_coverage.sample(winner);
                end
                // The effective tree snapshot excludes requests arriving during a packet.
                if (tail_i[winner]) arb_coverage.sample(winner, contenders);
                if (waiting[winner]) packet_coverage.sample(4);
                waiting = '0;
                if (MULTI_FLIT && active && winner == owner) begin
                    if (!tail_i[winner]) packet_coverage.sample(0);
                    if (request_gap) packet_coverage.sample(1);
                end
                if (winner == stalled_owner) begin
                    if (MULTI_FLIT && body_stall) packet_coverage.sample(2);
                    if (tail_stall) packet_coverage.sample(3);
                end
                active = !tail_i[winner];
                owner = winner;
                request_gap = 0;
                body_stall = 0;
                tail_stall = 0;
                stalled_owner = -1;
                if (tail_i[winner]) waiting = request_i & ~(NUM_INPUTS'(1) << winner);
            end
        end
    end
endmodule

module router_buffer_coverage #(
    parameter int DEPTH = 8
) (
    input wire clk_i,
    input wire rst_n_i,
    input wire [cc_pkg::cnt_width(DEPTH)-1:0] usage_i,
    input wire full_i,
    input wire empty_i,
    input wire push_i,
    input wire pop_i
);
    covergroup router_buffer_cg with function sample(int occupancy, bit push, bit pop);
        option.per_instance = 1;
        cp_occupancy: coverpoint (occupancy == 0 ? 0 : occupancy == DEPTH ? 2 : 1) {
            bins empty = {0}; bins partial = {1}; bins full = {2};
            ignore_bins no_partial = {DEPTH > 1 ? -1 : 1};
        }
        cp_operation: coverpoint int'({push, pop}) {
            bins idle = {0}; bins pop = {1}; bins push = {2}; bins both = {3};
            ignore_bins no_simultaneous = {DEPTH > 1 ? -1 : 3};
        }
        occupancy_operation: cross cp_occupancy, cp_operation {
            ignore_bins empty_pop = binsof(cp_occupancy.empty) && binsof(cp_operation) intersect {1, 3};
            ignore_bins full_push = binsof(cp_occupancy.full) && binsof(cp_operation) intersect {2, 3};
        }
    endgroup
    router_buffer_cg buffer_coverage = new();
    initial buffer_coverage.set_inst_name($sformatf("%m.buffer"));
    bit full_seen = 0;
    full_reuse: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        full_seen && push_i && !full_i);
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) full_seen <= 0;
        else begin
            buffer_coverage.sample(int'(usage_i), push_i && !full_i, pop_i && !empty_i);
            if (full_i) full_seen <= 1;
            else if (push_i) full_seen <= 0;
        end
    end
endmodule

module router_dat_coverage (
    input wire clk_i,
    input wire rst_n_i,
    input wire [1:0] pending_i,
    input wire [1:0] ready_i,
    input wire [1:0] transfer_i
);
    covergroup router_dat_cg with function sample(int event_kind);
        option.per_instance = 1;
        cp_event: coverpoint event_kind {
            bins both_pending = {0};
            bins write_progress_read_blocked = {1}; bins read_progress_write_blocked = {2};
            bins write_resume = {3}; bins read_resume = {4};
        }
    endgroup
    router_dat_cg dat_coverage = new();
    covergroup router_flit_cg with function sample(int winner, int contenders);
        option.per_instance = 1;
        cp_winner: coverpoint winner { bins write = {0}; bins read = {1}; }
        cp_contenders: coverpoint contenders { bins one = {1}; bins two = {2}; }
        winner_contention: cross cp_winner, cp_contenders;
    endgroup
    router_flit_cg flit_coverage = new();
    initial begin
        dat_coverage.set_inst_name($sformatf("%m.dat"));
        flit_coverage.set_inst_name($sformatf("%m.flit"));
    end
    bit [1:0] blocked = '0;
    wire both_eligible = &(pending_i & ready_i);
    write_to_read: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        both_eligible && transfer_i[noc_unit_params_pkg::DAT_WRITE_VC] ##1
        both_eligible && transfer_i[noc_unit_params_pkg::DAT_READ_VC]);
    read_to_write: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        both_eligible && transfer_i[noc_unit_params_pkg::DAT_READ_VC] ##1
        both_eligible && transfer_i[noc_unit_params_pkg::DAT_WRITE_VC]);
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) blocked = '0;
        else begin
            if (&pending_i) dat_coverage.sample(0);
            for (int v = 0; v < 2; v++) begin
                if (pending_i[v] && !ready_i[v]) blocked[v] = 1;
                if (transfer_i[v]) begin
                    flit_coverage.sample(v, $countones(pending_i & ready_i));
                    if (pending_i[1-v] && !ready_i[1-v]) dat_coverage.sample(1+v);
                    if (blocked[v]) dat_coverage.sample(3+v);
                    blocked[v] = 0;
                end
            end
        end
    end
endmodule

module router_multicast_coverage #(
    parameter int MAX_BRANCHES = 5
) (
    input wire clk_i,
    input wire rst_n_i,
    input wire multicast_i,
    input wire valid_i,
    input wire complete_i,
    input wire [4:0] route_i,
    input wire [4:0] transfer_i
);
    covergroup router_multicast_cg with function sample(int branches, int event_kind);
        option.per_instance = 1;
        cp_branches: coverpoint int'(branches > 1) {
            bins one = {0}; bins multiple = {1};
            ignore_bins no_fork = {MAX_BRANCHES > 1 ? -1 : 1};
        }
        cp_event: coverpoint event_kind {
            bins branch_transfer = {0}; bins partial = {1}; bins partial_complete = {2};
            ignore_bins no_fork = {MAX_BRANCHES > 1 ? -1 : 1, MAX_BRANCHES > 1 ? -1 : 2};
        }
        branches_event: cross cp_branches, cp_event {
            ignore_bins single_partial = binsof(cp_branches.one) && binsof(cp_event) intersect {1, 2};
        }
    endgroup
    router_multicast_cg multicast_coverage = new();
    initial multicast_coverage.set_inst_name($sformatf("%m.multicast"));
    bit partial = 0;
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) partial = 0;
        else if (valid_i && multicast_i) begin
            if (|transfer_i) begin
                multicast_coverage.sample($countones(route_i), 0);
                if (!complete_i) begin
                    multicast_coverage.sample($countones(route_i), 1);
                    partial = 1;
                end
            end
            if (complete_i) begin
                if (partial) multicast_coverage.sample($countones(route_i), 2);
                partial = 0;
            end
        end
    end
endmodule

module router_merge_coverage #(
    parameter int MAX_CONTRIBUTORS = 5
) (
    input wire clk_i,
    input wire rst_n_i,
    input wire [4:0] pending_i,
    input wire valid_i,
    input wire ready_i,
    input wire [4:0] contributors_i,
    input wire [4:0][noc_payload_pkg::B_BRESP_WIDTH-1:0] bresp_i,
    input wire [4:0] nominal_i,
    input wire [4:0] selected_i
);
    covergroup router_merge_cg with function sample(int event_kind);
        option.per_instance = 1;
        cp_event: coverpoint event_kind {
            bins waiting = {0}; bins stalled = {1};
            bins progress_after_wait = {2}; bins progress_after_stall = {3}; bins accepted = {4};
            ignore_bins no_merge_wait = {MAX_CONTRIBUTORS > 1 ? -1 : 0, MAX_CONTRIBUTORS > 1 ? -1 : 2};
        }
    endgroup
    router_merge_cg merge_coverage = new();
    covergroup router_fanin_cg with function sample(int contributors);
        option.per_instance = 1;
        cp_contributors: coverpoint int'(contributors > 1) {
            bins one = {0}; bins multiple = {1};
            ignore_bins no_merge = {MAX_CONTRIBUTORS > 1 ? -1 : 1};
        }
    endgroup
    router_fanin_cg fanin_coverage = new();
    covergroup router_merge_resp_cg with function sample(int selection);
        option.per_instance = 1;
        cp_selection: coverpoint selection {
            bins all_okay = {0};
            bins slverr_nominal = {1};
            bins slverr_other = {2};
            ignore_bins single_source = {MAX_CONTRIBUTORS > 1 ? -1 : 2};
        }
    endgroup
    router_merge_resp_cg response_coverage = new();
    initial begin
        merge_coverage.set_inst_name($sformatf("%m.merge"));
        fanin_coverage.set_inst_name($sformatf("%m.fanin"));
        response_coverage.set_inst_name($sformatf("%m.response"));
    end
    bit waited = 0, stalled = 0;
    always @(posedge clk_i or negedge rst_n_i) begin : sample_merge
        bit all_okay, nominal_okay;
        logic [4:0] slverr_sources;
        if (!rst_n_i) begin
            waited = 0;
            stalled = 0;
        end else begin
            if ((|pending_i) && !valid_i) begin
                merge_coverage.sample(0);
                waited = 1;
            end
            if (valid_i) begin
                if (!ready_i) begin
                    merge_coverage.sample(1);
                    stalled = 1;
                end else begin
                    merge_coverage.sample(4);
                    fanin_coverage.sample($countones(contributors_i));
                    if (waited) merge_coverage.sample(2);
                    if (stalled) merge_coverage.sample(3);
                    all_okay = |contributors_i;
                    nominal_okay = 0;
                    slverr_sources = '0;
                    for (int i = 0; i < 5; i++) begin
                        if (contributors_i[i]) begin
                            all_okay &= bresp_i[i] === 2'b00;
                            if (nominal_i[i]) nominal_okay = bresp_i[i] === 2'b00;
                            if (bresp_i[i] === 2'b10) slverr_sources[i] = 1;
                        end
                    end
                    if (!$isunknown({contributors_i, nominal_i, selected_i}) &&
                            $onehot(nominal_i) && $onehot(selected_i) &&
                            (|(nominal_i & contributors_i)) && (|(selected_i & contributors_i))) begin
                        if (all_okay) response_coverage.sample(0);
                        else if (|(slverr_sources & selected_i)) begin
                            if (selected_i == nominal_i) response_coverage.sample(1);
                            else if (nominal_okay) response_coverage.sample(2);
                        end
                    end
                    waited = 0;
                    stalled = 0;
                end
            end
        end
    end
endmodule

module router_reset_coverage (
    input wire clk_i,
    input wire rst_n_i,
    input wire [5:0] pending_i,
    input wire [2:0] progress_i
);
    covergroup router_reset_cg with function sample(int resource);
        option.per_instance = 1;
        cp_resource: coverpoint resource {
            bins idle = {0}; bins input_fifo = {1}; bins packet = {2}; bins dat_output = {3};
            bins multicast = {4}; bins merge = {5}; bins dat_route = {6};
        }
    endgroup
    router_reset_cg reset_coverage = new();
    covergroup router_recovery_cg with function sample(int network);
        option.per_instance = 1;
        cp_network: coverpoint network { bins req = {0}; bins rsp = {1}; bins dat = {2}; }
    endgroup
    router_recovery_cg recovery_coverage = new();
    initial begin
        reset_coverage.set_inst_name($sformatf("%m.reset"));
        recovery_coverage.set_inst_name($sformatf("%m.recovery"));
    end
    bit [2:0] recovery = '0;
    // Sample the actual state in the active region, before asynchronous-reset NBAs.
    always @(negedge rst_n_i) begin
        recovery = '0;
        if (!$isunknown(pending_i)) begin
            if (!(|pending_i)) reset_coverage.sample(0);
            for (int i = 0; i < 6; i++)
                if (pending_i[i]) reset_coverage.sample(i+1);
            if (|pending_i) recovery = '1;
        end
    end
    always @(posedge clk_i) begin
        if (rst_n_i) begin
            for (int network = 0; network < 3; network++) begin
                if (recovery[network] && progress_i[network]) begin
                    recovery_coverage.sample(network);
                    recovery[network] = 0;
                end
            end
        end
    end
endmodule
`endif
