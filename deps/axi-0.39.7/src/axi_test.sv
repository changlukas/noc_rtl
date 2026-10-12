// Copyright (c) 2014-2018 ETH Zurich, University of Bologna
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Authors:
// - Andreas Kurth <akurth@iis.ee.ethz.ch>
// - Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>
// - Fabian Schuiki <fschuiki@iis.ee.ethz.ch>
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Matheus Cavalcante <matheusd@iis.ee.ethz.ch>


/// A set of testbench utilities for AXI interfaces.
package axi_test;

  import axi_pkg::*;

  /// The data transferred on a beat on the AW/AR channels.
  class axi_ax_beat #(
    parameter int unsigned AW = 32,
    parameter int unsigned IW = 8 ,
    parameter int unsigned UW = 1
  );
    rand logic [IW-1:0] ax_id     = '0;
    rand logic [AW-1:0] ax_addr   = '0;
    logic [7:0]         ax_len    = '0;
    logic [2:0]         ax_size   = '0;
    logic [1:0]         ax_burst  = '0;
    logic               ax_lock   = '0;
    logic [3:0]         ax_cache  = '0;
    logic [2:0]         ax_prot   = '0;
    rand logic [3:0]    ax_qos    = '0;
    logic [3:0]         ax_region = '0;
    logic [5:0]         ax_atop   = '0; // Only defined on the AW channel.
    rand logic [UW-1:0] ax_user   = '0;
  endclass

  /// The data transferred on a beat on the W channel.
  class axi_w_beat #(
    parameter int unsigned DW = 32,
    parameter int unsigned UW = 1
  );
    rand logic [DW-1:0]   w_data = '0;
    rand logic [DW/8-1:0] w_strb = '0;
    logic                 w_last = '0;
    rand logic [UW-1:0]   w_user = '0;
  endclass

  /// The data transferred on a beat on the B channel.
  class axi_b_beat #(
    parameter int unsigned IW = 8,
    parameter int unsigned UW = 1
  );
    rand logic [IW-1:0] b_id   = '0;
    axi_pkg::resp_t     b_resp = '0;
    rand logic [UW-1:0] b_user = '0;
  endclass

  /// The data transferred on a beat on the R channel.
  class axi_r_beat #(
    parameter int unsigned DW = 32,
    parameter int unsigned IW = 8 ,
    parameter int unsigned UW = 1
  );
    rand logic [IW-1:0] r_id   = '0;
    rand logic [DW-1:0] r_data = '0;
    axi_pkg::resp_t     r_resp = '0;
    logic               r_last = '0;
    rand logic [UW-1:0] r_user = '0;
  endclass


  /// `axi_scoreboard` models a memory that only gets changed by the monitored AXI4+ATOP bus.
  ///
  /// This class is only capable of modeling `INCR` burst type, and cannot handle atomic operations.
  /// The internal memory representation is updated by W beats.  This class does not support
  /// reordering of two B responses to one memory location.  That is, if two write transactions on
  /// the observed bus target the same address, the B responses must be observed in the order of the
  /// AW beats; otherwise, the internal memory representation of this class gets corrupted.
  ///
  class axi_scoreboard #(
    /// AXI4+ATOP ID width
    parameter int unsigned IW = 0,
    /// AXI4+ATOP address width
    parameter int unsigned AW = 0,
    /// AXI4+ATOP data width
    parameter int unsigned DW = 0,
    /// AXI4+ATOP user width
    parameter int unsigned UW = 0
  );
    // Number of checks
    localparam int unsigned NUM_CHECKS  = 32'd3;
    // Size of the AXI4+ATOP bus, used for alignment of the beat address
    localparam axi_pkg::size_t BUS_SIZE = $clog2(DW/8);

    // Typedefs
    typedef enum logic [1:0] {
      ReadCheck  = 2'd0,
      BRespCheck = 2'd1,
      RRespCheck = 2'd2
    } check_e;
    typedef logic [7:0]      byte_t;
    typedef logic [IW-1:0]   axi_id_t;
    typedef logic [AW-1:0]   axi_addr_t;
    typedef axi_ax_beat #(.AW(AW), .IW(IW), .UW(UW)) ax_beat_t;
    typedef axi_w_beat  #(.DW(DW), .UW(UW))          w_beat_t;
    typedef axi_b_beat  #(.IW(IW), .UW(UW))          b_beat_t;
    typedef axi_r_beat  #(.DW(DW), .IW(IW), .UW(UW)) r_beat_t;

    // Memory model
    protected byte_t memory_q [axi_addr_t][$];
    // Which checks are enabled
    protected bit [NUM_CHECKS-1:0] check_en;
    // Sampling queues
    protected ax_beat_t aw_sample [$];
    protected w_beat_t   w_sample [$];
    protected b_beat_t   b_sample [2**IW][$];
    protected ax_beat_t ar_sample [2**IW][$];
    protected r_beat_t   r_sample [2**IW][$];

    // Write queues
    protected ax_beat_t  b_queue  [2**IW][$];

    function new();
      this.check_en = '0;
    endfunction

    /// Handle update of the golden model with W beats.
    protected task automatic handle_write();
      axi_addr_t beat_addresses [];
      axi_addr_t bus_address;
      ax_beat_t  aw_beat;
      w_beat_t   w_beat;
      byte_t     write_data;
      forever begin
        wait (this.aw_sample.size() > 0);
        aw_beat        = this.aw_sample.pop_front();
        // This scoreborad only supports this type of burst:
        assert (aw_beat.ax_burst == axi_pkg::BURST_INCR || aw_beat.ax_len == '0) else
            $warning("Not supported AW burst: BURST: %0h.", aw_beat.ax_burst);
        assert (aw_beat.ax_atop == '0) else
            $warning("Atomic transfers not supported: ATOP: %0h.", aw_beat.ax_atop);

        beat_addresses = new[aw_beat.ax_len + 1];
        for (int unsigned i = 0; i <= aw_beat.ax_len; i++) begin
          beat_addresses[i] = axi_pkg::beat_addr(aw_beat.ax_addr, aw_beat.ax_size, aw_beat.ax_len,
              aw_beat.ax_burst, i);
          bus_address       = axi_pkg::aligned_addr(beat_addresses[i], BUS_SIZE);
          // Check if the memory array is initialyzed at this beat address (aligned on the bus)
          if (!this.memory_q.exists(bus_address)) begin
            for (int unsigned j = 0; j < axi_pkg::num_bytes(BUS_SIZE); j++) begin
              this.memory_q[bus_address+j].push_back(8'bxxxxxxxx);
            end
          end
        end
        // handle all write beats for this write access
        for (int unsigned i = 0; i <= aw_beat.ax_len; i++) begin
          wait (this.w_sample.size() > 0);
          w_beat      = this.w_sample.pop_front();
          bus_address = axi_pkg::aligned_addr(beat_addresses[i], BUS_SIZE);
          for (int unsigned j = 0; j < axi_pkg::num_bytes(BUS_SIZE); j++) begin
            write_data = this.memory_q[bus_address+j][$];
            write_data = (w_beat.w_strb[j]) ? w_beat.w_data[8*j+:8] : write_data;
            this.memory_q[bus_address+j].push_back(write_data);
          end
        end
        assert (w_beat.w_last) else $warning("Unexpected W last not set.");
        this.b_queue[aw_beat.ax_id].push_back(aw_beat);
      end
    endtask : handle_write

    /// Handle Write response checking, update golden model
    protected task automatic handle_write_resp(input axi_id_t id);
      ax_beat_t  aw_beat;
      b_beat_t   b_beat;
      axi_addr_t bus_address;
      forever begin
        wait (this.b_sample[id].size() > 0);
        assert (this.b_queue[id].size() > 0) else
            wait (this.b_queue[id].size() > 0);
        aw_beat = b_queue[id].pop_front();
        b_beat  = b_sample[id].pop_front();
        if (check_en[BRespCheck]) begin
          assert (b_beat.b_id   == id);
        end
        // pop all accessed memory locations by this beat
        for (int unsigned i = 0; i <= aw_beat.ax_len; i++) begin
          bus_address = axi_pkg::aligned_addr(
              axi_pkg::beat_addr(aw_beat.ax_addr, aw_beat.ax_size, aw_beat.ax_len, aw_beat.ax_burst,
                  i), BUS_SIZE);
          for (int j = 0; j < axi_pkg::num_bytes(BUS_SIZE); j++) begin
            if (b_beat.b_resp inside {axi_pkg::RESP_OKAY, axi_pkg::RESP_EXOKAY}) begin
              memory_q[bus_address+j].delete(0);
            end else begin
              memory_q[bus_address+j].delete(memory_q[bus_address+j].size() - 1);
            end
          end
        end
      end
    endtask : handle_write_resp

    // Local adaptation: UVM consumers override reporting without duplicating comparison logic.
    virtual function void report_read_error(string message);
      $warning("%s", message);
    endfunction

    /// Handle read checking against the golden model
    protected task automatic handle_read(input axi_id_t id);
      ax_beat_t  ar_beat;
      r_beat_t   r_beat;
      axi_addr_t bus_address, beat_address, idx_data;
      byte_t     act_data;
      byte_t     exp_data[$];
      byte_t     tst_data[$];
      int        first_byte_to_check;
      forever begin
        wait (this.ar_sample[id].size() > 0);
        ar_beat = this.ar_sample[id].pop_front();
        // This scoreborad only supports this type of burst:
        assert (ar_beat.ax_burst == axi_pkg::BURST_INCR || ar_beat.ax_len == '0) else
            $warning("Not supported AR burst: BURST: %0h.", ar_beat.ax_burst);

        for (int unsigned i = 0; i <= ar_beat.ax_len; i++) begin
          wait (this.r_sample[id].size() > 0);
          r_beat = this.r_sample[id].pop_front();
          beat_address = axi_pkg::beat_addr(ar_beat.ax_addr, ar_beat.ax_size, ar_beat.ax_len,
              ar_beat.ax_burst, i);
          beat_address = axi_pkg::aligned_addr(beat_address, ar_beat.ax_size);
          bus_address  = axi_pkg::aligned_addr(beat_address, BUS_SIZE);
          if(i!=0)
            first_byte_to_check = 0;
          else
            first_byte_to_check = ar_beat.ax_addr - beat_address;
          if (!this.memory_q.exists(bus_address)) begin
            for (int unsigned j = 0; j < axi_pkg::num_bytes(BUS_SIZE); j++) begin
              this.memory_q[bus_address+j].push_back(8'bxxxxxxxx);
            end
          end
          // Assert that the correct data is read.
          if (this.check_en[ReadCheck] &&
              (r_beat.r_resp inside {axi_pkg::RESP_OKAY, axi_pkg::RESP_EXOKAY})) begin
            for (int unsigned j = first_byte_to_check; j < axi_pkg::num_bytes(ar_beat.ax_size); j++) begin
              idx_data  = 8*BUS_SIZE'(beat_address+j);
              act_data  = r_beat.r_data[idx_data+:8];
              exp_data  = this.memory_q[beat_address+j];
              if (exp_data.size() > 0) begin
                tst_data  = exp_data.find with (item === 8'hxx || item === act_data);
                assert (tst_data.size() > 0) else begin
                  report_read_error($sformatf("Unexpected RData ID: %0h \n \
                            Addr:     %h \n \
                            Byte Idx: %h \n \
                            Exp Data: %s \n \
                            Act Data: %h \n \
                            BeatData: %h",
                  r_beat.r_id, beat_address+j, idx_data, $sformatf("%p", exp_data), act_data, r_beat.r_data));
                end
              end
            end
          end
        end
        if (this.check_en[RRespCheck]) begin
          assert (r_beat.r_id   == id);
          assert (r_beat.r_last);
        end
      end
    endtask : handle_read

    /// Enable checking of the read data
    /// Asserts that the data on the R channel matches the expected response modeled by th class.
    task enable_read_check();
      this.check_en[ReadCheck] = 1'b1;
    endtask : enable_read_check

    /// Disable checking of the read data
    task disable_read_check();
      this.check_en[ReadCheck] = 1'b0;
    endtask : disable_read_check

    /// Enable checking of the write resp
    /// Asserts that the B channel response is `axi_pkg::RESP_OKAY`.
    task enable_b_resp_check();
      this.check_en[BRespCheck] = 1'b1;
    endtask : enable_b_resp_check

    /// Disable checking of the write resp
    task disable_b_resp_check();
      this.check_en[BRespCheck] = 1'b0;
    endtask : disable_b_resp_check

    /// Enable checking of the read resp
    /// Asserts that the R channel response is `axi_pkg::RESP_OKAY`.
    /// Asserts that the R channel last flag is correctly set.
    task enable_r_resp_check();
      this.check_en[RRespCheck] = 1'b1;
    endtask : enable_r_resp_check

    /// Disable checking of the read resp
    task disable_r_resp_check();
      this.check_en[RRespCheck] = 1'b0;
    endtask : disable_r_resp_check

    /// Enable all checks
    task enable_all_checks();
      this.check_en = '1;
    endtask : enable_all_checks

    /// Disable all checks
    task disable_all_checks();
      this.check_en = '0;
    endtask : disable_all_checks

    /// Reset the monitor, clear internal memory and all queues, only call if there are no
    /// transactions in flight.
    task automatic reset();
      this.check_en = '0;
      this.memory_q.delete();
      assert(this.aw_sample.size() == 0);
      assert(this.w_sample.size()  == 0);
      for (int unsigned i = 0; i < 2**IW; i++) begin
        assert(this.b_sample[i].size()  == 0);
        assert(this.ar_sample[i].size() == 0);
        assert(this.r_sample[i].size()  == 0);
        assert(this.b_queue[i].size()   == 0);
      end
    endtask : reset

    /// Check that the byte in memory_q is the same as check_data.
    task automatic check_byte(axi_addr_t check_addr, byte_t check_data);
      assert(this.memory_q[check_addr][0] === check_data) else
        $warning("Byte at ADDR: %h does not match: memory_q: %h check_data: %h",
            check_addr, this.memory_q[check_addr][0], check_data);
    endtask : check_byte

    /// Clear a byte from memoy. Can be used to partially delete mem space.
    task clear_byte(axi_addr_t clear_addr);
      if (this.memory_q.exists(clear_addr)) begin
        this.memory_q.delete(clear_addr);
      end
    endtask : clear_byte

    /// Clear a memory range.
    /// The end address alo gets cleared.
    task automatic clear_range(axi_addr_t clear_start_addr, clear_end_addr);
      axi_addr_t curr_addr = clear_start_addr;
      while (curr_addr <= clear_end_addr) begin
        this.clear_byte(curr_addr);
        curr_addr++;
      end
    endtask : clear_range

    /// Get a byte from the modeled memory.
    task automatic get_byte(input axi_addr_t byte_addr, output byte_t byte_data);
      if (this.memory_q.exists(byte_addr)) begin
        byte_data = this.memory_q[byte_addr][0];
      end else begin
        byte_data = 8'hxx;
      end
    endtask : get_byte

  endclass : axi_scoreboard




endpackage
