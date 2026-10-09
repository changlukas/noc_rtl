// SPDX-License-Identifier: Apache-2.0
class ni_noc_sample extends uvm_sequence_item;
    bit reset;
    bit req_accept, rsp_accept, dat_accept;
    ni_flit_pkg::req_flit_t req;
    ni_flit_pkg::rsp_flit_t rsp;
    ni_flit_pkg::dat_flit_t dat;
    logic [NUM_DAT_VC-1:0] credit;
    function new(string name = "ni_noc_sample"); super.new(name); endfunction
    `uvm_object_utils(ni_noc_sample)
endclass

class ni_noc_monitor extends uvm_monitor;
    virtual ni_noc_if vif;
    uvm_analysis_port #(ni_noc_sample) analysis_port;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        analysis_port = new("analysis_port", this);
        if (!uvm_config_db #(virtual ni_noc_if)::get(this, "", "vif", vif))
            `uvm_fatal("CONFIG", "Missing NoC monitor interface")
    endfunction
    task run_phase(uvm_phase phase);
        forever begin
            ni_noc_sample s;
            @(vif.monitor_cb);
            s = new();
            s.reset = !vif.monitor_cb.rst_n;
            s.req_accept = vif.monitor_cb.req_valid && vif.monitor_cb.req_ready;
            s.rsp_accept = vif.monitor_cb.rsp_valid && vif.monitor_cb.rsp_ready;
            s.dat_accept = vif.monitor_cb.dat_valid;
            s.req = vif.monitor_cb.req;
            s.rsp = vif.monitor_cb.rsp;
            s.dat = vif.monitor_cb.dat;
            s.credit = vif.monitor_cb.credit;
            analysis_port.write(s);
        end
    endtask
    `uvm_component_utils(ni_noc_monitor)
endclass

`ifdef NI_COVERAGE
class ni_credit_coverage;
    // Same credit states/cross as the former bound counter coverage.
    covergroup credit_cg with function sample(bit available, bit give, bit take);
        option.per_instance = 1;
        cp_available: coverpoint available { bins zero = {0}; bins nonzero = {1}; }
        cp_give: coverpoint give { bins idle = {0}; bins returned = {1}; }
        cp_take: coverpoint take { bins idle = {0}; bins sent = {1}; }
        credit_return_send: cross cp_available, cp_give, cp_take {
            ignore_bins no_credit_send = binsof(cp_available.zero) && binsof(cp_give.idle) && binsof(cp_take.sent);
        }
    endgroup
    function new(string name);
        credit_cg = new();
        credit_cg.set_inst_name(name);
    endfunction
endclass
`endif

class ni_noc_coverage extends uvm_subscriber #(ni_noc_sample);
    int credits[NUM_DAT_VC];
`ifdef NI_COVERAGE
    ni_credit_coverage credit_coverage[NUM_DAT_VC];
`endif
    function new(string name, uvm_component parent);
        super.new(name, parent);
        foreach (credits[i]) begin
            credits[i] = CREDIT_DEPTH;
`ifdef NI_COVERAGE
            credit_coverage[i] = new($sformatf("%s.vc%0d", get_full_name(), i));
`endif
        end
    endfunction
    function void write(ni_noc_sample s);
        if (s.reset) begin
            foreach (credits[i]) credits[i] = CREDIT_DEPTH;
            return;
        end
        foreach (credits[i]) begin
            bit take = s.dat_accept && s.dat.header[ni_flit_pkg::VC_ID_LSB+:ni_flit_pkg::VC_ID_WIDTH] == i;
`ifdef NI_COVERAGE
            credit_coverage[i].credit_cg.sample(credits[i] != 0, s.credit[i], take);
`endif
            credits[i] += int'(s.credit[i]) - int'(take);
            if (credits[i] < 0 || credits[i] > CREDIT_DEPTH)
                `uvm_error("CREDIT", $sformatf("VC%0d credit balance=%0d", i, credits[i]))
        end
    endfunction
    `uvm_component_utils(ni_noc_coverage)
endclass
