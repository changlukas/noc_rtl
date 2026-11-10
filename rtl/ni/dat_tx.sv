// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

// Share the physical DAT link without coupling write and read VC progress.
module ni_txdat #(
    parameter int unsigned NUM_DAT_VC = noc_unit_params_pkg::DAT_NUM_VC
) (
    input  wire logic                                     clk_i,
    input  wire logic                                     rst_n_i,
    input  wire noc_payload_pkg::dat_flit_t          [1:0] s_dat_i,
    input  wire logic                              [1:0] s_valid_i,
    output wire logic                              [1:0] s_ready_o,
    output wire noc_payload_pkg::dat_flit_t                m_dat_o,
    output wire logic                   [NUM_DAT_VC-1:0] m_valid_o,
    input  wire logic                   [NUM_DAT_VC-1:0] m_ready_i
);
    if (NUM_DAT_VC != 2 || NUM_DAT_VC != noc_unit_params_pkg::DAT_NUM_VC ||
            noc_unit_params_pkg::DAT_WRITE_VC != 0 || noc_unit_params_pkg::DAT_READ_VC != 1) begin : gen_invalid_vcs
        initial $fatal(0, "NI DAT TX requires write VC0 and read VC1 (instance %m)");
    end

    flit_rr_arbiter #(
        .NUM_DAT_VC  (NUM_DAT_VC),
        .DAT_VC_MASK ('1)
    ) i_flit_arbiter (
        .clk_i         (clk_i),
        .rst_n_i       (rst_n_i),
        .s_dat_i       (s_dat_i),
        .s_dat_valid_i (s_valid_i),
        .s_dat_ready_o (s_ready_o),
        .m_dat_o       (m_dat_o),
        .m_dat_valid_o (m_valid_o),
        .m_dat_ready_i (m_ready_i)
    );

    // synthesis translate_off
    for (genvar i = 0; i < 2; i++) begin : gen_checks
        input_class: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            s_valid_i[i] |-> noc_unit_params_pkg::dat_class(s_dat_i[i].header.packet_type) == i);
        eligible_transfer: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            s_valid_i[i] && m_ready_i[i] && !(s_valid_i[1-i] && m_ready_i[1-i])
            |-> s_ready_o[i]);
        tx_tail_stall: cover property (@(posedge clk_i) disable iff (!rst_n_i)
            s_valid_i[i] && s_dat_i[i].header.flit_tail && !m_ready_i[i]);
        tx_bubble: cover property (@(posedge clk_i) disable iff (!rst_n_i)
            s_valid_i[i] && s_ready_o[i] && !s_dat_i[i].header.flit_tail |=> !s_valid_i[i]);
    end
    tx_contention: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        (&s_valid_i) && (|s_ready_o));
    tx_stall: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        (|s_valid_i) && !(|s_ready_o));
    // synthesis translate_on
endmodule

`resetall
