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

    bit cov_b_inverted[1 << ni_flit_pkg::ORDERING_TAG_WIDTH] = '{default:0};
    bit cov_r_inverted[1 << ni_flit_pkg::ORDERING_TAG_WIDTH] = '{default:0};

    covergroup ordering_cg with function sample(bit is_read, bit same_id, bit other_id);
        option.per_instance = 1;
        cp_direction: coverpoint is_read { bins write = {0}; bins read = {1}; }
        cp_same_id_inversion: coverpoint same_id { bins absent = {0}; bins observed = {1}; }
        cp_cross_id_inversion: coverpoint other_id { bins absent = {0}; bins observed = {1}; }
        direction_same_id: cross cp_direction, cp_same_id_inversion;
        direction_cross_id: cross cp_direction, cp_cross_id_inversion;
    endgroup
    ordering_cg ordering_coverage = new();

    covergroup reset_cg with function sample(bit pending);
        option.per_instance = 1;
        cp_pending: coverpoint pending { bins occupied = {1}; }
    endgroup
    reset_cg reset_coverage = new();

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
        end
    end

    final begin
        if (cov_wr_pending.size() != 0 || cov_rd_pending.size() != 0)
            $error("Coverage monitor has pending ordering records");
    end
    `undef COV_ORDER
`endif
