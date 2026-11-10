// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

// Group AW/W as one packet source and arbitrate it against AR.
module nmu_request_dispatch (
    input  wire logic                                                          clk_i,
    input  wire logic                                                          rst_n_i,
    input  wire noc_payload_pkg::req_flit_t [ni_types_pkg::NUM_NMU_REQ_CH-1:0] s_req_i,
    input  wire logic                       [ni_types_pkg::NUM_NMU_REQ_CH-1:0] s_req_valid_i,
    output wire logic                       [ni_types_pkg::NUM_NMU_REQ_CH-1:0] s_req_ready_o,
    input  wire noc_payload_pkg::dat_flit_t [ni_types_pkg::NUM_NMU_DAT_CH-1:0] s_dat_i,
    input  wire logic                       [ni_types_pkg::NUM_NMU_DAT_CH-1:0] s_dat_valid_i,
    output wire logic                       [ni_types_pkg::NUM_NMU_DAT_CH-1:0] s_dat_ready_o,
    output wire noc_payload_pkg::req_flit_t                                    m_req_o,
    output wire logic                                                          m_req_valid_o,
    input  wire logic                                                          m_req_ready_i,
    output wire noc_payload_pkg::dat_flit_t                                    m_dat_o,
    output wire logic                                                          m_dat_valid_o,
    input  wire logic                                                          m_dat_ready_i
);
    import ni_types_pkg::*;

    localparam int unsigned REQ_SEL_W = NUM_NMU_REQ_CH > 1 ? $clog2(NUM_NMU_REQ_CH) : 1;

    logic req_write_lock_reg = 1'b0, req_write_lock_next;
    logic dat_write_lock_reg = 1'b0, dat_write_lock_next;
    wire [1:0] req_valid, req_last, req_select, req_grant;
    wire [REQ_SEL_W-1:0] write_sel = req_write_lock_reg ?
        REQ_SEL_W'(NMU_REQ_W_IDX) : REQ_SEL_W'(NMU_REQ_AW_IDX);
    wire [REQ_SEL_W-1:0] req_sel = req_select[0] ? write_sel : REQ_SEL_W'(NMU_REQ_AR_IDX);
    wire noc_payload_pkg::dat_flit_t dat_flit;
    wire req_transfer = m_req_valid_o && m_req_ready_i;
    wire dat_transfer = m_dat_valid_o && m_dat_ready_i;

    // The write source changes from AW to W without releasing packet ownership.
    assign req_valid = {s_req_valid_i[NMU_REQ_AR_IDX], s_req_valid_i[write_sel]};
    assign req_last  = {s_req_i[NMU_REQ_AR_IDX].header.flit_tail,
                        s_req_i[write_sel].header.flit_tail};
    packet_rr_arbiter #(
        .NUM_INPUTS (2)
    ) i_req_arbiter (
        .clk_i    (clk_i        ),
        .rst_n_i  (rst_n_i      ),
        .req_i    (req_valid    ),
        .last_i   (req_last     ),
        .select_o (req_select   ),
        .grant_o  (req_grant    ),
        .valid_o  (m_req_valid_o),
        .ready_i  (m_req_ready_i)
    );
    assign m_req_o                      = m_req_valid_o ? s_req_i[req_sel] : '0;
    assign s_req_ready_o[NMU_REQ_AW_IDX] = !req_write_lock_reg && req_grant[0];
    assign s_req_ready_o[NMU_REQ_W_IDX]  = req_write_lock_reg && req_grant[0];
    assign s_req_ready_o[NMU_REQ_AR_IDX] = req_grant[1];

    assign m_dat_valid_o = s_dat_valid_i[dat_write_lock_reg ? NMU_DAT_W_IDX : NMU_DAT_AW_IDX];
    assign s_dat_ready_o[NMU_DAT_AW_IDX] = !dat_write_lock_reg && m_dat_ready_i;
    assign s_dat_ready_o[NMU_DAT_W_IDX]  = dat_write_lock_reg && m_dat_ready_i;
    assign dat_flit = s_dat_i[dat_write_lock_reg ? NMU_DAT_W_IDX : NMU_DAT_AW_IDX];
    assign m_dat_o = m_dat_valid_o ? dat_flit : '0;

    always_comb begin
        req_write_lock_next = req_write_lock_reg;
        dat_write_lock_next = dat_write_lock_reg;
        if (req_transfer) begin
            req_write_lock_next = req_select[0] && !m_req_o.header.flit_tail;
        end
        if (dat_transfer) begin
            if (dat_write_lock_reg) begin
                if (m_dat_o.header.flit_tail) dat_write_lock_next = 1'b0;
            end else begin
                dat_write_lock_next = 1'b1;
            end
        end
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            req_write_lock_reg <= '0;
            dat_write_lock_reg <= '0;
        end else begin
            req_write_lock_reg <= req_write_lock_next;
            dat_write_lock_reg <= dat_write_lock_next;
        end
    end
endmodule
`resetall
