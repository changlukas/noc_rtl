class ni_test extends uvm_test;
    ni_env env;
    virtual ni_tb_if control;
    ni_pattern_sequence requests, initialization, readback;
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
        requests = ni_pattern_sequence::type_id::create("requests");
        requests.load_files(directory);
        requests.concurrent_rw = $test$plusargs("concurrent_rw");
        void'($value$plusargs("source_response_hold_cycles=%d", requests.first_response_delay));
        if (requests.writes.size() + requests.reads.size() == 0) `uvm_fatal("PATTERN", "Empty memory test")
        if ($test$plusargs("init_phase")) begin
            initialization = ni_pattern_sequence::type_id::create("initialization");
            initialization.load_files(directory, "init_write.txt", "");
        end
        if ($test$plusargs("readback")) begin
            readback = ni_pattern_sequence::type_id::create("readback");
            readback.load_files(directory, "", "verify_read.txt");
        end
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
            warmup.start(env.source.sequencer);
            begin
                wait (env.scoreboard.peak_w != 0 && env.scoreboard.peak_r != 0);
                repeat (delay_cycles) @(negedge control.clk);
            end
        join_any
        env.source.sequencer.stop_sequences();
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
        expect_sequence(requests);
        if (initialization != null) expect_sequence(initialization);
        if (readback != null) expect_sequence(readback);
        env.scoreboard.concurrent_active = requests.concurrent_rw;
        if (initialization != null) initialization.start(env.source.sequencer);
        requests.start(env.source.sequencer);
        if (readback != null) readback.start(env.source.sequencer);
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
