`timescale 1ns / 1ps

module tb_nmu_response_depacketize #(
    parameter int NUM_DAT_VC   = 2,
    localparam int unsigned DAT_VC_MODE  = (NUM_DAT_VC > 1),
    parameter int CREDIT_DEPTH = 2,
    parameter int REG_TYPE     = 0
);
    import ni_types_pkg::*;
    localparam int FIRST_VC = DAT_VC_MODE == 1 ? NUM_DAT_VC/2 : 0;
    logic clk = 0, rst_n_i = 0;
    always #5 clk = ~clk;
    noc_payload_pkg::rsp_flit_t rsp;
    noc_payload_pkg::dat_flit_t dat;
    logic rsp_valid = 0, rsp_ready, dat_valid = 0;
    logic            [NUM_DAT_VC-1:0] credit_return;
    nmu_b_response_t                  b;
    nmu_r_response_t                  r;
    logic b_valid, r_valid, b_ready = 1, r_ready = 0;
    int wr_cnt [NUM_DAT_VC+1], rd_cnt [NUM_DAT_VC+1];
    int credit [NUM_DAT_VC];
    int fifo_rd_cnt [NUM_DAT_VC];
    int total_r = 0, total_b = 0, recoveries = 0, parallel_ingress = 0;
    logic [NUM_DAT_VC-1:0] expected_credit = '0;
    nmu_r_response_t held_r;
    bit held = 0;
    int rr_checks = 0;
    int grant_wait [NUM_DAT_VC+1];
    int fault = 0;
    initial void'($value$plusargs("fault=%d", fault));

    noc_payload_pkg::rsp_flit_t buffered_b;
    noc_payload_pkg::dat_flit_t buffered_r;
    wire buffered_b_valid, buffered_b_ready, buffered_r_valid, buffered_r_ready;
    wire noc_payload_pkg::rsp_flit_t rx_rsp_head;
    wire noc_payload_pkg::dat_flit_t [NUM_DAT_VC-1:0] rx_dat_head;
    wire rx_rsp_valid, rx_rsp_ready;
    wire [NUM_DAT_VC-1:0] rx_dat_valid, rx_dat_ready;
    rx_credit_buffer #(
        .CTRL_FIFO_DEPTH  (2              ),
        .NUM_DAT_VC      (NUM_DAT_VC     ),
        .CREDIT_DEPTH (CREDIT_DEPTH)
    ) i_buffer (
        .clk_i               (clk          ),
        .rst_n_i             (rst_n_i      ),
        .s_ctrl_i             (rsp          ),
        .s_ctrl_valid_i       (rsp_valid    ),
        .s_ctrl_ready_o       (rsp_ready    ),
        .s_dat_i             (dat          ),
        .s_dat_valid_i       (dat_valid ? (NUM_DAT_VC'(1) << (fault == 3 ? noc_unit_params_pkg::DAT_WRITE_VC : FIRST_VC)) : '0),
        .credit_o            (credit_return),
        .m_ctrl_o             (rx_rsp_head  ),
        .m_ctrl_valid_o       (rx_rsp_valid ),
        .m_ctrl_ready_i       (rx_rsp_ready ),
        .m_dat_o             (rx_dat_head  ),
        .m_dat_valid_o       (rx_dat_valid ),
        .m_dat_ready_i       (rx_dat_ready )
    );
    wire noc_payload_pkg::rsp_flit_t selected_rsp;
    wire selected_rsp_valid, selected_rsp_ready;
    wire noc_payload_pkg::dat_flit_t selected_dat;
    wire selected_dat_valid, selected_dat_ready;
    for (genvar vc = 0; vc < NUM_DAT_VC; vc++) begin : gen_unused_read
        if (vc != FIRST_VC) assign rx_dat_ready[vc] = 1'b0;
    end
    nmu_read_response_arbiter i_read_response_arbiter (
        .s_rsp_i       (rx_rsp_head       ),
        .s_rsp_valid_i (rx_rsp_valid      ),
        .s_rsp_ready_o (rx_rsp_ready      ),
        .m_rsp_o       (selected_rsp      ),
        .m_rsp_valid_o (selected_rsp_valid),
        .m_rsp_ready_i (selected_rsp_ready),
        .clk_i         (clk               ),
        .rst_n_i       (rst_n_i           ),
        .s_dat_i       (rx_dat_head[FIRST_VC]       ),
        .s_dat_valid_i (rx_dat_valid[FIRST_VC]      ),
        .s_dat_ready_o (rx_dat_ready[FIRST_VC]      ),
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

    function automatic nmu_r_response_t expected(input int vc, input int seq);
        nmu_r_response_t value;
        value           = '0;
        value.axi.rid   = noc_payload_pkg::DATA_R_RID_WIDTH'(vc);
        value.axi.rresp = 2'(seq % 3);
        value.axi.rlast = seq % 3 == 2;
        value.axi.rdata = '0;
        for (int lane = 0; lane < (vc == NUM_DAT_VC ? 2 : 16); lane++)
            value.axi.rdata[lane*32 +: 32] = 32'(seq + lane*1024 + vc*65536);
        value.packet_info.packet_type = noc_header_pkg::packet_type_t'(vc != NUM_DAT_VC ?
            noc_header_pkg::PKT_DATA_R : noc_header_pkg::PKT_NARROW_R);
        value.packet_info.ordering_req = 1;
        value.packet_info.ordering_tag = noc_header_pkg::ORD_TAG_WIDTH'(seq);
        return value;
    endfunction

    task automatic set_dat(input int vc);
        nmu_r_response_t value;
        value                                               = expected(vc, wr_cnt[vc]);
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
        value                                              = expected(NUM_DAT_VC, wr_cnt[NUM_DAT_VC]);
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

    always @(posedge clk) begin : check
        int vc;
        if (~rst_n_i) begin
            for (int n = 0; n <= NUM_DAT_VC; n++) grant_wait[n] = 0;
            held            = 0;
            expected_credit = '0;
            for (int n = 0; n <= NUM_DAT_VC; n++) begin
                wr_cnt[n] = 0; rd_cnt[n] = 0;
            end
            for (int n = 0; n < NUM_DAT_VC; n++) begin
                credit[n] = CREDIT_DEPTH;
                fifo_rd_cnt[n] = 0;
            end
            if (credit_return !== '0) $fatal(1, "credit pulse during reset");
        end else if (fault == 0) begin
            if (buffered_r_ready && |i_read_response_arbiter.r_valid && !buffered_r_valid)
                $fatal(1, "avoidable R output bubble");
            for (int n = 0; n < 2; n++) begin
                if (!i_read_response_arbiter.r_valid[n] || i_read_response_arbiter.r_ready[n])
                    grant_wait[n] = 0;
                else if (buffered_r_valid && buffered_r_ready) begin
                    grant_wait[n]++;
                    // Allow one grant from a request snapshot held before arrival.
                    if (grant_wait[n] > NUM_DAT_VC+1) $fatal(1, "RX RR starved input %0d", n);
                    rr_checks++;
                end
            end
            if (held && (!r_valid || r !== held_r)) $fatal(1, "stalled R changed");
            held = r_valid && !r_ready; held_r = r;
            if (!$onehot0(credit_return)) $fatal(1, "multiple DAT pops");
            if (r_valid && r_ready) begin
                vc = (r.packet_info.packet_type == noc_header_pkg::PKT_DATA_R) ? int'(r.axi.rid) : NUM_DAT_VC;
                if (rd_cnt[vc] >= wr_cnt[vc] || r !== expected(vc, rd_cnt[vc]))
                    $fatal(1, "response mismatch vc=%0d seq=%0d", vc, rd_cnt[vc]);
                rd_cnt[vc]++; total_r++;
            end
            if (credit_return !== expected_credit) $fatal(1, "registered credit mismatch");
            expected_credit = '0;
            if (buffered_r_valid && buffered_r_ready &&
                    buffered_r.header.packet_type == noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_DATA_R)) begin
                vc = int'(noc_unit_params_pkg::dat_class(buffered_r.header.packet_type));
                expected_credit[vc] = 1'b1;
                fifo_rd_cnt[vc]++;
            end
            for (int n = 0; n < NUM_DAT_VC; n++) credit[n] += int'(credit_return[n]);
            if (dat_valid) begin
                vc = int'(noc_unit_params_pkg::dat_class(dat.header.packet_type));
                if (credit[vc] <= 0) $fatal(1, "sender violated credits");
                if (credit[vc] == 1 && credit_return[vc]) recoveries++;
                credit[vc]--; wr_cnt[vc]++;
                if (rsp_valid && rsp_ready) parallel_ingress++;
            end
            if (rsp_valid && rsp_ready && rsp.header.packet_type == noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_NARROW_R))
                wr_cnt[NUM_DAT_VC]++;
            for (int n = FIRST_VC; n < NUM_DAT_VC; n++)
                if (credit[n] + wr_cnt[n] - fifo_rd_cnt[n] + int'(expected_credit[n]) != CREDIT_DEPTH)
                    $fatal(1, "per-VC conservation mismatch");
            if (b_valid && b_ready) begin
                if (b.axi.bid != 3 || b.axi.bresp != 2 || b.packet_info.packet_type != noc_header_pkg::PKT_DATA_B || !b.packet_info.ordering_req)
                    $fatal(1, "B decode mismatch");
                total_b++;
            end
        end
    end

    always @(negedge rst_n_i) begin
        #1ps;
        if (i_buffer.credit_return_reg !== '0 ||
            i_buffer.rsp_empty !== 1'b1 ||
            i_buffer.dat_empty !== '1)
            $fatal(1, "Response FIFO/credit reset waited for a clock edge");
    end

    initial begin : stimulus
        int sel, before_r;
        bit drained;
        rsp = '0; dat = '0;
        repeat (3) @(negedge clk); rst_n_i = 1;
        if (fault != 0) begin
            set_dat(FIRST_VC);
            if (fault == 1) dat.header.packet_type = noc_header_pkg::packet_type_t'(noc_header_pkg::PACKET_TYPE_WIDTH'(noc_header_pkg::PKT_DATA_W));
            if (fault == 2) dat.header.packet_type = noc_header_pkg::PKT_NARROW_R;
            // fault 3 drives a write valid lane for the read packet below.
            repeat (CREDIT_DEPTH+3) @(negedge clk);
            $fatal(1, "fault escaped ingress checks");
        end
        // Fill every VC while the selected output is stalled. RLAST stays low
        // on initial beats, so progress to other VCs proves beat arbitration.
        for (int vc = FIRST_VC; vc < NUM_DAT_VC; vc++) begin
            for (int beat = 0; beat < CREDIT_DEPTH; beat++) begin
                set_dat(vc);
                if (vc == FIRST_VC && beat == 0) set_rsp(0);
                @(negedge clk); rsp_valid = 0;
            end
        end
        dat_valid = 0;
        repeat (3) @(negedge clk);
        if (total_b != 1) $fatal(1, "B blocked behind DAT");
        set_rsp(1); @(negedge clk); rsp_valid = 0;
        r_ready = 1;
        // A full FIFO pops first; the registered credit permits refill next cycle.
        @(negedge clk);
        #1ps;
        sel = -1;
        for (int vc = FIRST_VC; vc < NUM_DAT_VC; vc++) if (credit_return[vc]) sel = vc;
        if (sel < 0) $fatal(1, "no available DAT head");
        set_dat(sel);
        @(negedge clk); dat_valid = 0;
        before_r = total_r;
        repeat (NUM_DAT_VC+2) @(negedge clk);
        for (int vc = FIRST_VC; vc < NUM_DAT_VC; vc++)
            if (rd_cnt[vc] == 0) $fatal(1, "VC starved while other VC RLAST was low");
        if (total_r == before_r) $fatal(1, "arbiter did not progress");
        do begin
            drained = 1;
            for (int vc = 0; vc <= NUM_DAT_VC; vc++) if (rd_cnt[vc] != wr_cnt[vc]) drained = 0;
            @(negedge clk);
        end while (!drained);
        if (recoveries == 0 || parallel_ingress == 0) $fatal(1, "vacuous full/parallel coverage");
        // Shared RSP head blocks the opposite AXI class, but not independent DAT.
        if (REG_TYPE == 0) begin : rsp_head_wait
            int start_b, start_r, start_dat;
            start_b = total_b;
            start_r = rd_cnt[NUM_DAT_VC];
            start_dat = rd_cnt[FIRST_VC];
            b_ready = 0;
            set_rsp(0); @(negedge clk);
            set_rsp(1); @(negedge clk); rsp_valid = 0;
            set_dat(FIRST_VC); @(negedge clk); dat_valid = 0;
            repeat (4) @(negedge clk);
            if (total_b != start_b || rd_cnt[NUM_DAT_VC] != start_r ||
                !i_buffer.rsp_full || rsp_ready || !buffered_b_valid)
                $fatal(1, "RSP bypassed blocked B head");
            if (rd_cnt[FIRST_VC] != start_dat+1)
                $fatal(1, "blocked RSP B head blocked DAT");
            b_ready = 1;
            repeat (4) @(negedge clk);
            if (total_b != start_b+1 || rd_cnt[NUM_DAT_VC] != start_r+1)
                $fatal(1, "B-head recovery lost RSP response");

            start_b = total_b;
            start_r = rd_cnt[NUM_DAT_VC];
            r_ready = 0;
            set_rsp(1); @(negedge clk);
            set_rsp(0); @(negedge clk); rsp_valid = 0;
            repeat (4) @(negedge clk);
            if (total_b != start_b || rd_cnt[NUM_DAT_VC] != start_r ||
                !i_buffer.rsp_full || rsp_ready || buffered_b_valid)
                $fatal(1, "RSP bypassed blocked R head");
            r_ready = 1;
            repeat (4) @(negedge clk);
            if (total_b != start_b+1 || rd_cnt[NUM_DAT_VC] != start_r+1)
                $fatal(1, "R-head recovery lost RSP response");
            $display("PASS shared RSP head wait: B/R, R/B, independent DAT, full/recovery");
        end
        begin : class_contention
            // Exercise flat RR with concurrent control and DAT VC requests.
            for (int cycle = 0; cycle < 96; cycle++) begin
                sel = FIRST_VC + cycle % (NUM_DAT_VC-FIRST_VC);
                if (credit[sel] + int'(credit_return[sel]) > 0) set_dat(sel);
                else dat_valid = 0;
                set_rsp(1);
                @(negedge clk);
            end
            dat_valid = 0;
            while (!rsp_ready) @(negedge clk);
            @(negedge clk); rsp_valid = 0;
            do begin
                drained = 1;
                for (int vc = 0; vc <= NUM_DAT_VC; vc++)
                    if (rd_cnt[vc] != wr_cnt[vc]) drained = 0;
                @(negedge clk);
            end while (!drained);
            if (rr_checks < 8) $fatal(1, "vacuous control/data RR coverage");
            $display("PASS single-level RX RR checks=%0d", rr_checks);
        end
        begin : throughput
            int sent, cycles, start_r;
            sent = 0; cycles = 0; start_r = total_r;
            while (sent < 64) begin
                if (credit[FIRST_VC] + int'(credit_return[FIRST_VC]) > 0) begin
                    set_dat(FIRST_VC); sent++;
                end else dat_valid = 0;
                @(negedge clk); cycles++;
            end
            dat_valid = 0;
            while (rd_cnt[FIRST_VC] != wr_cnt[FIRST_VC]) begin
                @(negedge clk); cycles++;
            end
            repeat (2) @(negedge clk);
            if (total_r-start_r != 64) $fatal(1, "throughput lost response");
            $display("PERF depth=%0d beats=64 cycles=%0d", CREDIT_DEPTH, cycles);
            if (cycles > 66) $fatal(1, "avoidable throughput bubble with one-cycle credits");
        end
        // Flush occupied queues and a held arbitration decision, then reseed.
        r_ready = 0; set_dat(FIRST_VC); @(negedge clk); dat_valid = 0;
        repeat (2) @(negedge clk); rst_n_i = 0;
        repeat (2) @(negedge clk); rst_n_i = 1; r_ready = 1;
        if (r_valid) $fatal(1, "reset retained response");
        set_dat(FIRST_VC); @(negedge clk); dat_valid = 0;
        repeat (5) @(negedge clk);
        if (rd_cnt[FIRST_VC] != 1 || credit[FIRST_VC] != CREDIT_DEPTH)
            $fatal(1, "reset credit reseed/drain failed");
        $display("PASS depacketize vcs=%0d mode=%0d depth=%0d R=%0d credit_recovery=%0d parallel=%0d",
            NUM_DAT_VC, DAT_VC_MODE, CREDIT_DEPTH, total_r, recoveries, parallel_ingress);
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
