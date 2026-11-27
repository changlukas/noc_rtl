`timescale 1ns / 1ps

module tb_nmu_response_depacketize #(
    parameter int REG_TYPE = 0
);
    import ni_types_pkg::*;
    logic clk = 0, rst_n_i = 0;
    always #5 clk = ~clk;

    noc_payload_pkg::rsp_flit_t rsp;
    noc_payload_pkg::dat_flit_t dat;
    logic rsp_valid = 0, rsp_ready, dat_valid = 0, dat_ready;
    nmu_b_response_t b, held_b;
    nmu_r_response_t r, held_r;
    logic b_valid, r_valid, b_ready = 1, r_ready = 0;
    localparam int WIDE = 0, NARROW = 1;
    int received[2], accepted[2], accepted_b, received_b;
    bit held, b_held;
    noc_payload_pkg::rsp_flit_t buffered_b;
    noc_payload_pkg::dat_flit_t buffered_r;
    wire buffered_b_valid, buffered_b_ready, buffered_r_valid, buffered_r_ready;
    wire noc_payload_pkg::rsp_flit_t selected_rsp;
    wire selected_rsp_valid, selected_rsp_ready;
    wire noc_payload_pkg::dat_flit_t selected_dat;
    wire selected_dat_valid, selected_dat_ready;
    nmu_read_response_arbiter i_read_response_arbiter (
        .s_rsp_i       (rsp       ),
        .s_rsp_valid_i (rsp_valid      ),
        .s_rsp_ready_o (rsp_ready      ),
        .m_rsp_o       (selected_rsp      ),
        .m_rsp_valid_o (selected_rsp_valid),
        .m_rsp_ready_i (selected_rsp_ready),
        .clk_i         (clk               ),
        .rst_n_i       (rst_n_i           ),
        .s_dat_i       (dat       ),
        .s_dat_valid_i (dat_valid      ),
        .s_dat_ready_o (dat_ready      ),
        .m_dat_o       (selected_dat      ),
        .m_dat_valid_o (selected_dat_valid),
        .m_dat_ready_i (selected_dat_ready)
    );
    nmu_response_dispatch i_response_dispatch (
        .s_rsp_i       (selected_rsp      ),
        .s_rsp_valid_i (selected_rsp_valid),
        .s_rsp_ready_o (selected_rsp_ready),
        .s_dat_i       (selected_dat      ),
        .s_dat_valid_i (selected_dat_valid),
        .s_dat_ready_o (selected_dat_ready),
        .m_b_o         (buffered_b        ),
        .m_b_valid_o   (buffered_b_valid  ),
        .m_b_ready_i   (buffered_b_ready  ),
        .m_r_o         (buffered_r        ),
        .m_r_valid_o   (buffered_r_valid  ),
        .m_r_ready_i   (buffered_r_ready  )
    );
    nmu_response_depacketize #(
        .B_REG_TYPE (REG_TYPE),
        .R_REG_TYPE (REG_TYPE)
    ) dut (
        .clk_i (clk), .rst_n_i (rst_n_i                                                     ),
        .s_b_i (buffered_b), .s_b_valid_i (buffered_b_valid), .s_b_ready_o (buffered_b_ready),
        .s_r_i (buffered_r), .s_r_valid_i (buffered_r_valid), .s_r_ready_o (buffered_r_ready),
        .m_b_o (b), .m_b_valid_o (b_valid), .m_b_ready_i (b_ready                           ),
        .m_r_o (r), .m_r_valid_o (r_valid), .m_r_ready_i (r_ready                           )
    );

    function automatic nmu_r_response_t expected(input int source, input int seq);
        nmu_r_response_t value;
        value           = '0;
        value.axi.rid   = noc_payload_pkg::DATA_R_RID_WIDTH'(source);
        value.axi.rresp = 2'(seq % 3);
        value.axi.rlast = seq % 3 == 2;
        value.axi.rdata = '0;
        for (int lane = 0; lane < (source == NARROW ? 2 : 16); lane++)
            value.axi.rdata[lane*32 +: 32] = 32'(seq + lane*1024 + source*65536);
        value.packet_info.packet_type = noc_header_pkg::packet_type_t'(source != NARROW ?
            noc_header_pkg::PKT_DATA_R : noc_header_pkg::PKT_NARROW_R);
        value.packet_info.ordering_req = 1;
        value.packet_info.ordering_tag = noc_header_pkg::ORD_TAG_WIDTH'(seq);
        return value;
    endfunction

    task automatic set_dat();
        nmu_r_response_t value;
        value                                               = expected(WIDE, accepted[WIDE]);
        dat                                                 = '0;
        dat.header.packet_type = noc_header_pkg::packet_type_t'(noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_DATA_R));
        dat.header.flit_tail                           = 1;
        dat.header.ord_req                        = value.packet_info.ordering_req;
        dat.header.ord_tag  = value.packet_info.ordering_tag;
        dat.payload[noc_payload_pkg::DATA_R_RID_LSB +: noc_payload_pkg::DATA_R_RID_WIDTH]     = value.axi.rid;
        dat.payload[noc_payload_pkg::DATA_R_RRESP_LSB +: noc_payload_pkg::DATA_R_RRESP_WIDTH] = value.axi.rresp;
        dat.payload[noc_payload_pkg::DATA_R_RLAST_LSB]                       = value.axi.rlast;
        dat.payload[noc_payload_pkg::DATA_R_RDATA_LSB +: noc_payload_pkg::DATA_R_RDATA_WIDTH] = value.axi.rdata;
        dat_valid                                           = 1;
    endtask

    task automatic set_rsp(input bit read_rsp);
        nmu_r_response_t value;
        value                                              = expected(NARROW, accepted[NARROW]);
        rsp                                                = '0;
        rsp.header.packet_type = noc_header_pkg::packet_type_t'(noc_header_pkg::PACKET_TYPE_WIDTH'(read_rsp ? noc_header_pkg::PKT_NARROW_R : noc_header_pkg::PKT_DATA_B));
        rsp.header.ord_req                       = 1;
        rsp.header.ord_tag = value.packet_info.ordering_tag;
        if (read_rsp) begin
            rsp.payload[noc_payload_pkg::NARROW_R_RID_LSB +: noc_payload_pkg::NARROW_R_RID_WIDTH]     = value.axi.rid;
            rsp.payload[noc_payload_pkg::NARROW_R_RRESP_LSB +: noc_payload_pkg::NARROW_R_RRESP_WIDTH] = value.axi.rresp;
            rsp.payload[noc_payload_pkg::NARROW_R_RLAST_LSB]                         = value.axi.rlast;
            rsp.payload[noc_payload_pkg::NARROW_R_RDATA_LSB +: noc_payload_pkg::NARROW_R_RDATA_WIDTH] = value.axi.rdata[63:0];
        end else begin
            rsp.payload[noc_payload_pkg::B_BID_LSB +: noc_payload_pkg::B_BID_WIDTH]     = 3;
            rsp.payload[noc_payload_pkg::B_BRESP_LSB +: noc_payload_pkg::B_BRESP_WIDTH] = 2;
        end
        rsp_valid = 1;
    endtask

    always @(posedge clk) begin
        int source;
        if (!rst_n_i) begin
            held = 0;
            b_held = 0;
            foreach (accepted[i]) begin
                accepted[i] = 0;
                received[i] = 0;
            end
            accepted_b = 0;
            received_b = 0;
        end else begin
            if (dat_valid && dat_ready) accepted[WIDE]++;
            if (rsp_valid && rsp_ready) begin
                if (rsp.header.packet_type == noc_header_pkg::PKT_NARROW_R) accepted[NARROW]++;
                else accepted_b++;
            end
            if (b_held && (!b_valid || b !== held_b)) $fatal(1, "stalled B changed");
            b_held = b_valid && !b_ready;
            held_b = b;
            if (held && (!r_valid || r !== held_r)) $fatal(1, "stalled R changed");
            held = r_valid && !r_ready;
            held_r = r;
            if (r_valid && r_ready) begin
                source = r.packet_info.packet_type == noc_header_pkg::PKT_DATA_R ? WIDE : NARROW;
                if (received[source] >= accepted[source] || r !== expected(source, received[source]))
                    $fatal(1, "R mismatch source=%0d seq=%0d", source, received[source]);
                received[source]++;
            end
            if (b_valid && b_ready) begin
                if (received_b >= accepted_b || b.axi.bid != 3 || b.axi.bresp != 2 ||
                    b.packet_info.packet_type != noc_header_pkg::PKT_DATA_B || !b.packet_info.ordering_req)
                    $fatal(1, "B decode mismatch");
                received_b++;
            end
        end
    end

    initial begin : stimulus
        int issued_wide, issued_narrow;
        dat = '0;
        rsp = '0;
        repeat (3) @(negedge clk);
        rst_n_i = 1;

        // A stalled R must leave the B path available.
        set_dat();
        set_rsp(0);
        @(negedge clk);
        rsp_valid = 0;
        if (accepted[WIDE]) dat_valid = 0;
        repeat (4) @(negedge clk);
        if (!held || received_b != 1 || received[WIDE] != 0)
            $fatal(1, "independent B transfer or R stall was not exercised");
        r_ready = 1;
        @(negedge clk);
        dat_valid = 0;
        repeat (3) @(negedge clk);
        if (received[WIDE] != 1) $fatal(1, "stalled R did not recover");

        // A stalled B must also leave the independent DAT read path available.
        b_ready = 0;
        set_rsp(0);
        set_dat();
        @(negedge clk);
        dat_valid = 0;
        if (accepted_b == 2) rsp_valid = 0;
        repeat (4) @(negedge clk);
        if (!b_held || received_b != 1 || received[WIDE] != 2)
            $fatal(1, "independent DAT transfer or B stall was not exercised");
        b_ready = 1;
        @(negedge clk);
        rsp_valid = 0;
        repeat (3) @(negedge clk);
        if (received_b != 2) $fatal(1, "stalled B did not recover");

        // Keep both read sources valid until each has sent 32 distinct beats.
        issued_wide = accepted[WIDE];
        issued_narrow = accepted[NARROW];
        repeat (64) begin
            if (accepted[WIDE] < issued_wide + 32) set_dat(); else dat_valid = 0;
            if (accepted[NARROW] < issued_narrow + 32) set_rsp(1); else rsp_valid = 0;
            @(negedge clk);
            if (accepted[WIDE] - issued_wide > accepted[NARROW] - issued_narrow + 1 ||
                accepted[NARROW] - issued_narrow > accepted[WIDE] - issued_wide + 1)
                $fatal(1, "read sources did not alternate");
        end
        dat_valid = 0;
        rsp_valid = 0;
        repeat (3) @(negedge clk);
        if (received[WIDE] != issued_wide + 32 || received[NARROW] != issued_narrow + 32)
            $fatal(1, "read stream lost a beat or inserted a bubble");

        // Clear the held grant and any registered output, then send a fresh beat.
        r_ready = 0;
        set_dat();
        @(negedge clk);
        rst_n_i = 0;
        dat_valid = 0;
        repeat (2) @(negedge clk);
        rst_n_i = 1;
        r_ready = 1;
        if (r_valid) $fatal(1, "reset retained R");
        set_dat();
        @(negedge clk);
        dat_valid = 0;
        repeat (3) @(negedge clk);
        if (received[WIDE] != 1) $fatal(1, "post-reset transfer failed");
        $display("PASS depacketize REG_TYPE=%0d", REG_TYPE);
        $finish;
    end
`ifdef DUMP_WAVE
    initial begin
        string wave_file;
        if (!$value$plusargs("wave_file=%s", wave_file)) wave_file = "dat_ingress.fsdb";
`ifdef VERILATOR
        $dumpfile(wave_file); $dumpvars(0, tb_nmu_response_depacketize);
`else
        $fsdbDumpfile(wave_file); $fsdbDumpvars(0, tb_nmu_response_depacketize, "+all");
`endif
    end
`endif
    initial begin #100us; $fatal(1, "depacketize timeout"); end
endmodule
