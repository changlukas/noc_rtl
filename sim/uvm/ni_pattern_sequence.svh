class ni_pattern_sequence extends tvip_axi_master_sequence_base;
    tvip_axi_master_item writes[$], reads[$];
    bit concurrent_rw;
    int first_response_delay;

    function new(string name = "ni_pattern_sequence");
        super.new(name);
    endfunction

    task send_requests(ref tvip_axi_master_item items[$]);
        uvm_event phase_start;
        if (items.size() != 0) begin
            phase_start = uvm_event_pool::get_global(items[0].is_read() ? "ni_read_start" : "ni_write_start");
            phase_start.trigger();
        end
        foreach (items[i]) begin
            items[i].set_context(configuration, status);
            if (!items[i].randomize(start_delay, write_data_delay, response_ready_delay))
                `uvm_fatal("PATTERN", "Invalid pattern or delay configuration")
            if (i == 0 && first_response_delay != 0)
                items[i].response_ready_delay[0] = first_response_delay;
            start_item(items[i]);
            finish_item(items[i]);
        end
        foreach (items[i]) items[i].wait_for_done();
    endtask

    task body();
        if (concurrent_rw) begin
            ni_pattern_sequence wr = new("writes");
            ni_pattern_sequence rd = new("reads");
            wr.writes = writes;
            rd.reads = reads;
            wr.first_response_delay = first_response_delay;
            rd.first_response_delay = first_response_delay;
            fork
                wr.start(m_sequencer, this);
                rd.start(m_sequencer, this);
            join
        end else begin
            send_requests(writes);
            send_requests(reads);
        end
    endtask
    `uvm_object_utils(ni_pattern_sequence)
endclass
