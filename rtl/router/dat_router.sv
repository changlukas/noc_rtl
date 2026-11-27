// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module dat_router #(
    parameter int unsigned ROUTER_X        = 0,
    parameter int unsigned ROUTER_Y        = 0,
    parameter int unsigned MESH_X          = noc_unit_params_pkg::MESH_X_DIM,
    parameter int unsigned MESH_Y          = noc_unit_params_pkg::MESH_Y_DIM,
    parameter int unsigned NUM_VC          = noc_unit_params_pkg::DAT_NUM_VC,
    parameter int unsigned FIFO_DEPTH      = noc_unit_params_pkg::DAT_RX_FIFO_DEPTH,
    parameter int unsigned OUT_FIFO_DEPTH  = noc_unit_params_pkg::ROUTER_OUTPUT_FIFO_DEPTH
) (
    input  wire logic                                     clk_i,
    input  wire logic                                     rst_n_i,
    input  wire noc_payload_pkg::dat_flit_t             [4:0] RXDAT,
    input  wire logic                   [4:0][NUM_VC-1:0] RXDATVLD,
    output wire logic                   [4:0][NUM_VC-1:0] RXDATRDY,
    output wire noc_payload_pkg::dat_flit_t             [4:0] TXDAT,
    output wire logic                   [4:0][NUM_VC-1:0] TXDATVLD,
    input  wire logic                   [4:0][NUM_VC-1:0] TXDATRDY
);
    localparam int unsigned NUM_INPUTS = 5*NUM_VC;
    typedef struct packed {
        noc_payload_pkg::dat_flit_t flit;
        logic [4:0] route_mask;
    } route_data_t;
    wire noc_payload_pkg::dat_flit_t [NUM_INPUTS-1:0] head, fifo_head;
    wire [NUM_INPUTS-1:0] fifo_pop, route_ready, head_valid;
    wire [NUM_INPUTS-1:0] full, empty, pop, last, output_last;
    wire [NUM_INPUTS-1:0][4:0] route_mask, input_route, branch_valid, branch_ready;
    logic [NUM_INPUTS-1:0][4:0] route_reg = '0, route_next;
    logic [NUM_INPUTS-1:0] active_reg = '0, active_next;
    for (genvar i = 0; i < NUM_INPUTS; i++) begin : gen_input
        localparam int PORT = i/NUM_VC;
        localparam int VC = i%NUM_VC;
        wire [4:0] computed_route;
        wire multicast = fifo_head[i].header.coll_op == noc_header_pkg::COLL_MULTICAST;
        assign RXDATRDY[PORT][VC] = !full[i];
        assign last[i]                    = fifo_head[i].header.flit_tail;
        assign output_last[i] = head[i].header.flit_tail;
        assign input_route[i] = active_reg[i] ? route_reg[i] : computed_route;
        wire route_data_t route_in = '{flit: fifo_head[i], route_mask: input_route[i]};
        wire route_data_t route_out;
        assign route_mask[i] = route_out.route_mask;
        assign head[i] = route_out.flit;
        assign fifo_pop[i] = !empty[i] && route_ready[i];
        stream_register #(
            .REG_TYPE       (2),
            .data_t         (route_data_t)
        ) i_route_register (
            .clk_i          (clk_i),
            .rst_n_i        (rst_n_i),
            .s_valid_i      (!empty[i]),
            .s_ready_o      (route_ready[i]),
            .s_data_i       (route_in),
            .m_valid_o      (head_valid[i]),
            .m_ready_i      (pop[i]),
            .m_data_o       (route_out)
        );
        cc_fifo #(
            .Depth          (FIFO_DEPTH),
            .FallThrough    (1'b0),
            .data_t         (noc_payload_pkg::dat_flit_t)
        ) i_fifo (
            .clk_i          (clk_i),
            .rst_ni         (rst_n_i),
            .clr_i          (1'b0),
            .flush_i        (1'b0),
            .full_o         (full[i]),
            .empty_o        (empty[i]),
            .usage_o        (),
            .data_i         (RXDAT[PORT]),
            .push_i         (RXDATVLD[PORT][VC] && RXDATRDY[PORT][VC]),
            .data_o         (fifo_head[i]),
            .pop_i          (fifo_pop[i])
        );
        route_compute #(
            .ROUTER_X       (ROUTER_X),
            .ROUTER_Y       (ROUTER_Y),
            .MESH_X         (MESH_X),
            .MESH_Y         (MESH_Y)
        ) i_route (
            .header_i       (fifo_head[i].header),
            .multicast_i    (multicast),
            .route_mask_o   (computed_route),
            .merge_mask_o   ()
        );
        // synthesis translate_off
        input_class: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            RXDATVLD[PORT][VC] |-> noc_unit_params_pkg::dat_class(RXDAT[PORT].header.packet_type) == VC);
        multicast_partial: cover property (@(posedge clk_i) disable iff (!rst_n_i)
            head_valid[i] && (|branch_valid[i]) && (|(branch_valid[i] & branch_ready[i])) && !pop[i]);
        packet_bubble: cover property (@(posedge clk_i) disable iff (!rst_n_i)
            active_reg[i] && empty[i]);
        // synthesis translate_on
        collective_control #(
            .MODE           ("MULTICAST"),
            .NUM_INPUTS     (1),
            .NUM_OUTPUTS    (5)
        ) i_collective (
            .clk_i          (clk_i),
            .rst_n_i        (rst_n_i),
            .header_i       ('0),
            .bid_i          ('0),
            .bresp_i        ('0),
            .s_valid_i      (head_valid[i]),
            .s_ready_o      (pop[i]),
            .route_mask_i   (route_mask[i]),
            .merge_mask_i   ('0),
            .data_select_o  (),
            .m_valid_o      (branch_valid[i]),
            .m_ready_i      (branch_ready[i])
        );
    end
    always_comb begin
        route_next = route_reg;
        active_next = active_reg;
        for (int i = 0; i < NUM_INPUTS; i++) begin
            if (fifo_pop[i]) begin
                active_next[i] = !last[i];
                route_next[i] = input_route[i];
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
        wire [NUM_VC-1:0] out_full, out_empty, out_pop;
        wire noc_payload_pkg::dat_flit_t [NUM_VC-1:0] output_head;
        for (genvar v = 0; v < NUM_VC; v++) begin : gen_vc
            wire [4:0] req, last, select, grant;
            wire selected_valid;
            wire noc_payload_pkg::dat_flit_t [4:0] data;
            wire noc_payload_pkg::dat_flit_t selected_data;
            for (genvar i = 0; i < 5; i++) begin : gen_request
                // Each class can reach only the same class at this output.
                assign data[i]                    = head[i*NUM_VC+v];
                assign req[i]                     = branch_valid[i*NUM_VC+v][o];
                assign last[i]                    = output_last[i*NUM_VC+v];
                assign branch_ready[i*NUM_VC+v][o] = grant[i];
            end
            switch_allocator #(
                .NUM_INPUTS (5)
            ) i_switch_allocator (
                .clk_i    (clk_i),
                .rst_n_i  (rst_n_i),
                .req_i    (req),
                .last_i   (last),
                .select_o (select),
                .grant_o  (grant),
                .valid_o  (selected_valid),
                .ready_i  (!out_full[v])
            );
            crossbar #(
                .NUM_INPUTS  (5),
                .NUM_OUTPUTS (1),
                .flit_t      (noc_payload_pkg::dat_flit_t)
            ) i_crossbar (
                .data_i   (data),
                .select_i (select),
                .data_o   (selected_data)
            );
            cc_fifo #(
                .Depth       (OUT_FIFO_DEPTH),
                .FallThrough (1'b0),
                .data_t      (noc_payload_pkg::dat_flit_t)
            ) i_fifo (
                .clk_i   (clk_i),
                .rst_ni  (rst_n_i),
                .clr_i   (1'b0),
                .flush_i (1'b0),
                .full_o  (out_full[v]),
                .empty_o (out_empty[v]),
                .usage_o (),
                .data_i  (selected_data),
                .push_i  (selected_valid && !out_full[v]),
                .data_o  (output_head[v]),
                .pop_i   (out_pop[v])
            );
            // synthesis translate_off
            output_class: assert property (@(posedge clk_i) disable iff (!rst_n_i)
                selected_valid |-> noc_unit_params_pkg::dat_class(selected_data.header.packet_type) == v);
            contention: cover property (@(posedge clk_i) disable iff (!rst_n_i)
                $countones(req) > 1 && selected_valid && !out_full[v]);
            fifo_backpressure: cover property (@(posedge clk_i) disable iff (!rst_n_i)
                selected_valid && out_full[v]);
            tail_stall: cover property (@(posedge clk_i) disable iff (!rst_n_i)
                selected_valid && selected_data.header.flit_tail && out_full[v]);
            class_progress: cover property (@(posedge clk_i) disable iff (!rst_n_i)
                !out_empty[1-v] && !TXDATRDY[o][1-v] && out_pop[v]);
            route_transfer: cover property (@(posedge clk_i) disable iff (!rst_n_i)
                out_pop[v]);
            // synthesis translate_on
        end
        flit_rr_arbiter #(
            .NUM_DAT_VC  (NUM_VC),
            .DAT_VC_MASK ('1)
        ) i_flit_arbiter (
            .clk_i         (clk_i),
            .rst_n_i       (rst_n_i),
            .s_dat_i       (output_head),
            .s_dat_valid_i (~out_empty),
            .s_dat_ready_o (out_pop),
            .m_dat_o       (TXDAT[o]),
            .m_dat_valid_o (TXDATVLD[o]),
            .m_dat_ready_i (TXDATRDY[o])
        );
    end
    initial begin
        if (NUM_VC != 2 || NUM_VC != noc_unit_params_pkg::DAT_NUM_VC ||
                noc_unit_params_pkg::DAT_WRITE_VC != 0 || noc_unit_params_pkg::DAT_READ_VC != 1)
            $fatal(1, "DAT router requires write VC0 and read VC1 (instance %m)");
        if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH-1)) != 0 ||
                OUT_FIFO_DEPTH < 1 || (OUT_FIFO_DEPTH & (OUT_FIFO_DEPTH-1)) != 0)
            $fatal(1, "Invalid router FIFO depth (instance %m)");
    end
endmodule
`resetall
