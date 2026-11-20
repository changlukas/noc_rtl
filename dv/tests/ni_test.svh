class ni_test extends uvm_test;
    ni_env env;
    virtual ni_tb_if control;
    ni_pattern_sequence requests[NI_NUM_SOURCES], initialization[NI_NUM_SOURCES], readback[NI_NUM_SOURCES];
    bit [NI_NUM_SOURCES-1:0] source_mask = 1;
    int primary_source;
    bit forwarding;
    string directory;
    int reset_drain_cycles;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = ni_env::type_id::create("env", this);
        if (!uvm_config_db #(virtual ni_tb_if)::get(this, "", "control", control) ||
                !uvm_config_db #(int)::get(this, "", "reset_drain_cycles", reset_drain_cycles))
            `uvm_fatal("CONFIG", "Missing clock/reset interface configuration")
        if (!$value$plusargs("stim_dir=%s", directory)) `uvm_fatal("CONFIG", "Missing stim_dir")
        void'($value$plusargs("source_mask=%h", source_mask));
        if (source_mask == 0) `uvm_fatal("CONFIG", "Empty source mask")
        forwarding = $test$plusargs("forwarding");
        if (forwarding && $test$plusargs("preload"))
            `uvm_fatal("FORWARD", "Forwarding device memories must start empty")
        if (forwarding && $test$plusargs("concurrent_rw"))
            `uvm_fatal("FORWARD", "Forwarding does not support concurrent read/write")
        primary_source = 0;
        while (!source_mask[primary_source]) primary_source++;
        foreach (requests[i]) begin
            string path;
            bit injection_enabled;
            if (!source_mask[i]) continue;
            path = i == primary_source ? directory : $sformatf("%s/source%0d", directory, i);
            requests[i] = ni_pattern_sequence::type_id::create($sformatf("requests%0d", i));
            requests[i].load_files(path);
            if ($value$plusargs("row_copies=%d", requests[i].row_copies)) begin
                if (source_mask != 'h1111 || !(requests[i].row_copies inside {1, 4}))
                    `uvm_fatal("ROW_FEED", "Expected four row sources and one or four AXI writes")
            end
            requests[i].zero_load = $test$plusargs("zero_load");
            injection_enabled = $value$plusargs("injection_ratio=%f", requests[i].injection_ratio);
            if (injection_enabled && (!(requests[i].injection_ratio > 0 &&
                    requests[i].injection_ratio <= 0.5) || requests[i].zero_load))
                `uvm_fatal("PATTERN", "Positive injection and zero-load are mutually exclusive")
            if (injection_enabled || requests[i].zero_load) begin
                if (requests[i].writes.size() != 0 || $test$plusargs("concurrent_rw"))
                    `uvm_fatal("PATTERN", "Latency injection modes require plain reads")
                foreach (requests[i].reads[j]) begin
                    if (requests[i].reads[j].burst_length != 1 || requests[i].reads[j].burst_size != 8)
                        `uvm_fatal("PATTERN", "Injection requires single-beat 64-bit reads")
                end
            end
            if ($value$plusargs("read_outstanding_limit=%d", requests[i].read_outstanding_limit)) begin
                if (requests[i].read_outstanding_limit < 1 || requests[i].writes.size() != 0 ||
                        $test$plusargs("concurrent_rw"))
                    `uvm_fatal("PATTERN", "read_outstanding_limit requires positive limit and plain reads")
            end
            if ($value$plusargs("write_outstanding_limit=%d", requests[i].write_outstanding_limit)) begin
                if (requests[i].write_outstanding_limit < 1 || requests[i].reads.size() != 0 ||
                        $test$plusargs("concurrent_rw"))
                    `uvm_fatal("PATTERN", "write_outstanding_limit requires positive limit and plain writes")
            end
            requests[i].concurrent_rw = $test$plusargs("concurrent_rw");
            void'($value$plusargs("source_response_hold_cycles=%d", requests[i].first_response_delay));
            if (requests[i].writes.size() + requests[i].reads.size() == 0) `uvm_fatal("PATTERN", "Empty memory test")
            if ($test$plusargs("init_phase")) begin
                initialization[i] = ni_pattern_sequence::type_id::create($sformatf("initialization%0d", i));
                initialization[i].load_files(path, "init_write.txt", "");
            end
            if ($test$plusargs("readback")) begin
                readback[i] = ni_pattern_sequence::type_id::create($sformatf("readback%0d", i));
                readback[i].load_files(path, "", "verify_read.txt");
            end
        end
        if (forwarding) load_forwarding();
    endfunction

    function void load_forwarding();
        int fd, count, source, index, parent, transaction;
        string line;
        tvip_axi_address address;
        fd = $fopen({directory, "/schedule.txt"}, "r");
        if (!fd) `uvm_fatal("FORWARD", "Missing forwarding schedule")
        while ($fgets(line, fd)) begin
            if (line.len() >= 6 && line.substr(0, 5) == "#after") begin
                count = $sscanf(line, "#after %d %d %d %d", source, index, parent, transaction);
                if (count != 4 || source < 0 || source >= NI_NUM_SOURCES ||
                        parent < 0 || parent >= NI_NUM_SOURCES)
                    `uvm_fatal("FORWARD", "Invalid dependency endpoints")
                if (requests[source] == null || requests[parent] == null ||
                        index < 0 || index >= requests[source].writes.size() ||
                        transaction < 0 || transaction >= requests[parent].writes.size() ||
                        (source == parent && transaction >= index))
                    `uvm_fatal("FORWARD", "Invalid dependency transaction")
                requests[source].dependencies[index].push_back(requests[parent].writes[transaction]);
            end else if (line.len() >= 8 && line.substr(0, 7) == "#forward") begin
                count = $sscanf(line, "#forward %d %d 0x%h", source, index, address);
                if (count != 3 || source < 0 || source >= NI_NUM_SOURCES)
                    `uvm_fatal("FORWARD", "Invalid forwarding endpoint")
                if (requests[source] == null || index < 0 || index >= requests[source].writes.size() ||
                        requests[source].forward_address.exists(index))
                    `uvm_fatal("FORWARD", "Invalid forwarding transaction")
                requests[source].forward_address[index] = address;
            end
        end
        $fclose(fd);
    endfunction

    function void expect_sequence(ni_pattern_sequence seq);
        env.scoreboard.expected_writes += seq.writes.size();
        env.scoreboard.expected_reads += seq.reads.size();
        env.scoreboard.expected_beats += seq.read_beats();
    endfunction
    task reset_recovery();
        ni_pattern_sequence warmup;
        int seed = 1, delay_cycles;
        warmup = ni_pattern_sequence::type_id::create("warmup");
        warmup.load_files(directory);
        warmup.concurrent_rw = 1;
        warmup.first_response_delay = 100000;
        void'($value$plusargs("reset_seed=%d", seed));
        void'($urandom(seed));
        delay_cycles = $urandom_range(2, 24);
        fork
            warmup.start(env.source[0].sequencer);
            begin
                wait (env.scoreboard.peak_w != 0 && env.scoreboard.peak_r != 0);
                repeat (delay_cycles) @(negedge control.clk);
            end
        join_any
        env.source[0].sequencer.stop_sequences();
        disable fork;
        if (!env.scoreboard.outstanding(0) || !env.scoreboard.outstanding(1))
            `uvm_fatal("RESET", "Reset missed pending traffic")
        control.reset_pending_seen = 1;
        $display("RESET_PENDING time=%0t seed=%0d delay=%0d writes=%0d reads=%0d", $time, seed,
            delay_cycles, env.scoreboard.outstanding(0), env.scoreboard.outstanding(1));
        control.rst_n = 0;
        control.release_reset();
        // Monitors/checkers remain active: a stale response is unsolicited.
        repeat (reset_drain_cycles) @(negedge control.clk);
        control.reset_complete = 1;
    endtask
    task execute();
        control.release_reset();
        @(posedge control.clk);
        if ($test$plusargs("reset_recovery")) reset_recovery();
        foreach (requests[i]) begin
            if (requests[i] != null) expect_sequence(requests[i]);
            if (initialization[i] != null) expect_sequence(initialization[i]);
            if (readback[i] != null) expect_sequence(readback[i]);
        end
        if (forwarding) begin
            foreach (requests[i]) begin
                if (requests[i] != null) begin
                    tvip_axi_status state = env.device[i].get_status();
                    requests[i].forwarding_memory = state.memory;
                end
            end
        end
        env.scoreboard.concurrent_active = $test$plusargs("concurrent_rw");
        foreach (requests[i]) begin
            automatic int source = i;
            if (requests[i] != null) fork
                begin
                    ni_perf::source_phase[source] = 0;
                    if (initialization[source] != null) initialization[source].start(env.source[source].sequencer);
                    ni_perf::source_phase[source] = 1;
                    requests[source].start(env.source[source].sequencer);
                    if (env.source_perf[source] != null) begin
                        control.perf_source_done[source] = 1;
                        env.source_perf[source].emit("SOURCE_DONE", $time);
                    end
                    ni_perf::source_phase[source] = 2;
                    if (!forwarding && readback[source] != null) readback[source].start(env.source[source].sequencer);
                end
            join_none
        end
        wait fork;
        if (forwarding) begin
            foreach (readback[i]) begin
                automatic int source = i;
                if (readback[i] != null) fork
                    readback[source].start(env.source[source].sequencer);
                join_none
            end
            wait fork;
        end
        env.scoreboard.concurrent_active = 0;
        repeat (10) @(posedge control.clk);
        if (!env.scoreboard.drained()) `uvm_fatal("PENDING", "Scoreboard has pending transactions")
        control.completed = 1;
    endtask
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        fork
            execute();
            begin
                repeat (100000) @(posedge control.clk);
                `uvm_fatal("TIMEOUT", "NI simulation timeout")
            end
        join_any
        disable fork;
        phase.drop_objection(this);
    endtask
    `uvm_component_utils(ni_test)
endclass
