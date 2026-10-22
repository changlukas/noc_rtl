// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module ni_dat_tx #(
    parameter int unsigned NUM_DAT_VC   = ni_params_pkg::NUM_DAT_VC,
    parameter int unsigned CREDIT_DEPTH = ni_params_pkg::CREDIT_DEPTH
) (
    input  wire logic                                         clk_i,
    input  wire logic                                         rst_n_i,
    input  wire ni_flit_pkg::dat_flit_t [1:0][NUM_DAT_VC-1:0] s_dat_i,
    input  wire logic                   [1:0][NUM_DAT_VC-1:0] s_valid_i,
    output wire logic                   [1:0][NUM_DAT_VC-1:0] s_ready_o,
    output wire ni_flit_pkg::dat_flit_t                       m_dat_o,
    output wire logic                        [NUM_DAT_VC-1:0] m_valid_o,
    input  wire logic                        [NUM_DAT_VC-1:0] m_ready_i,
    input  wire logic                        [NUM_DAT_VC-1:0] credit_i
);
    import ni_flit_pkg::*;
    wire dat_flit_t [NUM_DAT_VC-1:0] vc_data;
    wire [NUM_DAT_VC-1:0] vc_valid, vc_ready, credit_left;
    for (genvar vc = 0; vc < NUM_DAT_VC; vc++) begin : gen_vc
        logic lock_reg = 1'b0, lock_next;
        logic select_reg = 1'b0, select_next;
        wire [1:0] req, grant;
        wire selected, valid;
        wire dat_flit_t [1:0] data = {s_dat_i[1][vc], s_dat_i[0][vc]};
        wire transfer = m_valid_o[vc] && m_ready_i[vc];
        assign req = {s_valid_i[1][vc], s_valid_i[0][vc]} &
            (lock_reg ? (2'b01 << select_reg) : 2'b11);
        assign vc_valid[vc] = valid && (credit_left[vc] || credit_i[vc]);
        assign s_ready_o[0][vc] = grant[0] && req[0];
        assign s_ready_o[1][vc] = grant[1] && req[1];
        rr_arb_tree #(
            .NumIn     (2         ),
            .DataType  (dat_flit_t),
            .AxiVldRdy (1'b1      ),
            .LockIn    (1'b1      ),
            .FairArb   (1'b1      )
        ) i_packet_arbiter (
            .clk_i   (clk_i      ),
            .rst_ni  (rst_n_i    ),
            .flush_i (1'b0       ),
            .rr_i    ('0         ),
            .req_i   (req        ),
            .gnt_o   (grant      ),
            .data_i  (data       ),
            .req_o   (valid      ),
            .gnt_i   (transfer   ),
            .data_o  (vc_data[vc]),
            .idx_o   (selected   )
        );
        always_comb begin
            lock_next = lock_reg;
            select_next = select_reg;
            if (transfer) begin
                lock_next = !vc_data[vc].header[FLIT_TAIL_LSB];
                select_next = selected;
            end
        end
        always @(posedge clk_i or negedge rst_n_i) begin
            if (~rst_n_i) begin
                lock_reg <= 1'b0;
                select_reg <= 1'b0;
            end else begin
                lock_reg <= lock_next;
                select_reg <= select_next;
            end
        end
        cc_credit_counter #(
            .NumCredits (CREDIT_DEPTH)
        ) i_credit (
            .clk_i         (clk_i          ),
            .rst_ni        (rst_n_i        ),
            .clr_i         (1'b0           ),
            .credit_o      (               ),
            .credit_give_i (credit_i[vc]   ),
            .credit_take_i (transfer       ),
            .credit_left_o (credit_left[vc]),
            .credit_crit_o (               ),
            .credit_full_o (               )
        );
    end
    tx_vc_arbiter #(
        .NUM_DAT_VC  (NUM_DAT_VC),
        .DAT_VC_MASK ('1        )
    ) i_link_arbiter (
        .clk_i         (clk_i    ),
        .rst_n_i       (rst_n_i  ),
        .s_dat_i       (vc_data  ),
        .s_dat_valid_i (vc_valid ),
        .s_dat_ready_o (vc_ready ),
        .m_dat_o       (m_dat_o  ),
        .m_dat_valid_o (m_valid_o),
        .m_dat_ready_i (m_ready_i)
    );
endmodule
`resetall
