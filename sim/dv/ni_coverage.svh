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

    covergroup write_strobe_cg with function sample(int active_bytes);
        option.per_instance = 1;
        // Raw WSTRB population; full/partial classification requires AW byte lanes.
        cp_bytes: coverpoint active_bytes {
            bins zero = {0};
            bins nonzero[] = {[1:AXI_DATA_WIDTH/8]};
        }
    endgroup
    write_strobe_cg write_strobe_coverage = new();

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
    endtask

    always @(posedge clk) begin : sample_ni_coverage
        cov_request_t request;
        int wr_total, rd_total;
        if (!axi_rst_n) begin
            reset_coverage.sample(cov_wr_pending.size() != 0 || cov_rd_pending.size() != 0);
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
                write_strobe_coverage.sample($countones(vip.w_strb));
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
        if (cov_wr_pending.size() != 0 || cov_rd_pending.size() != 0)
            $error("Coverage monitor has pending ordering records");
    end
    `undef COV_ORDER
`endif
