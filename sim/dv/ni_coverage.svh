// SPDX-License-Identifier: Apache-2.0
// Passive observations in the shared NI TB; never drive stimulus or DUT signals.
`ifdef NI_COVERAGE
    `define COV_ORDER dut.i_response_path.i_ordering
    longint unsigned cov_count[string];
    typedef struct packed {
        int id;
        int tag;
        bit reorder;
    } cov_request_t;
    cov_request_t cov_wr_pending[$], cov_rd_pending[$];
    int cov_wr_live[NUM_IDS] = '{default:0};
    int cov_rd_live[NUM_IDS] = '{default:0};

    function automatic void cov_hit(input string name);
        if (!cov_count.exists(name)) cov_count[name] = 0;
        cov_count[name]++;
    endfunction

    function automatic void cov_address(input bit is_read, input mon_addr_t addr,
            input int id, input int len, input int size, input int burst);
        string channel, mode;
        int destination;
        channel = is_read ? "ar" : "aw";
        mode = "unmapped";
        destination = -1;
        for (int rule = 0; rule < topology_pkg::SAM_NUM_RULES; rule++) begin
            if (addr >= topology_pkg::SAM[rule].start_addr &&
                    addr < topology_pkg::SAM[rule].end_addr) begin
                mode = topology_pkg::SAM[rule].idx.is_data ? "data" : "control";
                destination = int'(topology_pkg::SAM[rule].idx.dst_id);
                break;
            end
        end
        cov_hit(channel);
        cov_hit($sformatf("%s.%s", channel, mode));
        cov_hit($sformatf("%s.len.%0d", channel, len + 1));
        cov_hit($sformatf("%s.size.%0d", channel, size));
        cov_hit($sformatf("%s.burst.%0d", channel, burst));
        cov_hit($sformatf("%s.id.%0d", channel, id));
        cov_hit($sformatf("%s.dst.%0d", channel, destination));
        if (len != 0 && (((len + 1) & len) != 0)) cov_hit({channel, ".non_power_two"});
    endfunction

    // Match only identity/order information; data correctness stays in the existing checkers.
    task automatic cov_response(input bit is_read, input int id, input int tag,
            input bit reorder);
        int index;
        bit older_same_id, older_other_id;
        cov_request_t item;
        index = -1;
        older_same_id = 0;
        older_other_id = 0;
        if (is_read) begin
            foreach (cov_rd_pending[i]) begin
                if (cov_rd_pending[i].id == id && cov_rd_pending[i].reorder == reorder &&
                        (!reorder || cov_rd_pending[i].tag == tag)) begin
                    index = i;
                    break;
                end
                if (cov_rd_pending[i].id == id) older_same_id = 1;
                else older_other_id = 1;
            end
            if (index >= 0) cov_rd_pending.delete(index);
        end else begin
            foreach (cov_wr_pending[i]) begin
                if (cov_wr_pending[i].id == id && cov_wr_pending[i].reorder == reorder &&
                        (!reorder || cov_wr_pending[i].tag == tag)) begin
                    index = i;
                    break;
                end
                if (cov_wr_pending[i].id == id) older_same_id = 1;
                else older_other_id = 1;
            end
            if (index >= 0) cov_wr_pending.delete(index);
        end
        if (index < 0) cov_hit("observer_unmatched");
        else begin
            if (older_same_id) cov_hit(is_read ? "r.same_id_inversion" : "b.same_id_inversion");
            if (older_other_id) cov_hit(is_read ? "r.cross_id_inversion" : "b.cross_id_inversion");
        end
    endtask

    always @(posedge clk) begin : sample_ni_coverage
        cov_request_t request;
        int wr_total, rd_total;
        if (!axi_rst_n) begin
            if (cov_wr_pending.size() != 0 || cov_rd_pending.size() != 0)
                cov_hit("reset.pending");
            cov_wr_pending.delete();
            cov_rd_pending.delete();
            foreach (cov_wr_live[id]) begin
                cov_wr_live[id] = 0;
                cov_rd_live[id] = 0;
            end
        end else begin
            if (vip.aw_valid && vip.aw_ready) begin
                cov_address(0, vip.aw_addr, int'(vip.aw_id), int'(vip.aw_len),
                    int'(vip.aw_size), int'(vip.aw_burst));
                cov_wr_live[vip.aw_id]++;
            end
            if (vip.ar_valid && vip.ar_ready) begin
                cov_address(1, vip.ar_addr, int'(vip.ar_id), int'(vip.ar_len),
                    int'(vip.ar_size), int'(vip.ar_burst));
                cov_rd_live[vip.ar_id]++;
            end
            if (vip.w_valid && vip.w_ready) begin
                cov_hit("w");
                if (vip.w_strb == '0) cov_hit("w.zero_strobe");
                cov_hit($sformatf("w.strobe_bytes.%0d", $countones(vip.w_strb)));
            end
            if (vip.b_valid && vip.b_ready) begin
                cov_hit("b");
                cov_wr_live[vip.b_id]--;
            end
            if (vip.r_valid && vip.r_ready) begin
                cov_hit("r.beat");
                if (vip.r_last) begin
                    cov_hit("r.transaction");
                    cov_rd_live[vip.r_id]--;
                end
            end
            wr_total = 0;
            rd_total = 0;
            foreach (cov_wr_live[id]) begin
                wr_total += cov_wr_live[id];
                rd_total += cov_rd_live[id];
            end
            if (wr_total != 0 && rd_total != 0) cov_hit("rw.pending_overlap");
            if (wr_total > 1) cov_hit("wr.multiple_pending");
            if (rd_total > 1) cov_hit("rd.multiple_pending");
            if (`COV_ORDER.aw_accept) begin
                request = '{int'(`COV_ORDER.s_aw_i.axi.awid),
                    int'(`COV_ORDER.aw_tag), `COV_ORDER.aw_reorder};
                cov_wr_pending.push_back(request);
                cov_hit(`COV_ORDER.aw_reorder ? "b.rob_alloc" : "b.bypass_alloc");
            end
            if (`COV_ORDER.ar_accept) begin
                request = '{int'(`COV_ORDER.s_ar_i.axi.arid),
                    int'(`COV_ORDER.ar_tag), `COV_ORDER.ar_reorder};
                cov_rd_pending.push_back(request);
                cov_hit(`COV_ORDER.ar_reorder ? "r.rob_alloc" : "r.bypass_alloc");
            end
            if (`COV_ORDER.s_b_valid_i && `COV_ORDER.s_b_ready_o)
                cov_response(0, int'(`COV_ORDER.s_b_i.axi.bid),
                    int'(`COV_ORDER.s_b_i.meta.ordering_tag), `COV_ORDER.s_b_i.meta.ordering_req);
            if (`COV_ORDER.s_r_valid_i && `COV_ORDER.s_r_ready_o && `COV_ORDER.s_r_i.axi.rlast)
                cov_response(1, int'(`COV_ORDER.s_r_i.axi.rid),
                    int'(`COV_ORDER.s_r_i.meta.ordering_tag), `COV_ORDER.s_r_i.meta.ordering_req);
            if (`COV_ORDER.b_retire && `COV_ORDER.b_sel_valid) cov_hit("b.rob_retire");
            if (`COV_ORDER.r_retire && `COV_ORDER.r_sel_valid) cov_hit("r.rob_retire");
            if (`COV_ORDER.b_free_cnt == 0) cov_hit("b.rob_no_tail_space");
            if (`COV_ORDER.R_ROB_EN && `COV_ORDER.r_free_cnt == 0) cov_hit("r.rob_no_tail_space");
            if (wr_order_full) cov_hit("wr.per_id_limit");
            if (rd_order_full) cov_hit("rd.per_id_limit");
            if (vip.b_valid && !vip.b_ready) cov_hit("b.stall");
            if (vip.r_valid && !vip.r_ready) cov_hit("r.stall");
            if (`COV_ORDER.b_sel_valid && !`COV_ORDER.m_b_ready_i)
                cov_hit("b.rob_output_stall");
            if (`COV_ORDER.r_sel_valid && !`COV_ORDER.m_r_ready_i)
                cov_hit("r.rob_output_stall");
        end
    end

    final begin
        $display("NI_COVERAGE_BEGIN");
        foreach (cov_count[name])
            $display("NI_COVER scope=master event=%s count=%0d", name, cov_count[name]);
        $display("NI_COVER scope=master event=observer_pending count=%0d",
            cov_wr_pending.size() + cov_rd_pending.size());
        $display("NI_COVERAGE_END");
    end
    `undef COV_ORDER
`endif
