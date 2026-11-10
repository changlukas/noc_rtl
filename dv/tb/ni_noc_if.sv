// SPDX-License-Identifier: Apache-2.0
interface ni_noc_if(input logic clk, input logic rst_n);
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    logic [noc_unit_params_pkg::DAT_NUM_VC-1:0] dat_valid, dat_ready;
    noc_payload_pkg::req_flit_t req;
    noc_payload_pkg::rsp_flit_t rsp;
    noc_payload_pkg::dat_flit_t dat;
    clocking monitor_cb @(posedge clk);
        default input #1step;
        input rst_n, req_valid, req_ready, req, rsp_valid, rsp_ready, rsp, dat_valid, dat_ready, dat;
    endclocking
    property dat_stable;
        @(posedge clk) disable iff (!rst_n)
        ((|dat_valid) && !(|(dat_valid & dat_ready))) |=> $stable({dat_valid, dat});
    endproperty
    assert property (dat_stable) else $fatal(1, "DAT changed while stalled");
    always @(posedge clk) begin
        if (rst_n && |dat_valid) begin
            if (!$onehot(dat_valid) || !dat_valid[noc_unit_params_pkg::dat_class(dat.header.packet_type)])
                $fatal(1, "DAT valid vector does not match packet class");
        end
    end
endinterface
