`timescale 1ns/1ps
package ni_nmu_test_pkg;
    import uvm_pkg::*;
    import tvip_axi_types_pkg::*;
    import tvip_axi_pkg::*;
    `include "uvm_macros.svh"
    `include "ni_pattern_sequence.svh"
    class ni_nmu_test extends uvm_test;
        tvip_axi_master_agent source;
        virtual ni_nmu_if control;
        ni_pattern_sequence requests;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            tvip_axi_configuration cfg;
            string directory;
            super.build_phase(phase);
            if (!uvm_config_db #(virtual ni_nmu_if)::get(this, "", "control", control) ||
                    !uvm_config_db #(tvip_axi_configuration)::get(this, "", "source_cfg", cfg))
                `uvm_fatal("CONFIG", "Missing NMU interface configuration")
            source = tvip_axi_master_agent::type_id::create("source", this);
            source.set_configuration(cfg);
            requests = ni_pattern_sequence::type_id::create("requests");
            if (!$value$plusargs("stim_dir=%s", directory)) `uvm_fatal("CONFIG", "Missing stim_dir")
            requests.load_files(directory);
            requests.concurrent_rw = 1;
            if (requests.reads.size())
                for (int i = 0; i < topology_pkg::SAM_NUM_RULES; i++)
                    if (requests.reads[0].address >= topology_pkg::SAM[i].start_addr &&
                            requests.reads[0].address < topology_pkg::SAM[i].end_addr)
                        control.read_data = topology_pkg::SAM[i].idx.is_data;
            control.expected_writes = requests.writes.size();
            control.expected_reads = requests.reads.size();
        endfunction
        task execute();
            int reset_warmup = 1, seed = 1;
            bit random_reset;
            string case_name;
            ni_pattern_sequence warmup;
            tvip_axi_master_item item;
            realtime reset_delay, reset_duration;
            void'($value$plusargs("reset_warmup=%d", reset_warmup));
            void'($value$plusargs("case_name=%s", case_name));
            random_reset = case_name == "reset_recovery" || $test$plusargs("reset_random");
            if (random_reset) reset_warmup = 1;
            repeat (5) @(negedge control.clk);
            if ($test$plusargs("async_clocks")) #($urandom_range(1, 9999) * 1ps);
            control.rst_n = 1;
            wait (control.axi_rst_n && control.noc_rst_n);
            @(negedge control.clk);
            if (reset_warmup) begin
                if (!requests.writes.size() || !requests.reads.size())
                    `uvm_fatal("PATTERN", "Reset warmup requires read and write traffic")
                warmup = ni_pattern_sequence::type_id::create("warmup");
                warmup.concurrent_rw = 1;
                if (!$cast(item, requests.writes[0].clone())) `uvm_fatal("ITEM", "Write clone failed")
                warmup.writes.push_back(item);
                if (!$cast(item, requests.reads[0].clone())) `uvm_fatal("ITEM", "Read clone failed")
                warmup.reads.push_back(item);
                for (int direction = 0; control.read_reorder && direction < 2; direction++) begin
                    if (!$cast(item, direction ? requests.reads[0].clone() : requests.writes[0].clone()))
                        `uvm_fatal("ITEM", "Warmup clone failed")
                    item.address ^= 48'h100000000;
                    item.burst_length = 1;
                    item.burst_size = 8;
                    item.burst_type = TVIP_AXI_INCREMENTING_BURST;
                    if (direction) warmup.reads.push_back(item);
                    else begin
                        item.data = new[1]; item.strobe = new[1];
                        item.data[0] = '0; item.strobe[0] = '0;
                        warmup.writes.push_back(item);
                    end
                end
                fork
                    warmup.start(source.sequencer);
                    wait (control.warm_ready);
                join_any
                source.sequencer.stop_sequences();
                disable fork;
                void'($value$plusargs("seed=%d", seed));
                void'($urandom(seed));
                reset_delay = random_reset ? $urandom_range(1, 199999)*1ps : 5ns;
                reset_duration = random_reset ? $urandom_range(40000, 199999)*1ps : 100ns;
                #(reset_delay);
                control.rst_n = 0;
                #(reset_duration);
                control.rst_n = 1;
                wait (control.axi_rst_n && control.noc_rst_n);
                repeat (20) @(negedge control.clk);
            end
            control.warmup = 0;
            requests.start(source.sequencer);
            repeat (20) @(negedge control.clk);
            control.completed = 1;
        endtask
        task run_phase(uvm_phase phase);
            phase.raise_objection(this);
            fork
                execute();
                begin #2000000; `uvm_fatal("TIMEOUT", "NMU standalone timeout") end
            join_any
            disable fork;
            phase.drop_objection(this);
        endtask
        `uvm_component_utils(ni_nmu_test)
    endclass
endpackage
