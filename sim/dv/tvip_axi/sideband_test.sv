package sideband_test_pkg;
  import uvm_pkg::*;
  import tue_pkg::*;
  import tvip_axi_types_pkg::*;
  import tvip_axi_pkg::*;
  import tvip_axi_sample_pkg::*;
  `include "uvm_macros.svh"
  `include "tue_macros.svh"

  class sideband_configuration extends tvip_axi_sample_configuration;
    constraint c_axi_basic {
      foreach (axi_cfg[i]) {
        axi_cfg[i].id_width == 8;
        axi_cfg[i].address_width == 64;
        axi_cfg[i].data_width == 512;
        axi_cfg[i].max_burst_length == 64;
      }
    }
    constraint c_response_weight {
      axi_cfg[1].response_weight_okay == 1;
      axi_cfg[1].response_weight_exokay == 0;
      axi_cfg[1].response_weight_slave_error == 0;
      axi_cfg[1].response_weight_decode_error == 0;
    }
    constraint c_ready_delay {
      axi_cfg[1].awready_delay.min_delay == 3;
      axi_cfg[1].awready_delay.max_delay == 3;
      axi_cfg[1].arready_delay.min_delay == 3;
      axi_cfg[1].arready_delay.max_delay == 3;
    }
    function new(string name = "sideband_configuration");
      super.new(name);
      foreach (axi_cfg[i]) axi_cfg[i].awuser_width = 58;
    endfunction
    `uvm_object_utils(sideband_configuration)
  endclass

  function automatic tvip_axi_awuser expected_user(int index);
    return (index == 3) ? 64'h03ff_ffff_ffff_ffff : (64'h0200_0000_0000_0001 << index) & 64'h03ff_ffff_ffff_ffff;
  endfunction

  class sideband_sequence extends tvip_axi_master_sequence_base;
    function new(string name = "sideband_sequence");
      super.new(name);
      set_automatic_phase_objection(1);
    endfunction
    task body();
      int lengths[4] = '{1, 2, 16, 64};
      for (int i = 0; i < 4; i++) begin
        tvip_axi_master_write_sequence wr;
        tvip_axi_master_read_sequence rd;
        `tue_do_with(wr, {
          address == (i+1)*4096;
          burst_size == 64;
          burst_length == lengths[i];
          awuser == expected_user(i);
          region == i;
          lock == (i % 2);
          foreach (strobe[j]) strobe[j] == 64'hffff_ffff_ffff_ffff;
        })
        `tue_do_with(rd, {
          address == wr.address;
          burst_size == 64;
          burst_length == lengths[i];
          region == 15-i;
          lock == (1-i%2);
        })
        foreach (wr.data[j]) begin
          if (wr.data[j][511:0] !== rd.data[j][511:0])
            `uvm_error("DATA", $sformatf("Readback mismatch: transfer %0d beat %0d", i, j))
        end
      end
    endtask
    `uvm_object_utils(sideband_sequence)
  endclass

  class sideband_monitor_check extends uvm_subscriber #(tvip_axi_item);
    int count;
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void write(tvip_axi_item t);
      int index = int'(t.address / 4096)-1;
      if (index < 0 || index > 3) `uvm_fatal("ADDRESS", "Unexpected transaction")
      if (t.awuser !== (t.is_write() ? expected_user(index) : 0) ||
          t.region !== (t.is_write() ? index : 15-index) ||
          t.lock !== (t.is_write() ? index%2 : 1-index%2))
        `uvm_error("SIDEBAND", $sformatf("Sampled fields mismatch: address=%h user=%h region=%h lock=%b", t.address, t.awuser, t.region, t.lock))
      count++;
    endfunction
    function void check_phase(uvm_phase phase);
      if (count != 8) `uvm_error("COUNT", $sformatf("Expected 8 transactions, observed %0d", count))
    endfunction
    `uvm_component_utils(sideband_monitor_check)
  endclass

  class sideband_test extends tvip_axi_sample_test;
    sideband_monitor_check checks[2];
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      tvip_axi_sample_configuration::type_id::set_type_override(sideband_configuration::get_type());
      super.build_phase(phase);
      foreach (checks[i]) checks[i] = sideband_monitor_check::type_id::create($sformatf("check%0d", i), this);
    endfunction
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      master_agent.item_port.connect(checks[0].analysis_export);
      slave_agent.item_port.connect(checks[1].analysis_export);
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      uvm_config_db #(uvm_object_wrapper)::set(master_sequencer, "main_phase", "default_sequence", sideband_sequence::get_type());
    endfunction
    `uvm_component_utils(sideband_test)
  endclass
endpackage

module sideband_checks;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  bit enabled;
  string test_name;
  initial enabled = $value$plusargs("UVM_TESTNAME=%s", test_name) && test_name == "sideband_test";
  for (genvar i = 0; i < 2; i++) begin : g_port
    int aw_stalls = 0;
    int ar_stalls = 0;
    always @(posedge top.aclk) begin
      if (enabled && top.areset_n) begin
        if (top.axi_if[i].awvalid && !top.axi_if[i].awready) aw_stalls++;
        if (top.axi_if[i].arvalid && !top.axi_if[i].arready) ar_stalls++;
      end
    end
    assert property (@(posedge top.aclk) disable iff (!top.areset_n || !enabled)
      top.axi_if[i].awvalid && !top.axi_if[i].awready |=>
      top.axi_if[i].awvalid && $stable({top.axi_if[i].awuser, top.axi_if[i].awregion, top.axi_if[i].awlock}))
      else `uvm_error("AW_STABLE", "AW sideband changed during stall")
    assert property (@(posedge top.aclk) disable iff (!top.areset_n || !enabled)
      top.axi_if[i].arvalid && !top.axi_if[i].arready |=>
      top.axi_if[i].arvalid && $stable({top.axi_if[i].arregion, top.axi_if[i].arlock}))
      else `uvm_error("AR_STABLE", "AR sideband changed during stall")
    final if (enabled) begin
      $display("PORT %0d AW_STALL=%0d AR_STALL=%0d", i, aw_stalls, ar_stalls);
      if (i == 1 && (aw_stalls == 0 || ar_stalls == 0)) $error("Stall checks were not exercised");
    end
  end
  initial if ($test$plusargs("CORRUPT_AWUSER")) force top.axi_if[1].awuser[57] = 1'b0;
endmodule
