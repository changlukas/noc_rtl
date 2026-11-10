// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module rsp_router #(
    parameter int unsigned ROUTER_X     = 0,
    parameter int unsigned ROUTER_Y     = 0,
    parameter int unsigned MESH_X       = noc_unit_params_pkg::MESH_X_DIM,
    parameter int unsigned MESH_Y       = noc_unit_params_pkg::MESH_Y_DIM,
    parameter int unsigned FIFO_DEPTH   = 32,
    parameter int unsigned OUT_REG_TYPE = 0
) (
    input  wire logic                         clk_i,
    input  wire logic                         rst_n_i,
    input  wire noc_payload_pkg::rsp_flit_t [4:0] RXRSP,
    input  wire logic                   [4:0] RXRSPVLD,
    output wire logic                   [4:0] RXRSPRDY,
    output wire noc_payload_pkg::rsp_flit_t [4:0] TXRSP,
    output wire logic                   [4:0] TXRSPVLD,
    input  wire logic                   [4:0] TXRSPRDY
);
    wire noc_payload_pkg::rsp_flit_t [4:0] head;
    wire noc_header_pkg::header_t [4:0] header;
    wire [4:0][noc_payload_pkg::B_BID_WIDTH-1:0] bid;
    wire [4:0][noc_payload_pkg::B_BRESP_WIDTH-1:0] bresp;
    wire [4:0] full, empty, pop, last, collect_b;
    wire [4:0][4:0] route_mask, merge_mask, branch_valid, branch_ready;
    logic [4:0][4:0] route_reg = '0, route_next;
    logic [4:0] active_reg = '0, active_next;
    assign RXRSPRDY = ~full;
    for (genvar i = 0; i < 5; i++) begin : gen_input
        wire [4:0] computed_route;
        assign header[i] = head[i].header;
        assign bid[i] = head[i].payload[noc_payload_pkg::B_BID_LSB +: noc_payload_pkg::B_BID_WIDTH];
        assign bresp[i] = head[i].payload[noc_payload_pkg::B_BRESP_LSB +: noc_payload_pkg::B_BRESP_WIDTH];
        assign last[i] = head[i].header.flit_tail;
        assign collect_b[i] = head[i].header.coll_op == noc_header_pkg::COLL_MULTICAST &&
            (head[i].header.packet_type == noc_header_pkg::PKT_NARROW_B ||
             head[i].header.packet_type == noc_header_pkg::PKT_DATA_B);
        assign route_mask[i] = active_reg[i] ? route_reg[i] : computed_route;
        cc_fifo #(
            .Depth          (FIFO_DEPTH),
            .FallThrough    (1'b0),
            .data_t         (noc_payload_pkg::rsp_flit_t)
        ) i_fifo (
            .clk_i          (clk_i),
            .rst_ni         (rst_n_i),
            .clr_i          (1'b0),
            .flush_i        (1'b0),
            .full_o         (full[i]),
            .empty_o        (empty[i]),
            .usage_o        (),
            .data_i         (RXRSP[i]),
            .push_i         (RXRSPVLD[i] && RXRSPRDY[i]),
            .data_o         (head[i]),
            .pop_i          (pop[i])
        );
        route_compute #(
            .ROUTER_X       (ROUTER_X),
            .ROUTER_Y       (ROUTER_Y),
            .MESH_X         (MESH_X),
            .MESH_Y         (MESH_Y)
        ) i_route (
            .header_i       (head[i].header),
            .multicast_i    (1'b0),
            .route_mask_o   (computed_route),
            .merge_mask_o   (merge_mask[i])
        );
        assign branch_valid[i] = {5{!empty[i]}} & route_mask[i];
        assign pop[i] = |branch_ready[i];
        // synthesis translate_off
        rsp_packet_type: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            RXRSPVLD[i] |-> RXRSP[i].header.packet_type inside {
                noc_header_pkg::PKT_NARROW_B, noc_header_pkg::PKT_DATA_B,
                noc_header_pkg::PKT_NARROW_R})
            else $fatal(1, "Invalid RSP packet type (instance %m)");
        rsp_tail: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            RXRSPVLD[i] |-> RXRSP[i].header.flit_tail)
            else $fatal(1, "Each RSP flit must end its packet (instance %m)");
        // synthesis translate_on
    end
    always_comb begin
        route_next = route_reg;
        active_next = active_reg;
        for (int i = 0; i < 5; i++) begin
            if (pop[i]) begin
                active_next[i] = !last[i];
                route_next[i] = route_mask[i];
            end
        end
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            active_reg <= '0;
            route_reg <= '0;
        end else begin
            active_reg <= active_next;
            route_reg <= route_next;
        end
    end
    for (genvar o = 0; o < 5; o++) begin : gen_output
        wire [4:0] merge_valid, merge_ready;
        wire [4:0] merge_select, data_select;
        wire merged_valid;
        wire [5:0] req, select, grant;
        assign data_select = select[4:0] | ({5{select[5]}} & merge_select);
        wire [5:0] arb_last = {1'b1, last};
        collective_control #(
            .MODE           ("MERGE"),
            .NUM_INPUTS     (5),
            .NUM_OUTPUTS    (1)
        ) i_collective (
            .clk_i          (clk_i),
            .rst_n_i        (rst_n_i),
            .header_i       (header),
            .bid_i          (bid),
            .bresp_i        (bresp),
            .s_valid_i      (merge_valid),
            .s_ready_o      (merge_ready),
            .route_mask_i   (1'b1),
            .merge_mask_i   (merge_mask),
            .data_select_o  (merge_select),
            .m_valid_o      (merged_valid),
            .m_ready_i      (grant[5])
        );
        assign req[5] = merged_valid;
        for (genvar i = 0; i < 5; i++) begin : gen_request
            assign merge_valid[i] = branch_valid[i][o] && collect_b[i];
            assign req[i] = branch_valid[i][o] && !collect_b[i];
            assign branch_ready[i][o] = grant[i] || merge_ready[i];
        end
        wire selected_valid, selected_ready;
        wire noc_payload_pkg::rsp_flit_t selected_data;
        switch_allocator #(
            .NUM_INPUTS     (6)
        ) i_switch_allocator (
            .clk_i          (clk_i),
            .rst_n_i        (rst_n_i),
            .req_i          (req),
            .last_i         (arb_last),
            .select_o       (select),
            .grant_o        (grant),
            .valid_o        (selected_valid),
            .ready_i        (selected_ready)
        );
        crossbar #(
            .NUM_INPUTS     (5),
            .NUM_OUTPUTS    (1),
            .flit_t         (noc_payload_pkg::rsp_flit_t)
        ) i_crossbar (
            .data_i         (head),
            .select_i       (data_select),
            .data_o         (selected_data)
        );
        stream_register #(
            .REG_TYPE       (OUT_REG_TYPE),
            .data_t         (noc_payload_pkg::rsp_flit_t)
        ) i_output (
            .clk_i          (clk_i),
            .rst_n_i        (rst_n_i),
            .s_valid_i      (selected_valid),
            .s_ready_o      (selected_ready),
            .s_data_i       (selected_data),
            .m_valid_o      (TXRSPVLD[o]),
            .m_ready_i      (TXRSPRDY[o]),
            .m_data_o       (TXRSP[o])
        );
        // synthesis translate_off
        // CollectB forwards one complete response, including its opaque USER.
        for (genvar i = 0; i < 5; i++) begin : gen_checks
            // VCS M-2017 samples the scalar comparison reliably for packed structs.
            wire flit_match = selected_data == head[i];
            selected_flit: assert property (@(posedge clk_i) disable iff (!rst_n_i)
                selected_valid && data_select[i] |-> flit_match)
                else $fatal(1, "Selected response flit mismatch: select=%b data_select=%b data=%h head=%h unknown=%b/%b (instance %m)",
                    $sampled(select), $sampled(data_select), $sampled(selected_data), $sampled(head[i]),
                    $isunknown($sampled(selected_data)), $isunknown($sampled(head[i])));
        end
        merge_held: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            merged_valid && !grant[5] |-> !(|merge_ready))
            else $fatal(1, "Merged response popped before acceptance (instance %m)");
`ifdef NI_COVERAGE
        merged_transfer: cover property (@(posedge clk_i) disable iff (!rst_n_i)
            merged_valid && grant[5]);
        merge_wait: cover property (@(posedge clk_i) disable iff (!rst_n_i)
            (|merge_valid) && !merged_valid ##[1:256] merged_valid && grant[5]);
        merge_stall: cover property (@(posedge clk_i) disable iff (!rst_n_i)
            merged_valid && !grant[5] ##[1:256] merged_valid && grant[5]);
        route_transfer: cover property (@(posedge clk_i) disable iff (!rst_n_i)
            TXRSPVLD[o] && TXRSPRDY[o]);
`endif
        // synthesis translate_on
    end
    initial begin
        if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH-1)) != 0)
            $fatal(1, "Router FIFO depth must be a power of two >= 2 (instance %m)");
    end
endmodule

`resetall
