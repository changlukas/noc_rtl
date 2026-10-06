// SPDX-License-Identifier: Apache-2.0
// Passive functional coverage; existing scoreboards own correctness checking.
`ifdef NI_COVERAGE
    `define COV_ORDER dut.i_response_path.i_ordering
    typedef struct packed {
        int id;
        int tag;
        bit reorder;
    } cov_request_t;
    cov_request_t cov_wr_pending[$], cov_rd_pending[$];
    int cov_wr_live[NUM_IDS] = '{default:0};
    int cov_rd_live[NUM_IDS] = '{default:0};

    covergroup response_cg with function sample(bit read, logic [1:0] resp);
        option.per_instance = 1;
        cp_read: coverpoint read;
        cp_resp: coverpoint resp {
            bins okay = {0};
            bins slverr = {2};
            bins decerr = {3};
        }
        response_type: cross cp_read, cp_resp;
    endgroup
    response_cg response_coverage = new();
    always @(posedge clk) begin
        if (axi_rst_n) begin
            if (vip.b_valid && vip.b_ready) response_coverage.sample(0, vip.b_resp);
            if (vip.r_valid && vip.r_ready) response_coverage.sample(1, vip.r_resp);
        end
    end

    covergroup transaction_cg with function sample(
            bit is_read, bit is_data, int id, int beats, int size, int burst, int dst);
        option.per_instance = 1;
        cp_direction: coverpoint is_read { bins write = {0}; bins read = {1}; }
        cp_traffic: coverpoint is_data { bins control = {0}; bins data = {1}; }
        cp_id: coverpoint id { bins id[] = {[0:NUM_IDS-1]}; }
        cp_beats: coverpoint beats {
            bins single = {1};
            bins burst[] = {2,3,4,7,8,15,16,31,32,63,64,127,128,255,256};
        }
        cp_size: coverpoint size { bins size[] = {[0:$clog2(AXI_DATA_WIDTH/8)]}; }
        cp_burst: coverpoint burst { bins incr = {1}; }
        cp_destination: coverpoint dst { bins destination[] = {[0:NUM_NSUS-1]}; }
        direction_traffic: cross cp_direction, cp_traffic;
        direction_length: cross cp_direction, cp_beats;
        direction_destination: cross cp_direction, cp_destination;
    endgroup
    transaction_cg transaction_coverage = new();

    mon_aw_chan_t cov_aw_queue[$];
    mon_w_chan_t cov_w_queue[$];
    int cov_w_beat = 0;
    bit cov_b_inverted[1 << ni_flit_pkg::ORDERING_TAG_WIDTH] = '{default:0};
    bit cov_r_inverted[1 << ni_flit_pkg::ORDERING_TAG_WIDTH] = '{default:0};

    covergroup write_strobe_cg with function sample(int kind, int lane, int size);
        option.per_instance = 1;
        cp_strobe: coverpoint kind { bins zero = {0}; bins partial = {1}; bins full = {2}; }
        cp_lane: coverpoint lane { bins lane[] = {[0:AXI_DATA_WIDTH/8-1]}; }
        cp_size: coverpoint size { bins size[] = {[0:$clog2(AXI_DATA_WIDTH/8)]}; }
        strobe_size: cross cp_strobe, cp_size {
            ignore_bins byte_partial = binsof(cp_strobe.partial) && binsof(cp_size) intersect {0};
        }
    endgroup
    write_strobe_cg write_strobe_coverage = new();

    covergroup boundary_cg with function sample(bit is_read, bit is_data,
            bit page_end, bit sam_start, bit sam_end);
        option.per_instance = 1;
        cp_direction: coverpoint is_read { bins write = {0}; bins read = {1}; }
        cp_traffic: coverpoint is_data { bins control = {0}; bins data = {1}; }
        cp_page_end: coverpoint page_end { bins observed = {1}; }
        cp_sam_start: coverpoint sam_start { bins observed = {1}; }
        cp_sam_end: coverpoint sam_end { bins observed = {1}; }
        page_boundary: cross cp_direction, cp_traffic, cp_page_end;
        sam_first: cross cp_direction, cp_traffic, cp_sam_start;
        sam_last: cross cp_direction, cp_traffic, cp_sam_end;
    endgroup
    boundary_cg boundary_coverage = new();

    covergroup stress_cg with function sample(bit is_read, bit limit_reuse,
            bit rob_full, bit rob_reuse, bit hol_progress, bit reset_recovered,
            bit inversion_stall);
        option.per_instance = 1;
        cp_direction: coverpoint is_read { bins write = {0}; bins read = {1}; }
        cp_limit_reuse: coverpoint limit_reuse { bins observed = {1}; }
        cp_rob_full: coverpoint rob_full { bins observed = {1}; }
        cp_rob_reuse: coverpoint rob_reuse { bins observed = {1}; }
        cp_hol: coverpoint hol_progress { bins observed = {1}; }
        cp_reset: coverpoint reset_recovered { bins observed = {1}; }
        cp_inversion_stall: coverpoint inversion_stall { bins observed = {1}; }
        direction_limit_reuse: cross cp_direction, cp_limit_reuse;
        storage_full: cross cp_direction, cp_rob_full;
        storage_reuse: cross cp_direction, cp_rob_reuse;
        direction_hol_progress: cross cp_direction, cp_hol;
        reset_recovery: cross cp_direction, cp_reset;
        reorder_backpressure: cross cp_direction, cp_inversion_stall;
    endgroup
    stress_cg stress_coverage = new();

    covergroup outstanding_cg with function sample(int writes, int reads);
        option.per_instance = 1;
        cp_write: coverpoint writes {
            bins idle = {0}; bins single = {1}; bins multiple = {[2:$]};
        }
        cp_read: coverpoint reads {
            bins idle = {0}; bins single = {1}; bins multiple = {[2:$]};
        }
        read_write: cross cp_write, cp_read;
    endgroup
    outstanding_cg outstanding_coverage = new();

    covergroup ordering_cg with function sample(bit is_read, bit same_id, bit other_id);
        option.per_instance = 1;
        cp_direction: coverpoint is_read { bins write = {0}; bins read = {1}; }
        cp_same_id_inversion: coverpoint same_id { bins absent = {0}; bins observed = {1}; }
        cp_cross_id_inversion: coverpoint other_id { bins absent = {0}; bins observed = {1}; }
        direction_same_id: cross cp_direction, cp_same_id_inversion;
        direction_cross_id: cross cp_direction, cp_cross_id_inversion;
    endgroup
    ordering_cg ordering_coverage = new();

    covergroup rob_cg with function sample(int allocation, bit retire, bit no_tail_space,
            bit per_id_limit, bit axi_stall, bit output_stall);
        option.per_instance = 1;
        cp_allocation: coverpoint allocation { bins bypass = {1}; bins reorder = {2}; }
        cp_retire: coverpoint retire { bins observed = {1}; }
        cp_no_tail_space: coverpoint no_tail_space { bins observed = {1}; }
        cp_per_id_limit: coverpoint per_id_limit { bins observed = {1}; }
        cp_axi_stall: coverpoint axi_stall { bins observed = {1}; }
        cp_output_stall: coverpoint output_stall { bins observed = {1}; }
    endgroup
    rob_cg b_rob_coverage = new();
    rob_cg r_rob_coverage = new();

    covergroup reset_cg with function sample(bit pending);
        option.per_instance = 1;
        cp_pending: coverpoint pending { bins occupied = {1}; }
    endgroup
    reset_cg reset_coverage = new();

    function automatic void cov_address(input bit is_read, input mon_addr_t addr,
            input int id, input int len, input int size, input int burst);
        bit is_data;
        int destination;
        is_data = 0;
        destination = -1;
        for (int rule = 0; rule < topology_pkg::SAM_NUM_RULES; rule++) begin
            if (addr >= topology_pkg::SAM[rule].start_addr &&
                    addr < topology_pkg::SAM[rule].end_addr) begin
                is_data = topology_pkg::SAM[rule].idx.is_data;
                boundary_coverage.sample(is_read, is_data,
                    ((addr + ((len+1) << size)) % 4096) == 0,
                    addr == topology_pkg::SAM[rule].start_addr,
                    addr + ((len+1) << size) == topology_pkg::SAM[rule].end_addr);
                for (int n = 0; n < NUM_NSUS; n++)
                    if (topology_pkg::SAM[rule].idx.dst_id == nsu_id(n+1)) destination = n;
                break;
            end
        end
        if (destination < 0) $fatal(1, "Coverage monitor cannot decode destination");
        transaction_coverage.sample(is_read, is_data, id, len+1, size, burst, destination);
    endfunction

    // Identity tracking is needed to sample actual arrival inversions.
    task automatic cov_response(input bit is_read, input int id, input int tag,
            input bit reorder);
        int index;
        bit older_same_id, older_other_id;
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
        if (index < 0) $fatal(1, "Coverage monitor cannot match ordering response");
        ordering_coverage.sample(is_read, older_same_id, older_other_id);
        cov_same_id_seen[is_read] |= older_same_id;
        cov_cross_id_seen[is_read] |= older_other_id;
        if (reorder && (older_same_id || older_other_id)) begin
            if (is_read) cov_r_inverted[tag] = 1;
            else cov_b_inverted[tag] = 1;
        end
    endtask

    always @(posedge clk) begin : sample_ni_coverage
        int wr_total, rd_total;
        mon_aw_chan_t aw;
        mon_w_chan_t w;
        mon_strb_t mask;
        int lo, hi;
        if (!axi_rst_n) begin
            cov_aw_queue.delete();
            cov_w_queue.delete();
            cov_w_beat = 0;
            foreach (cov_wr_live[id]) begin
                cov_wr_live[id] = 0;
                cov_rd_live[id] = 0;
            end
        end else begin
            if (vip.aw_valid && vip.aw_ready) begin
                cov_address(0, vip.aw_addr, int'(vip.aw_id), int'(vip.aw_len),
                    int'(vip.aw_size), int'(vip.aw_burst));
                cov_wr_live[vip.aw_id]++;
                cov_aw_queue.push_back(mon_mst_raw.aw);
            end
            if (vip.ar_valid && vip.ar_ready) begin
                cov_address(1, vip.ar_addr, int'(vip.ar_id), int'(vip.ar_len),
                    int'(vip.ar_size), int'(vip.ar_burst));
                cov_rd_live[vip.ar_id]++;
            end
            if (vip.w_valid && vip.w_ready) begin
                cov_w_queue.push_back(mon_mst_raw.w);
            end
            // AW and W are independent; pair accepted beats in AXI write order.
            while (cov_aw_queue.size() != 0 && cov_w_queue.size() != 0) begin
                aw = cov_aw_queue[0];
                w = cov_w_queue.pop_front();
                lo = axi_pkg::beat_lower_byte(aw.addr, aw.size, aw.len, aw.burst,
                    AXI_DATA_WIDTH/8, cov_w_beat);
                hi = axi_pkg::beat_upper_byte(aw.addr, aw.size, aw.len, aw.burst,
                    AXI_DATA_WIDTH/8, cov_w_beat);
                mask = '0;
                for (int lane = lo; lane <= hi; lane++) mask[lane] = 1;
                write_strobe_coverage.sample(w.strb == 0 ? 0 : w.strb == mask ? 2 : 1,
                    lo, int'(aw.size));
                if (w.last) begin
                    void'(cov_aw_queue.pop_front());
                    cov_w_beat = 0;
                end else cov_w_beat++;
            end
            if (vip.b_valid && vip.b_ready) begin
                cov_wr_live[vip.b_id]--;
            end
            if (vip.r_valid && vip.r_ready) begin
                if (vip.r_last) begin
                    cov_rd_live[vip.r_id]--;
                end
            end
            wr_total = 0;
            rd_total = 0;
            foreach (cov_wr_live[id]) begin
                wr_total += cov_wr_live[id];
                rd_total += cov_rd_live[id];
            end
            outstanding_coverage.sample(wr_total, rd_total);

        end
    end

    always @(posedge noc_clk) begin : sample_noc_coverage
        cov_request_t request;
        if (!noc_rst_n) begin
            reset_coverage.sample(cov_wr_pending.size() != 0 || cov_rd_pending.size() != 0);
            cov_wr_pending.delete();
            cov_rd_pending.delete();
            cov_b_stall_inversion = 0;
            cov_r_stall_inversion = 0;
            foreach (cov_b_inverted[tag]) begin
                cov_b_inverted[tag] = 0;
                cov_r_inverted[tag] = 0;
            end
        end else begin
            if (`COV_ORDER.aw_accept) begin
                request = '{int'(`COV_ORDER.s_aw_i.axi.awid),
                    int'(`COV_ORDER.aw_tag), `COV_ORDER.aw_reorder};
                cov_wr_pending.push_back(request);
            end
            if (`COV_ORDER.ar_accept) begin
                request = '{int'(`COV_ORDER.s_ar_i.axi.arid),
                    int'(`COV_ORDER.ar_tag), `COV_ORDER.ar_reorder};
                cov_rd_pending.push_back(request);
            end
            if (`COV_ORDER.s_b_valid_i && `COV_ORDER.s_b_ready_o)
                cov_response(0, int'(`COV_ORDER.s_b_i.axi.bid),
                    int'(`COV_ORDER.s_b_i.meta.ordering_tag), `COV_ORDER.s_b_i.meta.ordering_req);
            if (`COV_ORDER.s_r_valid_i && `COV_ORDER.s_r_ready_o && `COV_ORDER.s_r_i.axi.rlast)
                cov_response(1, int'(`COV_ORDER.s_r_i.axi.rid),
                    int'(`COV_ORDER.s_r_i.meta.ordering_tag), `COV_ORDER.s_r_i.meta.ordering_req);
            if (`COV_ORDER.b_sel_valid && !`COV_ORDER.m_b_ready_i &&
                    cov_b_inverted[`COV_ORDER.wr_order_head[`COV_ORDER.b_sel_id].base])
                cov_b_stall_inversion = 1;
            if (`COV_ORDER.r_sel_valid && !`COV_ORDER.m_r_ready_i &&
                    cov_r_inverted[`COV_ORDER.rd_order_head[`COV_ORDER.r_sel_id].base])
                cov_r_stall_inversion = 1;
            if (`COV_ORDER.b_retire && `COV_ORDER.b_sel_valid)
                cov_b_inverted[`COV_ORDER.wr_order_head[`COV_ORDER.b_sel_id].base] = 0;
            if (`COV_ORDER.r_retire && `COV_ORDER.r_sel_valid && `COV_ORDER.m_r_o.rlast)
                cov_r_inverted[`COV_ORDER.rd_order_head[`COV_ORDER.r_sel_id].base] = 0;
            stress_coverage.sample(0, wr_limit_reused, b_storage_full, b_storage_reused,
                hol_wr_progress, reset_complete && b_count != 0, cov_b_stall_inversion);
            stress_coverage.sample(1, rd_limit_reused, r_storage_full, r_storage_reused,
                hol_rd_progress, reset_complete && r_count != 0, cov_r_stall_inversion);
            b_rob_coverage.sample(
                `COV_ORDER.aw_accept ? (`COV_ORDER.aw_reorder ? 2 : 1) : 0,
                `COV_ORDER.b_retire && `COV_ORDER.b_sel_valid,
                `COV_ORDER.b_free_cnt == 0, wr_order_full, vip.b_valid && !vip.b_ready,
                `COV_ORDER.b_sel_valid && !`COV_ORDER.m_b_ready_i);
            r_rob_coverage.sample(
                `COV_ORDER.ar_accept ? (`COV_ORDER.ar_reorder ? 2 : 1) : 0,
                `COV_ORDER.r_retire && `COV_ORDER.r_sel_valid,
                `COV_ORDER.R_ROB_EN && `COV_ORDER.r_free_cnt == 0,
                rd_order_full, vip.r_valid && !vip.r_ready,
                `COV_ORDER.r_sel_valid && !`COV_ORDER.m_r_ready_i);
        end
    end

    final begin
        if (cov_wr_pending.size() != 0 || cov_rd_pending.size() != 0 ||
                cov_aw_queue.size() != 0 || cov_w_queue.size() != 0)
            $error("Coverage monitor has pending ordering records");
    end
    `undef COV_ORDER
`endif
