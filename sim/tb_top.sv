`timescale 1ps / 1ps
`include "axi/assign.svh"
`include "axi/typedef.svh"
module tb_top #(
    parameter int unsigned AXI_CLK_PERIOD_PS         = 1000,
    parameter int unsigned NOC_CLK_PERIOD_PS         = 1000,
    parameter int unsigned NOC_CLK_PHASE_PS          = 0,
    parameter int unsigned INPUT_ID_WIDTH            = ni_params_pkg::AXI_ID_WIDTH,
    parameter int unsigned OUTPUT_ID_WIDTH           = ni_params_pkg::NOC_ID_WIDTH,
    parameter int unsigned MAX_OUTSTANDING_PER_ID    = ni_params_pkg::NMU_MAX_OUTSTANDING_PER_ID,
    parameter int unsigned RSP_DELAY_CYCLES          = 0,
    parameter int unsigned OUTPUT_REG_TYPE           = 0,
    parameter int unsigned IO_FIFO_DEPTH             = 32,
    parameter int unsigned B_ROB_DEPTH               = ni_params_pkg::NMU_ROB_B_DEPTH,
    parameter int unsigned R_ROB_DEPTH               = ni_params_pkg::NMU_ROB_R_DEPTH,
    parameter bit          R_ROB_EN                  = bit'(ni_params_pkg::NMU_R_ROB_EN),
    parameter bit          RTL_NSU                   = 0,
    parameter int unsigned DEVICE_ID_WIDTH           = ni_params_pkg::NSU_AXI_ID_WIDTH,
    parameter int unsigned CONTEXT_DEPTH             = ni_params_pkg::NSU_MAX_OUTSTANDING
);
    import ni_params_pkg::*;
    localparam int unsigned NUM_IDS = 1 << INPUT_ID_WIDTH;
    localparam time CLK_PERIOD = AXI_CLK_PERIOD_PS * 1ps;
    localparam time NOC_CLK_PERIOD = NOC_CLK_PERIOD_PS * 1ps;
    localparam time APPL_DELAY = 0ps;
    localparam time ACQ_DELAY  = CLK_PERIOD / 5;
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
        if (!RTL_NSU && (AXI_CLK_PERIOD_PS != NOC_CLK_PERIOD_PS || NOC_CLK_PHASE_PS != 0))
            $fatal(1, "Independent clocks require RTL NSU");
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
        $display("TX_STORAGE_OLD equal_depth_bits=%0d prior_depth_bits=%0d",
            IO_FIFO_DEPTH*(3*$bits(ni_types_pkg::nmu_aw_request_t)+$bits(ni_types_pkg::nmu_ar_request_t)+
                2*($bits(ni_signals_pkg::axi_w_t)+$bits(ni_types_pkg::nmu_aw_request_t)+ni_flit_pkg::AXI_LEN_WIDTH)),
            NOC_FIFO_DEPTH*(3*$bits(ni_types_pkg::nmu_aw_request_t)+$bits(ni_types_pkg::nmu_ar_request_t)+
                2*($bits(ni_signals_pkg::axi_w_t)+$bits(ni_types_pkg::nmu_aw_request_t)+ni_flit_pkg::AXI_LEN_WIDTH)));
    end
    wire wr_order_full = dut.path_aw_valid &&
        dut.i_response_path.i_ordering.wr_outstanding_cnt_reg[dut.path_aw.axi.awid] >= MAX_OUTSTANDING_PER_ID;
    wire rd_order_full = dut.path_ar_valid &&
        dut.i_response_path.i_ordering.rd_outstanding_cnt_reg[dut.path_ar.axi.arid] >= MAX_OUTSTANDING_PER_ID;
    int reorder_test = 0;
    int stress_test = 0;
    string capacity_target = "per_id";
    int response_error = 0;
    bit response_backpressure = 0;
    bit response_random_delay = 0;
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
        .AXI_ID_WIDTH   (INPUT_ID_WIDTH),
        .AXI_USER_WIDTH (AXI_AWUSER_WIDTH)) vip(clk);
    axi_if #(.ADDR_W(AXI_ADDR_WIDTH), .DATA_W(AXI_DATA_WIDTH),
        .ID_W     (INPUT_ID_WIDTH),
        .AWUSER_W (AXI_AWUSER_WIDTH)) bus();
    typedef logic [AXI_ADDR_WIDTH-1:0] mon_addr_t;
    localparam int MON_ID_WIDTH = INPUT_ID_WIDTH > DEVICE_ID_WIDTH ? INPUT_ID_WIDTH : DEVICE_ID_WIDTH;
    typedef logic [MON_ID_WIDTH-1:0] mon_id_t;
    typedef logic [AXI_DATA_WIDTH-1:0] mon_data_t;
    typedef logic [AXI_DATA_WIDTH/8-1:0] mon_strb_t;
    typedef logic [AXI_AWUSER_WIDTH-1:0] mon_user_t;
    `AXI_TYPEDEF_ALL(mon, mon_addr_t, mon_id_t, mon_data_t, mon_strb_t, mon_user_t)
    typedef struct packed {
        int unsigned idx;
        mon_addr_t start_addr;
        mon_addr_t end_addr;
    } mon_rule_t;
    function automatic mon_rule_t [topology_pkg::SAM_NUM_RULES-1:0] monitor_rules();
        for (int r = 0; r < topology_pkg::SAM_NUM_RULES; r++) begin
            monitor_rules[r].start_addr = topology_pkg::SAM[r].start_addr;
            monitor_rules[r].end_addr   = topology_pkg::SAM[r].end_addr;
            for (int n = 0; n < NUM_NSUS; n++) begin
                if (topology_pkg::SAM[r].idx.dst_id == nsu_id(n+1))
                    monitor_rules[r].idx = n;
            end
        end
    endfunction
    localparam mon_rule_t [topology_pkg::SAM_NUM_RULES-1:0] MON_RULES = monitor_rules();
    mon_req_t mon_mst_raw;
    mon_req_t mon_mst_req;
    mon_resp_t mon_mst_rsp;
    mon_req_t [NUM_NSUS-1:0] mon_slv_req;
    mon_resp_t [NUM_NSUS-1:0] mon_slv_rsp;
    wire ordering_done;
    `AXI_ASSIGN_TO_REQ(mon_mst_raw, vip)
    // RTL preserves opaque AWUSER; upper collective fields terminate in the NI.
    // The reference-model port omits AWUSER. WUSER/ARUSER are tied off.
    always_comb begin
        mon_mst_req         = mon_mst_raw;
        mon_mst_req.aw.user = RTL_NSU ? mon_user_t'(mon_mst_raw.aw.user[ni_flit_pkg::AXI_USER_WIDTH-1:0]) : '0;
        mon_mst_req.w.user  = '0;
        mon_mst_req.ar.user = '0;
    end
    `AXI_ASSIGN_TO_RESP(mon_mst_rsp, vip)
    axi_reorder_compare #(
        .NumSlaves      (NUM_NSUS),
        .AxiIdWidth     (MON_ID_WIDTH),
        .NumAddrRegions (topology_pkg::SAM_NUM_RULES),
        .addr_t         (mon_addr_t),
        .rule_t         (mon_rule_t),
        .AddrRegions    (MON_RULES),
        .aw_chan_t      (mon_aw_chan_t),
        .w_chan_t       (mon_w_chan_t),
        .b_chan_t       (mon_b_chan_t),
        .ar_chan_t      (mon_ar_chan_t),
        .r_chan_t       (mon_r_chan_t),
        .req_t          (mon_req_t),
        .rsp_t          (mon_resp_t)
    ) i_ordering_checker (
        .clk_i          (clk),
        .rst_ni         (axi_rst_n),
        .mon_mst_req_i  (mon_mst_req),
        .mon_mst_rsp_i  (mon_mst_rsp),
        .mon_slv_req_i  (mon_slv_req),
        .mon_slv_rsp_i  (mon_slv_rsp),
        .end_of_sim_o   (ordering_done)
    );
    longint unsigned router_ctx, nsu_ctx[NUM_NSUS];
    wire [NUM_PORTS-1:0] tx_req_valid, rx_req_valid;
    wire [NOC_REQ_FLIT_WIDTH-1:0] tx_req_flit [NUM_PORTS], rx_req_flit [NUM_PORTS];
    wire [NUM_PORTS-1:0] tx_rsp_valid, rx_rsp_valid;
    wire [NOC_RSP_FLIT_WIDTH-1:0] tx_rsp_flit [NUM_PORTS], rx_rsp_flit [NUM_PORTS];
    wire [NUM_PORTS-1:0] tx_dat_valid, rx_dat_valid;
    wire [NOC_DAT_FLIT_WIDTH-1:0] tx_dat_flit [NUM_PORTS], rx_dat_flit [NUM_PORTS];
    wire [NUM_PORTS-1:0] tx_req_ready, rx_req_ready, tx_rsp_ready, rx_rsp_ready;
    wire [NUM_DAT_VC-1:0] tx_dat_credit [NUM_PORTS], rx_dat_credit [NUM_PORTS];
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
    initial if (!RTL_NSU) $fatal(1, "Direct-link environment requires RTL NSU");
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
        ni_signals_pkg::axi_req_t mem_req;
        ni_signals_pkg::axi_rsp_t mem_rsp;
        AXI_BUS #(.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
            .AXI_ID_WIDTH   (DEVICE_ID_WIDTH),
            .AXI_USER_WIDTH (AXI_AWUSER_WIDTH)) delayed_bus();
        `AXI_ASSIGN_TO_REQ(mon_slv_req[n], mem_bus)
        `AXI_ASSIGN_TO_RESP(mon_slv_rsp[n], mem_bus)
        initial begin : preload_memory
            string directory;
            int error_code;
            if ($value$plusargs("response_error=%d", error_code)) begin
                if (!(error_code inside {2, 3})) $fatal(1, "Invalid response_error");
                if (!$value$plusargs("stim_dir=%s", directory)) $fatal(1, "Missing stim_dir");
                $readmemh({directory, "/rerr.mem"}, i_memory.i_sim_mem.rerr);
                $readmemh({directory, "/werr.mem"}, i_memory.i_sim_mem.werr);
            end
            if ($test$plusargs("preload")) begin
                if (!$value$plusargs("stim_dir=%s", directory)) $fatal(1, "Missing stim_dir");
                $readmemh({directory, "/preload.mem"}, i_memory.i_sim_mem.mem);
            end
        end
        int b_wait_start = -1, r_wait_start = -1;
        int sample_cycle = 0;
        always @(posedge clk) begin
            if (axi_rst_n) begin
                sample_cycle++;
                if (mem_bus.aw_valid && mem_bus.aw_ready) dst_wr_cnt[n]++;
                if (mem_bus.ar_valid && mem_bus.ar_ready) dst_rd_cnt[n]++;
                if (reorder_test != 0 && PORT == 4) begin
                    if (delayed_bus.b_valid && b_wait_start < 0) b_wait_start = sample_cycle;
                    if (mem_bus.b_valid && mem_bus.b_ready && b_wait_start >= 0) begin
                        $display("DELAY_SAMPLE channel=B cycles=%0d", sample_cycle - b_wait_start);
                        b_wait_start = -1;
                    end
                    if (delayed_bus.r_valid && r_wait_start < 0) r_wait_start = sample_cycle;
                    if (mem_bus.r_valid && mem_bus.r_ready && r_wait_start >= 0) begin
                        $display("DELAY_SAMPLE channel=R cycles=%0d", sample_cycle - r_wait_start);
                        r_wait_start = -1;
                    end
                end
            end
        end
        if (RTL_NSU) begin : gen_rtl_nsu
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
`ifndef TB_DIRECT_LINK
        else begin : gen_cmodel_nsu
        nsu_wrap i_nsu (
            .clk_i             (noc_clk),
            .rst_n_i           (noc_rst_n),
            .ctx_i             (nsu_ctx[n]),
            .rx_req_valid_i    (tx_req_valid[PORT]),
            .rx_req_flit_i     (tx_req_flit[PORT]),
            .rx_req_ready_o    (tx_req_ready[PORT]),
            .tx_rsp_valid_o    (rx_rsp_valid[PORT]),
            .tx_rsp_flit_o     (rx_rsp_flit[PORT]),
            .tx_rsp_ready_i    (rx_rsp_ready[PORT]),
            .tx_dat_valid_o    (rx_dat_valid[PORT]),
            .tx_dat_flit_o     (rx_dat_flit[PORT]),
            .tx_dat_crdvalid_i (rx_dat_credit[PORT]),
            .rx_dat_valid_i    (tx_dat_valid[PORT]),
            .rx_dat_flit_i     (tx_dat_flit[PORT]),
            .rx_dat_crdvalid_o (tx_dat_credit[PORT]),
            .axi_req_o         (mem_req),
            .axi_rsp_i         (mem_rsp)
        );
        assign mem_bus.aw_id = mem_req.awid;
        assign mem_bus.aw_addr = mem_req.awaddr;
        assign mem_bus.aw_len = mem_req.awlen;
        assign mem_bus.aw_size = mem_req.awsize;
        assign mem_bus.aw_burst = mem_req.awburst;
        assign mem_bus.aw_lock = mem_req.awlock;
        assign mem_bus.aw_cache = mem_req.awcache;
        assign mem_bus.aw_prot = mem_req.awprot;
        assign mem_bus.aw_qos = mem_req.awqos;
        assign mem_bus.aw_region = mem_req.awregion;
        assign mem_bus.aw_valid = mem_req.awvalid;
        assign mem_bus.w_data = mem_req.wdata;
        assign mem_bus.w_strb = mem_req.wstrb;
        assign mem_bus.w_last = mem_req.wlast;
        assign mem_bus.w_valid = mem_req.wvalid;
        assign mem_bus.ar_id = mem_req.arid;
        assign mem_bus.ar_addr = mem_req.araddr;
        assign mem_bus.ar_len = mem_req.arlen;
        assign mem_bus.ar_size = mem_req.arsize;
        assign mem_bus.ar_burst = mem_req.arburst;
        assign mem_bus.ar_lock = mem_req.arlock;
        assign mem_bus.ar_cache = mem_req.arcache;
        assign mem_bus.ar_prot = mem_req.arprot;
        assign mem_bus.ar_qos = mem_req.arqos;
        assign mem_bus.ar_region = mem_req.arregion;
        assign mem_bus.ar_valid = mem_req.arvalid;
        assign mem_bus.aw_user = '0;
        assign mem_bus.aw_atop = '0;
        assign mem_bus.w_user = '0;
        assign mem_bus.ar_user = '0;
        assign mem_bus.b_ready = mem_req.bready;
        assign mem_bus.r_ready = mem_req.rready;
        assign mem_rsp.awready = mem_bus.aw_ready;
        assign mem_rsp.wready = mem_bus.w_ready;
        assign mem_rsp.arready = mem_bus.ar_ready;
        assign mem_rsp.bid = mem_bus.b_id;
        assign mem_rsp.bresp = mem_bus.b_resp;
        assign mem_rsp.bvalid = mem_bus.b_valid;
        assign mem_rsp.rid = mem_bus.r_id;
        assign mem_rsp.rdata = mem_bus.r_data;
        assign mem_rsp.rresp = mem_bus.r_resp;
        assign mem_rsp.rlast = mem_bus.r_last;
        assign mem_rsp.rvalid = mem_bus.r_valid;
        end
`endif
        AXI_BUS #(
            .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
            .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
            .AXI_ID_WIDTH   (DEVICE_ID_WIDTH),
            .AXI_USER_WIDTH (AXI_AWUSER_WIDTH)
        ) request_delay_bus();
        axi_delayer_intf #(
            .AXI_ID_WIDTH        (DEVICE_ID_WIDTH),
            .AXI_ADDR_WIDTH      (AXI_ADDR_WIDTH),
            .AXI_DATA_WIDTH      (AXI_DATA_WIDTH),
            .AXI_USER_WIDTH      (AXI_AWUSER_WIDTH),
            .STALL_RANDOM_INPUT  (1'b1),
            .STALL_RANDOM_OUTPUT (1'b0),
            .FIXED_DELAY_INPUT   (0),
            .FIXED_DELAY_OUTPUT  (0)
        ) i_request_delay (
            .clk_i    (clk),
            .rst_ni   (axi_rst_n),
            .bypass_i (!response_backpressure),
            .slv      (mem_bus),
            .mst      (request_delay_bus)
        );
`ifdef NI_COVERAGE
        aw_stall_recover: cover property (@(posedge clk) disable iff (!axi_rst_n)
            mem_bus.aw_valid && !mem_bus.aw_ready ##[1:64] mem_bus.aw_valid && mem_bus.aw_ready);
        w_stall_recover: cover property (@(posedge clk) disable iff (!axi_rst_n)
            mem_bus.w_valid && !mem_bus.w_ready ##[1:64] mem_bus.w_valid && mem_bus.w_ready);
        ar_stall_recover: cover property (@(posedge clk) disable iff (!axi_rst_n)
            mem_bus.ar_valid && !mem_bus.ar_ready ##[1:64] mem_bus.ar_valid && mem_bus.ar_ready);
`endif
        AXI_BUS #(
            .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
            .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
            .AXI_ID_WIDTH   (DEVICE_ID_WIDTH),
            .AXI_USER_WIDTH (AXI_AWUSER_WIDTH)
        ) response_delay_bus();
        axi_delayer_intf #(
            .AXI_ID_WIDTH        (DEVICE_ID_WIDTH),
            .AXI_ADDR_WIDTH      (AXI_ADDR_WIDTH),
            .AXI_DATA_WIDTH      (AXI_DATA_WIDTH),
            .AXI_USER_WIDTH      (AXI_AWUSER_WIDTH),
            .STALL_RANDOM_INPUT  (1'b0),
            .STALL_RANDOM_OUTPUT (1'b1),
            .FIXED_DELAY_INPUT   (0),
            .FIXED_DELAY_OUTPUT  (0)
        ) i_response_delay (
            .clk_i    (clk),
            .rst_ni   (axi_rst_n),
            .bypass_i (!response_random_delay),
            .slv      (request_delay_bus),
            .mst      (response_delay_bus)
        );
        wire delay_en = reorder_test != 0 && PORT == 4;
        if (RSP_DELAY_CYCLES == 0) begin : gen_no_delay
            `AXI_ASSIGN(delayed_bus, response_delay_bus)
        end else begin : gen_rsp_delay
            AXI_BUS #(
                .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
                .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
                .AXI_ID_WIDTH   (DEVICE_ID_WIDTH),
                .AXI_USER_WIDTH (AXI_AWUSER_WIDTH)
            ) delay_bus[RSP_DELAY_CYCLES+1]();
            `AXI_ASSIGN(delay_bus[0], response_delay_bus)
            `AXI_ASSIGN(delayed_bus, delay_bus[RSP_DELAY_CYCLES])
            // One-cycle upstream cells make the sweep include every integer delay.
            for (genvar stage = 0; stage < RSP_DELAY_CYCLES; stage++) begin : gen_stage
                axi_delayer_intf #(
                    .AXI_ID_WIDTH        (DEVICE_ID_WIDTH),
                    .AXI_ADDR_WIDTH      (AXI_ADDR_WIDTH),
                    .AXI_DATA_WIDTH      (AXI_DATA_WIDTH),
                    .AXI_USER_WIDTH      (AXI_AWUSER_WIDTH),
                    .STALL_RANDOM_INPUT  (1'b0),
                    .STALL_RANDOM_OUTPUT (1'b0),
                    .FIXED_DELAY_INPUT   (0),
                    .FIXED_DELAY_OUTPUT  (1)
                ) i_rsp_delay (
                    .clk_i    (clk),
                    .rst_ni   (axi_rst_n),
                    .bypass_i (!delay_en),
                    .slv      (delay_bus[stage]),
                    .mst      (delay_bus[stage+1])
                );
            end
        end
        AXI_BUS #(.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
            .AXI_ID_WIDTH(DEVICE_ID_WIDTH), .AXI_USER_WIDTH(AXI_AWUSER_WIDTH)) memory_bus();
        typedef logic [DEVICE_ID_WIDTH-1:0] memory_id_t;
        `AXI_TYPEDEF_ALL(gate, mon_addr_t, memory_id_t, mon_data_t, mon_strb_t, mon_user_t)
        gate_req_t gate_req, memory_req;
        gate_resp_t gate_rsp, memory_rsp;
        wire stop_b = block_b && (response_backpressure ? PORT == 1 : stress_test != 2 || n == 0 || !aw_context_full[0]);
        wire stop_r = block_r && (response_backpressure ? PORT == 1 : stress_test != 2 || n == 0 || !ar_context_full[0]);
        `AXI_ASSIGN_TO_REQ(gate_req, delayed_bus)
        `AXI_ASSIGN_FROM_RESP(delayed_bus, gate_rsp)
        `AXI_ASSIGN_FROM_REQ(memory_bus, memory_req)
        `AXI_ASSIGN_TO_RESP(memory_rsp, memory_bus)
        always_comb begin
            memory_req = gate_req;
            gate_rsp = memory_rsp;
            memory_req.b_ready = gate_req.b_ready && !stop_b;
            memory_req.r_ready = gate_req.r_ready && !stop_r;
            gate_rsp.b_valid = memory_rsp.b_valid && !stop_b;
            gate_rsp.r_valid = memory_rsp.r_valid && !stop_r;
        end
        assign memory_b_blocked[n] = stop_b && memory_rsp.b_valid;
        assign memory_r_blocked[n] = stop_r && memory_rsp.r_valid;
        axi_sim_mem_intf #(
            .AXI_ADDR_WIDTH     (AXI_ADDR_WIDTH),
            .AXI_DATA_WIDTH     (AXI_DATA_WIDTH),
            .AXI_ID_WIDTH       (DEVICE_ID_WIDTH),
            .AXI_USER_WIDTH     (AXI_AWUSER_WIDTH),
            .WARN_UNINITIALIZED (1'b1),
            .UNINITIALIZED_DATA ("undefined"),
            .APPL_DELAY         (APPL_DELAY),
            .ACQ_DELAY          (ACQ_DELAY)
        ) i_memory (
            .clk_i              (clk),
            .rst_ni             (axi_rst_n),
            .axi_slv            (memory_bus),
            .mon_w_valid_o      (),
            .mon_w_addr_o       (),
            .mon_w_data_o       (),
            .mon_w_id_o         (),
            .mon_w_user_o       (),
            .mon_w_beat_count_o (),
            .mon_w_last_o       (),
            .mon_r_valid_o      (),
            .mon_r_addr_o       (),
            .mon_r_data_o       (),
            .mon_r_id_o         (),
            .mon_r_user_o       (),
            .mon_r_beat_count_o (),
            .mon_r_last_o       ()
        );
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
        .AW (AXI_ADDR_WIDTH),
        .DW (AXI_DATA_WIDTH),
        .IW (INPUT_ID_WIDTH),
        .UW (AXI_AWUSER_WIDTH),
        .TA (APPL_DELAY),
        .TT (ACQ_DELAY)
    ) master_t;
    typedef axi_test::axi_scoreboard #(
        .AW (AXI_ADDR_WIDTH),
        .DW (AXI_DATA_WIDTH),
        .IW (INPUT_ID_WIDTH),
        .UW (AXI_AWUSER_WIDTH),
        .TT (ACQ_DELAY)
    ) scoreboard_base_t;
    class scoreboard_t extends scoreboard_base_t;
        function new(virtual AXI_BUS_DV #(
            .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
            .AXI_ID_WIDTH(INPUT_ID_WIDTH), .AXI_USER_WIDTH(AXI_AWUSER_WIDTH)) axi);
            super.new(axi);
        endfunction
        task preload(input string filename);
            logic [7:0] bytes[axi_addr_t];
            $readmemh(filename, bytes);
            foreach (bytes[address]) memory_q[address].push_back(bytes[address]);
        endtask
    endclass
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
    scoreboard_t scoreboard;
    int init_phase = 0, concurrent_rw = 0, stall_cycles = 0, hold_cycles = 0;
    int capacity_test = 0, data_case = 0;
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

    task automatic receive_b();
        master_t::b_beat_t beat;
        if (hold_cycles != 0) begin
            wait (vip.b_valid);
            repeat (hold_cycles) @(posedge clk);
        end
        if (stall_cycles == 0) begin
            master.wait_b();
        end else begin
            while (master.b_outst.size() != 0) begin
                wait (vip.b_valid);
                repeat (stall_cycles) @(posedge clk);
                master.drv.recv_b(beat);
                void'(master.b_outst.pop_front());
            end
        end
    endtask

    task automatic receive_r();
        master_t::r_beat_t beat;
        if (hold_cycles != 0) begin
            wait (vip.r_valid);
            repeat (hold_cycles) @(posedge clk);
        end
        if (stall_cycles == 0) begin
            master.wait_r();
        end else begin
            while (master.r_outst.size() != 0) begin
                wait (vip.r_valid);
                repeat (stall_cycles) @(posedge clk);
                master.drv.recv_r(beat);
                if (beat.r_last) void'(master.r_outst.pop_front());
            end
        end
    endtask

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
    import "DPI-C" context function longint unsigned cmodel_nsu_create(
        input string name, input int src_id, num_vc, max_ids, max_outstanding,
        port_id, input string config_path);
    import "DPI-C" context function void cmodel_nsu_set_dat_credit_depth(
        input longint unsigned ctx, input int depth);
`endif
    initial begin : run
        string stim_dir;
        int first_char;
`ifndef TB_DIRECT_LINK
        cmodel_init();
        router_ctx = cmodel_router_create("router", ROUTER_X, ROUTER_Y,
            MESH_DIM, MESH_DIM, NUM_DAT_VC);
        for (int n = 0; n < NUM_NSUS; n++) begin
            if (!RTL_NSU) begin
            nsu_ctx[n] = cmodel_nsu_create($sformatf("nsu_%0d", n + 1), nsu_id(n + 1),
                NUM_DAT_VC, NSU_META_BUFFER_MAX_UNIQUE_IDS,
                NSU_META_BUFFER_MAX_OUTSTANDING, 0, "");
            cmodel_nsu_set_dat_credit_depth(nsu_ctx[n], CREDIT_DEPTH);
            end
        end
`endif
        void'($value$plusargs("stress_test=%d", stress_test));
        void'($value$plusargs("capacity_target=%s", capacity_target));
        void'($value$plusargs("response_error=%d", response_error));
        response_backpressure = $test$plusargs("response_backpressure");
        response_random_delay = $test$plusargs("response_random_delay");
        void'($value$plusargs("response_hold_cycles=%d", response_hold_cycles));
        if (response_hold_cycles < 0) $fatal(1, "Negative response hold");
        $display("SLAVE_RESPONSE_DELAY random=%0d hold_cycles=%0d",
            response_random_delay, response_hold_cycles);
        if (stress_test != 0 && !RTL_NSU) $fatal(1, "Stress cases require RTL NSU");
        void'($value$plusargs("reorder_test=%d", reorder_test));
        $display("RESPONSE_DELAY enabled=%0d west_setting=%0d", reorder_test != 0, RSP_DELAY_CYCLES);
        $display("DAT_CREDIT_DEPTH router=%0d nmu_rx=%0d nsu_rx=%0d",
            CREDIT_DEPTH, CREDIT_DEPTH, CREDIT_DEPTH);
        master = new(vip);
        scoreboard = new(vip);
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
        void'($value$plusargs("min_outstanding=%d", min_outstanding));
        void'($value$plusargs("min_unique=%d", min_unique));
        expected_writes = master.num_writes;
        expected_reads = master.num_reads;
        expected_beats = 0;
        expect_reads(master);
        void'($value$plusargs("init_phase=%d", init_phase));
        void'($value$plusargs("concurrent_rw=%d", concurrent_rw));
        void'($value$plusargs("stall_cycles=%d", stall_cycles));
        void'($value$plusargs("hold_cycles=%d", hold_cycles));
        void'($value$plusargs("capacity_test=%d", capacity_test));
        void'($value$plusargs("data_case=%d", data_case));
        if (init_phase) begin
            init_master = new(vip);
            init_master.write_fd = $fopen({stim_dir, "/init_write.txt"}, "r");
            if (!init_master.write_fd) $fatal(1, "Missing initialization writes");
            init_master.parse_write();
            $fclose(init_master.write_fd);
            init_master.num_writes = init_master.aw_queue.size();
            expected_writes += init_master.num_writes;
        end
        if (concurrent_rw) begin
            verify_master = new(vip);
            verify_master.read_fd = $fopen({stim_dir, "/verify_read.txt"}, "r");
            if (!verify_master.read_fd) $fatal(1, "Missing verification reads");
            verify_master.parse_read();
            $fclose(verify_master.read_fd);
            verify_master.num_reads = verify_master.ar_queue.size();
            expected_reads += verify_master.num_reads;
            expect_reads(verify_master);
        end
        if ($test$plusargs("preload")) scoreboard.preload({stim_dir, "/preload.mem"});
        if (expected_writes == 0 && expected_reads == 0)
            $fatal(1, "Empty memory test");
        repeat (5) @(negedge clk);
        rst_n = 1;
        wait (axi_rst_n && noc_rst_n);
        @(posedge clk);
        start_scoreboard();
        if (stress_test == 3) run_reset_recovery(stim_dir);
        if (init_phase) begin
            fork init_master.run_aw(); init_master.run_w(); init_master.wait_b(); join
        end
        if (concurrent_rw) begin
            concurrent_active = 1'b1;
            master.run();
            concurrent_active = 1'b0;
            fork verify_master.run_ar(); verify_master.wait_r(); join
        end else begin
            if (expected_writes != 0) begin
                start_stress_phase(0);
                fork master.run_aw(); master.run_w(); receive_b(); join
            end
            if (expected_reads != 0) begin
                start_stress_phase(1);
                fork master.run_ar(); receive_r(); join
            end
        end
        repeat (10) @(posedge clk);
        if (b_count != expected_writes || r_count != expected_reads ||
            r_beats != expected_beats || (expected_reads != 0 && checked_bytes == 0))
            $fatal(1, "Transaction count mismatch");
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
        if ((stall_cycles != 0 || hold_cycles != 0) &&
                (b_stall_cnt == 0 || r_stall_cnt == 0))
            $fatal(1, "Response backpressure was not exercised");
        if (capacity_test && stress_test == 0 && (b_full_cnt == 0 || wr_limit_cnt == 0 || rd_limit_cnt == 0 ||
                aw_stall_cnt == 0 || ar_stall_cnt == 0 ||
                (data_case ? dat_full_cnt == 0 : r_full_cnt == 0)))
            $fatal(1, "Required capacity saturation was not reached");
        if (concurrent_rw && (overlap_cnt == 0 || w_during_read_cnt == 0 || r_during_write_cnt == 0))
            $fatal(1, "Read/write concurrency was not exercised");
        check_stress();
        if (!ordering_done) $fatal(1, "AXI ordering checker has pending transactions");
        $display("AXI_ORDERING_CHECK_DRAINED");
        $display("RESPONSE_CHECK expected=%0d writes=%0d read_beats=%0d", response_error, b_count, r_beats);
        scoreboard.reset();
        $display("NMU_COSIM_COUNTS writes=%0d reads=%0d r_beats=%0d checked_bytes=%0d",
            b_count, r_count, r_beats, checked_bytes);
`ifndef TB_DIRECT_LINK
        cmodel_finalize();
`endif
        $finish;
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
            for (int byte_idx = 0; byte_idx < (1 << request.ax_size); byte_idx++) begin
                lane = int'(address % (AXI_DATA_WIDTH/8)) + byte_idx;
                scoreboard.get_byte(address + AXI_ADDR_WIDTH'(byte_idx), expected_byte);
                if ($isunknown(expected_byte) || $isunknown(vip.r_data[lane*8 +: 8]))
                    $fatal(1, "Read comparison contains uninitialized data id=%0d addr=%h lane=%0d expected=%h actual=%h",
                        vip.r_id, address, lane, expected_byte, vip.r_data[lane*8 +: 8]);
                checked_bytes++;
            end
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
