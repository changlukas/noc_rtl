// SPDX-License-Identifier: Apache-2.0
interface ni_noc_if(input logic clk, input logic rst_n);
    import ni_params_pkg::*;
    import ni_flit_pkg::*;
    logic req_valid, req_ready, rsp_valid, rsp_ready, dat_valid;
    req_flit_t req;
    rsp_flit_t rsp;
    dat_flit_t dat;
    logic [NUM_DAT_VC-1:0] credit;
    clocking monitor_cb @(posedge clk);
        default input #1step;
        input rst_n, req_valid, req_ready, req, rsp_valid, rsp_ready, rsp, dat_valid, dat, credit;
    endclocking
endinterface
