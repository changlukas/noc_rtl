// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module collective_control #(
    parameter string       MODE        = "MULTICAST",
    parameter int unsigned NUM_INPUTS  = 1,
    parameter int unsigned NUM_OUTPUTS = 5
) (
    input  wire logic                                                               clk_i,
    input  wire logic                                                               rst_n_i,
    input  wire logic [NUM_INPUTS-1:0][ni_flit_pkg::HEADER_WIDTH-1:0]               header_i,
    input  wire logic [NUM_INPUTS-1:0][ni_flit_pkg::B_BID_WIDTH-1:0]                bid_i,
    input  wire logic [NUM_INPUTS-1:0][ni_flit_pkg::B_BRESP_WIDTH-1:0]              bresp_i,
    input  wire logic [NUM_INPUTS-1:0]                                              s_valid_i,
    output wire logic [NUM_INPUTS-1:0]                                              s_ready_o,
    input  wire logic [NUM_OUTPUTS-1:0]                                             route_mask_i,
    input  wire logic [NUM_INPUTS-1:0][NUM_INPUTS-1:0]                              merge_mask_i,
    output wire logic [NUM_INPUTS-1:0]                                              data_select_o,
    output wire logic [NUM_OUTPUTS-1:0]                                             m_valid_o,
    input  wire logic [NUM_OUTPUTS-1:0]                                             m_ready_i
);
    import ni_flit_pkg::*;
    if (MODE == "MULTICAST") begin : gen_multicast
        logic [NUM_OUTPUTS-1:0] sent_reg = '0, sent_next;
        wire [NUM_OUTPUTS-1:0] transfer = m_valid_o & m_ready_i;
        assign m_valid_o = {NUM_OUTPUTS{s_valid_i[0]}} & route_mask_i & ~sent_reg;
        assign s_ready_o = NUM_INPUTS'((|route_mask_i) && ((sent_reg | transfer) == route_mask_i));
        assign data_select_o = '0;
        always_comb begin
            sent_next = sent_reg | transfer;
            if (s_valid_i[0] && s_ready_o[0]) sent_next = '0;
        end
        always @(posedge clk_i or negedge rst_n_i) begin
            if (~rst_n_i) begin
                sent_reg <= '0;
            end else begin
                sent_reg <= sent_next;
            end
        end
    end else if (MODE == "MERGE") begin : gen_merge
        logic [NUM_INPUTS-1:0] input_mask;
        logic [NUM_INPUTS-1:0] select_reg = '0, select_next, selected_input;
        logic complete, selected, error_selected;
        logic [NUM_INPUTS-1:0] data_select;
        always_comb begin
            data_select = '0;
            input_mask = '0;
            selected = 1'b0;
            complete = 1'b0;
            error_selected = 1'b0;
            selected_input = '0;
            for (int i = 0; i < NUM_INPUTS; i++) begin
                complete = s_valid_i[i] && merge_mask_i[i][i] && (|merge_mask_i[i]);
                for (int j = 0; j < NUM_INPUTS; j++) begin
                    if (merge_mask_i[i][j]) begin
                        complete = complete && s_valid_i[j] &&
                            header_i[j][DST_ID_LSB +: DST_ID_WIDTH] == header_i[i][DST_ID_LSB +: DST_ID_WIDTH] &&
                            header_i[j][COLLECTIVE_MASK_LSB +: COLLECTIVE_MASK_WIDTH] == header_i[i][COLLECTIVE_MASK_LSB +: COLLECTIVE_MASK_WIDTH] &&
                            (header_i[j][SRC_ID_LSB +: SRC_ID_WIDTH] & ~header_i[j][COLLECTIVE_MASK_LSB +: COLLECTIVE_MASK_WIDTH]) ==
                            (header_i[i][SRC_ID_LSB +: SRC_ID_WIDTH] & ~header_i[i][COLLECTIVE_MASK_LSB +: COLLECTIVE_MASK_WIDTH]) &&
                            header_i[j][DST_PORT_ID_LSB +: DST_PORT_ID_WIDTH] == header_i[i][DST_PORT_ID_LSB +: DST_PORT_ID_WIDTH] &&
                            header_i[j][ORDERING_REQ_LSB] == header_i[i][ORDERING_REQ_LSB] &&
                            header_i[j][ORDERING_TAG_LSB +: ORDERING_TAG_WIDTH] == header_i[i][ORDERING_TAG_LSB +: ORDERING_TAG_WIDTH] &&
                            header_i[j][AXI_CH_LSB +: AXI_CH_WIDTH] == header_i[i][AXI_CH_LSB +: AXI_CH_WIDTH] &&
                            bid_i[j] == bid_i[i];
                    end
                end
                if (complete && !selected && (!(|select_reg) || select_reg[i])) begin
                    selected_input[i] = 1'b1;
                    selected = 1'b1;
                    input_mask = merge_mask_i[i];
                    data_select[i] = 1'b1;
                    for (int j = 0; j < NUM_INPUTS; j++) begin
                        if (input_mask[j] && !error_selected &&
                                bresp_i[j] == 2'b10) begin
                            data_select = '0;
                            data_select[j] = 1'b1;
                            error_selected = 1'b1;
                        end
                    end
                end
            end
        end
        always_comb begin
            select_next = select_reg;
            if (selected) select_next = m_ready_i[0] ? '0 : selected_input;
        end
        always @(posedge clk_i or negedge rst_n_i) begin
            if (~rst_n_i) begin
                select_reg <= '0;
            end else begin
                select_reg <= select_next;
            end
        end
        assign m_valid_o = NUM_OUTPUTS'(selected);
        assign data_select_o = data_select;
        assign s_ready_o = input_mask & {NUM_INPUTS{selected && m_ready_i[0]}};
    end
    initial begin
        if ((MODE != "MULTICAST" && MODE != "MERGE") ||
                (MODE == "MULTICAST" && NUM_INPUTS != 1) ||
                (MODE == "MERGE" && NUM_OUTPUTS != 1))
            $fatal(1, "Invalid collective control mode/dimensions (instance %m)");
    end
endmodule

`resetall
