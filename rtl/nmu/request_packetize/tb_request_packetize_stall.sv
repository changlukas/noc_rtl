`timescale 1ns / 1ps
`default_nettype none

module tb_nmu_request_packetize_stall;

    localparam int unsigned NUM_DAT_VC = 2;
    localparam int unsigned CREDIT_DEPTH = 2;

    logic clk = 1'b0;
    logic rst_n_i = 1'b0;
    ni_types_pkg::nmu_aw_request_t                  s_aw;
    logic                                           s_aw_valid, s_aw_ready;
    ni_signals_pkg::noc_axi_w_t                         s_w;
    logic                                           s_w_valid, s_w_ready;
    ni_types_pkg::nmu_ar_request_t                  s_ar;
    logic                                           s_ar_valid, s_ar_ready;
    noc_payload_pkg::req_flit_t                         m_req;
    logic                                           m_req_valid, m_req_ready;
    noc_payload_pkg::dat_flit_t                         m_dat;
    logic                                           m_dat_valid;
    logic                          [NUM_DAT_VC-1:0] dat_credit_return;

    always #5 clk = ~clk;

    nmu_request_inject_tb_dut #(
        .FIFO_DEPTH      (4              ),
        .NUM_DAT_VC      (NUM_DAT_VC     ),
        .CREDIT_DEPTH (CREDIT_DEPTH),
        .SRC_ID          (8'h12          ),
        .SRC_PORT_ID     (2'h2           )
    ) dut (
        .clk_i               (clk              ),
        .rst_n_i             (rst_n_i          ),
        .s_aw_i              (s_aw             ),
        .s_aw_valid_i        (s_aw_valid       ),
        .s_aw_ready_o        (s_aw_ready       ),
        .s_w_i               (s_w              ),
        .s_w_valid_i         (s_w_valid        ),
        .s_w_ready_o         (s_w_ready        ),
        .s_ar_i              (s_ar             ),
        .s_ar_valid_i        (s_ar_valid       ),
        .s_ar_ready_o        (s_ar_ready       ),
        .m_req_o             (m_req            ),
        .m_req_valid_o       (m_req_valid      ),
        .m_req_ready_i       (m_req_ready      ),
        .m_dat_o             (m_dat            ),
        .m_dat_valid_o       (m_dat_valid      ),
        .credit_i            (dat_credit_return)
    );

    task automatic push_aw(input logic is_data, input logic [7:0] dst,
                           input logic [2:0] id, input logic [47:0] addr);
        s_aw                   = '0;
        s_aw.axi.awid          = id;
        s_aw.axi.awaddr        = addr;
        s_aw.axi.awsize        = is_data ? 3'd6 : 3'd3;
        s_aw.axi.awburst       = 2'b01;
        s_aw.axi.awuser        = noc_payload_pkg::AXI_AWUSER_WIDTH'(8'h5a);
        s_aw.packet_info.route.domain = '{dst_id: dst, dst_port_id: 2'h1, packet_type: is_data ? noc_header_pkg::PKT_DATA_AW : noc_header_pkg::PKT_NARROW_AW};
        s_aw.user              = 8'h5a;
        s_aw_valid             = 1'b1;
        do @(posedge clk); while (!s_aw_ready);
        @(negedge clk);
        s_aw_valid = 1'b0;
    endtask

    task automatic push_w(input logic [511:0] data);
        s_w       = '0;
        s_w.wdata = data;
        s_w.wstrb = '1;
        s_w.wlast = 1'b1;
        s_w_valid = 1'b1;
        do @(posedge clk); while (!s_w_ready);
        @(negedge clk);
        s_w_valid = 1'b0;
    endtask


    int dat_count = 0;
    always @(posedge clk) begin
        if (!rst_n_i) dat_count = 0;
        else if (m_dat_valid) begin
            if (int'(m_dat.header.packet_type) !=
                    (dat_count == 0 ? noc_header_pkg::PKT_DATA_AW : noc_header_pkg::PKT_DATA_W))
                $fatal(1, "post-reset DAT order mismatch");
            dat_count++;
        end
    end
    noc_payload_pkg::req_flit_t held_req;
    always @(negedge rst_n_i) begin
        #1ps;
        if ({dut.i_request_dispatch.req_write_lock_reg,
             dut.i_request_dispatch.dat_write_lock_reg} !== '0 ||
            dut.i_write_context.active_reg !== 1'b0)
            $fatal(1, "Request state did not reset asynchronously");
    end
    always @(negedge rst_n_i) begin : check_credit_reset
        #1ps;
        if (int'(dut.i_tx_credit_buffer.gen_dat_vc[noc_unit_params_pkg::DAT_WRITE_VC].gen_active.i_credit.credit_o) !== CREDIT_DEPTH)
            $fatal(1, "DAT credits did not reset asynchronously");
    end

    initial begin
        s_aw='0; s_w='0; s_ar='0;
        s_aw_valid=0; s_w_valid=0; s_ar_valid=0;
        m_req_ready=0; dat_credit_return='0;
        repeat (3) @(negedge clk);
        rst_n_i = 1;
        s_ar.axi.arid=3;
        s_ar.packet_info.route.domain.dst_id=8'h43;
        s_ar.packet_info.route.domain.packet_type = noc_header_pkg::PKT_NARROW_AR;
        s_ar_valid=1;
        @(posedge clk); @(negedge clk); s_ar_valid=0;
        #1;
        if (!m_req_valid) $fatal(1,"setup failed: AR absent");
        held_req=m_req;
        @(negedge clk);
        push_aw(0,8'h21,1,48'h18);
        push_w(512'h1234);
        #1;
        if (!m_req_valid || m_req !== held_req) begin
            $display("REPRO_FAIL REQ changed while valid=1 ready=0: channel %0d -> %0d",held_req.header.packet_type,m_req.header.packet_type);
            $fatal(1,"stalled REQ payload changed");
        end
        // Release the held AR and require exactly the queued AW/W afterward.
        m_req_ready = 1;
        @(posedge clk); #1;
        if (!m_req_valid || int'(m_req.header.packet_type) != noc_header_pkg::PKT_NARROW_AW)
            $fatal(1, "held AR did not retire before queued AW");
        @(posedge clk); #1;
        if (!m_req_valid || int'(m_req.header.packet_type) != noc_header_pkg::PKT_NARROW_W)
            $fatal(1, "queued W did not follow its AW");
        @(posedge clk); #1;
        if (m_req_valid) $fatal(1, "REQ duplicated a queued transaction");

        // Exercise the opposite selection: an AR arrives behind a stalled AW.
        @(negedge clk); m_req_ready = 0;
        push_aw(0, 8'h21, 1, 48'h18);
        push_w(512'h5678);
        #1; held_req = m_req;
        if (!m_req_valid) $fatal(1, "AW hold setup failed");
        @(negedge clk); s_ar_valid = 1;
        @(posedge clk); @(negedge clk); s_ar_valid = 0;
        #1;
        if (!m_req_valid || m_req !== held_req) $fatal(1, "stalled AW changed to AR");

        // Flush occupied primitive FIFOs and the active selection together.
        @(negedge clk); rst_n_i = 0;
        repeat (2) @(negedge clk);
        rst_n_i = 1;
        #1;
        if (m_req_valid || m_dat_valid) $fatal(1, "reset retained queued traffic");
        push_aw(1, 8'h32, 2, 48'h1000);
        push_w(512'hfeed);
        repeat (3) @(negedge clk);
        if (dat_count != 2 || m_dat_valid || m_req_valid)
            $fatal(1, "reset did not drain exactly one DAT write");
        $display("PASS: REQ selection holds both winners, drains exactly, and flushes on reset");
        $finish;
    end
    initial begin #10000; $fatal(1,"timeout"); end
endmodule
