// SPDX-License-Identifier: Apache-2.0

`resetall
`timescale 1ns / 1ps
`default_nettype none

// Simulation-only AXI burst and SAM-region contract. No DUT flow-control outputs.
module nmu_sam_burst_checker #(
    parameter int unsigned SAM_NUM_RULES,
    parameter type         sam_rule_t
) (
    input wire sam_rule_t [SAM_NUM_RULES-1:0] sam_i,

    input wire logic                        clk_i,
    input wire logic                        rst_n_i,
    input wire logic                        aw_valid_i,
    input wire ni_signals_pkg::noc_axi_aw_t aw_i,
    input wire logic                        ar_valid_i,
    input wire ni_signals_pkg::noc_axi_ar_t ar_i
);
    import axi_pkg::*;

    task automatic check_burst(
        input string         channel,
        input largest_addr_t addr,
        input len_t          len,
        input size_t         size,
        input burst_t        burst
    );
        largest_addr_t first_byte;
        largest_addr_t last_byte;
        int rule_index;

        if (burst == 2'b11 || int'(num_bytes(size)) > ni_params_pkg::AXI_DATA_WIDTH / 8 ||
                (burst == BURST_FIXED && len > 15) ||
                (burst == BURST_WRAP &&
                    (!(len inside {1, 3, 7, 15}) || addr != aligned_addr(addr, size)))) begin
            $fatal(1, "%s invalid AXI burst attributes (instance %m)", channel);
        end
        rule_index = -1;
        for (int i = 0; i < SAM_NUM_RULES; i++) begin
            if (addr >= largest_addr_t'(sam_i[i].start_addr) &&
                    (addr < largest_addr_t'(sam_i[i].end_addr) || sam_i[i].end_addr == '0)) begin
                rule_index = i;
            end
        end
        if (rule_index < 0) begin
            $fatal(1, "Error: invalid %s SAM mapping (instance %m)", channel);
        end
        for (int beat = 0; beat <= int'(len); beat++) begin
            first_byte = beat_addr(addr, size, len, burst, shortint'(beat));
            last_byte = aligned_addr(first_byte, size) + largest_addr_t'(num_bytes(size)) - 1;
            if ((first_byte >> 12) != (addr >> 12) || (last_byte >> 12) != (addr >> 12)) begin
                $fatal(1, "%s burst crosses 4 KB boundary (instance %m)", channel);
            end
            if (first_byte < largest_addr_t'(sam_i[rule_index].start_addr) ||
                    (sam_i[rule_index].end_addr != '0 &&
                        last_byte >= largest_addr_t'(sam_i[rule_index].end_addr))) begin
                $fatal(1, "%s burst crosses SAM region boundary (instance %m)", channel);
            end
        end
    endtask

    always @(posedge clk_i) begin
        if (rst_n_i) begin
            if (aw_valid_i) begin
                check_burst("AW", largest_addr_t'(aw_i.awaddr), aw_i.awlen, aw_i.awsize, aw_i.awburst);
            end
            if (ar_valid_i) begin
                check_burst("AR", largest_addr_t'(ar_i.araddr), ar_i.arlen, ar_i.arsize, ar_i.arburst);
            end
        end
    end
endmodule

`resetall
