// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

// TB connection for one NMU and multiple NSUs; no router model.
module ni_direct_link #(
    parameter int unsigned NUM_NSUS     = 4,
    parameter int unsigned NUM_DAT_VC   = ni_params_pkg::NUM_DAT_VC,
    parameter int unsigned CREDIT_DEPTH = ni_params_pkg::CREDIT_DEPTH,
    parameter logic [NUM_NSUS:0][ni_flit_pkg::DST_ID_WIDTH-1:0] NODE_IDS = '0,
    localparam int unsigned NUM_PORTS   = NUM_NSUS + 1
) (
    input  wire logic                                         clk_i,
    input  wire logic                                         rst_n_i,
    input  wire logic                         [NUM_PORTS-1:0] rx_req_valid_i,
    input  wire logic [ni_params_pkg::NOC_REQ_FLIT_WIDTH-1:0] rx_req_flit_i [NUM_PORTS],
    output wire logic                         [NUM_PORTS-1:0] rx_req_ready_o,
    output wire logic                         [NUM_PORTS-1:0] tx_req_valid_o,
    output wire logic [ni_params_pkg::NOC_REQ_FLIT_WIDTH-1:0] tx_req_flit_o [NUM_PORTS],
    input  wire logic                         [NUM_PORTS-1:0] tx_req_ready_i,
    input  wire logic                         [NUM_PORTS-1:0] rx_rsp_valid_i,
    input  wire logic [ni_params_pkg::NOC_RSP_FLIT_WIDTH-1:0] rx_rsp_flit_i [NUM_PORTS],
    output wire logic                         [NUM_PORTS-1:0] rx_rsp_ready_o,
    output wire logic                         [NUM_PORTS-1:0] tx_rsp_valid_o,
    output wire logic [ni_params_pkg::NOC_RSP_FLIT_WIDTH-1:0] tx_rsp_flit_o [NUM_PORTS],
    input  wire logic                         [NUM_PORTS-1:0] tx_rsp_ready_i,
    input  wire logic                         [NUM_PORTS-1:0] rx_dat_valid_i,
    input  wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] rx_dat_flit_i [NUM_PORTS],
    output wire logic                        [NUM_DAT_VC-1:0] rx_dat_crdvalid_o [NUM_PORTS],
    output wire logic                         [NUM_PORTS-1:0] tx_dat_valid_o,
    output wire logic [ni_params_pkg::NOC_DAT_FLIT_WIDTH-1:0] tx_dat_flit_o [NUM_PORTS],
    input  wire logic                        [NUM_DAT_VC-1:0] tx_dat_crdvalid_i [NUM_PORTS]
);
    import ni_flit_pkg::*;
    localparam int unsigned NUM_DAT_INPUTS = NUM_PORTS * NUM_DAT_VC;
    localparam int unsigned DAT_VC_MODE    = ni_params_pkg::NOC_DAT_VC_MODE;

    initial begin
        if (NUM_NSUS < 1 || NUM_DAT_VC < 1 || CREDIT_DEPTH < 2)
            $fatal(1, "Invalid direct-link dimensions");
        for (int i = 0; i < NUM_PORTS; i++)
            for (int j = i + 1; j < NUM_PORTS; j++)
                if (NODE_IDS[i] == NODE_IDS[j]) $fatal(1, "Duplicate direct-link node ID");
    end

    wire req_flit_t req = req_flit_t'(rx_req_flit_i[0]);
    wire [NUM_NSUS-1:0] req_select;
    wire [NUM_NSUS-1:0] req_ready;
    wire rsp_flit_t [NUM_NSUS-1:0] rsp_data;
    wire [NUM_NSUS-1:0] rsp_valid, rsp_ready;
    wire rsp_flit_t rsp;

    assign tx_req_valid_o[0] = 1'b0;
    assign tx_req_flit_o[0]  = '0;
    assign rx_req_ready_o[0] = rst_n_i && |req_ready;
    assign rx_rsp_ready_o[0] = 1'b0;
    assign tx_rsp_flit_o[0]  = rsp;
    for (genvar n = 0; n < NUM_NSUS; n++) begin : gen_control
        assign req_select[n]      = req.header[DST_ID_LSB +: DST_ID_WIDTH] == NODE_IDS[n+1];
        assign req_ready[n]       = req_select[n] && tx_req_ready_i[n+1];
        assign tx_req_valid_o[n+1]  = rst_n_i && rx_req_valid_i[0] && req_select[n];
        assign tx_req_flit_o[n+1]   = tx_req_valid_o[n+1] ? rx_req_flit_i[0] : '0;
        assign rx_req_ready_o[n+1]  = 1'b0;
        assign rsp_data[n]        = rsp_flit_t'(rx_rsp_flit_i[n+1]);
        assign rsp_valid[n]       = rst_n_i && rx_rsp_valid_i[n+1];
        assign rx_rsp_ready_o[n+1]  = rsp_ready[n];
        assign tx_rsp_valid_o[n+1]  = 1'b0;
        assign tx_rsp_flit_o[n+1]   = '0;
        always @(posedge clk_i) begin
            if (rst_n_i && rx_rsp_valid_i[n+1] &&
                    rsp_data[n].header[DST_ID_LSB +: DST_ID_WIDTH] != NODE_IDS[0])
                $fatal(1, "Direct-link RSP destination mismatch");
        end
    end
    rr_arb_tree #(
        .NumIn     (NUM_NSUS  ),
        .DataType  (rsp_flit_t),
        .AxiVldRdy (1'b1      ),
        .LockIn    (1'b1      ),
        .FairArb   (1'b1      )
    ) i_rsp_arb (
        .clk_i   (clk_i                       ),
        .rst_ni  (rst_n_i                     ),
        .flush_i (1'b0                        ),
        .rr_i    ('0                          ),
        .req_i   (rsp_valid                   ),
        .gnt_o   (rsp_ready                   ),
        .data_i  (rsp_data                    ),
        .req_o   (tx_rsp_valid_o[0]           ),
        .gnt_i   (rst_n_i && tx_rsp_ready_i[0]),
        .data_o  (rsp                         ),
        .idx_o   (                            )
    );

    wire dat_flit_t [NUM_DAT_VC-1:0] dat_head [NUM_PORTS];
    wire [NUM_DAT_VC-1:0] dat_valid [NUM_PORTS];
    wire [NUM_DAT_VC-1:0] dat_pop [NUM_PORTS];
    wire [NUM_DAT_INPUTS-1:0] dat_grant [NUM_PORTS];
    for (genvar p = 0; p < NUM_PORTS; p++) begin : gen_input
        wire dat_flit_t dat = dat_flit_t'(rx_dat_flit_i[p]);
        wire [VC_ID_WIDTH-1:0] vc_id = dat.header[VC_ID_LSB +: VC_ID_WIDTH];
        logic [NUM_DAT_VC-1:0] credit_return_reg = '0;
        always @(posedge clk_i or negedge rst_n_i) begin
            if (~rst_n_i) begin
                credit_return_reg <= '0;
            end else begin
                credit_return_reg <= dat_pop[p];
            end
        end
        assign rx_dat_crdvalid_o[p] = rst_n_i ? credit_return_reg : '0;
        for (genvar vc = 0; vc < NUM_DAT_VC; vc++) begin : gen_vc
            localparam bit ACTIVE = DAT_VC_MODE == 0 || ((p == 0) == (vc < NUM_DAT_VC/2));
            if (ACTIVE) begin : gen_active
                wire full, empty;
                wire push = rst_n_i && rx_dat_valid_i[p] && vc_id == VC_ID_WIDTH'(vc);
                wire [NUM_PORTS-1:0] grants;
                for (genvar q = 0; q < NUM_PORTS; q++) begin : gen_grant
                    assign grants[q] = dat_grant[q][p*NUM_DAT_VC+vc];
                end
                assign dat_pop[p][vc]   = |grants;
                assign dat_valid[p][vc] = rst_n_i && !empty;
                cc_fifo #(
                    .Depth       (CREDIT_DEPTH),
                    .FallThrough (1'b0        ),
                    .data_t      (dat_flit_t  )
                ) i_fifo (
                    .clk_i   (clk_i          ),
                    .rst_ni  (rst_n_i        ),
                    .clr_i   (1'b0           ),
                    .flush_i (1'b0           ),
                    .full_o  (full           ),
                    .empty_o (empty          ),
                    .usage_o (               ),
                    .data_i  (dat            ),
                    .push_i  (push           ),
                    .data_o  (dat_head[p][vc]),
                    .pop_i   (dat_pop[p][vc] )
                );
                always @(posedge clk_i) begin
                    if (push && full) $fatal(1, "Direct-link DAT FIFO overflow");
                    if (rst_n_i && !$onehot0(grants)) $fatal(1, "Direct-link DAT duplicate transfer");
                end
            end else begin : gen_unused
                assign dat_pop[p][vc]   = 1'b0;
                assign dat_valid[p][vc] = 1'b0;
                assign dat_head[p][vc]  = '0;
            end
        end
        always @(posedge clk_i) begin : check_input
            bit destination_valid;
            destination_valid = 0;
            for (int q = 0; q < NUM_PORTS; q++)
                if ((p == 0) != (q == 0) && dat.header[DST_ID_LSB +: DST_ID_WIDTH] == NODE_IDS[q])
                    destination_valid = 1;
            if (rst_n_i && rx_dat_valid_i[p] &&
                    ($isunknown({vc_id, dat.header}) || int'(vc_id) >= NUM_DAT_VC || !destination_valid ||
                     (DAT_VC_MODE == 1 && ((p == 0) != (int'(vc_id) < NUM_DAT_VC/2)))))
                $fatal(1, "Invalid direct-link DAT destination/VC");
        end
    end
    for (genvar q = 0; q < NUM_PORTS; q++) begin : gen_output
        wire [NUM_DAT_VC-1:0] credit_left;
        wire dat_flit_t selected_dat;
        wire [NUM_DAT_INPUTS-1:0] request;
        wire dat_flit_t [NUM_DAT_INPUTS-1:0] data;
        assign tx_dat_flit_o[q] = tx_dat_valid_o[q] ? selected_dat : '0;
        for (genvar vc = 0; vc < NUM_DAT_VC; vc++) begin : gen_credit
            localparam bit ACTIVE = DAT_VC_MODE == 0 || ((q != 0) == (vc < NUM_DAT_VC/2));
            if (ACTIVE) begin : gen_active
                cc_credit_counter #(
                    .NumCredits (CREDIT_DEPTH)
                ) i_credit (
                    .clk_i         (clk_i                                                                                 ),
                    .rst_ni        (rst_n_i                                                                               ),
                    .clr_i         (1'b0                                                                                  ),
                    .credit_o      (                                                                                      ),
                    .credit_give_i (rst_n_i && tx_dat_crdvalid_i[q][vc]                                                   ),
                    .credit_take_i (tx_dat_valid_o[q] && selected_dat.header[VC_ID_LSB +: VC_ID_WIDTH] == VC_ID_WIDTH'(vc)),
                    .credit_left_o (credit_left[vc]                                                                       ),
                    .credit_crit_o (                                                                                      ),
                    .credit_full_o (                                                                                      )
                );
            end else begin : gen_unused
                assign credit_left[vc] = 1'b0;
            end
        end
        for (genvar p = 0; p < NUM_PORTS; p++) begin : gen_source
            for (genvar vc = 0; vc < NUM_DAT_VC; vc++) begin : gen_vc
                assign data[p*NUM_DAT_VC+vc] = dat_head[p][vc];
                assign request[p*NUM_DAT_VC+vc] = rst_n_i && ((p == 0) != (q == 0)) &&
                    dat_valid[p][vc] && dat_head[p][vc].header[DST_ID_LSB +: DST_ID_WIDTH] == NODE_IDS[q] &&
                    (credit_left[vc] || tx_dat_crdvalid_i[q][vc]);
            end
        end
        rr_arb_tree #(
            .NumIn     (NUM_DAT_INPUTS),
            .DataType  (dat_flit_t    ),
            .AxiVldRdy (1'b1          ),
            .LockIn    (1'b0          ),
            .FairArb   (1'b1          )
        ) i_dat_arb (
            .clk_i   (clk_i            ),
            .rst_ni  (rst_n_i          ),
            .flush_i (1'b0             ),
            .rr_i    ('0               ),
            .req_i   (request          ),
            .gnt_o   (dat_grant[q]     ),
            .data_i  (data             ),
            .req_o   (tx_dat_valid_o[q]),
            .gnt_i   (rst_n_i          ),
            .data_o  (selected_dat     ),
            .idx_o   (                 )
        );
    end
    always @(posedge clk_i) begin
        if (rst_n_i && rx_req_valid_i[0] && !$onehot(req_select))
            $fatal(1, "Invalid direct-link REQ destination");
    end
endmodule
`resetall
