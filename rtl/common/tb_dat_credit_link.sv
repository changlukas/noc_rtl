// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module tb_dat_credit_link;
    import ni_flit_pkg::*;
    localparam int NUM_VC = 2;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    dat_flit_t source = '0, link;
    dat_flit_t [NUM_VC-1:0] tx_data, rx_data;
    logic source_valid = 0;
    wire [NUM_VC-1:0] source_ready, tx_valid, tx_ready, link_valid, link_ready;
    wire [NUM_VC-1:0] rx_valid, credit;
    logic [NUM_VC-1:0] link_enable = '0, consume = '0;
    int sent[NUM_VC], received[NUM_VC], balance[NUM_VC];
    int stalled = 0, exhausted = 0, simultaneous = 0;
    dat_flit_t expected[NUM_VC][$];

    tx_credit_buffer #(.NUM_DAT_VC(NUM_VC), .DAT_VC_MASK('1), .CREDIT_DEPTH(2)) tx (
        .clk_i(clk), .rst_n_i(rst_n),
        .s_ctrl_i('0), .s_ctrl_valid_i(1'b0), .s_ctrl_ready_o(),
        .m_ctrl_o(), .m_ctrl_valid_o(), .m_ctrl_ready_i(1'b1),
        .s_dat_i(source), .s_dat_valid_i(source_valid), .dat_ready_o(source_ready),
        .m_dat_o(tx_data), .m_dat_valid_o(tx_valid), .m_dat_ready_i(tx_ready),
        .credit_i           (credit)
    );
    tx_vc_arbiter #(.NUM_DAT_VC(NUM_VC), .DAT_VC_MASK('1)) arb (
        .clk_i(clk), .rst_n_i(rst_n), .s_dat_i(tx_data),
        .s_dat_valid_i(tx_valid), .s_dat_ready_o(tx_ready),
        .m_dat_o(link), .m_dat_valid_o(link_valid), .m_dat_ready_i(link_ready & link_enable)
    );
    rx_credit_buffer #(.NUM_DAT_VC(NUM_VC), .DAT_VC_MASK('1), .CREDIT_DEPTH(2), .DAT_CH_MASK('1)) rx (
        .clk_i(clk), .rst_n_i(rst_n),
        .s_ctrl_i('0), .s_ctrl_valid_i(1'b0), .s_ctrl_ready_o(),
        .m_ctrl_o(), .m_ctrl_valid_o(), .m_ctrl_ready_i(1'b1),
        .s_dat_i(link), .s_dat_valid_i(link_valid & link_enable), .s_dat_ready_o(link_ready),
        .credit_o           (credit), .m_dat_o(rx_data),
        .m_dat_valid_o(rx_valid), .m_dat_ready_i(consume)
    );
    assert property (@(posedge clk) disable iff (!rst_n)
        ((|link_valid) && !(|(link_valid & link_ready & link_enable))) |=>
        $stable({link_valid, link})) else $fatal(1, "DAT changed under ready stall");
    always @(posedge clk) begin
        if (!rst_n) begin
            foreach (balance[vc]) balance[vc] = 2;
        end else begin
            if (!$onehot0(link_valid)) $fatal(1, "More than one VC selected");
            if (|link_valid && !(|(link_valid & link_ready & link_enable))) stalled++;
            foreach (balance[vc]) begin
                bit take;
                take = link_valid[vc] && link_ready[vc] && link_enable[vc];
                if (source_valid && source_ready[vc] && source.header[VC_ID_LSB +: VC_ID_WIDTH] == vc)
                    expected[vc].push_back(source);
                if (take) sent[vc]++;
                if (balance[vc] == 0) exhausted++;
                if (credit[vc] && take) simultaneous++;
                balance[vc] += int'(credit[vc]) - int'(take);
                if (balance[vc] < 0 || balance[vc] > 2) $fatal(1, "Invalid credit balance");
                if (rx_valid[vc] && consume[vc]) begin
                    dat_flit_t exp;
                    if (expected[vc].size() == 0) $fatal(1, "Unexpected DAT flit");
                    exp = expected[vc].pop_front();
                    if (rx_data[vc] !== exp) $fatal(1, "DAT payload/order mismatch");
                    received[vc]++;
                end
            end
        end
    end
    task automatic send(input int vc, input int value);
        @(negedge clk);
        while (!source_ready[vc]) @(negedge clk);
        source = '0;
        source.header[VC_ID_LSB +: VC_ID_WIDTH] = VC_ID_WIDTH'(vc);
        source.payload = value;
        source_valid = 1;
        @(negedge clk);
        source_valid = 0;
    endtask
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        // A new competing VC must not replace the stalled selection.
        send(1, 1);
        send(0, 2);
        repeat (4) @(negedge clk);
        link_enable = '1;
        send(0, 3);
        send(1, 4);
        repeat (8) @(negedge clk);
        fork
            begin
                for (int i = 0; i < 16; i++) send(i % NUM_VC, i + 5);
            end
            begin
                repeat (4) @(negedge clk);
                consume = '1;
            end
        join
        repeat (12) @(negedge clk);
        foreach (received[vc]) begin
            if (received[vc] != 10 || sent[vc] != 10 || balance[vc] != 2 || expected[vc].size())
                $fatal(1, "DAT transfer count or credit recovery mismatch");
        end
        if (!stalled || !exhausted || !simultaneous) $fatal(1, "Missing handshake/credit scenario");
        $display("DAT_CREDIT_LINK_PASS stalled=%0d exhausted=%0d simultaneous=%0d", stalled, exhausted, simultaneous);
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "DAT link timeout");
    end
endmodule
