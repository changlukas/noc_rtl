// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module vc_arbiter #(
    parameter int unsigned NUM_VC       = ni_params_pkg::NUM_DAT_VC,
    parameter int unsigned CREDIT_DEPTH = ni_params_pkg::CREDIT_DEPTH
) (
    input  wire logic                                clk_i,
    input  wire logic                                rst_n_i,
    input  wire ni_flit_pkg::dat_flit_t [NUM_VC-1:0] s_data_i,
    input  wire logic                   [NUM_VC-1:0] s_valid_i,
    output wire logic                   [NUM_VC-1:0] s_ready_o,
    output wire ni_flit_pkg::dat_flit_t              m_data_o,
    output wire logic                   [NUM_VC-1:0] m_valid_o,
    input  wire logic                   [NUM_VC-1:0] m_ready_i,
    input  wire logic                   [NUM_VC-1:0] credit_i,
    output wire logic                   [NUM_VC-1:0] credit_available_o
);
    wire [NUM_VC-1:0] credit_left;
    wire [NUM_VC-1:0] selected_ready;
    assign s_ready_o = selected_ready & s_valid_i & credit_available_o;
    wire [NUM_VC-1:0] transfer = m_valid_o & m_ready_i;
    assign credit_available_o = credit_left | credit_i;
    tx_vc_arbiter #(
        .NUM_DAT_VC  (NUM_VC),
        .DAT_VC_MASK ('1)
    ) i_arb (
        .clk_i         (clk_i),
        .rst_n_i       (rst_n_i),
        .s_dat_i       (s_data_i),
        .s_dat_valid_i (s_valid_i & credit_available_o),
        .s_dat_ready_o (selected_ready),
        .m_dat_o       (m_data_o),
        .m_dat_valid_o (m_valid_o),
        .m_dat_ready_i (m_ready_i)
    );
    for (genvar v = 0; v < NUM_VC; v++) begin : gen_credit
        cc_credit_counter #(
            .NumCredits (CREDIT_DEPTH)
        ) i_credit (
            .clk_i         (clk_i),
            .rst_ni        (rst_n_i),
            .clr_i         (1'b0),
            .credit_o      (),
            .credit_give_i (credit_i[v]),
            .credit_take_i (transfer[v]),
            .credit_left_o (credit_left[v]),
            .credit_crit_o (),
            .credit_full_o ()
        );
    end
    // synthesis translate_off
    for (genvar v = 0; v < NUM_VC; v++) begin : gen_fairness
        int unsigned wait_count;
        always @(posedge clk_i or negedge rst_n_i) begin
            if (~rst_n_i) begin
                wait_count <= 0;
            end else if (!s_valid_i[v] || !credit_available_o[v] || transfer[v]) begin
                wait_count <= 0;
            end else if (|transfer) begin
                if (wait_count >= NUM_VC-1)
                    $fatal(1, "Eligible VC skipped by output RR (instance %m)");
                wait_count <= wait_count + 1;
            end
        end
    end
    // synthesis translate_on
endmodule
`resetall
