// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module nsu_context_buffer #(
    parameter int unsigned OUTPUT_ID_WIDTH  = ni_params_pkg::NSU_AXI_ID_WIDTH,
    parameter int unsigned AW_CONTEXT_DEPTH = ni_params_pkg::NSU_MAX_OUTSTANDING,
    parameter int unsigned AR_CONTEXT_DEPTH = ni_params_pkg::NSU_MAX_OUTSTANDING,

    parameter type b_t = ni_signals_pkg::noc_axi_b_t,
    parameter type r_t = ni_signals_pkg::noc_axi_r_t
) (
    input  wire logic                                                           clk_i,
    input  wire logic                                                           rst_n_i,
    input  wire ni_types_pkg::nsu_aw_request_t                                  s_aw_i,
    input  wire logic                                                           s_aw_valid_i,
    output wire logic                                                           s_aw_ready_o,
    output wire logic                                     [OUTPUT_ID_WIDTH-1:0] m_awid_o,
    input  wire ni_types_pkg::nsu_ar_request_t                                  s_ar_i,
    input  wire logic                                                           s_ar_valid_i,
    output wire logic                                                           s_ar_ready_o,
    output wire logic                                     [OUTPUT_ID_WIDTH-1:0] m_arid_o,
    output wire ni_types_pkg::nsu_w_context_t                                   m_w_context_o,
    output wire logic                                                           m_w_context_valid_o,
    output wire logic                          [ni_flit_pkg::AXI_LEN_WIDTH-1:0] m_w_beat_o,
    input  wire logic                                                           w_accept_i,
    input  wire logic                                                           w_last_i,
    input  wire b_t                                                             s_b_i,
    input  wire logic                                                           s_b_valid_i,
    output wire logic                                                           s_b_ready_o,
    output wire ni_types_pkg::nsu_b_response_t                                  m_b_o,
    output wire logic                                                           m_b_valid_o,
    input  wire logic                                                           m_b_ready_i,
    input  wire r_t                                                             s_r_i,
    input  wire logic                                                           s_r_valid_i,
    output wire logic                                                           s_r_ready_o,
    output wire ni_types_pkg::nsu_r_response_t                                  m_r_o,
    output wire logic                                                           m_r_valid_o,
    input  wire logic                                                           m_r_ready_i
);
    import ni_types_pkg::*;
    localparam int unsigned NUM_IDS = 1 << OUTPUT_ID_WIDTH;
    localparam int unsigned KEY_W   = ni_flit_pkg::SRC_ID_WIDTH +
        ni_flit_pkg::SRC_PORT_ID_WIDTH + ni_params_pkg::NOC_ID_WIDTH;
    if (OUTPUT_ID_WIDTH < 1 || OUTPUT_ID_WIDTH > 8 ||
            AW_CONTEXT_DEPTH < 1 || AR_CONTEXT_DEPTH < 1) begin : gen_invalid_config
        initial $fatal(0, "Error: invalid NSU ID/context capacity (instance %m)");
    end

    initial begin
        if ($bits(s_b_i.bid) != OUTPUT_ID_WIDTH || $bits(s_r_i.rid) != OUTPUT_ID_WIDTH) begin
            $fatal(0, "Error: NSU response ID type width mismatch: B=%0d R=%0d expected=%0d (instance %m)",
                $bits(s_b_i.bid), $bits(s_r_i.rid), OUTPUT_ID_WIDTH);
        end
    end

    function automatic logic [OUTPUT_ID_WIDTH-1:0] map_id(input nsu_context_t request);
        logic           [KEY_W-1:0] key;
        logic [OUTPUT_ID_WIDTH-1:0] id;
        key = {request.src_id, request.src_port_id, request.noc_id};
        id  = '0;
        for (int bit_idx = 0; bit_idx < KEY_W; bit_idx++) begin
            id[bit_idx % OUTPUT_ID_WIDTH] ^= key[bit_idx];
        end
        return id;
    endfunction

    wire                                                aw_ready, ar_ready, b_valid, r_valid, b_grant, r_grant;
    wire                                                w_full, w_empty, w_pop;
    wire                                                nsu_context_t b_context, r_context;
    wire                                                nsu_w_context_t w_head;
    wire                                                nsu_w_context_t w_context = '{response: s_aw_i.response, vc_id: s_aw_i.vc_id};
    logic              [ni_flit_pkg::AXI_LEN_WIDTH-1:0] w_beat_reg, w_beat_next;
    logic [NUM_IDS-1:0][ni_flit_pkg::AXI_LEN_WIDTH-1:0] r_beat_reg, r_beat_next;
    nsu_b_response_t b;
    nsu_r_response_t r;

    assign m_awid_o            = map_id(s_aw_i.response);
    assign m_arid_o            = map_id(s_ar_i.response);
    assign s_aw_ready_o        = aw_ready && !w_full;
    assign s_ar_ready_o        = ar_ready;
    assign m_w_context_valid_o = !w_empty;
    assign m_w_context_o       = m_w_context_valid_o ? w_head : '0;
    assign m_w_beat_o          = m_w_context_valid_o ? w_beat_reg : '0;
    assign w_pop               = w_accept_i && w_last_i;
    assign m_b_valid_o         = s_b_valid_i && b_valid && b_grant;
    assign m_r_valid_o         = s_r_valid_i && r_valid && r_grant;
    assign s_b_ready_o         = b_valid && b_grant && m_b_ready_i;
    assign s_r_ready_o         = r_valid && r_grant && m_r_ready_i;
    assign m_b_o               = m_b_valid_o ? b : '0;
    assign m_r_o               = m_r_valid_o ? r : '0;

    always_comb begin
        b            = '0;
        b.axi.bid    = b_context.noc_id;
        b.axi.bresp  = s_b_i.bresp;
        b.response   = b_context;
        r            = '0;
        r.axi.rid    = r_context.noc_id;
        r.axi.rdata  = s_r_i.rdata;
        r.axi.rresp  = s_r_i.rresp;
        r.axi.rlast  = s_r_i.rlast;
        r.response   = r_context;
        r.beat_index = r_beat_reg[s_r_i.rid];
        w_beat_next  = w_beat_reg;
        r_beat_next  = r_beat_reg;
        if (w_accept_i) begin
            w_beat_next = w_last_i ? '0 : w_beat_reg + 1'b1;
        end
        if (s_r_valid_i && s_r_ready_o) begin
            r_beat_next[s_r_i.rid] = s_r_i.rlast ? '0 : r_beat_reg[s_r_i.rid] + 1'b1;
        end
    end
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            w_beat_reg <= '0;
            r_beat_reg <= '0;
        end else begin
            w_beat_reg <= w_beat_next;
            r_beat_reg <= r_beat_next;
        end
    end
    cc_id_queue #(
        .IdWidth  (OUTPUT_ID_WIDTH ),
        .Capacity (AW_CONTEXT_DEPTH),
        .FullBw   (1'b1            ),
        .data_t   (nsu_context_t   )
    ) i_aw_context (
        .clk_i            (clk_i                     ),
        .rst_ni           (rst_n_i                   ),
        .clr_i            (1'b0                      ),
        .inp_id_i         (m_awid_o                  ),
        .inp_data_i       (s_aw_i.response           ),
        .inp_req_i        (s_aw_valid_i && !w_full   ),
        .inp_gnt_o        (aw_ready                  ),
        .exists_data_i    ('0                        ),
        .exists_mask_i    ('0                        ),
        .exists_req_i     ('0                        ),
        .exists_o         (                          ),
        .exists_gnt_o     (                          ),
        .oup_id_i         (s_b_i.bid                 ),
        .oup_req_i        (s_b_valid_i               ),
        .oup_pop_i        (s_b_valid_i && s_b_ready_o),
        .oup_data_o       (b_context                 ),
        .oup_data_valid_o (b_valid                   ),
        .oup_gnt_o        (b_grant                   ),
        .full_o           (                          ),
        .empty_o          (                          )
    );
    cc_id_queue #(
        .IdWidth  (OUTPUT_ID_WIDTH ),
        .Capacity (AR_CONTEXT_DEPTH),
        .FullBw   (1'b1            ),
        .data_t   (nsu_context_t   )
    ) i_ar_context (
        .clk_i            (clk_i                                    ),
        .rst_ni           (rst_n_i                                  ),
        .clr_i            (1'b0                                     ),
        .inp_id_i         (m_arid_o                                 ),
        .inp_data_i       (s_ar_i.response                          ),
        .inp_req_i        (s_ar_valid_i                             ),
        .inp_gnt_o        (ar_ready                                 ),
        .exists_data_i    ('0                                       ),
        .exists_mask_i    ('0                                       ),
        .exists_req_i     ('0                                       ),
        .exists_o         (                                         ),
        .exists_gnt_o     (                                         ),
        .oup_id_i         (s_r_i.rid                                ),
        .oup_req_i        (s_r_valid_i                              ),
        .oup_pop_i        (s_r_valid_i && s_r_ready_o && s_r_i.rlast),
        .oup_data_o       (r_context                                ),
        .oup_data_valid_o (r_valid                                  ),
        .oup_gnt_o        (r_grant                                  ),
        .full_o           (                                         ),
        .empty_o          (                                         )
    );
    cc_fifo #(
        .Depth       (AW_CONTEXT_DEPTH),
        .FallThrough (1'b0            ),
        .data_t      (nsu_w_context_t )
    ) i_w_context (
        .clk_i   (clk_i                       ),
        .rst_ni  (rst_n_i                     ),
        .clr_i   (1'b0                        ),
        .flush_i (1'b0                        ),
        .data_i  (w_context                   ),
        .push_i  (s_aw_valid_i && s_aw_ready_o),
        .full_o  (w_full                      ),
        .empty_o (w_empty                     ),
        .usage_o (                            ),
        .data_o  (w_head                      ),
        .pop_i   (w_pop                       )
    );

    // synthesis translate_off
    always @(posedge clk_i) begin
        if (rst_n_i) begin
            if (s_b_valid_i && !b_valid) $fatal(1, "B without AW context (instance %m)");
            if (s_r_valid_i && !r_valid) $fatal(1, "R without AR context (instance %m)");
            if (w_accept_i && (w_empty || w_last_i != (w_beat_reg == w_head.response.len)))
                $fatal(1, "W burst/context mismatch (instance %m)");
            if (s_r_valid_i && s_r_ready_o && s_r_i.rlast != (r_beat_reg[s_r_i.rid] == r_context.len))
                $fatal(1, "R burst/context mismatch (instance %m)");
        end
    end
    // synthesis translate_on
endmodule

`resetall
