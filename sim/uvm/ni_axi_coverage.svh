// SPDX-License-Identifier: Apache-2.0
class ni_axi_coverage extends uvm_subscriber #(uvm_sequence_item);
    int endpoint = -1;
`ifdef NI_COVERAGE
    int cov_wr_live[1 << NI_MON_ID_WIDTH] = '{default:0};
    int cov_rd_live[1 << NI_MON_ID_WIDTH] = '{default:0};
    ni_mon_aw_chan_t cov_aw_queue[$];
    ni_mon_w_chan_t cov_w_queue[$];
    int cov_w_beat;
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

    covergroup transaction_cg(int id_count, int first_dst, int last_dst) with function sample(
            bit is_read, bit is_data, int id, int beats, int size, int burst, int dst);
        option.per_instance = 1;
        cp_direction: coverpoint is_read { bins write = {0}; bins read = {1}; }
        cp_traffic: coverpoint is_data { bins control = {0}; bins data = {1}; }
        cp_id: coverpoint id { bins id[] = {[0:id_count-1]}; }
        cp_beats: coverpoint beats {
            bins single = {1};
            bins burst[] = {2,3,4,7,8,15,16,31,32,63,64,127,128,255,256};
        }
        cp_size: coverpoint size { bins size[] = {[0:$clog2(AXI_DATA_WIDTH/8)]}; }
        cp_burst: coverpoint burst { bins incr = {1}; }
        cp_destination: coverpoint dst { bins destination[] = {[first_dst:last_dst]}; }
        direction_traffic: cross cp_direction, cp_traffic;
        direction_length: cross cp_direction, cp_beats;
        direction_destination: cross cp_direction, cp_destination;
    endgroup

    covergroup write_strobe_cg with function sample(int kind, int lane, int size);
        option.per_instance = 1;
        cp_strobe: coverpoint kind { bins zero = {0}; bins partial = {1}; bins full = {2}; }
        cp_lane: coverpoint lane { bins lane[] = {[0:AXI_DATA_WIDTH/8-1]}; }
        cp_size: coverpoint size { bins size[] = {[0:$clog2(AXI_DATA_WIDTH/8)]}; }
        strobe_size: cross cp_strobe, cp_size {
            ignore_bins byte_partial = binsof(cp_strobe.partial) && binsof(cp_size) intersect {0};
        }
    endgroup

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

    function automatic void cov_address(input bit is_read, input ni_mon_addr_t addr,
            input int id, input int len, input int size, input int burst);
        bit is_data;
        int destination;
        is_data = 0;
        destination = -1;
        for (int rule = 0; rule < topology_pkg::SAM_NUM_RULES; rule++) begin
            if (addr >= topology_pkg::SAM[rule].start_addr &&
                    addr < topology_pkg::SAM[rule].end_addr) begin
                is_data = topology_pkg::SAM[rule].idx.is_data;
                boundary_cg.sample(is_read, is_data,
                    ((addr + ((len+1) << size)) % 4096) == 0,
                    addr == topology_pkg::SAM[rule].start_addr,
                    addr + ((len+1) << size) == topology_pkg::SAM[rule].end_addr);
                for (int n = 0; n < NI_NUM_NSUS; n++)
                    if (topology_pkg::SAM[rule].idx.dst_id == ni_nsu_id(n+1)) destination = n;
                break;
            end
        end
        if (endpoint >= 0) destination = endpoint;
        if (destination < 0) $fatal(1, "Coverage monitor cannot decode destination");
        transaction_cg.sample(is_read, is_data, id, len+1, size, burst, destination);
    endfunction
    function void write(uvm_sequence_item item);
        ni_axi_sample sample;
        int wr_total, rd_total;
        ni_mon_aw_chan_t aw;
        ni_mon_w_chan_t w;
        ni_mon_strb_t mask;
        int lo, hi;
        if (!$cast(sample, item)) `uvm_fatal("SAMPLE", "Unexpected coverage item")
        if (sample.reset) begin
            cov_aw_queue.delete();
            cov_w_queue.delete();
            cov_w_beat = 0;
            foreach (cov_wr_live[id]) begin
                cov_wr_live[id] = 0;
                cov_rd_live[id] = 0;
            end
        end else begin
            if (sample.req.aw_valid && sample.rsp.aw_ready) begin
                cov_address(0, sample.req.aw.addr, int'(sample.req.aw.id), int'(sample.req.aw.len),
                    int'(sample.req.aw.size), int'(sample.req.aw.burst));
                cov_wr_live[sample.req.aw.id]++;
                cov_aw_queue.push_back(sample.req.aw);
            end
            if (sample.req.ar_valid && sample.rsp.ar_ready) begin
                cov_address(1, sample.req.ar.addr, int'(sample.req.ar.id), int'(sample.req.ar.len),
                    int'(sample.req.ar.size), int'(sample.req.ar.burst));
                cov_rd_live[sample.req.ar.id]++;
            end
            if (sample.req.w_valid && sample.rsp.w_ready) begin
                cov_w_queue.push_back(sample.req.w);
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
                write_strobe_cg.sample(w.strb == 0 ? 0 : w.strb == mask ? 2 : 1,
                    lo, int'(aw.size));
                if (w.last) begin
                    void'(cov_aw_queue.pop_front());
                    cov_w_beat = 0;
                end else cov_w_beat++;
            end
            if (sample.rsp.b_valid && sample.req.b_ready) begin
                cov_wr_live[sample.rsp.b.id]--;
            end
            if (sample.rsp.r_valid && sample.req.r_ready) begin
                if (sample.rsp.r.last) begin
                    cov_rd_live[sample.rsp.r.id]--;
                end
            end
            wr_total = 0;
            rd_total = 0;
            foreach (cov_wr_live[id]) begin
                wr_total += cov_wr_live[id];
                rd_total += cov_rd_live[id];
            end
            outstanding_cg.sample(wr_total, rd_total);
            if (sample.rsp.b_valid && sample.req.b_ready) response_cg.sample(0, sample.rsp.b.resp);
            if (sample.rsp.r_valid && sample.req.r_ready) response_cg.sample(1, sample.rsp.r.resp);

        end
    endfunction
`else
    function void write(uvm_sequence_item item); endfunction
`endif
    function new(string name, uvm_component parent);
        int id_width;
        super.new(name, parent);
        id_width = NI_INPUT_ID_WIDTH;
        if (!uvm_config_db #(int)::get(this, "", "endpoint", endpoint)) endpoint = -1;
        if (!uvm_config_db #(int)::get(this, "", "id_width", id_width)) id_width = NI_INPUT_ID_WIDTH;
`ifdef NI_COVERAGE
        response_cg = new();
        response_cg.set_inst_name({get_full_name(), ".response_cg"});
        transaction_cg = new(1 << id_width, endpoint < 0 ? 0 : endpoint, endpoint < 0 ? NI_NUM_NSUS-1 : endpoint);
        transaction_cg.set_inst_name({get_full_name(), ".transaction_cg"});
        write_strobe_cg = new();
        write_strobe_cg.set_inst_name({get_full_name(), ".write_strobe_cg"});
        boundary_cg = new();
        boundary_cg.set_inst_name({get_full_name(), ".boundary_cg"});
        outstanding_cg = new();
        outstanding_cg.set_inst_name({get_full_name(), ".outstanding_cg"});
`endif
    endfunction
    `uvm_component_utils(ni_axi_coverage)
endclass
