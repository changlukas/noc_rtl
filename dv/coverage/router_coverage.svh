// SPDX-License-Identifier: Apache-2.0
// Included inside router_mesh.gen_router, beside i_router. No DUT drivers.
`ifdef NI_COVERAGE
    localparam logic [4:0] COV_ENDPOINTS = {
        endpoint(n, 4) >= 0, endpoint(n, 3) >= 0, endpoint(n, 2) >= 0,
        endpoint(n, 1) >= 0, endpoint(n, 0) >= 0
    };
    localparam logic [4:0] COV_LINKS = {
        n%MESH_X > 0, n/MESH_X > 0, n%MESH_X < MESH_X-1,
        n/MESH_X < MESH_Y-1, 1'b0
    };
    localparam logic [4:0] COV_PORTS = COV_ENDPOINTS | COV_LINKS;

    // XY turns depend on whether a port is a mesh link or an attached endpoint.
    // Endpoint injection/ejection includes local loopback and boundary endpoints.
    function automatic logic [4:0] cov_inputs(int output_port, bit multicast);
        logic [4:0] mask;
        mask = '0;
        for (int i = 0; i < 5; i++) begin
            if (COV_PORTS[i] && COV_PORTS[output_port]) begin
                if (multicast && COV_ENDPOINTS[output_port] && output_port != LOCAL)
                    mask[i] = 0;
                else if (COV_ENDPOINTS[output_port] || COV_ENDPOINTS[i])
                    mask[i] = 1;
                else if (output_port == NORTH || output_port == SOUTH)
                    mask[i] = i != output_port;
                else if (output_port == EAST)
                    mask[i] = i == WEST;
                else if (output_port == WEST)
                    mask[i] = i == EAST;
            end
        end
        return mask;
    endfunction

    function automatic int cov_branches(int input_port);
        if (COV_ENDPOINTS[input_port]) return 1+$countones(COV_LINKS);
        case (input_port)
            NORTH: return 1+int'(COV_LINKS[SOUTH]);
            SOUTH: return 1+int'(COV_LINKS[NORTH]);
            default: return $countones(COV_LINKS);
        endcase
    endfunction

    function automatic int cov_contributors(int output_port);
        if (COV_ENDPOINTS[output_port]) return 1+$countones(COV_LINKS);
        case (output_port)
            NORTH: return 1+int'(COV_LINKS[SOUTH])+int'(COV_LINKS[EAST])+int'(COV_LINKS[WEST]);
            EAST: return 1+int'(COV_LINKS[WEST]);
            SOUTH: return 1+int'(COV_LINKS[NORTH])+int'(COV_LINKS[EAST])+int'(COV_LINKS[WEST]);
            default: return 1+int'(COV_LINKS[EAST]);
        endcase
    endfunction

    wire [4:0] cov_req_progress, cov_rsp_progress, cov_dat_progress;
    wire [4:0] cov_input_pending, cov_packet_pending, cov_output_pending;
    wire [4:0] cov_multicast_pending, cov_merge_pending, cov_route_pending;
    for (genvar p = 0; p < 5; p++) begin : gen_coverage
        assign cov_req_progress[p] = tx_req_valid[n][p] && tx_req_ready[n][p];
        assign cov_rsp_progress[p] = tx_rsp_valid[n][p] && tx_rsp_ready[n][p];
        assign cov_dat_progress[p] = |(tx_dat_valid[n][p] & tx_dat_ready[n][p]);
        assign cov_input_pending[p] = !i_router.i_req_router.empty[p] ||
            !i_router.i_rsp_router.empty[p] ||
            (|(~i_router.i_dat_router.empty[p*NUM_VC +: NUM_VC]));
        wire [NUM_VC-1:0] dat_owner_pending;
        for (genvar v = 0; v < NUM_VC; v++) begin : gen_owner
            assign dat_owner_pending[v] =
                (|i_router.i_dat_router.gen_output[p].gen_vc[v].i_switch_allocator.i_packet_rr_arbiter.req_reg) &&
                !i_router.i_dat_router.gen_output[p].gen_vc[v].i_switch_allocator.i_packet_rr_arbiter.tail_reg;
        end
        assign cov_packet_pending[p] = i_router.i_req_router.active_reg[p] ||
            (|i_router.i_dat_router.active_reg[p*NUM_VC +: NUM_VC]) || (|dat_owner_pending) ||
            ((|i_router.i_req_router.gen_output[p].i_switch_allocator.i_packet_rr_arbiter.req_reg) &&
             !i_router.i_req_router.gen_output[p].i_switch_allocator.i_packet_rr_arbiter.tail_reg) ||
            ((|i_router.i_rsp_router.gen_output[p].i_switch_allocator.i_packet_rr_arbiter.req_reg) &&
             !i_router.i_rsp_router.gen_output[p].i_switch_allocator.i_packet_rr_arbiter.tail_reg);
        assign cov_output_pending[p] = |(~i_router.i_dat_router.gen_output[p].out_empty);
        assign cov_multicast_pending[p] =
            (!i_router.i_req_router.empty[p] && i_router.i_req_router.is_collective[p] &&
             (|i_router.i_req_router.branch_valid[p])) ||
            (i_router.i_dat_router.head_valid[p*NUM_VC] &&
             i_router.i_dat_router.head[p*NUM_VC].header.coll_op == noc_header_pkg::COLL_MULTICAST &&
             (|i_router.i_dat_router.branch_valid[p*NUM_VC]));
        assign cov_merge_pending[p] = |i_router.i_rsp_router.gen_output[p].merge_valid;
        assign cov_route_pending[p] = |i_router.i_dat_router.head_valid[p*NUM_VC +: NUM_VC];

        if (COV_PORTS[p]) begin : gen_active
            router_link_coverage #(
                .TYPE0(noc_header_pkg::PKT_NARROW_AW), .TYPE1(noc_header_pkg::PKT_NARROW_W),
                .TYPE2(noc_header_pkg::PKT_NARROW_AR), .TYPE3(noc_header_pkg::PKT_DATA_AR)
            ) i_req_link (
                .clk_i(clk_i), .rst_n_i(rst_n_i),
                .rx_valid_i(rx_req_valid[n][p]), .rx_ready_i(rx_req_ready[n][p]),
                .rx_header_i(i_router.req_in[p].header),
                .tx_valid_i(tx_req_valid[n][p]), .tx_ready_i(tx_req_ready[n][p]),
                .tx_header_i(i_router.req_out[p].header)
            );
            router_link_coverage #(
                .TYPE0(noc_header_pkg::PKT_NARROW_B), .TYPE1(noc_header_pkg::PKT_NARROW_R),
                .TYPE2(noc_header_pkg::PKT_DATA_B)
            ) i_rsp_link (
                .clk_i(clk_i), .rst_n_i(rst_n_i),
                .rx_valid_i(rx_rsp_valid[n][p]), .rx_ready_i(rx_rsp_ready[n][p]),
                .rx_header_i(i_router.rsp_in[p].header),
                .tx_valid_i(tx_rsp_valid[n][p]), .tx_ready_i(tx_rsp_ready[n][p]),
                .tx_header_i(i_router.rsp_out[p].header)
            );
            router_switch_coverage #(
                .UNICAST_INPUTS(cov_inputs(p, 0)), .MULTICAST_INPUTS(cov_inputs(p, 1))
            ) i_req_switch (
                .clk_i(clk_i), .rst_n_i(rst_n_i),
                .request_i(i_router.i_req_router.gen_output[p].req),
                .eligible_i(i_router.i_req_router.gen_output[p].i_switch_allocator.i_packet_rr_arbiter.req_next),
                .grant_i(i_router.i_req_router.gen_output[p].grant),
                .tail_i(i_router.i_req_router.last),
                .header_i(i_router.i_req_router.gen_output[p].selected_data.header),
                .owner_valid_i(i_router.i_req_router.gen_output[p].i_switch_allocator.i_packet_rr_arbiter.selected_valid),
                .owner_i(i_router.i_req_router.gen_output[p].i_switch_allocator.i_packet_rr_arbiter.selected_input)
            );
            router_switch_coverage #(
                .NUM_INPUTS(6), .UNICAST_INPUTS({1'b0, cov_inputs(p, 0)}),
                .MULTICAST_INPUTS(6'b100000), .MULTI_FLIT(0),
                .MAX_CONTENDERS($countones(cov_inputs(p, 0)))
            ) i_rsp_switch (
                .clk_i(clk_i), .rst_n_i(rst_n_i),
                .request_i(i_router.i_rsp_router.gen_output[p].req),
                .eligible_i(i_router.i_rsp_router.gen_output[p].i_switch_allocator.i_packet_rr_arbiter.req_next),
                .grant_i(i_router.i_rsp_router.gen_output[p].grant),
                .tail_i(i_router.i_rsp_router.gen_output[p].arb_last),
                .header_i(i_router.i_rsp_router.gen_output[p].selected_data.header),
                .owner_valid_i(i_router.i_rsp_router.gen_output[p].i_switch_allocator.i_packet_rr_arbiter.selected_valid),
                .owner_i(i_router.i_rsp_router.gen_output[p].i_switch_allocator.i_packet_rr_arbiter.selected_input)
            );
            router_buffer_coverage #(.DEPTH(REQ_FIFO_DEPTH)) i_req_fifo (
                .clk_i(clk_i), .rst_n_i(rst_n_i),
                .usage_i(i_router.i_req_router.gen_input[p].i_fifo.usage_o),
                .full_i(i_router.i_req_router.full[p]), .empty_i(i_router.i_req_router.empty[p]),
                .push_i(i_router.i_req_router.gen_input[p].i_fifo.push_i),
                .pop_i(i_router.i_req_router.pop[p])
            );
            router_buffer_coverage #(.DEPTH(RSP_FIFO_DEPTH)) i_rsp_fifo (
                .clk_i(clk_i), .rst_n_i(rst_n_i),
                .usage_i(i_router.i_rsp_router.gen_input[p].i_fifo.usage_o),
                .full_i(i_router.i_rsp_router.full[p]), .empty_i(i_router.i_rsp_router.empty[p]),
                .push_i(i_router.i_rsp_router.gen_input[p].i_fifo.push_i),
                .pop_i(i_router.i_rsp_router.pop[p])
            );
            router_multicast_coverage #(.MAX_BRANCHES(cov_branches(p))) i_req_multicast (
                .clk_i(clk_i), .rst_n_i(rst_n_i),
                .multicast_i(i_router.i_req_router.is_collective[p]),
                .valid_i(!i_router.i_req_router.empty[p]), .complete_i(i_router.i_req_router.pop[p]),
                .route_i(i_router.i_req_router.route_mask[p]),
                .transfer_i(i_router.i_req_router.branch_valid[p] & i_router.i_req_router.branch_ready[p])
            );
            router_merge_coverage #(.MAX_CONTRIBUTORS(cov_contributors(p))) i_rsp_merge (
                .clk_i(clk_i), .rst_n_i(rst_n_i),
                .pending_i(i_router.i_rsp_router.gen_output[p].merge_valid),
                .valid_i(i_router.i_rsp_router.gen_output[p].merged_valid),
                .ready_i(i_router.i_rsp_router.gen_output[p].grant[5]),
                .contributors_i(i_router.i_rsp_router.gen_output[p].merge_ready),
                .bresp_i(i_router.i_rsp_router.bresp),
                .nominal_i(i_router.i_rsp_router.gen_output[p].i_collective.gen_merge.selected_input),
                .selected_i(i_router.i_rsp_router.gen_output[p].merge_select)
            );
            router_dat_coverage i_dat_link (
                .clk_i(clk_i), .rst_n_i(rst_n_i),
                .pending_i(~i_router.i_dat_router.gen_output[p].out_empty),
                .ready_i(tx_dat_ready[n][p]),
                .transfer_i(tx_dat_valid[n][p] & tx_dat_ready[n][p])
            );
            for (genvar v = 0; v < NUM_VC; v++) begin : gen_vc
                localparam int INPUT = p*NUM_VC+v;
                router_link_coverage #(
                    .TYPE0(v == noc_unit_params_pkg::DAT_WRITE_VC ?
                        noc_header_pkg::PKT_DATA_AW : noc_header_pkg::PKT_DATA_R),
                    .TYPE1(v == noc_unit_params_pkg::DAT_WRITE_VC ?
                        noc_header_pkg::PKT_DATA_W : noc_header_pkg::PKT_DATA_R)
                ) i_link (
                    .clk_i(clk_i), .rst_n_i(rst_n_i),
                    .rx_valid_i(rx_dat_valid[n][p][v]), .rx_ready_i(rx_dat_ready[n][p][v]),
                    .rx_header_i(i_router.dat_in[p].header),
                    .tx_valid_i(tx_dat_valid[n][p][v]), .tx_ready_i(tx_dat_ready[n][p][v]),
                    .tx_header_i(i_router.dat_out[p].header)
                );
                router_switch_coverage #(
                    .UNICAST_INPUTS(cov_inputs(p, 0)),
                    .MULTICAST_INPUTS(v == noc_unit_params_pkg::DAT_WRITE_VC ? cov_inputs(p, 1) : 5'b0),
                    .MULTI_FLIT(v == noc_unit_params_pkg::DAT_WRITE_VC)
                ) i_switch (
                    .clk_i(clk_i), .rst_n_i(rst_n_i),
                    .request_i(i_router.i_dat_router.gen_output[p].gen_vc[v].req),
                    .eligible_i(i_router.i_dat_router.gen_output[p].gen_vc[v].i_switch_allocator.i_packet_rr_arbiter.req_next),
                    .grant_i(i_router.i_dat_router.gen_output[p].gen_vc[v].grant),
                    .tail_i(i_router.i_dat_router.gen_output[p].gen_vc[v].last),
                    .header_i(i_router.i_dat_router.gen_output[p].gen_vc[v].selected_data.header),
                    .owner_valid_i(i_router.i_dat_router.gen_output[p].gen_vc[v].i_switch_allocator.i_packet_rr_arbiter.selected_valid),
                    .owner_i(i_router.i_dat_router.gen_output[p].gen_vc[v].i_switch_allocator.i_packet_rr_arbiter.selected_input)
                );
                router_buffer_coverage #(.DEPTH(DAT_RX_FIFO_DEPTH)) i_input_fifo (
                    .clk_i(clk_i), .rst_n_i(rst_n_i),
                    .usage_i(i_router.i_dat_router.gen_input[INPUT].i_fifo.usage_o),
                    .full_i(i_router.i_dat_router.full[INPUT]), .empty_i(i_router.i_dat_router.empty[INPUT]),
                    .push_i(i_router.i_dat_router.gen_input[INPUT].i_fifo.push_i),
                    .pop_i(i_router.i_dat_router.fifo_pop[INPUT])
                );
                router_buffer_coverage #(.DEPTH(DAT_FIFO_DEPTH)) i_output_fifo (
                    .clk_i(clk_i), .rst_n_i(rst_n_i),
                    .usage_i(i_router.i_dat_router.gen_output[p].gen_vc[v].i_fifo.usage_o),
                    .full_i(i_router.i_dat_router.gen_output[p].out_full[v]),
                    .empty_i(i_router.i_dat_router.gen_output[p].out_empty[v]),
                    .push_i(i_router.i_dat_router.gen_output[p].gen_vc[v].i_fifo.push_i),
                    .pop_i(i_router.i_dat_router.gen_output[p].out_pop[v])
                );
                if (v == noc_unit_params_pkg::DAT_WRITE_VC) begin : gen_write
                    router_multicast_coverage #(.MAX_BRANCHES(cov_branches(p))) i_multicast (
                        .clk_i(clk_i), .rst_n_i(rst_n_i),
                        .multicast_i(i_router.i_dat_router.head[INPUT].header.coll_op == noc_header_pkg::COLL_MULTICAST),
                        .valid_i(i_router.i_dat_router.head_valid[INPUT]),
                        .complete_i(i_router.i_dat_router.pop[INPUT]),
                        .route_i(i_router.i_dat_router.route_mask[INPUT]),
                        .transfer_i(i_router.i_dat_router.branch_valid[INPUT] & i_router.i_dat_router.branch_ready[INPUT])
                    );
                end
            end
        end
    end
    router_reset_coverage i_reset_coverage (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .pending_i({(|cov_route_pending), (|cov_merge_pending), (|cov_multicast_pending),
            (|cov_output_pending), (|cov_packet_pending), (|cov_input_pending)}),
        .progress_i({(|cov_dat_progress), (|cov_rsp_progress), (|cov_req_progress)})
    );
`endif
