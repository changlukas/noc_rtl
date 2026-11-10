`timescale 1ns/1ps
interface ni_nmu_if(input logic clk, input logic axi_rst_n, input logic noc_rst_n);
    logic rst_n = 0;
    bit read_reorder, read_data;
    bit warmup = 1, warm_ready = 0, completed = 0;
    int expected_writes, expected_reads;
endinterface
