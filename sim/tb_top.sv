`timescale 1ps / 1ps
`include "axi/assign.svh"
`include "axi/typedef.svh"
`include "axi_vip_connect.svh"
module tb_top #(
    parameter int unsigned AXI_CLK_PERIOD_PS         = 1000,
    parameter int unsigned NOC_CLK_PERIOD_PS         = 1000,
    parameter int unsigned NOC_CLK_PHASE_PS          = 0,
    parameter int unsigned INPUT_ID_WIDTH            = ni_params_pkg::AXI_ID_WIDTH,
    parameter int unsigned OUTPUT_ID_WIDTH           = ni_params_pkg::NOC_ID_WIDTH,
    parameter int unsigned MAX_OUTSTANDING_PER_ID    = ni_params_pkg::NMU_MAX_OUTSTANDING_PER_ID,
    parameter int unsigned SOURCE_RESPONSE_DELAY_CYCLES = 4,
    parameter int unsigned RSP_DELAY_CYCLES          = 0,
    parameter int unsigned OUTPUT_REG_TYPE           = 0,
    parameter int unsigned IO_FIFO_DEPTH             = 32,
    parameter int unsigned B_ROB_DEPTH               = ni_params_pkg::NMU_ROB_B_DEPTH,
    parameter int unsigned R_ROB_DEPTH               = ni_params_pkg::NMU_ROB_R_DEPTH,
    parameter bit          R_ROB_EN                  = bit'(ni_params_pkg::NMU_R_ROB_EN),
    parameter int unsigned DEVICE_ID_WIDTH           = ni_params_pkg::NSU_AXI_ID_WIDTH,
    parameter int unsigned CONTEXT_DEPTH             = ni_params_pkg::NSU_MAX_OUTSTANDING
);
    import ni_params_pkg::*;
    import uvm_pkg::*;
    import tvip_axi_types_pkg::*;
    import tvip_axi_pkg::*;
    import ni_test_pkg::*;
    localparam int unsigned NUM_IDS = 1 << INPUT_ID_WIDTH;
    localparam time CLK_PERIOD = AXI_CLK_PERIOD_PS * 1ps;
    localparam time NOC_CLK_PERIOD = NOC_CLK_PERIOD_PS * 1ps;
    localparam time APPL_DELAY = 0ps;
    localparam time ACQ_DELAY  = 0ps;
    localparam int NUM_PORTS = 5;
    localparam int NMU_PORT = 0;
    localparam int NUM_NSUS = NUM_PORTS - 1;
    localparam int ROUTER_X = 1;
    localparam int ROUTER_Y = 1;
    localparam int MESH_DIM = 4;
    localparam int NMU_ID   = (ROUTER_Y << ni_flit_pkg::X_WIDTH) | ROUTER_X;
    localparam int NUM_WR_VC = NOC_DAT_VC_MODE == 1 ? NUM_DAT_VC/2 : NUM_DAT_VC;
    initial begin
        if (AXI_CLK_PERIOD_PS < 2 || NOC_CLK_PERIOD_PS < 2)
            $fatal(1, "Clock periods must be at least 2 ps");
        $display("PARAM_CONFIG device_id=%0d context=%0d per_id=%0d io_fifo=%0d reg_type=%0d b_rob=%0d r_rob=%0d r_rob_en=%0d vc=%0d vc_mode=%0d credit=%0d",
            DEVICE_ID_WIDTH, CONTEXT_DEPTH, MAX_OUTSTANDING_PER_ID, IO_FIFO_DEPTH,
            OUTPUT_REG_TYPE, B_ROB_DEPTH, R_ROB_DEPTH, R_ROB_EN, NUM_DAT_VC, NOC_DAT_VC_MODE, CREDIT_DEPTH);
        $display("CLOCK_CONFIG axi_period_ps=%0d noc_period_ps=%0d apply_delay_ps=%0d sample_delay_ps=%0d",
            CLK_PERIOD, NOC_CLK_PERIOD, APPL_DELAY, ACQ_DELAY);
        $display("CLOCK_PHASE noc_phase_ps=%0d", NOC_CLK_PHASE_PS);
        $display("TX_STORAGE req_bits=%0d dat_bits=%0d context_bits=%0d",
            IO_FIFO_DEPTH*$bits(ni_flit_pkg::req_flit_t),
            NUM_WR_VC*IO_FIFO_DEPTH*$bits(ni_flit_pkg::dat_flit_t),
            $bits(ni_types_pkg::nmu_aw_request_t)+ni_flit_pkg::AXI_LEN_WIDTH+1);

    end
    wire wr_order_full = dut.path_aw_valid &&
        dut.i_response_path.i_ordering.wr_outstanding_cnt_reg[dut.path_aw.axi.awid] >= MAX_OUTSTANDING_PER_ID;
    wire rd_order_full = dut.path_ar_valid &&
        dut.i_response_path.i_ordering.rd_outstanding_cnt_reg[dut.path_ar.axi.arid] >= MAX_OUTSTANDING_PER_ID;
    string check_order = "";
    string check_capacity = "";
    string check_fifo_capacity = "";
    bit check_destination_progress = 0;
    bit reset_recovery = 0;
    int response_delay_port = 0;
    int response_hold_port = 0;
    int response_error = 0;
    bit check_response_stall = 0;
    bit response_random_delay = 0;
    bit request_random_delay = 0;
    bit source_response_delay = 0;
    int response_hold_cycles = 0;
    bit block_b = 0, block_r = 0;
    wire [NUM_NSUS-1:0] aw_context_full, ar_context_full;
    wire [NUM_NSUS-1:0] aw_context_accept, ar_context_accept;
    wire [NUM_NSUS-1:0] memory_b_blocked, memory_r_blocked;
    int dst_wr_cnt[NUM_NSUS] = '{default:0};
    int dst_rd_cnt[NUM_NSUS] = '{default:0};
    function automatic int nsu_id(input int port);
        case (port)
            1: return ((ROUTER_Y + 1) << ni_flit_pkg::X_WIDTH) | ROUTER_X;
            2: return (ROUTER_Y << ni_flit_pkg::X_WIDTH) | (ROUTER_X + 1);
            3: return ((ROUTER_Y - 1) << ni_flit_pkg::X_WIDTH) | ROUTER_X;
            4: return (ROUTER_Y << ni_flit_pkg::X_WIDTH) | (ROUTER_X - 1);
            default: return NMU_ID;
        endcase
    endfunction
    bit corrupt_rsp = 0;
    logic clk = 0, noc_clk = 0, rst_n = 0;
    wire axi_rst_n, noc_rst_n;
    tvip_axi_if source_axi(clk, axi_rst_n);
    tvip_axi_if device_axi[4](clk, axi_rst_n);

    always #(CLK_PERIOD / 2) clk = ~clk;
    initial begin
        #(NOC_CLK_PHASE_PS * 1ps);
        forever #(NOC_CLK_PERIOD / 2) noc_clk = ~noc_clk;
    end
    cc_rstgen_bypass #(.NumRegs(2)) i_axi_reset_sync (
        .clk_i            (clk),
        .rst_ni           (rst_n),
        .rst_test_mode_ni (rst_n),
        .test_mode_i      (1'b0),
        .rst_no           (axi_rst_n),
        .init_no          ()
    );
    cc_rstgen_bypass #(.NumRegs(2)) i_noc_reset_sync (
        .clk_i            (noc_clk),
        .rst_ni           (rst_n),
        .rst_test_mode_ni (rst_n),
        .test_mode_i      (1'b0),
        .rst_no           (noc_rst_n),
        .init_no          ()
    );
    AXI_BUS_DV #(.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(INPUT_ID_WIDTH), .AXI_USER_WIDTH(AXI_AWUSER_WIDTH)) vip(clk);
    axi_if #(.ADDR_W(AXI_ADDR_WIDTH), .DATA_W(AXI_DATA_WIDTH),
        .ID_W     (INPUT_ID_WIDTH),
        .AWUSER_W (AXI_AWUSER_WIDTH)) bus();
    typedef logic [AXI_ADDR_WIDTH-1:0] mon_addr_t;
    localparam ni_mon_rule_t [topology_pkg::SAM_NUM_RULES-1:0] MON_RULES = NI_MON_RULES;
    longint unsigned router_ctx;
    wire [NUM_PORTS-1:0] tx_req_valid, rx_req_valid;
    wire [NOC_REQ_FLIT_WIDTH-1:0] tx_req_flit [NUM_PORTS], rx_req_flit [NUM_PORTS];
    wire [NUM_PORTS-1:0] tx_rsp_valid, rx_rsp_valid;
    wire [NOC_RSP_FLIT_WIDTH-1:0] tx_rsp_flit [NUM_PORTS], rx_rsp_flit [NUM_PORTS];
    wire [NUM_PORTS-1:0] tx_dat_valid, rx_dat_valid;
    wire [NOC_DAT_FLIT_WIDTH-1:0] tx_dat_flit [NUM_PORTS], rx_dat_flit [NUM_PORTS];
    wire [NUM_PORTS-1:0] tx_req_ready, rx_req_ready, tx_rsp_ready, rx_rsp_ready;
    wire [NUM_DAT_VC-1:0] tx_dat_credit [NUM_PORTS], rx_dat_credit [NUM_PORTS];
    ni_noc_if noc_observe[2*NUM_PORTS](noc_clk, noc_rst_n);
    for (genvar p = 0; p < NUM_PORTS; p++) begin : gen_noc_observe
        assign noc_observe[2*p+0].req = rx_req_flit[p];
        assign noc_observe[2*p+0].req_valid = rx_req_valid[p];
        assign noc_observe[2*p+0].req_ready = rx_req_ready[p];
        assign noc_observe[2*p+0].rsp = rx_rsp_flit[p];
        assign noc_observe[2*p+0].rsp_valid = rx_rsp_valid[p];
        assign noc_observe[2*p+0].rsp_ready = rx_rsp_ready[p];
        assign noc_observe[2*p+0].dat = rx_dat_flit[p];
        assign noc_observe[2*p+0].dat_valid = rx_dat_valid[p];
        assign noc_observe[2*p+0].credit = rx_dat_credit[p];
        initial uvm_config_db #(virtual ni_noc_if)::set(null, $sformatf("uvm_test_top.env.noc_tx%0d", p), "vif", noc_observe[2*p+0]);
        assign noc_observe[2*p+1].req = tx_req_flit[p];
        assign noc_observe[2*p+1].req_valid = tx_req_valid[p];
        assign noc_observe[2*p+1].req_ready = tx_req_ready[p];
        assign noc_observe[2*p+1].rsp = tx_rsp_flit[p];
        assign noc_observe[2*p+1].rsp_valid = tx_rsp_valid[p];
        assign noc_observe[2*p+1].rsp_ready = tx_rsp_ready[p];
        assign noc_observe[2*p+1].dat = tx_dat_flit[p];
        assign noc_observe[2*p+1].dat_valid = tx_dat_valid[p];
        assign noc_observe[2*p+1].credit = tx_dat_credit[p];
        initial uvm_config_db #(virtual ni_noc_if)::set(null, $sformatf("uvm_test_top.env.noc_rx%0d", p), "vif", noc_observe[2*p+1]);
    end
    assign bus.awid     = vip.aw_id;
    assign bus.awaddr   = vip.aw_addr;
    assign bus.awlen    = vip.aw_len;
    assign bus.awsize   = vip.aw_size;
    assign bus.awburst  = vip.aw_burst;
    assign bus.awlock   = vip.aw_lock;
    assign bus.awcache  = vip.aw_cache;
    assign bus.awprot   = vip.aw_prot;
    assign bus.awqos    = vip.aw_qos;
    assign bus.awregion = vip.aw_region;
    assign bus.awuser   = vip.aw_user;
    assign bus.awvalid  = vip.aw_valid;
    assign vip.aw_ready = bus.awready;
    assign bus.wdata    = vip.w_data;
    assign bus.wstrb    = vip.w_strb;
    assign bus.wlast    = vip.w_last;
    assign bus.wvalid   = vip.w_valid;
    assign vip.w_ready  = bus.wready;
    assign bus.arid     = vip.ar_id;
    assign bus.araddr   = vip.ar_addr;
    assign bus.arlen    = vip.ar_len;
    assign bus.arsize   = vip.ar_size;
    assign bus.arburst  = vip.ar_burst;
    assign bus.arlock   = vip.ar_lock;
    assign bus.arcache  = vip.ar_cache;
    assign bus.arprot   = vip.ar_prot;
    assign bus.arqos    = vip.ar_qos;
    assign bus.arregion = vip.ar_region;
    assign bus.arvalid  = vip.ar_valid;
    assign vip.ar_ready = bus.arready;
    assign bus.wuser    = '0;
    assign bus.aruser   = '0;
    assign bus.bready   = vip.b_ready;
    assign vip.b_valid  = bus.bvalid;
    assign vip.b_id     = bus.bid;
    assign vip.b_resp   = bus.bresp;
    assign vip.b_user   = '0;
    assign bus.rready   = vip.r_ready;
    assign vip.r_valid  = bus.rvalid;
    assign vip.r_id     = bus.rid;
    assign vip.r_data   = bus.rdata ^ (corrupt_rsp ? AXI_DATA_WIDTH'(1) : '0);
    assign vip.r_resp   = bus.rresp;
    assign vip.r_last   = bus.rlast;
    assign vip.r_user   = '0;
    nmu #(
        .REQ_AW_REG_TYPE (OUTPUT_REG_TYPE),
        .REQ_W_REG_TYPE (OUTPUT_REG_TYPE),
        .REQ_AR_REG_TYPE (OUTPUT_REG_TYPE),
        .DAT_AW_REG_TYPE (OUTPUT_REG_TYPE),
        .DAT_W_REG_TYPE (OUTPUT_REG_TYPE),
        .B_REG_TYPE (OUTPUT_REG_TYPE),
        .R_REG_TYPE (OUTPUT_REG_TYPE),
        .INPUT_ID_WIDTH (INPUT_ID_WIDTH),
        .OUTPUT_ID_WIDTH (OUTPUT_ID_WIDTH),
        .MAX_OUTSTANDING_PER_ID (MAX_OUTSTANDING_PER_ID),
        .B_ROB_DEPTH (B_ROB_DEPTH),
        .R_ROB_DEPTH (R_ROB_DEPTH),
        .R_ROB_EN (R_ROB_EN),
        .AXI_FIFO_DEPTH (IO_FIFO_DEPTH),
        .REQ_FIFO_DEPTH (IO_FIFO_DEPTH),
        .CREDIT_DEPTH (ni_params_pkg::CREDIT_DEPTH),
        .RSP_FIFO_DEPTH (IO_FIFO_DEPTH),
        .SRC_ID (ni_flit_pkg::SRC_ID_WIDTH'(NMU_ID))
    ) dut (
        .ACLK              (clk),
        .ARESETn           (axi_rst_n),
        .noc_clk           (noc_clk),
        .noc_rst_n         (noc_rst_n),
        .axi_wr_i          (bus),
        .axi_rd_i          (bus),
        .tx_req_valid_o    (rx_req_valid[NMU_PORT]),
        .tx_req_flit_o     (rx_req_flit[NMU_PORT]),
        .tx_req_ready_i    (rx_req_ready[NMU_PORT]),
        .rx_rsp_valid_i    (tx_rsp_valid[NMU_PORT]),
        .rx_rsp_flit_i     (tx_rsp_flit[NMU_PORT]),
        .rx_rsp_ready_o    (tx_rsp_ready[NMU_PORT]),
        .tx_dat_valid_o    (rx_dat_valid[NMU_PORT]),
        .tx_dat_flit_o     (rx_dat_flit[NMU_PORT]),
        .tx_dat_crdvalid_i (rx_dat_credit[NMU_PORT]),
        .rx_dat_valid_i    (tx_dat_valid[NMU_PORT]),
        .rx_dat_flit_i     (tx_dat_flit[NMU_PORT]),
        .rx_dat_crdvalid_o (tx_dat_credit[NMU_PORT])
    );
`ifdef TB_DIRECT_LINK
    function automatic logic [NUM_NSUS:0][ni_flit_pkg::DST_ID_WIDTH-1:0] node_ids();
        for (int p = 0; p <= NUM_NSUS; p++)
            node_ids[p] = ni_flit_pkg::DST_ID_WIDTH'(p == 0 ? NMU_ID : nsu_id(p));
    endfunction
    ni_direct_link #(
        .NUM_NSUS (NUM_NSUS ),
        .NODE_IDS (node_ids())
    ) i_direct_link (
        .clk_i             (noc_clk          ),
        .rst_n_i           (noc_rst_n    ),
        .tx_req_valid_o    (tx_req_valid ),
        .tx_req_flit_o     (tx_req_flit  ),
        .tx_req_ready_i    (tx_req_ready ),
        .rx_req_valid_i    (rx_req_valid ),
        .rx_req_flit_i     (rx_req_flit  ),
        .rx_req_ready_o    (rx_req_ready ),
        .tx_rsp_valid_o    (tx_rsp_valid ),
        .tx_rsp_flit_o     (tx_rsp_flit  ),
        .tx_rsp_ready_i    (tx_rsp_ready ),
        .rx_rsp_valid_i    (rx_rsp_valid ),
        .rx_rsp_flit_i     (rx_rsp_flit  ),
        .rx_rsp_ready_o    (rx_rsp_ready ),
        .tx_dat_valid_o    (tx_dat_valid ),
        .tx_dat_flit_o     (tx_dat_flit  ),
        .tx_dat_crdvalid_i (tx_dat_credit),
        .rx_dat_valid_i    (rx_dat_valid ),
        .rx_dat_flit_i     (rx_dat_flit  ),
        .rx_dat_crdvalid_o (rx_dat_credit)
    );
`else
    router_wrap i_router (
        .clk_i           (noc_clk),
        .rst_n_i         (noc_rst_n),
        .ctx_i           (router_ctx),
        .tx_req_valid    (tx_req_valid),
        .tx_req_flit     (tx_req_flit),
        .tx_req_ready    (tx_req_ready),
        .rx_req_valid    (rx_req_valid),
        .rx_req_flit     (rx_req_flit),
        .rx_req_ready    (rx_req_ready),
        .tx_rsp_valid    (tx_rsp_valid),
        .tx_rsp_flit     (tx_rsp_flit),
        .tx_rsp_ready    (tx_rsp_ready),
        .rx_rsp_valid    (rx_rsp_valid),
        .rx_rsp_flit     (rx_rsp_flit),
        .rx_rsp_ready    (rx_rsp_ready),
        .tx_dat_valid    (tx_dat_valid),
        .tx_dat_flit     (tx_dat_flit),
        .tx_dat_crdvalid (tx_dat_credit),
        .rx_dat_valid    (rx_dat_valid),
        .rx_dat_flit     (rx_dat_flit),
        .rx_dat_crdvalid (rx_dat_credit)
    );
`endif
    for (genvar n = 0; n < NUM_NSUS; n++) begin : gen_nsu
        localparam int PORT = n + 1;
        AXI_BUS #(.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
            .AXI_ID_WIDTH   (DEVICE_ID_WIDTH),
            .AXI_USER_WIDTH (AXI_AWUSER_WIDTH)) mem_bus();
        initial begin
            tvip_axi_configuration cfg;
            int code, delay_port;
            bit stall_requests, stall_responses;
            stall_requests = $test$plusargs("request_random_delay");
            stall_responses = $test$plusargs("response_random_delay");
            code = 0;
            delay_port = 0;
            void'($value$plusargs("response_delay_port=%d", delay_port));
            void'($value$plusargs("response_error=%d", code));
            cfg = tvip_axi_configuration::type_id::create($sformatf("device_cfg%0d", n));
            cfg.vif = device_axi[n];
            cfg.awuser_width = AXI_AWUSER_WIDTH;
            if (!cfg.randomize() with {
                id_width == DEVICE_ID_WIDTH; address_width == AXI_ADDR_WIDTH;
                data_width == AXI_DATA_WIDTH; max_burst_length == 256;
                response_ordering == TVIP_AXI_IN_ORDER;
                default_awready == !stall_requests;
                default_wready == !stall_requests;
                default_arready == !stall_requests;
                awready_delay.min_delay == 0; awready_delay.max_delay == (stall_requests ? 4 : 0);
                wready_delay.min_delay == 0; wready_delay.max_delay == (stall_requests ? 4 : 0);
                arready_delay.min_delay == 0; arready_delay.max_delay == (stall_requests ? 4 : 0);
                response_delay.min_delay == 0; response_delay.max_delay == (stall_responses ? 4 : 0);
                response_start_delay.min_delay == (PORT == delay_port ? RSP_DELAY_CYCLES : 0);
                response_start_delay.max_delay == (PORT == delay_port ? RSP_DELAY_CYCLES : 0);
                response_weight_okay == (code == 0 ? 1 : 0);
                response_weight_exokay == 0;
                response_weight_slave_error == (code == 2 ? 1 : 0);
                response_weight_decode_error == (code == 3 ? 1 : 0);
            }) $fatal(1, "Device VIP configuration failed");
            uvm_config_db #(tvip_axi_configuration)::set(null, "uvm_test_top.env", $sformatf("device_cfg%0d", n), cfg);
        end
        int pending_aw = 0, pending_w = 0, pending_ar = 0;
        always @(posedge clk) begin
            if (!axi_rst_n) begin
                pending_aw = 0;
                pending_w = 0;
                pending_ar = 0;
            end else begin
                if (mem_bus.aw_valid && mem_bus.aw_ready) begin
                    dst_wr_cnt[n]++;
                    pending_aw++;
                end
                if (mem_bus.w_valid && mem_bus.w_ready && mem_bus.w_last) pending_w++;
                if (mem_bus.ar_valid && mem_bus.ar_ready) begin
                    dst_rd_cnt[n]++;
                    pending_ar++;
                end
                if (mem_bus.b_valid && mem_bus.b_ready) begin
                    pending_aw--;
                    pending_w--;
                end
                if (mem_bus.r_valid && mem_bus.r_ready && mem_bus.r_last) pending_ar--;
            end
        end
        assign memory_b_blocked[n] = block_b && (response_hold_port == 0 || PORT == response_hold_port) &&
            pending_aw > 0 && pending_w > 0;
        assign memory_r_blocked[n] = block_r && (response_hold_port == 0 || PORT == response_hold_port) && pending_ar > 0;
        begin : gen_rtl_nsu
            axi_if #(.ADDR_W(AXI_ADDR_WIDTH), .DATA_W(AXI_DATA_WIDTH),
                .ID_W(DEVICE_ID_WIDTH), .AWUSER_W(AXI_AWUSER_WIDTH)) device_bus();
            nsu #(
                .OUTPUT_ID_WIDTH(DEVICE_ID_WIDTH),
                .AXI_AWUSER_WIDTH(AXI_AWUSER_WIDTH),
                .AXI_FIFO_DEPTH(IO_FIFO_DEPTH),
                .AW_CONTEXT_DEPTH(CONTEXT_DEPTH), .AR_CONTEXT_DEPTH(CONTEXT_DEPTH),
                .AW_REG_TYPE(OUTPUT_REG_TYPE), .W_REG_TYPE(OUTPUT_REG_TYPE),
                .AR_REG_TYPE(OUTPUT_REG_TYPE), .B_REG_TYPE(OUTPUT_REG_TYPE),
                .R_REG_TYPE(OUTPUT_REG_TYPE),
                .SRC_ID(ni_flit_pkg::SRC_ID_WIDTH'(nsu_id(PORT)))
            ) i_nsu (
                .ACLK(clk), .ARESETn(axi_rst_n), .noc_clk(noc_clk), .noc_rst_n(noc_rst_n),
                .axi_wr_o(device_bus), .axi_rd_o(device_bus),
                .rx_req_valid_i(tx_req_valid[PORT]), .rx_req_flit_i(tx_req_flit[PORT]),
                .rx_req_ready_o(tx_req_ready[PORT]),
                .tx_rsp_valid_o(rx_rsp_valid[PORT]), .tx_rsp_flit_o(rx_rsp_flit[PORT]),
                .tx_rsp_ready_i(rx_rsp_ready[PORT]),
                .tx_dat_valid_o(rx_dat_valid[PORT]), .tx_dat_flit_o(rx_dat_flit[PORT]),
                .tx_dat_crdvalid_i(rx_dat_credit[PORT]),
                .rx_dat_valid_i(tx_dat_valid[PORT]), .rx_dat_flit_i(tx_dat_flit[PORT]),
                .rx_dat_crdvalid_o(tx_dat_credit[PORT])
            );
            assign aw_context_full[n] = i_nsu.i_response_path.i_context_buffer.i_aw_context.full_o;
            assign ar_context_full[n] = i_nsu.i_response_path.i_context_buffer.i_ar_context.full_o;
            assign aw_context_accept[n] = i_nsu.aw_context_valid && i_nsu.aw_context_ready;
            assign ar_context_accept[n] = i_nsu.ar_context_valid && i_nsu.ar_context_ready;
            initial begin
                repeat (99990) @(posedge clk);
                $display("NSU_TIMEOUT node=%0d aw_vr=%b%b w_vr=%b%b ar_vr=%b%b b_vr=%b%b r_vr=%b%b", n,
                    device_bus.awvalid, device_bus.awready, device_bus.wvalid, device_bus.wready,
                    device_bus.arvalid, device_bus.arready, device_bus.bvalid, device_bus.bready,
                    device_bus.rvalid, device_bus.rready);
                $display("NSU_CONTEXT node=%0d aw_vr=%b%b ar_vr=%b%b w_valid=%b w_context=%h w_beat=%0d", n,
                    i_nsu.aw_context_valid, i_nsu.aw_context_ready, i_nsu.ar_context_valid, i_nsu.ar_context_ready,
                    i_nsu.w_context_valid, i_nsu.w_context, i_nsu.w_beat);
                $display("NSU_HEAD node=%0d req_vr=%b%b req=%h dat_valid=%b dat_ready=%b dat=%h", n,
                    i_nsu.i_request_path.rx_req_valid, i_nsu.i_request_path.rx_req_ready, i_nsu.i_request_path.rx_req_head,
                    i_nsu.i_request_path.rx_dat_valid, i_nsu.i_request_path.rx_dat_ready, i_nsu.i_request_path.rx_dat_head);
            end
            assign mem_bus.aw_id = device_bus.awid;
            assign mem_bus.aw_addr = device_bus.awaddr;
            assign mem_bus.aw_len = device_bus.awlen;
            assign mem_bus.aw_size = device_bus.awsize;
            assign mem_bus.aw_burst = device_bus.awburst;
            assign mem_bus.aw_lock = device_bus.awlock;
            assign mem_bus.aw_cache = device_bus.awcache;
            assign mem_bus.aw_prot = device_bus.awprot;
            assign mem_bus.aw_qos = device_bus.awqos;
            assign mem_bus.aw_region = device_bus.awregion;
            assign mem_bus.aw_user = device_bus.awuser;
            assign mem_bus.aw_valid = device_bus.awvalid;
            assign mem_bus.w_data = device_bus.wdata;
            assign mem_bus.w_strb = device_bus.wstrb;
            assign mem_bus.w_last = device_bus.wlast;
            assign mem_bus.w_valid = device_bus.wvalid;
            assign mem_bus.w_user = device_bus.wuser;
            assign mem_bus.ar_id = device_bus.arid;
            assign mem_bus.ar_addr = device_bus.araddr;
            assign mem_bus.ar_len = device_bus.arlen;
            assign mem_bus.ar_size = device_bus.arsize;
            assign mem_bus.ar_burst = device_bus.arburst;
            assign mem_bus.ar_lock = device_bus.arlock;
            assign mem_bus.ar_cache = device_bus.arcache;
            assign mem_bus.ar_prot = device_bus.arprot;
            assign mem_bus.ar_qos = device_bus.arqos;
            assign mem_bus.ar_region = device_bus.arregion;
            assign mem_bus.ar_valid = device_bus.arvalid;
            assign mem_bus.ar_user = device_bus.aruser;
            assign mem_bus.b_ready = device_bus.bready;
            assign mem_bus.r_ready = device_bus.rready;
            assign mem_bus.aw_atop = '0;
            assign device_bus.awready = mem_bus.aw_ready;
            assign device_bus.wready = mem_bus.w_ready;
            assign device_bus.arready = mem_bus.ar_ready;
            assign device_bus.bid = mem_bus.b_id;
            assign device_bus.bresp = mem_bus.b_resp;
            assign device_bus.bvalid = mem_bus.b_valid;
            assign device_bus.buser = mem_bus.b_user;
            assign device_bus.rid = mem_bus.r_id;
            assign device_bus.rdata = mem_bus.r_data;
            assign device_bus.rresp = mem_bus.r_resp;
            assign device_bus.rlast = mem_bus.r_last;
            assign device_bus.rvalid = mem_bus.r_valid;
            assign device_bus.ruser = mem_bus.r_user;
        end
`ifdef NI_COVERAGE
        aw_stall_recover: cover property (@(posedge clk) disable iff (!axi_rst_n)
            mem_bus.aw_valid && !mem_bus.aw_ready ##[1:64] mem_bus.aw_valid && mem_bus.aw_ready);
        w_stall_recover: cover property (@(posedge clk) disable iff (!axi_rst_n)
            mem_bus.w_valid && !mem_bus.w_ready ##[1:64] mem_bus.w_valid && mem_bus.w_ready);
        ar_stall_recover: cover property (@(posedge clk) disable iff (!axi_rst_n)
            mem_bus.ar_valid && !mem_bus.ar_ready ##[1:64] mem_bus.ar_valid && mem_bus.ar_ready);
`endif
        `NI_AXI_UVM_SLAVE(mem_bus, device_axi[n])

    end
    assign rx_rsp_valid[NMU_PORT] = 1'b0;
    assign rx_rsp_flit[NMU_PORT]  = '0;
    assign tx_req_ready[NMU_PORT] = 1'b0;
    for (genvar port = 1; port < NUM_PORTS; port++) begin : gen_tieoff
        assign rx_req_valid[port] = 1'b0;
        assign rx_req_flit[port]  = '0;
        assign tx_rsp_ready[port] = 1'b0;
        always @(posedge noc_clk) begin
            if (noc_rst_n && tx_rsp_valid[port])
                $fatal(1, "Response routed away from LOCAL");
        end
    end
    always @(posedge noc_clk) begin
        if (noc_rst_n && tx_req_valid[NMU_PORT])
            $fatal(1, "Request routed back to LOCAL");
    end
    typedef axi_test::axi_file_master #(
        .AW(AXI_ADDR_WIDTH), .DW(AXI_DATA_WIDTH), .IW(INPUT_ID_WIDTH),
        .UW(AXI_AWUSER_WIDTH), .TA(APPL_DELAY), .TT(ACQ_DELAY)
    ) master_t;
    function automatic tvip_axi_master_item convert_address(master_t::ax_beat_t address, bit is_read);
        tvip_axi_master_item item = new();
        item.access_type = is_read ? TVIP_AXI_READ_ACCESS : TVIP_AXI_WRITE_ACCESS;
        item.id = address.ax_id;
        item.address = address.ax_addr;
        item.burst_length = int'(address.ax_len) + 1;
        item.burst_size = 1 << address.ax_size;
        item.burst_type = tvip_axi_burst_type'(address.ax_burst);
        item.lock = address.ax_lock;
        item.put_cache(address.ax_cache);
        item.protection = tvip_axi_protection'(address.ax_prot);
        item.qos = address.ax_qos;
        item.region = address.ax_region;
        item.awuser = is_read ? 0 : address.ax_user;
        item.need_response = 0;
        return item;
    endfunction

    function automatic void load_sequence(master_t source, ni_pattern_sequence seq);
        int beat = 0;
        foreach (source.aw_queue[i]) begin
            tvip_axi_master_item item = convert_address(source.aw_queue[i], 0);
            if (source.aw_queue[i].ax_atop != 0) $fatal(1, "AXI VIP adapter does not carry AWATOP");
            item.data = new[item.burst_length];
            item.strobe = new[item.burst_length];
            foreach (item.data[j]) begin
                if (source.w_queue[beat].w_user != 0) $fatal(1, "AXI VIP adapter does not carry WUSER");
                item.data[j] = source.w_queue[beat].w_data;
                item.strobe[j] = source.w_queue[beat].w_strb;
                beat++;
            end
            seq.writes.push_back(item);
        end
        foreach (source.ar_queue[i]) begin
            if (source.ar_queue[i].ax_user != 0) $fatal(1, "AXI VIP adapter does not carry ARUSER");
            seq.reads.push_back(convert_address(source.ar_queue[i], 1));
        end
    endfunction

    `NI_AXI_UVM_MASTER(vip, source_axi)
    uvm_event stimulus_start = uvm_event_pool::get_global("ni_start");
    uvm_event stimulus_done = uvm_event_pool::get_global("ni_done");
    uvm_event checks_done = uvm_event_pool::get_global("ni_checked");
`ifndef TB_DIRECT_LINK
    import "DPI-C" context function int cmodel_check_error(output string message);
    always @(negedge noc_clk) begin : check_model_error
        string message;
        if (noc_rst_n && cmodel_check_error(message) != 0)
            $fatal(1, "C++ model error: %s", message);
    end
`endif
    int b_count = 0, r_count = 0, r_beats = 0, checked_bytes = 0;
    int expected_writes, expected_reads, expected_beats;
    int live_w[2**INPUT_ID_WIDTH] = '{default:0};
    int live_r[2**INPUT_ID_WIDTH] = '{default:0};
    int peak_w = 0, peak_r = 0, peak_unique_w = 0, peak_unique_r = 0;
    int min_outstanding = 1, min_unique = 1;
    master_t::ax_beat_t expected_ar[2**INPUT_ID_WIDTH][$];
    int read_beat[2**INPUT_ID_WIDTH] = '{default:0};
    master_t master, init_master, verify_master;
    ni_scoreboard scoreboard;
    bit init_phase = 0, concurrent_rw = 0, readback = 0;
    int source_response_hold_cycles = 0;
    int b_stall_cnt = 0, r_stall_cnt = 0, aw_stall_cnt = 0, ar_stall_cnt = 0;
    int tx_req_peak = 0;
    int tx_dat_peak[NUM_DAT_VC] = '{default:0};
    int tx_req_beats = 0, tx_dat_beats = 0;
    always @(posedge noc_clk) begin
        if (noc_rst_n) begin
            if (int'(dut.i_request_path.i_tx_credit_buffer.i_ctrl_fifo.usage_o) > tx_req_peak)
                tx_req_peak = int'(dut.i_request_path.i_tx_credit_buffer.i_ctrl_fifo.usage_o);
            if (rx_req_valid[NMU_PORT] && rx_req_ready[NMU_PORT]) tx_req_beats++;
            if (rx_dat_valid[NMU_PORT]) tx_dat_beats++;
        end
    end
    for (genvar vc = 0; vc < NUM_DAT_VC; vc++) begin : gen_tx_occupancy
        if (NOC_DAT_VC_MODE == 0 || vc < NUM_DAT_VC/2) begin : gen_write
            always @(posedge noc_clk) begin
                if (noc_rst_n && int'(dut.i_request_path.i_tx_credit_buffer.gen_dat_vc[vc].gen_active.i_fifo.usage_o) > tx_dat_peak[vc])
                    tx_dat_peak[vc] = int'(dut.i_request_path.i_tx_credit_buffer.gen_dat_vc[vc].gen_active.i_fifo.usage_o);
            end
        end
    end
    int b_full_cnt = 0, r_full_cnt = 0, dat_full_cnt = 0;
    int wr_limit_cnt = 0, rd_limit_cnt = 0;
    int overlap_cnt = 0, w_during_read_cnt = 0, r_during_write_cnt = 0;
    bit concurrent_active = 0;

    function automatic void expect_reads(input master_t source);
        foreach (source.ar_queue[i]) begin
            expected_ar[source.ar_queue[i].ax_id].push_back(source.ar_queue[i]);
            expected_beats += int'(source.ar_queue[i].ax_len) + 1;
        end
    endfunction

    assert property (@(posedge clk) disable iff (!axi_rst_n)
        bus.bvalid && !bus.bready |=> bus.bvalid && $stable({bus.bid, bus.bresp}))
        else $fatal(1, "B response changed under backpressure");
    assert property (@(posedge clk) disable iff (!axi_rst_n)
        bus.rvalid && !bus.rready |=> bus.rvalid &&
        $stable({bus.rid, bus.rdata, bus.rresp, bus.rlast}))
        else $fatal(1, "R response changed under backpressure");
`ifndef TB_DIRECT_LINK
    import "DPI-C" context function void cmodel_init();
    import "DPI-C" context function void cmodel_finalize();
    import "DPI-C" context function longint unsigned cmodel_router_create(
        input string name, input int x, y, mesh_x, mesh_y, num_vc);
`endif
    initial begin
        uvm_event write_start = uvm_event_pool::get_global("ni_write_start");
        forever begin
            write_start.wait_trigger();
            start_response_hold(0);
        end
    end
    initial begin
        uvm_event read_start = uvm_event_pool::get_global("ni_read_start");
        forever begin
            read_start.wait_trigger();
            start_response_hold(1);
        end
    end
    initial begin : run
        string stim_dir;
        int first_char;
`ifndef TB_DIRECT_LINK
        cmodel_init();
        router_ctx = cmodel_router_create("router", ROUTER_X, ROUTER_Y,
            MESH_DIM, MESH_DIM, NUM_DAT_VC);
`endif
        void'($value$plusargs("check_order=%s", check_order));
        void'($value$plusargs("check_capacity=%s", check_capacity));
        void'($value$plusargs("check_fifo_capacity=%s", check_fifo_capacity));
        void'($value$plusargs("check_destination_progress=%d", check_destination_progress));
        void'($value$plusargs("check_response_stall=%d", check_response_stall));
        reset_recovery = $test$plusargs("reset_recovery");
        void'($value$plusargs("response_error=%d", response_error));
        response_random_delay = $test$plusargs("response_random_delay");
        request_random_delay = $test$plusargs("request_random_delay");
        void'($value$plusargs("response_delay_port=%d", response_delay_port));
        void'($value$plusargs("response_hold_port=%d", response_hold_port));
        void'($value$plusargs("response_hold_cycles=%d", response_hold_cycles));
        if (response_hold_cycles < 0 || response_hold_port < 0 || response_hold_port > NUM_NSUS ||
                response_delay_port < 0 || response_delay_port > NUM_NSUS)
            $fatal(1, "Invalid response delay configuration");
        $display("SLAVE_RESPONSE_DELAY random=%0d hold_cycles=%0d hold_port=%0d delay_port=%0d delay_cycles=%0d",
            response_random_delay, response_hold_cycles, response_hold_port, response_delay_port, RSP_DELAY_CYCLES);
        $display("DAT_CREDIT_DEPTH router=%0d nmu_rx=%0d nsu_rx=%0d",
            CREDIT_DEPTH, CREDIT_DEPTH, CREDIT_DEPTH);
        master = new(null);
        if (!$value$plusargs("stim_dir=%s", stim_dir)) $fatal(1, "Missing stim_dir");
        master.read_fd = $fopen({stim_dir, "/read.txt"}, "r");
        master.write_fd = $fopen({stim_dir, "/write.txt"}, "r");
        if (!master.read_fd || !master.write_fd) $fatal(1, "Missing AXI stimulus file");
        first_char = $fgetc(master.read_fd);
        if (first_char != -1) begin
            void'($ungetc(first_char, master.read_fd));
            master.parse_read();
        end
        first_char = $fgetc(master.write_fd);
        if (first_char != -1) begin
            void'($ungetc(first_char, master.write_fd));
            master.parse_write();
        end
        $fclose(master.read_fd);
        $fclose(master.write_fd);
        master.num_reads = master.ar_queue.size();
        master.num_writes = master.aw_queue.size();
        corrupt_rsp = $test$plusargs("corrupt_rsp");
        void'($value$plusargs("check_min_outstanding=%d", min_outstanding));
        void'($value$plusargs("check_min_unique=%d", min_unique));
        expected_writes = master.num_writes;
        expected_reads = master.num_reads;
        expected_beats = 0;
        expect_reads(master);
        init_phase = $test$plusargs("init_phase");
        concurrent_rw = $test$plusargs("concurrent_rw");
        readback = $test$plusargs("readback");
        source_response_delay = $test$plusargs("source_response_delay");
        void'($value$plusargs("source_response_hold_cycles=%d", source_response_hold_cycles));
        if (init_phase) begin
            init_master = new(null);
            init_master.write_fd = $fopen({stim_dir, "/init_write.txt"}, "r");
            if (!init_master.write_fd) $fatal(1, "Missing initialization writes");
            init_master.parse_write();
            $fclose(init_master.write_fd);
            init_master.num_writes = init_master.aw_queue.size();
            expected_writes += init_master.num_writes;
        end
        if (readback) begin
            verify_master = new(null);
            verify_master.read_fd = $fopen({stim_dir, "/verify_read.txt"}, "r");
            if (!verify_master.read_fd) $fatal(1, "Missing verification reads");
            verify_master.parse_read();
            $fclose(verify_master.read_fd);
            verify_master.num_reads = verify_master.ar_queue.size();
            expected_reads += verify_master.num_reads;
            expect_reads(verify_master);
        end
        if (expected_writes == 0 && expected_reads == 0)
            $fatal(1, "Empty memory test");
        begin
            ni_pattern_sequence seq;
            tvip_axi_configuration cfg;
            uvm_config_db #(int)::set(null, "uvm_test_top.env.*", "clock_period_ps", AXI_CLK_PERIOD_PS);
            cfg = tvip_axi_configuration::type_id::create("source_cfg");
            cfg.vif = source_axi;
            cfg.awuser_width = AXI_AWUSER_WIDTH;
            if (!cfg.randomize() with {
                id_width == INPUT_ID_WIDTH; address_width == AXI_ADDR_WIDTH;
                data_width == AXI_DATA_WIDTH; max_burst_length == 256;
                default_bready == !(source_response_delay || source_response_hold_cycles != 0 || reset_recovery);
                default_rready == !(source_response_delay || source_response_hold_cycles != 0 || reset_recovery);
                bready_delay.min_delay == (source_response_delay ? SOURCE_RESPONSE_DELAY_CYCLES : 0);
                bready_delay.max_delay == (source_response_delay ? SOURCE_RESPONSE_DELAY_CYCLES : 0);
                rready_delay.min_delay == (source_response_delay ? SOURCE_RESPONSE_DELAY_CYCLES : 0);
                rready_delay.max_delay == (source_response_delay ? SOURCE_RESPONSE_DELAY_CYCLES : 0);
            }) $fatal(1, "Source VIP configuration failed");
            uvm_config_db #(tvip_axi_configuration)::set(null, "uvm_test_top.env", "source_cfg", cfg);
            seq = new("requests");
            load_sequence(master, seq);
            seq.concurrent_rw = concurrent_rw;
            seq.first_response_delay = source_response_hold_cycles;
            uvm_config_db #(tvip_axi_master_sequence_base)::set(null, "uvm_test_top", "sequence1", seq);
            if (reset_recovery) begin
                seq = new("warmup");
                load_sequence(master, seq);
                seq.concurrent_rw = 1;
                // Keep warmup responses pending until reset aborts the sequence.
                seq.first_response_delay = 100000;
                uvm_config_db #(tvip_axi_master_sequence_base)::set(null, "uvm_test_top", "warmup", seq);
            end
            if (init_phase) begin
                seq = new("initialization");
                load_sequence(init_master, seq);
                uvm_config_db #(tvip_axi_master_sequence_base)::set(null, "uvm_test_top", "sequence0", seq);
            end
            if (readback) begin
                seq = new("readback");
                load_sequence(verify_master, seq);
                uvm_config_db #(tvip_axi_master_sequence_base)::set(null, "uvm_test_top", "sequence2", seq);
            end
        end
        fork
            run_test("ni_test");
        join_none
        repeat (5) @(negedge clk);
        rst_n = 1;
        wait (axi_rst_n && noc_rst_n);
        @(posedge clk);
        if (!uvm_config_db #(ni_scoreboard)::get(null, "", "ni_scoreboard", scoreboard))
            $fatal(1, "Missing UVM scoreboard");
        stimulus_start.trigger();
        if (reset_recovery) run_reset_recovery(stim_dir);
        concurrent_active = concurrent_rw;
        stimulus_done.wait_on();
        concurrent_active = 0;
        repeat (10) @(posedge clk);
        checked_bytes = scoreboard.checked_bytes;
        if (b_count != expected_writes || r_count != expected_reads ||
            r_beats != expected_beats || (expected_reads != 0 && checked_bytes == 0))
            $fatal(1, "Transaction count mismatch B=%0d/%0d R=%0d/%0d beats=%0d/%0d",
                b_count, expected_writes, r_count, expected_reads, r_beats, expected_beats);
        foreach (expected_ar[id])
            if (expected_ar[id].size() != 0) $fatal(1, "Unreturned read ID %0d", id);
        if ((expected_writes != 0 && (peak_w < min_outstanding || peak_unique_w < min_unique)) ||
            (expected_reads != 0 && (peak_r < min_outstanding || peak_unique_r < min_unique)))
            $fatal(1, "Outstanding/ID coverage not reached");
        $display("TX_BUFFER req_peak=%0d req_beats=%0d dat_beats=%0d", tx_req_peak, tx_req_beats, tx_dat_beats);
        for (int vc = 0; vc < NUM_DAT_VC; vc++) $display("TX_DAT_BUFFER vc=%0d peak=%0d", vc, tx_dat_peak[vc]);
        $display("COVERAGE peak_w=%0d peak_r=%0d unique_w=%0d unique_r=%0d",
            peak_w, peak_r, peak_unique_w, peak_unique_r);
        $display("STALL b=%0d r=%0d aw=%0d ar=%0d", b_stall_cnt, r_stall_cnt, aw_stall_cnt, ar_stall_cnt);
        $display("CAPACITY b_full=%0d r_full=%0d dat_full=%0d wr_limit=%0d rd_limit=%0d",
            b_full_cnt, r_full_cnt, dat_full_cnt, wr_limit_cnt, rd_limit_cnt);
        $display("CONCURRENT live=%0d w_during_read=%0d r_during_write=%0d",
            overlap_cnt, w_during_read_cnt, r_during_write_cnt);
        if ((source_response_delay || source_response_hold_cycles != 0) &&
                (b_stall_cnt == 0 || r_stall_cnt == 0))
            $fatal(1, "Response backpressure was not exercised");
        if (check_fifo_capacity != "" && (b_full_cnt == 0 || wr_limit_cnt == 0 || rd_limit_cnt == 0 ||
                aw_stall_cnt == 0 || ar_stall_cnt == 0 ||
                (check_fifo_capacity == "data" ? dat_full_cnt == 0 : r_full_cnt == 0)))
            $fatal(1, "Required capacity saturation was not reached");
        if (concurrent_rw && (overlap_cnt == 0 || w_during_read_cnt == 0 || r_during_write_cnt == 0))
            $fatal(1, "Read/write concurrency was not exercised");
        check_test_conditions();
        if (!scoreboard.drained()) $fatal(1, "AXI ordering checker has pending transactions");
        $display("AXI_ORDERING_CHECK_DRAINED");
        $display("RESPONSE_CHECK expected=%0d writes=%0d read_beats=%0d", response_error, b_count, r_beats);

        $display("NMU_COSIM_COUNTS writes=%0d reads=%0d r_beats=%0d checked_bytes=%0d",
            b_count, r_count, r_beats, checked_bytes);
`ifndef TB_DIRECT_LINK
        cmodel_finalize();
`endif
        checks_done.trigger();
    end
    initial begin
        repeat (100000) @(posedge clk);
        $fatal(1, "NMU co-simulation timeout B=%0d R=%0d", b_count, r_count);
    end
    always @(posedge clk) begin : check_responses
        master_t::ax_beat_t request;
        logic [AXI_ADDR_WIDTH-1:0] address;
        logic [7:0] expected_byte;
        int lane, total_w, total_r, unique_w, unique_r;
        #(ACQ_DELAY);
        if (axi_rst_n && vip.aw_valid && vip.aw_ready) live_w[vip.aw_id]++;
        if (axi_rst_n && vip.ar_valid && vip.ar_ready) live_r[vip.ar_id]++;
        if (axi_rst_n && vip.b_valid && vip.b_ready) begin
            if ($isunknown(vip.b_id) || vip.b_resp !== axi_pkg::resp_t'(response_error))
                $fatal(1, "Invalid B response");
            if (live_w[vip.b_id] == 0) $fatal(1, "Unsolicited B response");
            live_w[vip.b_id]--;
            b_count++;
        end
        if (axi_rst_n && vip.r_valid && vip.r_ready) begin
            if ($isunknown(vip.r_id) || expected_ar[vip.r_id].size() == 0)
                $fatal(1, "Unexpected read ID");
            request = expected_ar[vip.r_id][0];
            if (vip.r_resp !== axi_pkg::resp_t'(response_error) ||
                vip.r_last !== (read_beat[vip.r_id] == int'(request.ax_len)))
                $fatal(1, "Invalid RRESP/RLAST");
            address = request.ax_addr + AXI_ADDR_WIDTH'(read_beat[vip.r_id] << request.ax_size);
            r_beats++;
            if (vip.r_last) begin
                void'(expected_ar[vip.r_id].pop_front());
                read_beat[vip.r_id] = 0;
                if (live_r[vip.r_id] == 0) $fatal(1, "Unsolicited R response");
                live_r[vip.r_id]--;
                r_count++;
            end else read_beat[vip.r_id]++;
        end
        total_w = 0; total_r = 0; unique_w = 0; unique_r = 0;
        foreach (live_w[id]) begin
            total_w += live_w[id]; total_r += live_r[id];
            if (live_w[id] != 0) unique_w++;
            if (live_r[id] != 0) unique_r++;
        end
        if (axi_rst_n) begin
            if (vip.b_valid && !vip.b_ready) b_stall_cnt++;
            if (vip.r_valid && !vip.r_ready) r_stall_cnt++;
            if (vip.aw_valid && !vip.aw_ready) aw_stall_cnt++;
            if (vip.ar_valid && !vip.ar_ready) ar_stall_cnt++;
            if ((dut.i_response_path.i_rx_credit_buffer.ctrl_full && !dut.i_response_path.i_rx_vc_arbiter.is_r)) b_full_cnt++;
            if ((dut.i_response_path.i_rx_credit_buffer.ctrl_full && dut.i_response_path.i_rx_vc_arbiter.is_r)) r_full_cnt++;
            if (|dut.i_response_path.i_rx_credit_buffer.dat_full) dat_full_cnt++;
            if (wr_order_full) wr_limit_cnt++;
            if (rd_order_full) rd_limit_cnt++;
            if (concurrent_active) begin
                if (total_w != 0 && total_r != 0) overlap_cnt++;
                if (total_r != 0 && vip.w_valid && vip.w_ready) w_during_read_cnt++;
                if (total_w != 0 && vip.r_valid && vip.r_ready) r_during_write_cnt++;
            end
        end
        if (total_w > peak_w) peak_w = total_w;
        if (total_r > peak_r) peak_r = total_r;
        if (unique_w > peak_unique_w) peak_unique_w = unique_w;
        if (unique_r > peak_unique_r) peak_unique_r = unique_r;
    end
`ifdef DUMP_WAVE
    initial begin : dump_wave
        string wave_file;
        if (!$value$plusargs("wave_file=%s", wave_file)) wave_file = "ni.fsdb";
        $fsdbDumpfile(wave_file);
        $fsdbDumpvars(0, tb_top, "+all");
    end
`endif
    int perf_cycle = 0, perf_start = -1, perf_end = -1;
    int wr_txn_stall = 0, rd_txn_stall = 0;
    always @(posedge clk) begin
        if (axi_rst_n) begin
            perf_cycle++;
            if (perf_start < 0 && ((vip.aw_valid && vip.aw_ready) || (vip.ar_valid && vip.ar_ready)))
                perf_start = perf_cycle;
            if ((vip.b_valid && vip.b_ready) || (vip.r_valid && vip.r_ready && vip.r_last))
                perf_end = perf_cycle;

        end
    end
    always @(posedge noc_clk) begin
        if (noc_rst_n) begin
            if (wr_order_full && !dut.path_aw_ready) wr_txn_stall++;
            if (rd_order_full && !dut.path_ar_ready) rd_txn_stall++;
        end
    end
    final begin
        $display("CAPACITY_PERF num_ids=%0d per_id=%0d cycles=%0d wr_txn_stall=%0d rd_txn_stall=%0d",
            NUM_IDS, MAX_OUTSTANDING_PER_ID, perf_end-perf_start+1,
            wr_txn_stall, rd_txn_stall);
    end
    `include "ni_stress.svh"
    `include "ni_coverage.svh"
endmodule
