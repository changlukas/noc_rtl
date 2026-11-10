class ni_slave_sequence extends tvip_axi_slave_default_sequence;
    int port, clock_period_ps;
    int hold_port, hold_cycles;
    time hold_epoch[2];

    function new(string name = "ni_slave_sequence");
        super.new(name);
        void'($value$plusargs("response_hold_port=%d", hold_port));
        void'($value$plusargs("response_hold_cycles=%d", hold_cycles));
    endfunction

    task body();
        if (!uvm_config_db #(int)::get(m_sequencer, "", "port", port) ||
            !uvm_config_db #(int)::get(m_sequencer, "", "clock_period_ps", clock_period_ps))
            `uvm_fatal("CONFIG", "Missing Device AXI timing configuration")
        super.body();
    endtask

    protected function int get_response_start_delay(tvip_axi_slave_item item);
        uvm_event phase_start = uvm_event_pool::get_global(item.is_read() ? "ni_read_start" : "ni_write_start");
        time epoch = phase_start.get_trigger_time();
        int remaining;
        if (hold_cycles == 0 || (hold_port != 0 && hold_port != port) ||
                hold_epoch[item.is_read()] == epoch) return -1;
        hold_epoch[item.is_read()] = epoch;
        remaining = hold_cycles - int'(($time - epoch) / clock_period_ps);
        return item.start_delay + (remaining > 0 ? remaining : 0);
    endfunction
    `uvm_object_utils(ni_slave_sequence)
endclass
