`timescale 1ns / 1ps
`default_nettype none

module tb_nmu_request_packetize;


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
    logic                                           m_dat_valid, m_dat_ready;

    always #5 clk = ~clk;

    nmu_request_inject_tb_dut #(
        .REQ_AW_REG_TYPE (1),
        .REQ_W_REG_TYPE  (1),
        .REQ_AR_REG_TYPE (1),
        .DAT_AW_REG_TYPE (1),
        .DAT_W_REG_TYPE  (1),
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
        .m_dat_ready_i       (m_dat_ready      )
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
        if (rst_n_i && m_dat_valid && m_dat_ready) begin
            if (dat_count % 2 == 0) begin
                if (m_dat.header.packet_type != noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_DATA_AW) ||
                        m_dat.header[(noc_header_pkg::DST_ID_LSB + ni_types_pkg::NODE_ID_W - 1):noc_header_pkg::DST_ID_LSB] != 8'h32)
                    $fatal(1, "DAT AW mismatch");
            end else begin
                if (m_dat.header.packet_type != noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_DATA_W) ||
                        m_dat.payload[(noc_payload_pkg::DATA_W_WDATA_LSB + noc_payload_pkg::DATA_W_WDATA_WIDTH - 1):noc_payload_pkg::DATA_W_WDATA_LSB] != (dat_count == 1 ? 512'hfeed_face : 512'h1234_5678) ||
                        !m_dat.header.flit_tail)
                    $fatal(1, "DAT W mismatch");
            end
            dat_count++;
        end
    end
    initial begin
        logic [511:0] narrow_data;
        s_aw              = '0;
        s_w               = '0;
        s_ar              = '0;
        s_aw_valid        = 1'b0;
        s_w_valid         = 1'b0;
        s_ar_valid        = 1'b0;
        m_req_ready       = 1'b0;
        m_dat_ready = 1'b0;
        repeat (3) @(posedge clk);
        rst_n_i = 1'b1;
        @(negedge clk);

        // Queue one write for each physical network.  REQ is stalled until
        // both are ready, proving the two schedulers can transfer together.
        push_aw(1'b0, 8'h21, 3'h1, 48'h18);
        narrow_data             = '0;
        narrow_data[3*64 +: 64] = 64'h0123_4567_89ab_cdef;
        push_w(narrow_data);
        push_aw(1'b1, 8'h32, 3'h2, 48'h1000);
        push_w(512'hfeed_face);

        m_req_ready = 1'b1;
        m_dat_ready = 1'b1;
        #1;
        assert (m_req_valid && m_dat_valid)
            else $fatal(1, "REQ and DAT AW were not independently available");
        assert (m_req.header.packet_type ==
                noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_NARROW_AW));
        assert (m_req.header[(noc_header_pkg::SRC_ID_LSB + ni_types_pkg::NODE_ID_W - 1):noc_header_pkg::SRC_ID_LSB] == 8'h12);
        @(posedge clk);
        #1;
        assert (m_req_valid && m_dat_valid)
            else $fatal(1, "REQ and DAT W did not transfer in parallel");
        assert (m_req.header.packet_type ==
                noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_NARROW_W));
        assert (m_req.payload[(noc_payload_pkg::NARROW_W_WDATA_LSB + noc_payload_pkg::NARROW_W_WDATA_WIDTH - 1):
                              noc_payload_pkg::NARROW_W_WDATA_LSB] ==
                64'h0123_4567_89ab_cdef)
            else $fatal(1, "narrow W did not extract the AW-addressed lane");
        assert (m_req.header.flit_tail);
        @(posedge clk);

        // A Data-class AR always rides REQ and is a single-flit packet.
        s_ar                   = '0;
        s_ar.axi.arid          = 3'h3;
        s_ar.axi.araddr        = 48'h2000;
        s_ar.packet_info.route.domain = '{dst_id: 8'h43, dst_port_id: 2'h3, packet_type: noc_header_pkg::PKT_DATA_AR};
        s_ar_valid             = 1'b1;
        do @(posedge clk); while (!s_ar_ready);
        @(negedge clk);
        s_ar_valid = 1'b0;
        #1;
        assert (m_req_valid);
        assert (m_req.header.packet_type ==
                noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_DATA_AR));
        assert (m_req.header.flit_tail);
        @(posedge clk);

        // Hold AW and W independently on the scalar DAT output.
        @(negedge clk);
        m_dat_ready = 0;
        push_aw(1'b1, 8'h32, 3'h2, 48'h1080);
        push_w(512'h1234_5678);
        repeat (3) @(negedge clk);
        if (!m_dat_valid || dat_count != 2 ||
            m_dat.header.packet_type != noc_header_pkg::PKT_DATA_AW)
            $fatal(1, "DAT AW did not remain pending while stalled");
        m_dat_ready = 1;
        @(negedge clk); m_dat_ready = 0;
        repeat (3) @(negedge clk);
        if (!m_dat_valid || dat_count != 3 ||
            m_dat.header.packet_type != noc_header_pkg::PKT_DATA_W)
            $fatal(1, "DAT W did not remain pending while stalled");
        m_dat_ready = 1;
        @(negedge clk);
        if (dat_count != 4) $fatal(1, "DAT transfer count mismatch");
        $display("PASS: NMU request packetization and independent REQ/DAT scheduling");
        $finish;
    end
    initial begin #100us; $fatal(1, "packetization timeout"); end

endmodule

`default_nettype wire
