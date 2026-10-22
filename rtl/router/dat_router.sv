// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module dat_router #(
    parameter int unsigned ROUTER_X        = 0,
    parameter int unsigned ROUTER_Y        = 0,
    parameter int unsigned MESH_X          = ni_params_pkg::NOC_MESH_X_DIM,
    parameter int unsigned MESH_Y          = ni_params_pkg::NOC_MESH_Y_DIM,
    parameter int unsigned NUM_VC          = ni_params_pkg::NUM_DAT_VC,
    localparam int unsigned VC_MODE         = (NUM_VC > 1),
    parameter int unsigned CREDIT_DEPTH    = ni_params_pkg::CREDIT_DEPTH,
    parameter int unsigned OUT_FIFO_DEPTH  = ni_params_pkg::NOC_ROUTER_OUTPUT_FIFO_DEPTH
) (
    input  wire logic                                     clk_i,
    input  wire logic                                     rst_n_i,
    input  wire ni_flit_pkg::dat_flit_t             [4:0] s_flit_i,
    input  wire logic                   [4:0][NUM_VC-1:0] s_valid_i,
    output wire logic                   [4:0][NUM_VC-1:0] s_ready_o,
    output wire logic                   [4:0][NUM_VC-1:0] credit_o,
    output wire ni_flit_pkg::dat_flit_t             [4:0] m_flit_o,
    output wire logic                   [4:0][NUM_VC-1:0] m_valid_o,
    input  wire logic                   [4:0][NUM_VC-1:0] m_ready_i,
    input  wire logic                   [4:0][NUM_VC-1:0] credit_i
);
    import ni_flit_pkg::*;
    localparam int unsigned NUM_INPUTS = 5*NUM_VC;
    typedef struct packed {
        dat_flit_t flit;
        logic [4:0] route_mask;
    } route_data_t;
    wire dat_flit_t [NUM_INPUTS-1:0] head, fifo_head;
    wire [NUM_INPUTS-1:0] fifo_pop, route_ready, head_valid;
    wire [NUM_INPUTS-1:0] full, empty, pop, last, output_last;
    wire [NUM_INPUTS-1:0][4:0] route_mask, input_route, branch_valid, branch_ready;
    logic [NUM_INPUTS-1:0][4:0] route_reg = '0, route_next;
    logic [NUM_INPUTS-1:0] active_reg = '0, active_next;
    logic [4:0][NUM_VC-1:0] credit_reg = '0;
    assign credit_o = credit_reg;
    for (genvar i = 0; i < NUM_INPUTS; i++) begin : gen_input
        localparam int PORT = i/NUM_VC;
        localparam int VC = i%NUM_VC;
        wire [4:0] computed_route;
        wire multicast = fifo_head[i].header[COLLECTIVE_OP_LSB +: COLLECTIVE_OP_WIDTH] == COLLECTIVE_OP_WIDTH'(COLLECTIVE_OP_MULTICAST);
        assign s_ready_o[PORT][VC] = !full[i];
        assign last[i] = fifo_head[i].header[FLIT_TAIL_LSB];
        assign output_last[i] = head[i].header[FLIT_TAIL_LSB];
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
            .Depth          (CREDIT_DEPTH),
            .FallThrough    (1'b0),
            .data_t         (dat_flit_t)
        ) i_fifo (
            .clk_i          (clk_i),
            .rst_ni         (rst_n_i),
            .clr_i          (1'b0),
            .flush_i        (1'b0),
            .full_o         (full[i]),
            .empty_o        (empty[i]),
            .usage_o        (),
            .data_i         (s_flit_i[PORT]),
            .push_i         (s_valid_i[PORT][VC] && s_ready_o[PORT][VC]),
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
            credit_reg <= '0;
        end else begin
            active_reg <= active_next;
            route_reg <= route_next;
            credit_reg <= fifo_pop;
        end
    end
    for (genvar o = 0; o < 5; o++) begin : gen_output
        wire [NUM_INPUTS-1:0] req;
        wire [NUM_VC-1:0][NUM_INPUTS-1:0] allocation, select, grant;
        wire [NUM_VC-1:0] release_vc, credit_available;
        wire [NUM_VC-1:0] out_full, out_empty, out_pop;
        wire dat_flit_t [NUM_VC-1:0] selected_data, output_head;
        for (genvar i = 0; i < NUM_INPUTS; i++) begin : gen_request
            logic accepted;
            assign req[i] = branch_valid[i][o];
            always_comb begin
                accepted = 1'b0;
                for (int v = 0; v < NUM_VC; v++) accepted |= grant[v][i];
            end
            assign branch_ready[i][o] = accepted;
        end
        vc_allocator #(
            .NUM_VC         (NUM_VC),
            .NUM_INPUTS     (NUM_INPUTS),
            .ROUTER_X       (ROUTER_X),
            .ROUTER_Y       (ROUTER_Y),
            .OUTPUT_PORT    (o)
        ) i_vc_allocator (
            .clk_i          (clk_i),
            .rst_n_i        (rst_n_i),
            .data_i         (head),
            .req_i          (req),
            .credit_available_i (credit_available),
            .release_i      (release_vc),
            .select_o       (allocation)
        );
        crossbar #(
            .NUM_INPUTS     (NUM_INPUTS),
            .NUM_OUTPUTS    (NUM_VC),
            .flit_t         (dat_flit_t)
        ) i_crossbar (
            .data_i         (head),
            .select_i       (select),
            .data_o         (selected_data)
        );
        for (genvar v = 0; v < NUM_VC; v++) begin : gen_vc
            wire selected_valid;
            dat_flit_t output_data;
            always_comb begin
                output_data = selected_data[v];
                output_data.header[VC_ID_LSB +: VC_ID_WIDTH] = VC_ID_WIDTH'(v);
            end
            assign release_vc[v] = selected_valid && !out_full[v] && selected_data[v].header[FLIT_TAIL_LSB];
            switch_allocator #(
                .NUM_INPUTS     (NUM_INPUTS)
            ) i_switch_allocator (
                .clk_i          (clk_i),
                .rst_n_i        (rst_n_i),
                .req_i          (req & allocation[v]),
                .last_i         (output_last),
                .select_o       (select[v]),
                .grant_o        (grant[v]),
                .valid_o        (selected_valid),
                .ready_i        (!out_full[v])
            );
            cc_fifo #(
                .Depth          (OUT_FIFO_DEPTH),
                .FallThrough    (1'b0),
                .data_t         (dat_flit_t)
            ) i_fifo (
                .clk_i          (clk_i),
                .rst_ni         (rst_n_i),
                .clr_i          (1'b0),
                .flush_i        (1'b0),
                .full_o         (out_full[v]),
                .empty_o        (out_empty[v]),
                .usage_o        (),
                .data_i         (output_data),
                .push_i         (selected_valid && !out_full[v]),
                .data_o         (output_head[v]),
                .pop_i          (out_pop[v])
            );
        end
        vc_arbiter #(
            .NUM_VC         (NUM_VC),
            .CREDIT_DEPTH   (CREDIT_DEPTH)
        ) i_vc_arbiter (
            .clk_i          (clk_i),
            .rst_n_i        (rst_n_i),
            .s_data_i       (output_head),
            .s_valid_i      (~out_empty),
            .s_ready_o      (out_pop),
            .m_data_o       (m_flit_o[o]),
            .m_valid_o      (m_valid_o[o]),
            .m_ready_i      (m_ready_i[o]),
            .credit_i       (credit_i[o]),
            .credit_available_o (credit_available)
        );
    end
    initial begin
        if (NUM_VC < 1 || NUM_VC > (1 << VC_ID_WIDTH) || VC_MODE > 1 ||
                (VC_MODE == 1 && (NUM_VC < 2 || NUM_VC%2 != 0)))
            $fatal(1, "Invalid router VC configuration (instance %m)");
        if (CREDIT_DEPTH < 2 || (CREDIT_DEPTH & (CREDIT_DEPTH-1)) != 0 ||
                OUT_FIFO_DEPTH < 1 || (OUT_FIFO_DEPTH & (OUT_FIFO_DEPTH-1)) != 0)
            $fatal(1, "Invalid router FIFO depth (instance %m)");
    end
endmodule
`resetall
