// SPDX-License-Identifier: Apache-2.0
`resetall
`timescale 1ns / 1ps
`default_nettype none

module tb_nsu_elaborate;
    import ni_flit_pkg::*;
    logic clk = 0, noc_clk = 0, reset_n = 0;
    wire rst_n, noc_rst_n;
    always #5 clk = ~clk;
    always #7 noc_clk = ~noc_clk;
    cc_rstgen_bypass #(.NumRegs(2)) i_axi_reset (
        .clk_i       (clk), .rst_ni(reset_n), .rst_test_mode_ni(reset_n),
        .test_mode_i (1'b0), .rst_no(rst_n), .init_no(                 )
    );
    cc_rstgen_bypass #(.NumRegs(2)) i_noc_reset (
        .clk_i       (noc_clk), .rst_ni(reset_n), .rst_test_mode_ni(reset_n),
        .test_mode_i (1'b0), .rst_no(noc_rst_n), .init_no(                 )
    );
    req_flit_t req = '0;
    rsp_flit_t rsp;
    logic req_valid = 0, rsp_ready = 0;
    wire req_ready, rsp_valid;
    logic aw_ready = 0, w_ready = 0, b_valid = 0;
    logic [ni_params_pkg::NSU_AXI_ID_WIDTH-1:0] device_id = '0;
    axi_if #(.ID_W(ni_params_pkg::NSU_AXI_ID_WIDTH), .ADDR_W(ni_params_pkg::AXI_ADDR_WIDTH),
        .DATA_W(ni_params_pkg::AXI_DATA_WIDTH), .AWUSER_W(ni_flit_pkg::AXI_USER_WIDTH)) bus();
    assign bus.awready = aw_ready;
    assign bus.wready  = w_ready;
    assign bus.arready = 1'b1;
    assign bus.bvalid  = b_valid;
    assign bus.bid     = device_id;
    assign bus.bresp   = '0;
    assign bus.buser   = '0;
    assign bus.rvalid  = 1'b0;
    assign bus.rid     = '0;
    assign bus.rdata   = '0;
    assign bus.rresp   = '0;
    assign bus.rlast   = 1'b0;
    assign bus.ruser   = '0;
    localparam topology_pkg::sam_rule_t [0:0] TEST_SAM = '{
        0: '{idx: '{dst_id: 8'h23, dst_port_id: '0, is_data: 1'b0, collective_en: 1'b1,
                   mask_x: '{offset: 6'd8, len: 6'd4}, mask_y: '{offset: 6'd12, len: 6'd4}},
             start_addr: 48'h0, end_addr: 48'h10000}
    };
    nsu #(
        .AXI_FIFO_DEPTH (4), .AW_CONTEXT_DEPTH(3), .AR_CONTEXT_DEPTH(3),
        .SAM_NUM_RULES  (1), .SAM(TEST_SAM), .SRC_ID(8'h23            )
    ) dut (
        .ACLK              (clk      ),
        .ARESETn           (rst_n    ),
        .noc_clk           (noc_clk  ),
        .noc_rst_n         (noc_rst_n),
        .axi_wr_o          (bus      ),
        .axi_rd_o          (bus      ),
        .rx_req_valid_i    (req_valid),
        .rx_req_flit_i     (req      ),
        .rx_req_ready_o    (req_ready),
        .rx_dat_valid_i    (1'b0     ),
        .rx_dat_flit_i     ('0       ),
        .rx_dat_crdvalid_o (         ),
        .tx_rsp_valid_o    (rsp_valid),
        .tx_rsp_flit_o     (rsp      ),
        .tx_rsp_ready_i    (rsp_ready),
        .tx_dat_valid_o    (         ),
        .tx_dat_flit_o     (         ),
        .tx_dat_crdvalid_i ('0       )
    );
    task automatic send_req(input req_flit_t flit);
        @(negedge noc_clk); req = flit; req_valid = 1;
        do @(posedge noc_clk); while (!req_ready);
        @(negedge noc_clk); req_valid = 0;
    endtask
    initial begin
        req_flit_t aw, w;
        rsp_flit_t held_rsp;
        aw = '0; w = '0;
        aw.header[AXI_CH_LSB +: AXI_CH_WIDTH] = AXI_CH_WIDTH'(AXI_CH_NarrowAw);
        aw.header[SRC_ID_LSB +: SRC_ID_WIDTH] = 'h31;
        aw.header[SRC_PORT_ID_LSB +: SRC_PORT_ID_WIDTH] = 2;
        aw.header[ORDERING_REQ_LSB] = 1;
        aw.header[ORDERING_TAG_LSB +: ORDERING_TAG_WIDTH] = 9;
        aw.payload[AW_AWID_LSB +: AW_AWID_WIDTH] = 5;
        aw.payload[AW_AWADDR_LSB +: AW_AWADDR_WIDTH] = 'h18;
        aw.payload[AW_AWSIZE_LSB +: AW_AWSIZE_WIDTH] = 3;
        aw.payload[AW_AWBURST_LSB +: AW_AWBURST_WIDTH] = 1;
        aw.payload[AW_AWUSER_LSB +: AW_AWUSER_WIDTH] = 'ha5;
        w.header[AXI_CH_LSB +: AXI_CH_WIDTH] = AXI_CH_WIDTH'(AXI_CH_NarrowW);
        w.header[FLIT_TAIL_LSB] = 1;
        w.payload[NARROW_W_WDATA_LSB +: NARROW_W_WDATA_WIDTH] = 64'h1234_5678_9abc_def0;
        w.payload[NARROW_W_WSTRB_LSB +: NARROW_W_WSTRB_WIDTH] = 'h5a;
        w.payload[NARROW_W_WLAST_LSB] = 1;
        repeat (5) @(negedge clk); reset_n = 1;
        wait (rst_n && noc_rst_n);
        for (int collective = 0; collective < 2; collective++) begin
            aw.payload[AW_AWADDR_LSB +: AW_AWADDR_WIDTH] = (collective != 0) ? 'hf018 : 'h18;
            aw.header[COLLECTIVE_OP_LSB +: COLLECTIVE_OP_WIDTH] = COLLECTIVE_OP_WIDTH'(collective);
            aw.header[COLLECTIVE_MASK_LSB +: COLLECTIVE_MASK_WIDTH] = (collective != 0) ? 'ha5 : '0;
            rsp_ready = 0;
            send_req(aw); send_req(w);
            wait (bus.wvalid);
            repeat (4) begin
                @(negedge clk);
                if (!bus.awvalid || bus.awaddr !== ((collective != 0) ? 48'h2318 : 48'h18) || bus.awuser !== 8'ha5 ||
                        !bus.wvalid || !bus.wlast || bus.wdata !== (512'h1234_5678_9abc_def0 << 192) ||
                        bus.wstrb !== (64'h5a << 24))
                    $fatal(1, "NSU AW/W CDC, lane or held-valid mismatch");
            end
            device_id = bus.awid;
            w_ready   = 1;
            @(negedge clk); w_ready = 0;
            if (!bus.awvalid) $fatal(1, "AW incorrectly consumed before handshake");
            aw_ready = 1;
            @(negedge clk); aw_ready = 0; b_valid = 1;
            do @(posedge clk); while (!bus.bready);
            @(negedge clk); b_valid = 0;
            wait (rsp_valid);
            @(negedge noc_clk); held_rsp = rsp;
            repeat (3) begin
                @(negedge noc_clk);
                if (!rsp_valid || rsp !== held_rsp) $fatal(1, "NSU stalled RSP changed");
            end
            if (rsp.header[DST_ID_LSB +: DST_ID_WIDTH] !== 8'h31 ||
                    rsp.header[DST_PORT_ID_LSB +: DST_PORT_ID_WIDTH] != 2 ||
                    !rsp.header[ORDERING_REQ_LSB] ||
                    rsp.header[ORDERING_TAG_LSB +: ORDERING_TAG_WIDTH] != 9 ||
                    rsp.payload[B_BID_LSB +: B_BID_WIDTH] != 5 ||
                    rsp.header[COLLECTIVE_OP_LSB +: COLLECTIVE_OP_WIDTH] != COLLECTIVE_OP_WIDTH'(collective) ||
                    rsp.header[COLLECTIVE_MASK_LSB +: COLLECTIVE_MASK_WIDTH] != ((collective != 0) ? 8'ha5 : 8'h0))
                $fatal(1, "NSU B identity/order restoration");
            rsp_ready = 1;
            @(negedge noc_clk);
        end
        $display("NSU_REQUEST_PASS axi_period=10 noc_period=14 W_before_AW=1 lane=3 multicast_address=1");
        $finish;
    end
    initial begin #20000; $fatal(1, "NSU request timeout"); end
endmodule

`resetall
