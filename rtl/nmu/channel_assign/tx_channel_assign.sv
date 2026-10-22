// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

// Network injection: packet locks, VC ownership and local FIFO admission.
module tx_channel_assign #(
    parameter int unsigned NUM_DAT_VC  = ni_params_pkg::NUM_DAT_VC,
    localparam int unsigned DAT_VC_MODE = (NUM_DAT_VC > 1)
) (
    input  wire logic                                                      clk_i,
    input  wire logic                                                      rst_n_i,
    input  wire ni_flit_pkg::req_flit_t [ni_types_pkg::NUM_NMU_REQ_CH-1:0] s_req_i,
    input  wire logic                   [ni_types_pkg::NUM_NMU_REQ_CH-1:0] s_req_valid_i,
    output wire logic                   [ni_types_pkg::NUM_NMU_REQ_CH-1:0] s_req_ready_o,
    input  wire ni_flit_pkg::dat_flit_t [ni_types_pkg::NUM_NMU_DAT_CH-1:0] s_dat_i,
    input  wire logic                   [ni_types_pkg::NUM_NMU_DAT_CH-1:0] s_dat_valid_i,
    output wire logic                   [ni_types_pkg::NUM_NMU_DAT_CH-1:0] s_dat_ready_o,
    output wire ni_flit_pkg::req_flit_t                                    m_req_o,
    output wire logic                                                      m_req_valid_o,
    input  wire logic                                                      m_req_ready_i,
    output wire ni_flit_pkg::dat_flit_t                                    m_dat_o,
    output wire logic                                                      m_dat_valid_o,
    input  wire logic                                     [NUM_DAT_VC-1:0] dat_ready_i
);
    import ni_types_pkg::*;

    import ni_flit_pkg::*;
    localparam int unsigned NUM_WR_VC = NUM_DAT_VC > 1 ? NUM_DAT_VC/2 : 1;
    localparam int unsigned VC_IDX_W  = NUM_DAT_VC > 1 ? $clog2(NUM_DAT_VC) : 1;
    localparam int REQ_SEL_W = NUM_NMU_REQ_CH > 1 ? $clog2(NUM_NMU_REQ_CH) : 1;
    if (NUM_DAT_VC < 1 || NUM_DAT_VC > (1 << ni_flit_pkg::VC_ID_WIDTH)) begin : gen_invalid_vc_count
        initial $fatal(0, "Error: NUM_DAT_VC is outside the encoded VC range (instance %m)");
    end
    if (DAT_VC_MODE > 1 ||
        (DAT_VC_MODE == 1 &&
         (NUM_DAT_VC < 2 || NUM_DAT_VC[0]))) begin : gen_invalid_vc_mode
        initial $fatal(0, "Error: split DAT VC mode requires a positive even NUM_DAT_VC (instance %m)");
    end
    logic                    req_write_lock_reg, req_write_lock_next;
    logic                    dat_write_lock_reg, dat_write_lock_next;
    logic                    req_rr_reg, req_rr_next;
    logic                    req_hold_reg, req_hold_next, req_hold_aw_reg, req_hold_aw_next;
    logic [VC_IDX_W-1:0] dat_vc_reg, dat_vc_next;
    wire  [VC_IDX_W-1:0] dat_aw_vc, dat_vc;
    wire ni_flit_pkg::dat_flit_t dat_aw = s_dat_i[NMU_DAT_AW_IDX];
    wire [31:0] dat_flow_hash =
        32'(dat_aw.header[SRC_ID_LSB +: X_WIDTH]) ^
        32'(dat_aw.header[SRC_ID_LSB+X_WIDTH +: Y_WIDTH]) ^
        32'(dat_aw.header[SRC_PORT_ID_LSB +: SRC_PORT_ID_WIDTH]) ^
        32'(dat_aw.header[DST_ID_LSB +: X_WIDTH]) ^
        32'(dat_aw.header[DST_ID_LSB+X_WIDTH +: Y_WIDTH]) ^
        32'(dat_aw.header[DST_PORT_ID_LSB +: DST_PORT_ID_WIDTH]) ^
        32'(dat_aw.payload[AW_AWID_LSB +: AW_AWID_WIDTH]);
    assign dat_aw_vc = VC_IDX_W'(dat_flow_hash % NUM_WR_VC);
    assign dat_vc    = dat_write_lock_reg ? dat_vc_reg : dat_aw_vc;
    logic                                   req_sel_aw, dat_vc_available;
    logic                   [REQ_SEL_W-1:0] req_sel;
    ni_flit_pkg::dat_flit_t                 dat_flit;
    wire req_transfer = m_req_valid_o && m_req_ready_i;
    wire dat_transfer = m_dat_valid_o;

    always_comb begin
        req_sel_aw = 1'b0;
        if (req_hold_reg) req_sel_aw = req_hold_aw_reg;
        else if (!req_write_lock_reg)
            req_sel_aw = s_req_valid_i[NMU_REQ_AW_IDX] && (!s_req_valid_i[NMU_REQ_AR_IDX] || !req_rr_reg);
        req_sel = req_write_lock_reg ? REQ_SEL_W'(NMU_REQ_W_IDX) : req_sel_aw ? REQ_SEL_W'(NMU_REQ_AW_IDX) : REQ_SEL_W'(NMU_REQ_AR_IDX);
    end
    assign m_req_valid_o                 = s_req_valid_i[req_sel];
    assign m_req_o                       = m_req_valid_o ? s_req_i[req_sel] : '0;
    assign s_req_ready_o[NMU_REQ_AW_IDX] = !req_write_lock_reg && req_sel_aw && m_req_ready_i;
    assign s_req_ready_o[NMU_REQ_W_IDX]  = req_write_lock_reg && m_req_ready_i;
    assign s_req_ready_o[NMU_REQ_AR_IDX] = !req_write_lock_reg && !req_sel_aw && m_req_ready_i;

    assign dat_vc_available = dat_ready_i[dat_vc];
    assign m_dat_valid_o = (dat_write_lock_reg ?
        (s_dat_valid_i[NMU_DAT_W_IDX] && (dat_ready_i[dat_vc])) :
        (s_dat_valid_i[NMU_DAT_AW_IDX] && dat_vc_available));
    assign s_dat_ready_o[NMU_DAT_AW_IDX] = !dat_write_lock_reg && dat_vc_available;
    assign s_dat_ready_o[NMU_DAT_W_IDX]  = dat_write_lock_reg && dat_ready_i[dat_vc];
    always_comb begin
        dat_flit = s_dat_i[dat_write_lock_reg ? NMU_DAT_W_IDX : NMU_DAT_AW_IDX];
        dat_flit.header[VC_ID_LSB +: VC_ID_WIDTH] = VC_ID_WIDTH'(dat_vc);
    end
    assign m_dat_o = m_dat_valid_o ? dat_flit : '0;

    always_comb begin
        req_write_lock_next = req_write_lock_reg;
        dat_write_lock_next = dat_write_lock_reg;
        dat_vc_next         = dat_vc_reg;
        req_rr_next         = req_rr_reg;
        req_hold_next       = m_req_valid_o && !m_req_ready_i && !req_write_lock_reg;
        req_hold_aw_next    = req_hold_aw_reg;
        if (req_hold_next && !req_hold_reg) req_hold_aw_next = req_sel_aw;
        if (req_transfer) begin
            if (req_write_lock_reg) begin
                if (m_req_o.header[FLIT_TAIL_LSB]) req_write_lock_next = 1'b0;
            end else if (req_sel_aw) begin
                req_write_lock_next = 1'b1;
                req_rr_next         = 1'b1;
            end else req_rr_next = 1'b0;
        end
        if (dat_transfer) begin
            if (dat_write_lock_reg) begin
                if (m_dat_o.header[FLIT_TAIL_LSB]) dat_write_lock_next = 1'b0;
            end else begin
                dat_write_lock_next = 1'b1;
                dat_vc_next         = dat_aw_vc;
            end
        end
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            req_write_lock_reg <= '0;
            dat_write_lock_reg <= '0;
            dat_vc_reg         <= '0;
            req_rr_reg         <= '0;
            req_hold_reg       <= '0;
            req_hold_aw_reg    <= '0;
        end else begin
            req_write_lock_reg <= req_write_lock_next;
            dat_write_lock_reg <= dat_write_lock_next;
            dat_vc_reg         <= dat_vc_next;
            req_rr_reg         <= req_rr_next;
            req_hold_reg       <= req_hold_next;
            req_hold_aw_reg    <= req_hold_aw_next;
        end
    end
endmodule
`resetall
