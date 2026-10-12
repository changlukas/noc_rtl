`timescale 1ps/1ps
interface ni_tb_if(input logic clk, input logic axi_rst_n, input logic noc_rst_n);
    logic rst_n = 0;
    bit completed = 0;
    bit reset_pending_seen = 0, reset_complete = 0;
    task release_reset();
        repeat (5) @(negedge clk);
        rst_n = 1;
        wait (axi_rst_n && noc_rst_n);
    endtask
endinterface
