`timescale 1ns / 1ps
`default_nettype none

module tb_nmu_request_packetize_stress #(
    parameter int unsigned REG_TYPE    = 0,
    parameter int unsigned AW_REG_TYPE = REG_TYPE,
    parameter int unsigned W_REG_TYPE  = REG_TYPE,
    parameter int unsigned AR_REG_TYPE = REG_TYPE
);
    localparam int unsigned WRITES = 24;
    localparam int unsigned READS = 24;
    localparam int unsigned BEATS = 3;
    logic clk_i = 0, rst_n_i = 0;
    ni_types_pkg::nmu_aw_request_t                  s_aw_i;
    ni_signals_pkg::noc_axi_w_t                         s_w_i;
    ni_types_pkg::nmu_ar_request_t                  s_ar_i;
    noc_payload_pkg::req_flit_t                         m_req_o, previous_req;
    noc_payload_pkg::dat_flit_t                         m_dat_o;
    logic                                           s_aw_valid_i, s_aw_ready_o, s_w_valid_i, s_w_ready_o;
    logic                                           s_ar_valid_i, s_ar_ready_o, m_req_valid_o, m_req_ready_i, m_dat_valid_o;
    logic m_dat_ready_i, dat_stalled;
    noc_payload_pkg::dat_flit_t previous_dat;
    logic [31:0] random_reg = 32'hb7251309;
    logic req_stalled = 0;
    int narrow_count = 0, data_count = 0, read_count = 0;
    int narrow_beat = 0, data_beat = 0;
    int cycle = 0, parallel_count = 0;
    bit narrow_active = 0, data_active = 0;
    int dat_stall_cycles = 0;
    bit writes_done = 0, reads_done = 0;

    nmu_request_inject_tb_dut #(
        .REQ_AW_REG_TYPE (AW_REG_TYPE),
        .REQ_W_REG_TYPE (W_REG_TYPE),
        .REQ_AR_REG_TYPE (AR_REG_TYPE),
        .DAT_AW_REG_TYPE (AW_REG_TYPE),
        .DAT_W_REG_TYPE (W_REG_TYPE)
    ) dut (.*);

    always #5ns clk_i = !clk_i;

    function automatic logic [47:0] address(input int transaction, input bit wide);
        return 48'h1000 + 48'(transaction * 256 + (wide ? 0 : 8));
    endfunction
    function automatic logic [63:0] payload(input int transaction, input int beat);
        return 64'habc00000 + 64'(transaction * 16 + beat);
    endfunction

    // Stall REQ and DAT independently.
    always @(negedge clk_i) begin
        if (~rst_n_i) begin
            m_req_ready_i       = 0;
            m_dat_ready_i = 0;
            random_reg          = 32'hb7251309;
        end else begin
            random_reg          = {random_reg[30:0], random_reg[31] ^ random_reg[21] ^ random_reg[1] ^ random_reg[0]};
            m_req_ready_i       = cycle > 12 && random_reg[0];
            m_dat_ready_i       = cycle > 18 && random_reg[3];
        end
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            dat_stalled = 0;
            req_stalled = 0;
        end else begin
            cycle++;
            if (req_stalled && (!m_req_valid_o || m_req_o !== previous_req))
                $fatal(1, "REQ payload changed under randomized stalls");
            req_stalled     = m_req_valid_o && !m_req_ready_i;
            previous_req    = m_req_o;
            if (dat_stalled && (!m_dat_valid_o || m_dat_o !== previous_dat))
                $fatal(1, "DAT changed while stalled");
            dat_stalled = m_dat_valid_o && !m_dat_ready_i;
            previous_dat = m_dat_o;
            if (dat_stalled) dat_stall_cycles++;
            if (m_req_valid_o && m_req_ready_i) begin
                case (int'(m_req_o.header.packet_type))
                    noc_header_pkg::PKT_NARROW_AW: begin
                        if (narrow_active || narrow_count >= WRITES/2 ||
                                m_req_o.payload[(noc_payload_pkg::AW_AWADDR_LSB + noc_payload_pkg::AW_AWADDR_WIDTH - 1):noc_payload_pkg::AW_AWADDR_LSB] != address(narrow_count*2, 0))
                            $fatal(1, "narrow AW lost ownership or order");
                        narrow_active = 1; narrow_beat = 0;
                    end
                    noc_header_pkg::PKT_NARROW_W: begin
                        if (!narrow_active ||
                                m_req_o.payload[(noc_payload_pkg::NARROW_W_WDATA_LSB + noc_payload_pkg::NARROW_W_WDATA_WIDTH - 1):noc_payload_pkg::NARROW_W_WDATA_LSB] != payload(narrow_count*2, narrow_beat) ||
                                m_req_o.header.flit_tail != (narrow_beat == BEATS-1))
                            $fatal(1, "narrow W payload or burst lock mismatch");
                        narrow_beat++;
                        if (narrow_beat == BEATS) begin narrow_active = 0; narrow_count++; end
                    end
                    noc_header_pkg::PKT_DATA_AR: begin
                        if (narrow_active || read_count >= READS ||
                                m_req_o.payload[(noc_payload_pkg::AR_ARADDR_LSB + noc_payload_pkg::AR_ARADDR_WIDTH - 1):noc_payload_pkg::AR_ARADDR_LSB] != address(read_count, 1))
                            $fatal(1, "AR lost order or interrupted write packet");
                        read_count++;
                    end
                    default: $fatal(1, "unexpected REQ channel");
                endcase
            end
            if (m_dat_valid_o && m_dat_ready_i) begin
                case (int'(m_dat_o.header.packet_type))
                    noc_header_pkg::PKT_DATA_AW: begin
                        int txn;
                        txn = int'((m_dat_o.payload[(noc_payload_pkg::AW_AWADDR_LSB + noc_payload_pkg::AW_AWADDR_WIDTH - 1):noc_payload_pkg::AW_AWADDR_LSB] - 48'h1000) >> 8);
                        if (txn != 2*data_count+1 || data_active ||
                            m_dat_o.payload[noc_payload_pkg::AW_AWID_LSB +: noc_payload_pkg::AW_AWID_WIDTH] != noc_payload_pkg::NOC_ID_WIDTH'(data_count))
                            $fatal(1, "data AW address, ID, or order mismatch");
                        data_active = 1;
                        data_beat = 0;
                    end
                    noc_header_pkg::PKT_DATA_W: begin
                        if (!data_active ||
                                m_dat_o.payload[(noc_payload_pkg::DATA_W_WDATA_LSB + noc_payload_pkg::DATA_W_WDATA_WIDTH - 1):noc_payload_pkg::DATA_W_WDATA_LSB] != noc_payload_pkg::DATA_WIDTH'(payload(2*data_count+1, data_beat)) ||
                                m_dat_o.header.flit_tail != (data_beat == BEATS-1))
                            $fatal(1, "data W payload or burst lock mismatch");
                        data_beat++;
                        if (data_beat == BEATS) begin
                            data_active = 0;
                            data_count++;
                        end
                    end
                    default: $fatal(1, "unexpected DAT channel");
                endcase
            end
            if (m_req_valid_o && m_req_ready_i && m_dat_valid_o && m_dat_ready_i) parallel_count++;
        end
    end

    initial begin
        s_aw_i              = '0; s_w_i = '0; s_ar_i = '0;
        s_aw_valid_i        = 0; s_w_valid_i = 0; s_ar_valid_i = 0;
        m_dat_ready_i = 0; m_req_ready_i = 0;
        repeat (4) @(negedge clk_i);
        #1; rst_n_i = 1;
        fork
            begin
                for (int txn = 0; txn < WRITES; txn++) begin
                    @(negedge clk_i); #1;
                    s_aw_i                           = '0;
                    s_aw_i.axi.awid                  = noc_payload_pkg::NOC_ID_WIDTH'((txn/2) % 8);
                    s_aw_i.axi.awaddr                = address(txn, txn[0]);
                    s_aw_i.axi.awlen                 = noc_payload_pkg::AXI_LEN_WIDTH'(BEATS-1);
                    s_aw_i.axi.awsize                = txn[0] ? 3'd6 : 3'd3;
                    s_aw_i.axi.awburst               = 2'b01;
                    s_aw_i.packet_info.route.domain.packet_type = noc_header_pkg::packet_type_t'(txn[0] ?
                        noc_header_pkg::PKT_DATA_AW : noc_header_pkg::PKT_NARROW_AW);
                    s_aw_i.packet_info.route.domain.dst_id  = '0;
                    s_aw_i.packet_info.ordering_req          = txn >= 16;
                    s_aw_valid_i                     = 1;
                    do @(posedge clk_i); while (!s_aw_ready_o);
                    @(negedge clk_i); #1; s_aw_valid_i = 0;
                    for (int beat = 0; beat < BEATS; beat++) begin
                        s_w_i = '0;
                        if (txn[0]) s_w_i.wdata = noc_payload_pkg::DATA_WIDTH'(payload(txn, beat));
                        else s_w_i.wdata[(beat+1)*64 +: 64] = payload(txn, beat);
                        s_w_i.wstrb = '1;
                        s_w_i.wlast = beat == BEATS-1;
                        s_w_valid_i = 1;
                        do @(posedge clk_i); while (!s_w_ready_o);
                        @(negedge clk_i); #1; s_w_valid_i = 0;
                    end
                end
                writes_done = 1;
            end
            begin
                for (int txn = 0; txn < READS; txn++) begin
                    @(negedge clk_i); #1;
                    s_ar_i                           = '0;
                    s_ar_i.axi.arid                  = noc_payload_pkg::NOC_ID_WIDTH'(txn % 8);
                    s_ar_i.axi.araddr                = address(txn, 1);
                    s_ar_i.packet_info.route.domain.packet_type = noc_header_pkg::PKT_DATA_AR;
                    s_ar_valid_i                     = 1;
                    do @(posedge clk_i); while (!s_ar_ready_o);
                    @(negedge clk_i); #1; s_ar_valid_i = 0;
                end
                reads_done = 1;
            end
        join
        wait (narrow_count == WRITES/2 && data_count == WRITES/2 && read_count == READS);
        repeat (8) @(negedge clk_i);
        if (!writes_done || !reads_done || parallel_count == 0 || m_req_valid_o || m_dat_valid_o)
            $fatal(1, "incomplete drain or no parallel progress");
        if (!dat_stall_cycles) $fatal(1, "DAT backpressure not exercised");
        $display("PASS: packet stress writes=%0d reads=%0d parallel=%0d", WRITES, READS, parallel_count);
        $finish;
    end
    initial begin #100us; $fatal(1, "packet stress timeout"); end
endmodule

`resetall
