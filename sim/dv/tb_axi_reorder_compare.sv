`timescale 1ns/1ps
`include "axi/typedef.svh"
module tb_axi_reorder_compare;
    typedef logic [31:0] addr_t;
    typedef logic [63:0] data_t;
    typedef logic [7:0] strb_t;
    typedef logic [1:0] id_t;
    typedef logic user_t;
    `AXI_TYPEDEF_ALL(test, addr_t, id_t, data_t, strb_t, user_t)
    typedef struct packed {
        int unsigned idx;
        addr_t start_addr;
        addr_t end_addr;
    } rule_t;
    localparam rule_t [1:0] RULES = '{'{0, 32'h800, 32'h1000}, '{0, 0, 32'h800}};
    bit clk = 0;
    bit rst_n = 1;
    always #5 clk = ~clk;
    test_req_t source_req;
    test_resp_t source_rsp;
    test_req_t [1:0] target_req;
    test_resp_t [1:0] target_rsp;
    wire done;
    int fault = 0;
    axi_reorder_compare #(
        .NumSlaves(2), .AxiIdWidth(2), .NumAddrRegions(2),
        .addr_t(addr_t), .rule_t(rule_t), .AddrRegions(RULES),
        .aw_chan_t(test_aw_chan_t), .w_chan_t(test_w_chan_t),
        .b_chan_t(test_b_chan_t), .ar_chan_t(test_ar_chan_t),
        .r_chan_t(test_r_chan_t), .req_t(test_req_t), .rsp_t(test_resp_t)
    ) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .mon_mst_req_i(source_req), .mon_mst_rsp_i(source_rsp),
        .mon_slv_req_i(target_req), .mon_slv_rsp_i(target_rsp),
        .end_of_sim_o(done)
    );
    task automatic clear_bus();
        source_req = '0;
        source_rsp = '0;
        target_req = '0;
        target_rsp = '0;
    endtask
    task automatic aw(input bit target, input id_t id, input addr_t addr);
        @(negedge clk);
        clear_bus();
        if (target) begin
            target_req[0].aw = '{id:id, addr:addr, size:3, burst:1, default:'0};
            target_req[0].aw_valid = 1;
            target_rsp[0].aw_ready = 1;
        end else begin
            source_req.aw = '{id:id, addr:addr, size:3, burst:1, default:'0};
            source_req.aw_valid = 1;
            source_rsp.aw_ready = 1;
        end
        @(negedge clk);
        clear_bus();
    endtask
    task automatic w(input bit target, input data_t data);
        @(negedge clk);
        clear_bus();
        if (target) begin
            target_req[0].w = '{data:data, strb:'1, last:1, default:'0};
            target_req[0].w_valid = 1;
            target_rsp[0].w_ready = 1;
        end else begin
            source_req.w = '{data:data, strb:'1, last:1, default:'0};
            source_req.w_valid = 1;
            source_rsp.w_ready = 1;
        end
        @(negedge clk);
        clear_bus();
    endtask
    task automatic b(input bit target, input id_t id);
        @(negedge clk);
        clear_bus();
        if (target) begin
            target_rsp[0].b = '{id:id, default:'0};
            target_rsp[0].b_valid = 1;
            target_req[0].b_ready = 1;
        end else begin
            source_rsp.b = '{id:id, default:'0};
            source_rsp.b_valid = 1;
            source_req.b_ready = 1;
        end
        @(negedge clk);
        clear_bus();
    endtask
    task automatic ar(input bit target, input id_t id, input addr_t addr);
        @(negedge clk);
        clear_bus();
        if (target) begin
            target_req[0].ar = '{id:id, addr:addr, size:3, burst:1, default:'0};
            target_req[0].ar_valid = 1;
            target_rsp[0].ar_ready = 1;
        end else begin
            source_req.ar = '{id:id, addr:addr, size:3, burst:1, default:'0};
            source_req.ar_valid = 1;
            source_rsp.ar_ready = 1;
        end
        @(negedge clk);
        clear_bus();
    endtask
    task automatic r(input bit target, input id_t id, input data_t data);
        @(negedge clk);
        clear_bus();
        if (target) begin
            target_rsp[0].r = '{id:id, data:data, last:1, default:'0};
            target_rsp[0].r_valid = 1;
            target_req[0].r_ready = 1;
        end else begin
            source_rsp.r = '{id:id, data:data, last:1, default:'0};
            source_rsp.r_valid = 1;
            source_req.r_ready = 1;
        end
        @(negedge clk);
        clear_bus();
    endtask
    initial begin
        clear_bus();
        void'($value$plusargs("fault=%d", fault));
        if (fault == 5 || fault == 6) begin
            w(0, 64'hdead);
            aw(0, 0, 32'h300);
            aw(1, 2, 32'h300);
            ar(0, 1, 32'h400);
            ar(1, 3, 32'h400);
            r(1, 3, 64'hbeef);
            @(negedge clk);
            rst_n = 0;
            repeat (3) @(negedge clk);
            rst_n = 1;
            if (fault == 6) fault = 4;
        end
        w(0, 64'h1111);
        aw(0, 0, 32'h100);
        aw(0, fault == 1 ? 0 : 1, 32'h200);
        aw(1, 3, 32'h200);
        if (fault == 1) begin
            repeat (3) @(negedge clk);
            $finish;
        end
        aw(1, 2, 32'h100);
        // The selected AW may reach the target before its source W is available.
        w(0, 64'h2222);
        w(1, fault == 3 ? 64'h1111 : 64'h2222);
        w(1, 64'h1111);
        // Target responses may also reorder across downstream IDs.
        b(1, 2);
        b(1, 3);
        b(0, 1);
        b(0, 0);
        ar(0, 0, 32'h100);
        ar(0, fault == 2 ? 0 : 1, 32'h200);
        ar(1, 3, 32'h200);
        if (fault == 2) begin
            repeat (3) @(negedge clk);
            $finish;
        end
        ar(1, 2, 32'h100);
        r(1, 2, 64'h1111);
        r(1, 3, 64'h2222);
        r(0, 1, fault == 4 ? 64'h1111 : 64'h2222);
        r(0, 0, 64'h1111);
        repeat (3) @(posedge clk);
        if (!done) $fatal(1, "Checker did not drain");
        $display("CHECKER_TEST_DONE");
        $finish;
    end
endmodule
