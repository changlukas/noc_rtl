// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Tim Fischer <fischeti@iis.ee.ethz.ch>
// Local adaptation: transaction-driven comparison core, shared by SV and UVM.
class axi_reorder_compare_core #(
  parameter int unsigned NumSlaves = 4,
  parameter int unsigned AxiIdWidth = 4,
  parameter int unsigned NumAddrRegions  = 1,
  parameter type addr_t = logic,
  parameter type rule_t = logic,
  parameter rule_t [NumAddrRegions-1:0] AddrRegions = '0,
  parameter bit Verbose = 0,
  parameter type aw_chan_t = logic,
  parameter type w_chan_t = logic,
  parameter type b_chan_t = logic,
  parameter type ar_chan_t = logic,
  parameter type r_chan_t = logic,
  parameter type req_t = logic,
  parameter type rsp_t = logic,
  // Derived parameters, do not change
  parameter type id_t = logic [AxiIdWidth-1:0],
  parameter int unsigned NumAxiIds = 2**AxiIdWidth
);
  virtual function void report_error(string message); $error("%s", message); endfunction
  virtual function void report_fatal(string message); $fatal(1, "%s", message); endfunction
  function automatic void print_aw (
      input aw_chan_t aw_expected,
      input aw_chan_t aw_received
  );
      // verilog_lint: waive-start line-length
      $display("AW      | expected                                                         | received                                                         ");
      $display("--------|------------------------------------------------------------------|-----------------------------------------------------------------");
      $display("id:     | %0d | %0d", aw_expected.id, aw_received.id);
      $display("addr:   | %0h | %0h", aw_expected.addr, aw_received.addr);
      $display("len:    | %0d | %0d", aw_expected.len, aw_received.len);
      $display("size:   | %0d | %0d", aw_expected.size, aw_received.size);
      $display("burst:  | %0d | %0d", aw_expected.burst, aw_received.burst);
      $display("lock:   | %0d | %0d", aw_expected.lock, aw_received.lock);
      $display("cache:  | %0d | %0d", aw_expected.cache, aw_received.cache);
      $display("prot:   | %0d | %0d", aw_expected.prot, aw_received.prot);
      $display("qos:    | %0d | %0d", aw_expected.qos, aw_received.qos);
      $display("region: | %0d | %0d", aw_expected.region, aw_received.region);
      $display("user:   | %0d | %0d", aw_expected.user, aw_received.user);
      $display("atop:   | %0d | %0d", aw_expected.atop, aw_received.atop);
      $display("--------|------------------------------------------------------------------|-----------------------------------------------------------------");
      // verilog_lint: waive-stop line-length
  endfunction

  function automatic void print_ar (
      input ar_chan_t ar_expected,
      input ar_chan_t ar_received
  );
      // verilog_lint: waive-start line-length
      $display("AR      | expected                                                         | received                                                         ");
      $display("--------|------------------------------------------------------------------|-----------------------------------------------------------------");
      $display("id:     | %0d | %0d", ar_expected.id, ar_received.id);
      $display("addr:   | %0h | %0h", ar_expected.addr, ar_received.addr);
      $display("len:    | %0d | %0d", ar_expected.len, ar_received.len);
      $display("size:   | %0d | %0d", ar_expected.size, ar_received.size);
      $display("burst:  | %0d | %0d", ar_expected.burst, ar_received.burst);
      $display("lock:   | %0d | %0d", ar_expected.lock, ar_received.lock);
      $display("cache:  | %0d | %0d", ar_expected.cache, ar_received.cache);
      $display("prot:   | %0d | %0d", ar_expected.prot, ar_received.prot);
      $display("qos:    | %0d | %0d", ar_expected.qos, ar_received.qos);
      $display("region: | %0d | %0d", ar_expected.region, ar_received.region);
      $display("user:   | %0d | %0d", ar_expected.user, ar_received.user);
      $display("--------|------------------------------------------------------------------|-----------------------------------------------------------------");
      // verilog_lint: waive-stop line-length
  endfunction

  function automatic void print_w (
      input w_chan_t w_expected,
      input w_chan_t w_received
  );
      // verilog_lint: waive-start line-length
      $display("W       | expected                                                         | received                                                         ");
      $display("--------|------------------------------------------------------------------|-----------------------------------------------------------------");
      $display("data:   | %0h | %0h", w_expected.data, w_received.data);
      $display("strb:   | %0d | %0d", w_expected.strb, w_received.strb);
      $display("last:   | %0d | %0d", w_expected.last, w_received.last);
      $display("user:   | %0d | %0d", w_expected.user, w_received.user);
      $display("--------|------------------------------------------------------------------|-----------------------------------------------------------------");
      // verilog_lint: waive-stop line-length
  endfunction

  function automatic void print_b (
      input b_chan_t b_expected,
      input b_chan_t b_received
  );
      // verilog_lint: waive-start line-length
      $display("B       | expected                                                         | received                                                         ");
      $display("--------|------------------------------------------------------------------|-----------------------------------------------------------------");
      $display("id:     | %0d | %0d", b_expected.id, b_received.id);
      $display("resp:   | %0d | %0d", b_expected.resp, b_received.resp);
      $display("user:   | %0d | %0d", b_expected.user, b_received.user);
      $display("--------|------------------------------------------------------------------|-----------------------------------------------------------------");
      // verilog_lint: waive-stop line-length
  endfunction

  function automatic void print_r (
      input r_chan_t r_expected,
      input r_chan_t r_received
  );
      // verilog_lint: waive-start line-length
      $display("R       | expected                                                         | received                                                         ");
      $display("--------|------------------------------------------------------------------|-----------------------------------------------------------------");
      $display("id:     | %0d | %0d", r_expected.id, r_received.id);
      $display("data:   | %0h | %0h", r_expected.data, r_received.data);
      $display("resp:   | %0d | %0d", r_expected.resp, r_received.resp);
      $display("last:   | %0d | %0d", r_expected.last, r_received.last);
      $display("user:   | %0d | %0d", r_expected.user, r_received.user);
      $display("--------|------------------------------------------------------------------|-----------------------------------------------------------------");
      // verilog_lint: waive-stop line-length
  endfunction

  typedef struct packed {
    int unsigned region_id;
    int unsigned num_rsp;
    ar_chan_t ar;
  } out_rsp_t;

  typedef struct packed {
    id_t id;
    int unsigned region_id;
  } rsp_id_t;

  function automatic int unsigned addr_region(input addr_t addr);
    for (int j = 0; j < NumAddrRegions; j++) begin
      if (addr >= AddrRegions[j].start_addr && addr < AddrRegions[j].end_addr)
        return j;
    end
    report_fatal($sformatf("Checker address outside configured regions: %h", addr));
    return 0;
  endfunction

  aw_chan_t aw_queue [NumSlaves][$];
  w_chan_t  w_queue  [int unsigned][$];
  int unsigned aw_seq_queue [NumSlaves][$];
  int unsigned w_output_queue [NumSlaves][$];
  int unsigned w_input_queue[$];
  int unsigned write_seq = 0;
  w_chan_t  w_pending[$];
  w_chan_t  w_device_pending[NumSlaves][$];
  ar_chan_t ar_queue [NumSlaves][$];
  b_chan_t  b_queue  [NumAddrRegions][NumAxiIds][$];
  r_chan_t  r_queue  [NumAddrRegions][NumAxiIds][$];

  out_rsp_t r_out_rsp_queue[NumAxiIds][$];
  out_rsp_t b_out_rsp_queue[NumAxiIds][$];

  rsp_id_t aw_id_queue [NumSlaves][NumAxiIds][$];
  rsp_id_t ar_id_queue [NumSlaves][NumAxiIds][$];
  function void reset();
    write_seq = 0;
    w_pending.delete();
    w_input_queue.delete();
    w_queue.delete();
    for (int i = 0; i < NumSlaves; i++) begin
      aw_queue[i].delete();
      aw_seq_queue[i].delete();
      w_output_queue[i].delete();
      w_device_pending[i].delete();
      ar_queue[i].delete();
      for (int id = 0; id < NumAxiIds; id++) begin
        aw_id_queue[i][id].delete();
        ar_id_queue[i][id].delete();
      end
    end
    for (int region = 0; region < NumAddrRegions; region++) begin
      for (int id = 0; id < NumAxiIds; id++) begin
        b_queue[region][id].delete();
        r_queue[region][id].delete();
      end
    end
    for (int id = 0; id < NumAxiIds; id++) begin
      r_out_rsp_queue[id].delete();
      b_out_rsp_queue[id].delete();
    end
  endfunction
  function void source_request(req_t mon_mst_req_i, rsp_t mon_mst_rsp_i);
    int aw_slv_idx, ar_slv_idx;
    if (mon_mst_req_i.aw_valid && mon_mst_rsp_i.aw_ready) aw_slv_idx = AddrRegions[addr_region(mon_mst_req_i.aw.addr)].idx;
    if (mon_mst_req_i.ar_valid && mon_mst_rsp_i.ar_ready) ar_slv_idx = AddrRegions[addr_region(mon_mst_req_i.ar.addr)].idx;
    if (mon_mst_req_i.aw_valid && mon_mst_rsp_i.aw_ready) begin
      aw_queue[aw_slv_idx].push_back(mon_mst_req_i.aw);
      aw_seq_queue[aw_slv_idx].push_back(write_seq);
      w_input_queue.push_back(write_seq);
      write_seq++;
      b_out_rsp_queue[mon_mst_req_i.aw.id].push_back('{region_id: addr_region(mon_mst_req_i.aw.addr), num_rsp: 0, ar: '0});
      if (Verbose) $info("Issued AW: id=%0d, len=%0d", mon_mst_req_i.aw.id, mon_mst_req_i.aw.len+1);
    end
    if (mon_mst_req_i.w_valid && mon_mst_rsp_i.w_ready) begin
      w_pending.push_back(mon_mst_req_i.w);
      if (Verbose) $info("Issued W");
    end
    while (w_pending.size() != 0 && w_input_queue.size() != 0) begin
      automatic w_chan_t w = w_pending.pop_front();
      w_queue[w_input_queue[0]].push_back(w);
      if (w.last) void'(w_input_queue.pop_front());
    end
    if (mon_mst_req_i.ar_valid && mon_mst_rsp_i.ar_ready) begin
      ar_queue[ar_slv_idx].push_back(mon_mst_req_i.ar);
      r_out_rsp_queue[mon_mst_req_i.ar.id].push_back(
        '{region_id: addr_region(mon_mst_req_i.ar.addr), num_rsp: mon_mst_req_i.ar.len, ar: mon_mst_req_i.ar});
      if (Verbose) $info("Issued AR: id=%0d, len=%0d",
                         mon_mst_req_i.ar.id, mon_mst_req_i.ar.len+1);
    end
  endfunction
  function void device_request(int i, req_t req, rsp_t rsp);
      if (req.aw_valid && rsp.aw_ready) begin
        automatic aw_chan_t aw_exp, aw_act;
        automatic id_t aw_id;
        aw_act = req.aw;
        if (aw_queue[i].size() == 0) report_error($sformatf("AW queue empty"));
        begin
          automatic bit [NumAddrRegions-1:0][NumAxiIds-1:0] seen = '0;
          automatic int match_idx = -1;
          aw_chan_t expected, received;
          received = aw_act;
          received.id = '0;
          // Requests remain ordered per source ID and address region.
          for (int j = 0; j < aw_queue[i].size(); j++) begin
            expected = aw_queue[i][j];
            if (!seen[addr_region(expected.addr)][expected.id]) begin
              seen[addr_region(expected.addr)][expected.id] = 1'b1;
              expected.id = '0;
              if (match_idx < 0 && expected === received) match_idx = j;
            end
          end
          if (match_idx < 0) begin
            report_error($sformatf("AW mismatch or same-ID request reordered"));
            if (aw_queue[i].size() != 0) print_aw(aw_queue[i][0], aw_act);
          end else begin
            aw_exp = aw_queue[i][match_idx];
            aw_id = aw_exp.id;
            w_output_queue[i].push_back(aw_seq_queue[i][match_idx]);
            aw_queue[i].delete(match_idx);
            aw_seq_queue[i].delete(match_idx);
            aw_id_queue[i][aw_act.id].push_back('{id: aw_id, region_id: addr_region(aw_exp.addr)});
            if (Verbose) $info("Slave[%0d] Received AW: id=%0d, len=%0d", i, aw_id, aw_exp.len+1);
          end
        end
      end
      if (req.w_valid && rsp.w_ready) w_device_pending[i].push_back(req.w);
      // AW and W handshakes are independent at the device interface.
      while (w_device_pending[i].size() != 0 && w_output_queue[i].size() != 0) begin
        automatic w_chan_t w_exp, w_act;
        w_act = w_device_pending[i].pop_front();
        if (w_queue[w_output_queue[i][0]].size() == 0)
          report_fatal($sformatf("W precedes its source data"));
        w_exp = w_queue[w_output_queue[i][0]].pop_front();
        if (w_exp.last) begin
          w_queue.delete(w_output_queue[i][0]);
          void'(w_output_queue[i].pop_front());
        end
        // Inactive byte lanes are not transferred by AXI.
        for (int b = 0; b < $bits(w_exp.strb); b++) begin
          if (!w_exp.strb[b]) w_exp.data[b*8 +: 8] = '0;
          if (!w_act.strb[b]) w_act.data[b*8 +: 8] = '0;
        end
        if (w_exp !== w_act) begin
          report_error($sformatf("W mismatch"));
          print_w(w_exp, w_act);
        end else begin
          if (Verbose) $info("Slave[%0d] Received W", i);
        end
      end
      if (req.ar_valid && rsp.ar_ready) begin
        automatic ar_chan_t ar_exp, ar_act;
        automatic id_t ar_id;
        ar_act = req.ar;
        if (ar_queue[i].size() == 0) report_error($sformatf("AR queue is empty!"));
        begin
          automatic bit [NumAddrRegions-1:0][NumAxiIds-1:0] seen = '0;
          automatic int match_idx = -1;
          ar_chan_t expected, received;
          received = ar_act;
          received.id = '0;
          for (int j = 0; j < ar_queue[i].size(); j++) begin
            expected = ar_queue[i][j];
            if (!seen[addr_region(expected.addr)][expected.id]) begin
              seen[addr_region(expected.addr)][expected.id] = 1'b1;
              expected.id = '0;
              if (match_idx < 0 && expected === received) match_idx = j;
            end
          end
          if (match_idx < 0) begin
            report_error($sformatf("AR mismatch or same-ID request reordered"));
            if (ar_queue[i].size() != 0) print_ar(ar_queue[i][0], ar_act);
          end else begin
            ar_exp = ar_queue[i][match_idx];
            ar_id = ar_exp.id;
            ar_queue[i].delete(match_idx);
            ar_id_queue[i][ar_act.id].push_back('{id: ar_id, region_id: addr_region(ar_exp.addr)});
            if (Verbose) $info("Slave[%0d] Received AR: id=%0d, len=%0d", i, ar_id, ar_exp.len+1);
          end
        end
      end
  endfunction
  function void device_response(int i, req_t req, rsp_t rsp);
      if (rsp.b_valid && req.b_ready) begin
        automatic b_chan_t b;
        b = rsp.b;
        if (aw_id_queue[i][b.id].size() == 0) report_fatal($sformatf("B has no accepted AW"));
        begin
          automatic rsp_id_t response_id = aw_id_queue[i][b.id].pop_front();
          b.id = response_id.id;
          b_queue[response_id.region_id][b.id].push_back(b);
        end
        if (Verbose) $info("Slave[%0d] Issued B: id=%0d", i, b.id);
      end
      if (rsp.r_valid && req.r_ready) begin
        automatic r_chan_t r;
        r = rsp.r;
        if (ar_id_queue[i][r.id].size() == 0) report_fatal($sformatf("R has no accepted AR"));
        begin
          automatic rsp_id_t response_id = ar_id_queue[i][r.id][0];
          if (r.last) void'(ar_id_queue[i][r.id].pop_front());
          r.id = response_id.id;
          r_queue[response_id.region_id][r.id].push_back(r);
        end
        if (Verbose) $info("Slave[%0d] Issued R: id=%0d, data=%0x, last=%0b",
                           i, r.id, r.data, r.last);
      end
  endfunction
  function void source_response(req_t mon_mst_req_i, rsp_t mon_mst_rsp_i);
    if (mon_mst_rsp_i.b_valid && mon_mst_req_i.b_ready) begin
      automatic b_chan_t b_exp, b_act;
      automatic id_t b_id;
      automatic int unsigned region_id;
      b_act = mon_mst_rsp_i.b;
      b_id = b_act.id;
      if (Verbose) $info("Received B: id=%0d", b_id);
      if (b_out_rsp_queue[b_id].size() == 0) report_error($sformatf("B: id=%0d out rsp queue is empty!", b_id));
      region_id = b_out_rsp_queue[b_id][0].region_id;
      if (b_queue[region_id][b_id].size() == 0) report_error($sformatf("Region [%0d] B queue is empty!", region_id));
      b_exp = b_queue[region_id][b_id].pop_front();
      if (b_exp !== b_act) begin
        report_error($sformatf("B mismatch"));
        print_b(b_exp, b_act);
      end else begin
        // This should always be true for B
        if (b_out_rsp_queue[b_id][0].num_rsp == 0) begin
          if (b_out_rsp_queue[b_id].size() == 0)
            report_error($sformatf("B: id=%0d out response queue is empty!", b_id));
          void'(b_out_rsp_queue[b_id].pop_front());
        end else begin
          b_out_rsp_queue[b_id][0].num_rsp--;
        end
      end
    end
    if (mon_mst_rsp_i.r_valid && mon_mst_req_i.r_ready) begin
      automatic r_chan_t r_exp, r_act;
      automatic id_t r_id;
      automatic int unsigned region_id;
      r_act = mon_mst_rsp_i.r;
      r_id = r_act.id;
      if (Verbose) $info("Received R: id=%0d, data=%0x, last=%0b", r_id, r_act.data, r_act.last);
      if (r_out_rsp_queue[r_id].size() == 0) report_error($sformatf("R: id=%0d out rsp queue is empty!", r_id));
      region_id = r_out_rsp_queue[r_id][0].region_id;
      if (r_queue[region_id][r_id].size() == 0) report_error($sformatf("Region [%0d] R queue is empty!", region_id));
      r_exp = r_queue[region_id][r_id].pop_front();
      begin
        automatic ar_chan_t ar = r_out_rsp_queue[r_id][0].ar;
        automatic int beat = int'(ar.len) - r_out_rsp_queue[r_id][0].num_rsp;
        automatic int lo = axi_pkg::beat_lower_byte(ar.addr, ar.size, ar.len,
            ar.burst, $bits(r_exp.data)/8, beat);
        automatic int hi = axi_pkg::beat_upper_byte(ar.addr, ar.size, ar.len,
            ar.burst, $bits(r_exp.data)/8, beat);
        for (int b = 0; b < $bits(r_exp.data)/8; b++) begin
          if (b < lo || b > hi) begin
            r_exp.data[b*8 +: 8] = '0;
            r_act.data[b*8 +: 8] = '0;
          end
        end
      end
      if (r_exp !== r_act) begin
        report_error($sformatf("R mismatch"));
        print_r(r_exp, r_act);
      end else begin
        if (r_out_rsp_queue[r_id][0].num_rsp == 0) begin
          if (r_out_rsp_queue[r_id].size() == 0) report_error($sformatf("R: id=%0d queue is empty!", r_id));
          void'(r_out_rsp_queue[r_id].pop_front());
          if (Verbose) $info("R: id=%0d region_id=%0d r_out_rsp_queue popped", r_id, region_id);
        end else begin
          r_out_rsp_queue[r_id][0].num_rsp--;
        end
      end
    end
  endfunction
  function bit drained();
    if (w_queue.num() || w_pending.size() || w_input_queue.size()) return 0;
    foreach (aw_queue[i]) begin
      if (aw_queue[i].size() || ar_queue[i].size() || aw_seq_queue[i].size() || w_output_queue[i].size() || w_device_pending[i].size()) return 0;
      for (int id = 0; id < NumAxiIds; id++)
        if (aw_id_queue[i][id].size() || ar_id_queue[i][id].size()) return 0;
    end
    foreach (b_queue[i,j]) if (b_queue[i][j].size() || r_queue[i][j].size()) return 0;
    foreach (b_out_rsp_queue[i]) if (b_out_rsp_queue[i].size() || r_out_rsp_queue[i].size()) return 0;
    return 1;
  endfunction
endclass
