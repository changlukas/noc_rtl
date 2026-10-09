class ni_test extends uvm_test;
    ni_env env;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = ni_env::type_id::create("env", this);
    endfunction
    task run_phase(uvm_phase phase);
        tvip_axi_master_sequence_base seq;
        uvm_event start_event = uvm_event_pool::get_global("ni_start");
        uvm_event done_event = uvm_event_pool::get_global("ni_done");
        uvm_event checked_event = uvm_event_pool::get_global("ni_checked");
        phase.raise_objection(this);
        start_event.wait_on();
        if ($test$plusargs("reset_recovery")) begin
            uvm_event reset_begin = uvm_event_pool::get_global("ni_reset_begin");
            uvm_event reset_done = uvm_event_pool::get_global("ni_reset_done");
            if (!uvm_config_db #(tvip_axi_master_sequence_base)::get(this, "", "warmup", seq))
                `uvm_fatal("CONFIG", "Missing reset warmup sequence")
            fork
                seq.start(env.source.sequencer);
                reset_begin.wait_on();
            join_any
            env.source.sequencer.stop_sequences();
            disable fork;
            reset_done.wait_on();
        end
        for (int i = 0; i < 3; i++) begin
            if (uvm_config_db #(tvip_axi_master_sequence_base)::get(this, "", $sformatf("sequence%0d", i), seq))
                seq.start(env.source.sequencer);
        end
        done_event.trigger();
        checked_event.wait_on();
        phase.drop_objection(this);
    endtask
    `uvm_component_utils(ni_test)
endclass
