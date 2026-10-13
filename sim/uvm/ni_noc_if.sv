// SPDX-License-Identifier: Apache-2.0
interface ni_noc_if(input logic clk, input logic rst_n);
    import ni_params_pkg::*;
    import ni_flit_pkg::*;
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    logic [NUM_DAT_VC-1:0] dat_valid, dat_ready;
    req_flit_t req;
    rsp_flit_t rsp;
    dat_flit_t dat;
    logic [NUM_DAT_VC-1:0] credit;
    clocking monitor_cb @(posedge clk);
        default input #1step;
        input rst_n, req_valid, req_ready, req, rsp_valid, rsp_ready, rsp, dat_valid, dat_ready, dat, credit;
    endclocking
    property dat_stable;
        @(posedge clk) disable iff (!rst_n)
        ((|dat_valid) && !(|(dat_valid & dat_ready))) |=> $stable({dat_valid, dat});
    endproperty
    assert property (dat_stable) else $fatal(1, "DAT changed while stalled");
    always @(posedge clk) begin
        if (rst_n && |dat_valid) begin
            if (!$onehot(dat_valid) || !dat_valid[dat.header[VC_ID_LSB +: VC_ID_WIDTH]])
                $fatal(1, "DAT valid vector does not match header VC");
        end
    end
endinterface
