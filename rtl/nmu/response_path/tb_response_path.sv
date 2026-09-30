`timescale 1ns / 1ps

// Focused CDC/reset check; full response path is covered by standalone.
module tb_nmu_response_path;
    logic noc_clk_i = 0, axi_clk_i = 0;
    logic noc_rst_n_i = 0, axi_rst_n_i = 0;
    ni_signals_pkg::noc_axi_b_t s_b_i, m_b_o;
    ni_signals_pkg::noc_axi_r_t s_r_i, m_r_o;
    logic                   s_b_valid_i, s_b_ready_o, s_r_valid_i, s_r_ready_o;
    logic                   m_b_valid_o, m_b_ready_i, m_r_valid_o, m_r_ready_i;

    nmu_response_fifo #(
        .AXI_FIFO_DEPTH (4                      ),
        .b_t            (ni_signals_pkg::noc_axi_b_t),
        .r_t            (ni_signals_pkg::noc_axi_r_t)
    ) dut (
        .noc_clk_i   (noc_clk_i  ),
        .noc_rst_n_i (noc_rst_n_i),
        .axi_clk_i   (axi_clk_i  ),
        .axi_rst_n_i (axi_rst_n_i),
        .s_b_data_i  (s_b_i      ),
        .s_b_valid_i (s_b_valid_i),
        .s_b_ready_o (s_b_ready_o),
        .s_r_data_i  (s_r_i      ),
        .s_r_valid_i (s_r_valid_i),
        .s_r_ready_o (s_r_ready_o),
        .m_b_data_o  (m_b_o      ),
        .m_b_valid_o (m_b_valid_o),
        .m_b_ready_i (m_b_ready_i),
        .m_r_data_o  (m_r_o      ),
        .m_r_valid_o (m_r_valid_o),
        .m_r_ready_i (m_r_ready_i)
    );

    always #5ns noc_clk_i = !noc_clk_i;
    always #3ns axi_clk_i = !axi_clk_i;

    task automatic send_pair;
        @(negedge noc_clk_i);
        s_b_valid_i = 1;
        s_r_valid_i = 1;
        fork
            begin
                do @(posedge noc_clk_i); while (!s_b_ready_o);
                @(negedge noc_clk_i); s_b_valid_i = 0;
            end
            begin
                do @(posedge noc_clk_i); while (!s_r_ready_o);
                @(negedge noc_clk_i); s_r_valid_i = 0;
            end
        join
    endtask

    task automatic check_pair;
        wait(m_b_valid_o && m_r_valid_o);
        @(negedge axi_clk_i);
        if (m_b_o !== s_b_i || m_r_o !== s_r_i)
            $fatal(1, "B/R changed across response FIFO");
        m_r_ready_i = 1;
        @(negedge axi_clk_i);
        if (!m_b_valid_o || m_r_valid_o) $fatal(1, "B/R FIFO independence failed");
        m_b_ready_i = 1;
        @(negedge axi_clk_i);
        m_b_ready_i = 0;
        m_r_ready_i = 0;
    endtask

    initial begin
        int seed, unused;
        seed = 1;
        void'($value$plusargs("seed=%d", seed));
        unused = $urandom(seed);
        s_b_i = '0; s_r_i = '0; s_b_valid_i = 0; s_r_valid_i = 0;
        m_b_ready_i = 0; m_r_ready_i = 0;
        repeat (3) @(negedge noc_clk_i); noc_rst_n_i = 1;
        repeat (3) @(negedge axi_clk_i); axi_rst_n_i = 1;
        s_b_i.bid = 'h2; s_b_i.bresp = 2'b01;
        s_r_i.rid = 'h3; s_r_i.rdata = 'h1234; s_r_i.rlast = 1;
        send_pair();
        check_pair();

        s_b_i.bid = 'h1;
        s_r_i.rdata = 'hdead;
        send_pair();
        wait(m_b_valid_o && m_r_valid_o);
        #($urandom_range(1, 9999) * 1ps);
        noc_rst_n_i = 0;
        axi_rst_n_i = 0;
        #($urandom_range(40000, 99999) * 1ps);
        if (m_b_valid_o !== 0 || m_r_valid_o !== 0)
            $fatal(1, "reset did not clear B/R FIFO valid");
        @(negedge noc_clk_i); noc_rst_n_i = 1;
        repeat (3) @(negedge axi_clk_i); axi_rst_n_i = 1;
        repeat (20) begin
            @(negedge axi_clk_i);
            if (m_b_valid_o || m_r_valid_o) $fatal(1, "stale B/R response after reset");
        end
        s_b_i.bid = 'h3; s_b_i.bresp = 2'b10;
        s_r_i.rid = 'h2; s_r_i.rdata = 'h5678;
        send_pair();
        check_pair();
        repeat (10) @(negedge axi_clk_i);
        if (m_b_valid_o || m_r_valid_o) $fatal(1, "duplicate B/R response after reset recovery");
        $display("PASS response FIFO reset recovery seed=%0d pre_B=1 pre_R=1 canceled_B=1 canceled_R=1 post_B=1 post_R=1", seed);
        $finish;
    end

    initial begin #10us; $fatal(1, "response path integration timeout"); end
endmodule
