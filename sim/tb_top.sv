`timescale 1ps / 1ps
`include "axi/assign.svh"
`include "axi/typedef.svh"
`include "axi_vip_connect.svh"
`ifdef TB_DIRECT_LINK
`define NI_NMU dut
`define NI_NSU i_nsu
`define NI_RX_DAT_FULL dut.i_response_path.i_rx_credit_buffer.dat_full
`else
`define NI_NMU gen_node[0].i_ni.i_nmu
`define NI_NSU i_ni.i_nsu
`define NI_RX_DAT_FULL gen_node[0].i_ni.i_dat_rx.dat_full
`endif
module tb_top #(
    parameter int unsigned AXI_CLK_PERIOD_PS         = 1000,
    parameter int unsigned NOC_CLK_PERIOD_PS         = 1000,
    parameter int unsigned NOC_CLK_PHASE_PS          = 0,
    parameter int unsigned INPUT_ID_WIDTH            = ni_test_pkg::NI_INPUT_ID_WIDTH,
    parameter int unsigned OUTPUT_ID_WIDTH           = ni_test_pkg::NI_OUTPUT_ID_WIDTH,
    parameter int unsigned MAX_OUTSTANDING_PER_ID    = ni_test_pkg::NI_MAX_OUTSTANDING_PER_ID,
    parameter int unsigned SOURCE_RESPONSE_DELAY_CYCLES = 4,
    parameter int unsigned RSP_DELAY_CYCLES          = 0,
    parameter int unsigned OUTPUT_REG_TYPE           = ni_test_pkg::NI_OUTPUT_REG_TYPE,
    parameter int unsigned IO_FIFO_DEPTH             = ni_test_pkg::NI_IO_FIFO_DEPTH,
    parameter int unsigned B_ROB_DEPTH               = ni_test_pkg::NI_B_ROB_DEPTH,
    parameter int unsigned R_ROB_DEPTH               = ni_test_pkg::NI_R_ROB_DEPTH,
    parameter bit          R_ROB_EN                  = ni_test_pkg::NI_R_ROB_EN,
    parameter int unsigned DEVICE_ID_WIDTH           = ni_test_pkg::NI_DEVICE_ID_WIDTH,
    parameter int unsigned CONTEXT_DEPTH             = ni_test_pkg::NI_CONTEXT_DEPTH
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
    localparam int NUM_PORTS = NI_NUM_LINKS;
    localparam int NMU_PORT = 0;
    localparam int NUM_NSUS = NI_NUM_NSUS;
    localparam int ROUTER_X = 1;
    localparam int ROUTER_Y = 1;
    localparam int MESH_DIM = 4;
    localparam int NMU_ID = NI_DIRECT_LINK ? ((ROUTER_Y << ni_flit_pkg::X_WIDTH) | ROUTER_X) : 0;
    localparam int NUM_WR_VC = NOC_DAT_VC_MODE == 1 ? NUM_DAT_VC/2 : NUM_DAT_VC;
    initial begin
        if (INPUT_ID_WIDTH != NI_INPUT_ID_WIDTH ||
            OUTPUT_ID_WIDTH != NI_OUTPUT_ID_WIDTH ||
            MAX_OUTSTANDING_PER_ID != NI_MAX_OUTSTANDING_PER_ID ||
            OUTPUT_REG_TYPE != NI_OUTPUT_REG_TYPE ||
            IO_FIFO_DEPTH != NI_IO_FIFO_DEPTH ||
            B_ROB_DEPTH != NI_B_ROB_DEPTH ||
            R_ROB_DEPTH != NI_R_ROB_DEPTH ||
            R_ROB_EN != NI_R_ROB_EN ||
            DEVICE_ID_WIDTH != NI_DEVICE_ID_WIDTH ||
            CONTEXT_DEPTH != NI_CONTEXT_DEPTH ||
            NUM_DAT_VC != NI_NUM_DAT_VC ||
            CREDIT_DEPTH != NI_CREDIT_DEPTH ||
            NOC_DAT_VC_MODE != NI_DAT_VC_MODE) begin
            $fatal(1, "Hardware parameters differ from ni_tb_params.svh; regenerate the profile");
        end
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
    wire wr_order_full = `NI_NMU.path_aw_valid &&
        `NI_NMU.i_response_path.i_ordering.wr_outstanding_cnt_reg[`NI_NMU.path_aw.axi.awid] >= MAX_OUTSTANDING_PER_ID;
    wire rd_order_full = `NI_NMU.path_ar_valid &&
        `NI_NMU.i_response_path.i_ordering.rd_outstanding_cnt_reg[`NI_NMU.path_ar.axi.arid] >= MAX_OUTSTANDING_PER_ID;
    string check_order = "";
    string check_capacity = "";
    string check_fifo_capacity = "";
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
        return ni_nsu_id(port);
    endfunction
    bit corrupt_rsp = 0;
    logic clk = 0, noc_clk = 0;
    wire rst_n = control.rst_n;
    wire axi_rst_n, noc_rst_n;
    ni_tb_if control(clk, axi_rst_n, noc_rst_n);
    int source_response_hold_cycles = 0;
    tvip_axi_if source_axi[NI_NUM_SOURCES](clk, axi_rst_n);
    tvip_axi_if device_axi[NUM_NSUS](clk, axi_rst_n);

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
    wire [NUM_DAT_VC-1:0] tx_dat_valid [NUM_PORTS], rx_dat_valid [NUM_PORTS];
    wire [NUM_DAT_VC-1:0] tx_dat_ready [NUM_PORTS], rx_dat_ready [NUM_PORTS];
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
        assign noc_observe[2*p+0].dat_ready = rx_dat_ready[p];
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
        assign noc_observe[2*p+1].dat_ready = tx_dat_ready[p];
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
`ifdef TB_DIRECT_LINK
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
        .tx_dat_ready_i    (rx_dat_ready[NMU_PORT]),
        .tx_dat_flit_o     (rx_dat_flit[NMU_PORT]),
        .credit_i          (rx_dat_credit[NMU_PORT]),
        .rx_dat_valid_i    (tx_dat_valid[NMU_PORT]),
        .rx_dat_ready_o    (tx_dat_ready[NMU_PORT]),
        .rx_dat_flit_i     (tx_dat_flit[NMU_PORT]),
        .credit_o          (tx_dat_credit[NMU_PORT])
    );
`endif
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
        .tx_dat_ready_i    (tx_dat_ready ),
        .tx_dat_flit_o     (tx_dat_flit  ),
        .credit_i          (tx_dat_credit),
        .rx_dat_valid_i    (rx_dat_valid ),
        .rx_dat_ready_o    (rx_dat_ready ),
        .rx_dat_flit_i     (rx_dat_flit  ),
        .credit_o          (rx_dat_credit)
    );
`elsif TB_CMODEL_ROUTER
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
        .tx_dat_ready    (tx_dat_ready),
        .tx_dat_flit     (tx_dat_flit),
        .credit_i        (tx_dat_credit),
        .rx_dat_valid    (rx_dat_valid),
        .rx_dat_ready    (rx_dat_ready),
        .rx_dat_flit     (rx_dat_flit),
        .credit_o        (rx_dat_credit)
    );
`else
    router_mesh #(

        .MESH_X (MESH_DIM),
        .MESH_Y (MESH_DIM)
    ) i_router (
        .clk_i           (noc_clk),
        .rst_n_i         (noc_rst_n),
        .tx_req_valid_o (tx_req_valid),
        .tx_req_flit_o (tx_req_flit),
        .tx_req_ready_i (tx_req_ready),
        .rx_req_valid_i (rx_req_valid),
        .rx_req_flit_i (rx_req_flit),
        .rx_req_ready_o (rx_req_ready),
        .tx_rsp_valid_o (tx_rsp_valid),
        .tx_rsp_flit_o (tx_rsp_flit),
        .tx_rsp_ready_i (tx_rsp_ready),
        .rx_rsp_valid_i (rx_rsp_valid),
        .rx_rsp_flit_i (rx_rsp_flit),
        .rx_rsp_ready_o (rx_rsp_ready),
        .tx_dat_valid_o (tx_dat_valid),
        .tx_dat_ready_i (tx_dat_ready),
        .tx_dat_flit_o (tx_dat_flit),
        .credit_i        (tx_dat_credit),
        .rx_dat_valid_i (rx_dat_valid),
        .rx_dat_ready_o (rx_dat_ready),
        .rx_dat_flit_i (rx_dat_flit),
        .credit_o        (rx_dat_credit)
    );
`endif
    for (genvar n = 0; n < NUM_NSUS; n++) begin : gen_node
        localparam int PORT = NI_DIRECT_LINK ? n+1 : n;
        localparam int DEVICE = n+1;
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
                response_start_delay.min_delay == (DEVICE == delay_port ? RSP_DELAY_CYCLES : 0);
                response_start_delay.max_delay == (DEVICE == delay_port ? RSP_DELAY_CYCLES : 0);
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
        assign memory_b_blocked[n] = block_b && (response_hold_port == 0 || DEVICE == response_hold_port) &&
            pending_aw > 0 && pending_w > 0;
        assign memory_r_blocked[n] = block_r && (response_hold_port == 0 || DEVICE == response_hold_port) && pending_ar > 0;
        axi_if #(.ADDR_W(AXI_ADDR_WIDTH), .DATA_W(AXI_DATA_WIDTH),
            .ID_W(DEVICE_ID_WIDTH), .AWUSER_W(AXI_AWUSER_WIDTH)) device_bus();
`ifdef TB_DIRECT_LINK
        nsu #(
            .OUTPUT_ID_WIDTH(DEVICE_ID_WIDTH),
            .AXI_AWUSER_WIDTH(AXI_AWUSER_WIDTH),
            .AXI_FIFO_DEPTH(IO_FIFO_DEPTH),
            .AW_CONTEXT_DEPTH(CONTEXT_DEPTH), .AR_CONTEXT_DEPTH(CONTEXT_DEPTH),
            .AW_REG_TYPE(OUTPUT_REG_TYPE), .W_REG_TYPE(OUTPUT_REG_TYPE),
            .AR_REG_TYPE(OUTPUT_REG_TYPE), .B_REG_TYPE(OUTPUT_REG_TYPE),
            .R_REG_TYPE(OUTPUT_REG_TYPE),
            .SRC_ID(ni_flit_pkg::SRC_ID_WIDTH'(nsu_id(DEVICE)))
        ) i_nsu (
            .ACLK(clk), .ARESETn(axi_rst_n), .noc_clk(noc_clk), .noc_rst_n(noc_rst_n),
            .axi_wr_o(device_bus), .axi_rd_o(device_bus),
            .rx_req_valid_i(tx_req_valid[PORT]), .rx_req_flit_i(tx_req_flit[PORT]),
            .rx_req_ready_o(tx_req_ready[PORT]),
            .tx_rsp_valid_o(rx_rsp_valid[PORT]), .tx_rsp_flit_o(rx_rsp_flit[PORT]),
            .tx_rsp_ready_i(rx_rsp_ready[PORT]),
            .tx_dat_valid_o(rx_dat_valid[PORT]), .tx_dat_flit_o(rx_dat_flit[PORT]),
            .tx_dat_ready_i(rx_dat_ready[PORT]),
            .credit_i         (rx_dat_credit[PORT]),
            .rx_dat_valid_i(tx_dat_valid[PORT]), .rx_dat_flit_i(tx_dat_flit[PORT]),
            .rx_dat_ready_o(tx_dat_ready[PORT]),
            .credit_o         (tx_dat_credit[PORT])
        );
`else
        axi_if #(.ADDR_W(AXI_ADDR_WIDTH), .DATA_W(AXI_DATA_WIDTH),
            .ID_W(INPUT_ID_WIDTH), .AWUSER_W(AXI_AWUSER_WIDTH)) source_bus();
        if (n == 0) begin : gen_source
            assign source_bus.awid = bus.awid;
            assign source_bus.awaddr = bus.awaddr;
            assign source_bus.awlen = bus.awlen;
            assign source_bus.awsize = bus.awsize;
            assign source_bus.awburst = bus.awburst;
            assign source_bus.awlock = bus.awlock;
            assign source_bus.awcache = bus.awcache;
            assign source_bus.awprot = bus.awprot;
            assign source_bus.awqos = bus.awqos;
            assign source_bus.awregion = bus.awregion;
            assign source_bus.awuser = bus.awuser;
            assign source_bus.awvalid = bus.awvalid;
            assign source_bus.wdata = bus.wdata;
            assign source_bus.wstrb = bus.wstrb;
            assign source_bus.wlast = bus.wlast;
            assign source_bus.wuser = bus.wuser;
            assign source_bus.wvalid = bus.wvalid;
            assign source_bus.bready = bus.bready;
            assign source_bus.arid = bus.arid;
            assign source_bus.araddr = bus.araddr;
            assign source_bus.arlen = bus.arlen;
            assign source_bus.arsize = bus.arsize;
            assign source_bus.arburst = bus.arburst;
            assign source_bus.arlock = bus.arlock;
            assign source_bus.arcache = bus.arcache;
            assign source_bus.arprot = bus.arprot;
            assign source_bus.arqos = bus.arqos;
            assign source_bus.arregion = bus.arregion;
            assign source_bus.aruser = bus.aruser;
            assign source_bus.arvalid = bus.arvalid;
            assign source_bus.rready = bus.rready;
            assign bus.awready = source_bus.awready;
            assign bus.wready = source_bus.wready;
            assign bus.bid = source_bus.bid;
            assign bus.bresp = source_bus.bresp;
            assign bus.buser = source_bus.buser;
            assign bus.bvalid = source_bus.bvalid;
            assign bus.arready = source_bus.arready;
            assign bus.rid = source_bus.rid;
            assign bus.rdata = source_bus.rdata;
            assign bus.rresp = source_bus.rresp;
            assign bus.rlast = source_bus.rlast;
            assign bus.ruser = source_bus.ruser;
            assign bus.rvalid = source_bus.rvalid;
        end else begin : gen_source_agent
            assign source_bus.awid = source_axi[n].awid;
            assign source_bus.awaddr = source_axi[n].awaddr;
            assign source_bus.awlen = source_axi[n].awlen;
            assign source_bus.awsize = source_axi[n].awsize;
            assign source_bus.awburst = source_axi[n].awburst;
            assign source_bus.awlock = source_axi[n].awlock;
            assign source_bus.awcache = source_axi[n].awcache;
            assign source_bus.awprot = source_axi[n].awprot;
            assign source_bus.awqos = source_axi[n].awqos;
            assign source_bus.awregion = source_axi[n].awregion;
            assign source_bus.awuser = source_axi[n].awuser;
            assign source_bus.awvalid = source_axi[n].awvalid;
            assign source_bus.wdata = source_axi[n].wdata;
            assign source_bus.wstrb = source_axi[n].wstrb;
            assign source_bus.wlast = source_axi[n].wlast;
            assign source_bus.wvalid = source_axi[n].wvalid;
            assign source_bus.bready = source_axi[n].bready;
            assign source_bus.arid = source_axi[n].arid;
            assign source_bus.araddr = source_axi[n].araddr;
            assign source_bus.arlen = source_axi[n].arlen;
            assign source_bus.arsize = source_axi[n].arsize;
            assign source_bus.arburst = source_axi[n].arburst;
            assign source_bus.arlock = source_axi[n].arlock;
            assign source_bus.arcache = source_axi[n].arcache;
            assign source_bus.arprot = source_axi[n].arprot;
            assign source_bus.arqos = source_axi[n].arqos;
            assign source_bus.arregion = source_axi[n].arregion;
            assign source_bus.arvalid = source_axi[n].arvalid;
            assign source_bus.rready = source_axi[n].rready;
            assign source_bus.wuser = '0;
            assign source_bus.aruser = '0;
            assign source_axi[n].awready = source_bus.awready;
            assign source_axi[n].wready = source_bus.wready;
            assign source_axi[n].bid = source_bus.bid;
            assign source_axi[n].bresp = tvip_axi_types_pkg::tvip_axi_response'(source_bus.bresp);
            assign source_axi[n].bvalid = source_bus.bvalid;
            assign source_axi[n].arready = source_bus.arready;
            assign source_axi[n].rid = source_bus.rid;
            assign source_axi[n].rdata = source_bus.rdata;
            assign source_axi[n].rresp = tvip_axi_types_pkg::tvip_axi_response'(source_bus.rresp);
            assign source_axi[n].rlast = source_bus.rlast;
            assign source_axi[n].rvalid = source_bus.rvalid;
            initial begin
                tvip_axi_configuration cfg;
                cfg = tvip_axi_configuration::type_id::create($sformatf("source_cfg%0d", n));
                cfg.vif = source_axi[n];
                cfg.awuser_width = AXI_AWUSER_WIDTH;
                if (!cfg.randomize() with {
                    id_width == INPUT_ID_WIDTH; address_width == AXI_ADDR_WIDTH;
                    data_width == AXI_DATA_WIDTH; max_burst_length == 256;
                    default_bready == 1; default_rready == 1;
                }) $fatal(1, "Source VIP configuration failed");
                uvm_config_db #(tvip_axi_configuration)::set(null, "uvm_test_top.env", $sformatf("source_cfg%0d", n), cfg);
            end
        end
        ni #(
            .NMU_INPUT_ID_WIDTH (INPUT_ID_WIDTH),
            .NMU_OUTPUT_ID_WIDTH (OUTPUT_ID_WIDTH),
            .NMU_MAX_OUTSTANDING_PER_ID (MAX_OUTSTANDING_PER_ID),
            .NMU_B_ROB_DEPTH (B_ROB_DEPTH),
            .NMU_R_ROB_DEPTH (R_ROB_DEPTH),
            .NMU_R_ROB_EN (R_ROB_EN),
            .NMU_AXI_FIFO_DEPTH (IO_FIFO_DEPTH),
            .NMU_REQ_FIFO_DEPTH (IO_FIFO_DEPTH),
            .NMU_RSP_FIFO_DEPTH (IO_FIFO_DEPTH),
            .NSU_OUTPUT_ID_WIDTH (DEVICE_ID_WIDTH),
            .NSU_AXI_AWUSER_WIDTH (AXI_AWUSER_WIDTH),
            .NSU_AXI_FIFO_DEPTH (IO_FIFO_DEPTH),
            .NSU_REQ_FIFO_DEPTH (IO_FIFO_DEPTH),
            .NSU_RSP_FIFO_DEPTH (IO_FIFO_DEPTH),
            .NSU_AW_CONTEXT_DEPTH (CONTEXT_DEPTH),
            .NSU_AR_CONTEXT_DEPTH (CONTEXT_DEPTH),
            .SRC_ID (ni_flit_pkg::SRC_ID_WIDTH'(nsu_id(DEVICE))),
            .NMU_REQ_AW_REG_TYPE (OUTPUT_REG_TYPE),
            .NMU_REQ_W_REG_TYPE (OUTPUT_REG_TYPE),
            .NMU_REQ_AR_REG_TYPE (OUTPUT_REG_TYPE),
            .NMU_DAT_AW_REG_TYPE (OUTPUT_REG_TYPE),
            .NMU_DAT_W_REG_TYPE (OUTPUT_REG_TYPE),
            .NMU_B_REG_TYPE (OUTPUT_REG_TYPE),
            .NMU_R_REG_TYPE (OUTPUT_REG_TYPE),
            .NSU_AW_REG_TYPE (OUTPUT_REG_TYPE),
            .NSU_W_REG_TYPE (OUTPUT_REG_TYPE),
            .NSU_AR_REG_TYPE (OUTPUT_REG_TYPE),
            .NSU_B_REG_TYPE (OUTPUT_REG_TYPE),
            .NSU_R_REG_TYPE (OUTPUT_REG_TYPE)
        ) i_ni (
            .ACLK (clk),
            .ARESETn (axi_rst_n),
            .noc_clk (noc_clk),
            .noc_rst_n (noc_rst_n),
            .axi_wr_i (source_bus),
            .axi_rd_i (source_bus),
            .axi_wr_o (device_bus),
            .axi_rd_o (device_bus),
            .credit_i (rx_dat_credit[PORT]),
            .credit_o (tx_dat_credit[PORT]),
            .tx_req_valid_o (rx_req_valid[PORT]),
            .rx_req_valid_i (tx_req_valid[PORT]),
            .tx_req_flit_o (rx_req_flit[PORT]),
            .rx_req_flit_i (tx_req_flit[PORT]),
            .tx_req_ready_i (rx_req_ready[PORT]),
            .rx_req_ready_o (tx_req_ready[PORT]),
            .tx_rsp_valid_o (rx_rsp_valid[PORT]),
            .rx_rsp_valid_i (tx_rsp_valid[PORT]),
            .tx_rsp_flit_o (rx_rsp_flit[PORT]),
            .rx_rsp_flit_i (tx_rsp_flit[PORT]),
            .tx_rsp_ready_i (rx_rsp_ready[PORT]),
            .rx_rsp_ready_o (tx_rsp_ready[PORT]),
            .tx_dat_valid_o (rx_dat_valid[PORT]),
            .rx_dat_valid_i (tx_dat_valid[PORT]),
            .tx_dat_flit_o (rx_dat_flit[PORT]),
            .rx_dat_flit_i (tx_dat_flit[PORT]),
            .tx_dat_ready_i (rx_dat_ready[PORT]),
            .rx_dat_ready_o (tx_dat_ready[PORT])
        );
`endif

        assign aw_context_full[n] = `NI_NSU.i_response_path.i_context_buffer.i_aw_context.full_o;
        assign ar_context_full[n] = `NI_NSU.i_response_path.i_context_buffer.i_ar_context.full_o;
        assign aw_context_accept[n] = `NI_NSU.aw_context_valid && `NI_NSU.aw_context_ready;
        assign ar_context_accept[n] = `NI_NSU.ar_context_valid && `NI_NSU.ar_context_ready;
        initial begin
            repeat (99990) @(posedge clk);
            $display("NSU_TIMEOUT node=%0d aw_vr=%b%b w_vr=%b%b ar_vr=%b%b b_vr=%b%b r_vr=%b%b", n,
                device_bus.awvalid, device_bus.awready, device_bus.wvalid, device_bus.wready,
                device_bus.arvalid, device_bus.arready, device_bus.bvalid, device_bus.bready,
                device_bus.rvalid, device_bus.rready);
            $display("NSU_CONTEXT node=%0d aw_vr=%b%b ar_vr=%b%b w_valid=%b w_context=%h w_beat=%0d", n,
                `NI_NSU.aw_context_valid, `NI_NSU.aw_context_ready, `NI_NSU.ar_context_valid, `NI_NSU.ar_context_ready,
                `NI_NSU.w_context_valid, `NI_NSU.w_context, `NI_NSU.w_beat);
            $display("NSU_HEAD node=%0d req_vr=%b%b req=%h dat_valid=%b dat_ready=%b dat=%h", n,
                `NI_NSU.i_request_path.rx_req_valid, `NI_NSU.i_request_path.rx_req_ready, `NI_NSU.i_request_path.rx_req_head,
                `NI_NSU.i_request_path.rx_dat_valid, `NI_NSU.i_request_path.rx_dat_ready, `NI_NSU.i_request_path.rx_dat_head);
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
`ifdef TB_DIRECT_LINK
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
`endif
    `NI_AXI_UVM_MASTER(vip, source_axi[0])
`ifdef TB_CMODEL_ROUTER
    import "DPI-C" context function int cmodel_check_error(output string message);
    always @(negedge noc_clk) begin : check_model_error
        string message;
        if (noc_rst_n && cmodel_check_error(message) != 0)
            $fatal(1, "C++ model error: %s", message);
    end
`endif
    int tx_req_peak = 0;
    int tx_dat_peak[NUM_DAT_VC] = '{default:0};
    int tx_req_beats = 0, tx_dat_beats = 0;
    always @(posedge noc_clk) begin
        if (noc_rst_n) begin
            if (int'(`NI_NMU.i_request_path.i_tx_credit_buffer.i_ctrl_fifo.usage_o) > tx_req_peak)
                tx_req_peak = int'(`NI_NMU.i_request_path.i_tx_credit_buffer.i_ctrl_fifo.usage_o);
            if (rx_req_valid[NMU_PORT] && rx_req_ready[NMU_PORT]) tx_req_beats++;
            if (|(rx_dat_valid[NMU_PORT] & rx_dat_ready[NMU_PORT])) tx_dat_beats++;
        end
    end
    for (genvar vc = 0; vc < NUM_DAT_VC; vc++) begin : gen_tx_occupancy
        if (NOC_DAT_VC_MODE == 0 || vc < NUM_DAT_VC/2) begin : gen_write
            always @(posedge noc_clk) begin
                if (noc_rst_n && int'(`NI_NMU.i_request_path.i_tx_credit_buffer.gen_dat_vc[vc].gen_active.i_fifo.usage_o) > tx_dat_peak[vc])
                    tx_dat_peak[vc] = int'(`NI_NMU.i_request_path.i_tx_credit_buffer.gen_dat_vc[vc].gen_active.i_fifo.usage_o);
            end
        end
    end
    int b_full_cnt = 0, r_full_cnt = 0, dat_full_cnt = 0;
    int wr_limit_cnt = 0, rd_limit_cnt = 0;
    assert property (@(posedge clk) disable iff (!axi_rst_n)
        bus.bvalid && !bus.bready |=> bus.bvalid && $stable({bus.bid, bus.bresp}))
        else $fatal(1, "B response changed under backpressure");
    assert property (@(posedge clk) disable iff (!axi_rst_n)
        bus.rvalid && !bus.rready |=> bus.rvalid &&
        $stable({bus.rid, bus.rdata, bus.rresp, bus.rlast}))
        else $fatal(1, "R response changed under backpressure");
`ifdef TB_CMODEL_ROUTER
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
`ifdef TB_CMODEL_ROUTER
        cmodel_init();
        router_ctx = cmodel_router_create("router", ROUTER_X, ROUTER_Y,
            MESH_DIM, MESH_DIM, NUM_DAT_VC);
`endif
        void'($value$plusargs("check_order=%s", check_order));
        void'($value$plusargs("check_capacity=%s", check_capacity));
        void'($value$plusargs("check_fifo_capacity=%s", check_fifo_capacity));
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
        source_response_delay = $test$plusargs("source_response_delay");
        void'($value$plusargs("source_response_hold_cycles=%d", source_response_hold_cycles));
        corrupt_rsp = $test$plusargs("corrupt_rsp");
        begin
            tvip_axi_configuration cfg;
            uvm_config_db #(int)::set(null, "uvm_test_top.env.*", "clock_period_ps", AXI_CLK_PERIOD_PS);
            cfg = tvip_axi_configuration::type_id::create("source_cfg");
            cfg.vif = source_axi[0];
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
            uvm_config_db #(tvip_axi_configuration)::set(null, "uvm_test_top.env", "source_cfg0", cfg);
        end
        uvm_config_db #(virtual ni_tb_if)::set(null, "uvm_test_top", "control", control);
        uvm_config_db #(int)::set(null, "uvm_test_top", "reset_drain_cycles", 2*IO_FIFO_DEPTH+2*CREDIT_DEPTH);
        run_test("ni_test");
    end
    final begin
        if (control.completed) begin
            $display("TX_BUFFER req_peak=%0d req_beats=%0d dat_beats=%0d", tx_req_peak, tx_req_beats, tx_dat_beats);
            for (int vc = 0; vc < NUM_DAT_VC; vc++) $display("TX_DAT_BUFFER vc=%0d peak=%0d", vc, tx_dat_peak[vc]);
            $display("CAPACITY b_full=%0d r_full=%0d dat_full=%0d wr_limit=%0d rd_limit=%0d",
                b_full_cnt, r_full_cnt, dat_full_cnt, wr_limit_cnt, rd_limit_cnt);
            if (check_fifo_capacity != "" && (b_full_cnt == 0 || wr_limit_cnt == 0 || rd_limit_cnt == 0 ||
                    (check_fifo_capacity == "data" ? dat_full_cnt == 0 : r_full_cnt == 0)))
                $fatal(1, "Required capacity saturation was not reached");
            check_test_conditions();
        end
`ifdef TB_CMODEL_ROUTER
        cmodel_finalize();
`endif
    end
    always @(posedge clk) begin
        if (axi_rst_n) begin
            if (`NI_NMU.i_response_path.i_rx_credit_buffer.ctrl_full && !`NI_NMU.i_response_path.i_rx_vc_arbiter.is_r) b_full_cnt++;
            if (`NI_NMU.i_response_path.i_rx_credit_buffer.ctrl_full && `NI_NMU.i_response_path.i_rx_vc_arbiter.is_r) r_full_cnt++;
            if (|`NI_RX_DAT_FULL) dat_full_cnt++;
            if (wr_order_full) wr_limit_cnt++;
            if (rd_order_full) rd_limit_cnt++;
        end
    end
`ifdef DUMP_WAVE
    initial begin : dump_wave
        string wave_file;
        if (!$value$plusargs("wave_file=%s", wave_file)) wave_file = "ni.fsdb";
        $fsdbDumpfile(wave_file);
        $fsdbDumpvars(0, tb_top, "+all");
    end
`endif
`ifdef TB_CMODEL_ROUTER
    always @(negedge rst_n) begin
        repeat (4) @(negedge clk);
        router_ctx = cmodel_router_create("router_after_reset", ROUTER_X, ROUTER_Y,
            MESH_DIM, MESH_DIM, NUM_DAT_VC);
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
            if (wr_order_full && !`NI_NMU.path_aw_ready) wr_txn_stall++;
            if (rd_order_full && !`NI_NMU.path_ar_ready) rd_txn_stall++;
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

`undef NI_NMU
`undef NI_NSU
`undef NI_RX_DAT_FULL
