// SPDX-License-Identifier: Apache-2.0

`resetall
`timescale 1ns / 1ps
`default_nettype none

/* Select synchronous or Gray-pointer CDC FIFO storage. */
module axi_async_fifo #(
    // 0: synchronous FIFO (common clock), 1: asynchronous FIFO.
    parameter int unsigned FIFO_TYPE      = 1,
    parameter int unsigned AXI_FIFO_DEPTH = 8,
    parameter type         data_t         = logic
) (
    input  wire logic   src_clk_i,
    input  wire logic   src_rst_n_i,
    input  wire logic   src_valid_i,
    output wire logic   src_ready_o,
    input  wire data_t  src_data_i,
    input  wire logic   dst_clk_i,
    input  wire logic   dst_rst_n_i,
    output wire logic   dst_valid_o,
    input  wire logic   dst_ready_i,
    output wire data_t  dst_data_o
);

    localparam int unsigned FIFO_ADDR_W = $clog2(AXI_FIFO_DEPTH);

    if (AXI_FIFO_DEPTH < 2 || (AXI_FIFO_DEPTH & (AXI_FIFO_DEPTH - 1)) != 0) begin : gen_invalid_depth
        initial $fatal(0, "Error: AXI_FIFO_DEPTH must be a power of two and at least 2 (instance %m)");
    end

    if (FIFO_TYPE == 0) begin : gen_sync
        // Both interfaces must use the same clock. Either reset flushes the FIFO.
        wire rst_n = src_rst_n_i && dst_rst_n_i;
        wire full, empty;

        assign src_ready_o = rst_n && !full;
        assign dst_valid_o = rst_n && !empty;

        cc_fifo #(
            .Depth       (AXI_FIFO_DEPTH),
            .FallThrough (1'b0),
            .data_t      (data_t)
        ) i_fifo (
            .clk_i   (src_clk_i),
            .rst_ni  (rst_n),
            .clr_i   (1'b0),
            .flush_i (1'b0),
            .full_o  (full),
            .empty_o (empty),
            .usage_o (),
            .data_i  (src_data_i),
            .push_i  (src_valid_i && src_ready_o),
            .data_o  (dst_data_o),
            .pop_i   (dst_valid_o && dst_ready_i)
        );
    end else if (FIFO_TYPE == 1) begin : gen_async
        cc_cdc_fifo_gray #(
            .data_t     (data_t     ),
            .LogDepth   (FIFO_ADDR_W),
            .SyncStages (2          )
        ) i_cc_cdc_fifo_gray (
            .src_rst_ni  (src_rst_n_i),
            .src_clk_i   (src_clk_i  ),
            .src_data_i  (src_data_i ),
            .src_valid_i (src_valid_i),
            .src_ready_o (src_ready_o),
            .dst_rst_ni  (dst_rst_n_i),
            .dst_clk_i   (dst_clk_i  ),
            .dst_data_o  (dst_data_o ),
            .dst_valid_o (dst_valid_o),
            .dst_ready_i (dst_ready_i)
        );
    end else begin : gen_invalid_fifo_type
        initial $fatal(0, "Error: FIFO_TYPE must be 0 (SYNC) or 1 (ASYNC) (instance %m)");
    end

endmodule

`resetall
