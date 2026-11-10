`timescale 1ns / 1ps

module tb_nmu_elaborate #(parameter int unsigned INVALID_WIDTH = 0);

    logic ACLK;
    logic ARESETn;
    logic noc_clk;
    logic noc_rst_n;

    axi_if #(
        .DATA_W    (noc_payload_pkg::DATA_WIDTH  ),
        .ADDR_W    (noc_payload_pkg::AXI_ADDR_WIDTH  ),
        .ID_W      (noc_payload_pkg::AXI_ID_WIDTH     ),
        .AWUSER_EN (1'b1                           ),
        .AWUSER_W  (noc_payload_pkg::AXI_AWUSER_WIDTH)
    ) axi_if();

    logic                                         tx_req_valid_o;
    logic [noc_payload_pkg::REQ_FLIT_WIDTH-1:0] tx_req_flit_o;
    logic                                         tx_req_ready_i;

    logic                                         rx_rsp_valid_i;
    logic [noc_payload_pkg::RSP_FLIT_WIDTH-1:0] rx_rsp_flit_i;
    logic                                         rx_rsp_ready_o;

    logic tx_dat_valid_o;
    logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] tx_dat_flit_o;
    logic rx_dat_valid_i;
    logic [noc_payload_pkg::DAT_FLIT_WIDTH-1:0] rx_dat_flit_i;

    nmu #(
        .INPUT_ID_WIDTH (noc_payload_pkg::AXI_ID_WIDTH),
        .AXI_ADDR_WIDTH (INVALID_WIDTH == 1 ? 64 : noc_payload_pkg::AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (INVALID_WIDTH == 2 ? 1024 : noc_payload_pkg::DATA_WIDTH),
        .AXI_AWUSER_WIDTH (INVALID_WIDTH == 3 ? 64 : noc_payload_pkg::AXI_AWUSER_WIDTH)
    ) dut (
        .ACLK              (ACLK             ),
        .ARESETn           (ARESETn          ),
        .noc_clk           (noc_clk          ),
        .noc_rst_n         (noc_rst_n        ),
        .axi_wr_i          (axi_if.wr_slv    ),
        .axi_rd_i          (axi_if.rd_slv    ),
        .TXREQVLD    (tx_req_valid_o   ),
        .TXREQ     (tx_req_flit_o    ),
        .TXREQRDY    (tx_req_ready_i   ),
        .RXRSPVLD    (rx_rsp_valid_i   ),
        .RXRSP     (rx_rsp_flit_i    ),
        .RXRSPRDY    (rx_rsp_ready_o   ),
        .TXDATVLD    (tx_dat_valid_o   ),
        .TXDATRDY    ('1),
        .TXDAT     (tx_dat_flit_o    ),
        .RXDATVLD    (rx_dat_valid_i   ),
        .RXDAT     (rx_dat_flit_i    )
    );

    initial begin
        assert ($bits(axi_if.awid) == noc_payload_pkg::AXI_ID_WIDTH)
            else $fatal(1, "AXI request ID width mismatch");
        assert ($bits(axi_if.awaddr) == noc_payload_pkg::AXI_ADDR_WIDTH)
            else $fatal(1, "AXI request address width mismatch");
        assert ($bits(axi_if.wdata) == noc_payload_pkg::DATA_WIDTH)
            else $fatal(1, "AXI request data width mismatch");
        assert ($bits(axi_if.awuser) == noc_payload_pkg::AXI_AWUSER_WIDTH)
            else $fatal(1, "AWUSER width mismatch");
        assert ($bits(tx_req_flit_o) == noc_payload_pkg::REQ_FLIT_WIDTH)
            else $fatal(1, "REQ flit width mismatch");
        assert ($bits(rx_rsp_flit_i) == noc_payload_pkg::RSP_FLIT_WIDTH)
            else $fatal(1, "RSP flit width mismatch");
        assert ($bits(tx_dat_flit_o) == noc_payload_pkg::DAT_FLIT_WIDTH)
            else $fatal(1, "DAT flit width mismatch");
        #1ns;
        if (INVALID_WIDTH != 0) $fatal(1, "Invalid width was not detected");
        $finish;
    end

endmodule
