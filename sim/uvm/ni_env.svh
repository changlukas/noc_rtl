class ni_env extends uvm_env;
    ni_noc_monitor noc_monitor[2*(NI_NUM_NSUS+1)];
    ni_noc_coverage noc_coverage[2*(NI_NUM_NSUS+1)];
    ni_scoreboard scoreboard;
    ni_axi_coverage coverage;
    ni_axi_coverage device_coverage[NI_NUM_NSUS];
    tvip_axi_master_agent source;
    tvip_axi_slave_agent device[4];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        tvip_axi_configuration cfg;
        super.build_phase(phase);
        tvip_axi_master_write_monitor::type_id::set_type_override(ni_axi_monitor #(tvip_axi_master_write_monitor)::get_type());
        tvip_axi_slave_write_monitor::type_id::set_type_override(ni_axi_monitor #(tvip_axi_slave_write_monitor)::get_type());
        foreach (noc_monitor[i]) begin
            noc_monitor[i] = ni_noc_monitor::type_id::create($sformatf("noc_%s%0d", i%2 == 0 ? "tx" : "rx", i/2), this);
            noc_coverage[i] = ni_noc_coverage::type_id::create($sformatf("noc_%s_coverage%0d", i%2 == 0 ? "tx" : "rx", i/2), this);
        end
        scoreboard = ni_scoreboard::type_id::create("scoreboard", this);
        coverage = ni_axi_coverage::type_id::create("coverage", this);
        uvm_config_db #(ni_scoreboard)::set(null, "", "ni_scoreboard", scoreboard);
        if (!uvm_config_db #(tvip_axi_configuration)::get(this, "", "source_cfg", cfg))
            `uvm_fatal("CONFIG", "Missing Source AXI configuration")
        source = tvip_axi_master_agent::type_id::create("source", this);
        source.set_configuration(cfg);
        foreach (device[i]) begin
            if (!uvm_config_db #(tvip_axi_configuration)::get(this, "", $sformatf("device_cfg%0d", i), cfg))
                `uvm_fatal("CONFIG", "Missing Device AXI configuration")
            device[i] = tvip_axi_slave_agent::type_id::create($sformatf("device%0d", i), this);
            device[i].set_configuration(cfg);
            uvm_config_db #(int)::set(this, $sformatf("device_coverage%0d", i), "endpoint", i);
            uvm_config_db #(int)::set(this, $sformatf("device_coverage%0d", i), "id_width", cfg.id_width);
            device_coverage[i] = ni_axi_coverage::type_id::create($sformatf("device_coverage%0d", i), this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        foreach (noc_monitor[i]) noc_monitor[i].analysis_port.connect(noc_coverage[i].analysis_export);
        source.transfer_port.connect(scoreboard.input_fifo[0].analysis_export);
        source.transfer_port.connect(coverage.analysis_export);
        foreach (device[i]) begin
            device[i].transfer_port.connect(scoreboard.input_fifo[i+1].analysis_export);
            device[i].transfer_port.connect(device_coverage[i].analysis_export);
        end
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        string directory;
        logic [7:0] bytes[tvip_axi_address];
        super.end_of_elaboration_phase(phase);
        if ($test$plusargs("preload")) begin
            if (!$value$plusargs("stim_dir=%s", directory)) `uvm_fatal("CONFIG", "Missing stim_dir")
            $readmemh({directory, "/preload.mem"}, bytes);
        end
        foreach (device[i]) begin
            tvip_axi_status state = device[i].get_status();
            foreach (bytes[address]) begin
                tvip_axi_data data = 0;
                tvip_axi_strobe strobe = 0;
                int lane = int'(address % (ni_params_pkg::AXI_DATA_WIDTH/8));
                data[8*lane+:8] = bytes[address];
                strobe[lane] = 1;
                state.memory.put(data, strobe, 1, address, 0);
            end
            uvm_config_db #(int)::set(device[i].sequencer, "", "port", i+1);
            uvm_config_db #(uvm_object_wrapper)::set(device[i].sequencer, "run_phase",
                "default_sequence", ni_slave_sequence::get_type());
        end
    endfunction
    `uvm_component_utils(ni_env)
endclass
