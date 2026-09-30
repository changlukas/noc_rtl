// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module tb_nsu_context_buffer #(
    parameter int OUTPUT_ID_WIDTH = 2,
    parameter int DEPTH           = 3
);
    import ni_types_pkg::*;
    import ni_signals_pkg::*;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    nsu_aw_request_t aw = '0;
    nsu_ar_request_t ar = '0;
    typedef struct packed {
        logic [1:0] bresp;
        logic [OUTPUT_ID_WIDTH-1:0] bid;
    } device_b_t;
    typedef struct packed {
        logic [ni_params_pkg::AXI_DATA_WIDTH-1:0] rdata;
        logic [1:0] rresp;
        logic [OUTPUT_ID_WIDTH-1:0] rid;
        logic rlast;
    } device_r_t;
    device_b_t b = '0;
    device_r_t r = '0;
    nsu_b_response_t b_out;
    nsu_r_response_t r_out;
    nsu_w_context_t w_context;
    logic aw_valid = 0, ar_valid = 0, b_valid = 0, r_valid = 0;
    logic b_ready = 1, r_ready = 1, w_accept = 0, w_last = 1;
    wire aw_ready, ar_ready, b_in_ready, r_in_ready, b_out_valid, r_out_valid, w_valid;
    wire [OUTPUT_ID_WIDTH-1:0] awid, arid;
    wire [ni_flit_pkg::AXI_LEN_WIDTH-1:0] w_beat;
    int b_count = 0, r_count = 0;
    nsu_context_t contexts[DEPTH+2];

    nsu_context_buffer #(
        .OUTPUT_ID_WIDTH (OUTPUT_ID_WIDTH), .AW_CONTEXT_DEPTH(DEPTH), .AR_CONTEXT_DEPTH(DEPTH),
        .b_t             (device_b_t), .r_t(device_r_t                                       )
    ) dut (
        .clk_i         (clk), .rst_n_i(rst_n                                                 ),
        .s_aw_i        (aw), .s_aw_valid_i(aw_valid), .s_aw_ready_o(aw_ready), .m_awid_o(awid),
        .s_ar_i        (ar), .s_ar_valid_i(ar_valid), .s_ar_ready_o(ar_ready), .m_arid_o(arid),
        .m_w_context_o (w_context), .m_w_context_valid_o(w_valid), .m_w_beat_o(w_beat        ),
        .w_accept_i    (w_accept), .w_last_i(w_last                                          ),
        .s_b_i         (b), .s_b_valid_i(b_valid), .s_b_ready_o(b_in_ready                   ),
        .m_b_o         (b_out), .m_b_valid_o(b_out_valid), .m_b_ready_i(b_ready              ),
        .s_r_i         (r), .s_r_valid_i(r_valid), .s_r_ready_o(r_in_ready                   ),
        .m_r_o         (r_out), .m_r_valid_o(r_out_valid), .m_r_ready_i(r_ready              )
    );

    // Distinct source node/port keys deliberately collide at device ID zero.
    function automatic nsu_context_t make_context(input int index, input int id = 0);
        nsu_context_t ctx;
        logic [ni_flit_pkg::SRC_ID_WIDTH+ni_flit_pkg::SRC_PORT_ID_WIDTH+ni_params_pkg::NOC_ID_WIDTH-1:0] key;
        int folded;
        ctx             = '0;
        ctx.src_id      = ni_flit_pkg::SRC_ID_WIDTH'(index+1);
        ctx.src_port_id = ni_flit_pkg::SRC_PORT_ID_WIDTH'(index);
        key             = {ctx.src_id, ctx.src_port_id, {ni_params_pkg::NOC_ID_WIDTH{1'b0}}};
        folded          = 0;
        for (int shift = 0; shift < $bits(key); shift += OUTPUT_ID_WIDTH)
            folded ^= int'(key >> shift) & ((1 << OUTPUT_ID_WIDTH)-1);
        ctx.noc_id       = ni_params_pkg::NOC_ID_WIDTH'(folded ^ id);
        ctx.local_addr   = ni_params_pkg::AXI_ADDR_WIDTH'(index*64);
        ctx.ordering_tag = ni_flit_pkg::ORDERING_TAG_WIDTH'(index);
        ctx.ordering_req = index % 2;
        ctx.is_data      = index % 2;
        ctx.burst        = 1;
        ctx.size         = 3;
        return ctx;
    endfunction
    task automatic tick;
        @(posedge clk); #1;
        @(negedge clk);
    endtask
    task automatic push_aw(input nsu_context_t ctx);
        aw.response = ctx;
        aw_valid    = 1;
        #1;
        if (!aw_ready || awid != 0) $fatal(1, "AW admission/hash");
        tick(); aw_valid = 0;
        #1;
        if (!w_valid || w_context.response !== ctx) $fatal(1, "W context order");
        w_accept = 1; tick(); w_accept = 0;
    endtask
    task automatic push_ar(input nsu_context_t ctx, input int id = 0);
        ar.response = ctx;
        ar_valid    = 1;
        #1;
        if (!ar_ready || arid != OUTPUT_ID_WIDTH'(id)) $fatal(1, "AR admission/hash");
        tick(); ar_valid = 0;
    endtask
    task automatic check_b(input nsu_context_t ctx);
        #1;
        if (!b_in_ready || !b_out_valid || b_out.response !== ctx || b_out.axi.bid !== ctx.noc_id)
            $fatal(1, "B source/ID/context restoration");
        b_count++;
    endtask
    task automatic check_r(input nsu_context_t ctx, input int beat);
        #1;
        if (!r_in_ready || !r_out_valid || r_out.response !== ctx || r_out.axi.rid !== ctx.noc_id ||
                r_out.beat_index != beat || r_out.axi.rdata !== r.rdata)
            $fatal(1, "R source/ID/context/beat restoration");
        r_count++;
    endtask
    task automatic read_beat(input nsu_context_t ctx, input int id, input int beat);
        r.rid   = OUTPUT_ID_WIDTH'(id);
        r.rlast = beat == ctx.len;
        r.rdata = ni_params_pkg::AXI_DATA_WIDTH'(ctx.local_addr + beat);
        r_valid = 1;
        check_r(ctx, beat); tick(); r_valid = 0;
    endtask
    initial begin
        if (OUTPUT_ID_WIDTH > ni_params_pkg::NOC_ID_WIDTH) $fatal(1, "Test requires narrowing/equal ID");
        for (int i = 0; i < DEPTH+2; i++) contexts[i] = make_context(i);
        repeat (3) tick(); rst_n = 1; tick();
        for (int i = 0; i < DEPTH; i++) push_aw(contexts[i]);
        aw.response = contexts[DEPTH]; aw_valid = 1;
        ar.response = contexts[0]; ar.response.len = 1; ar_valid = 1;
        #1;
        if (aw_ready || !ar_ready) $fatal(1, "AW full must not block AR");
        tick(); ar_valid = 0;
        b_valid = 1; b.bid = 0; b_ready = 0;
        repeat (2) begin
            #1;
            if (b_in_ready || aw_ready || !b_out_valid || b_out.response !== contexts[0])
                $fatal(1, "B stalled context changed or freed");
            tick();
        end
        b_ready = 1;
        check_b(contexts[0]);
        if (!aw_ready) $fatal(1, "AW full pop/push has a bubble");
        tick(); aw_valid = 0;
        w_accept = 1;
        for (int i = 1; i <= DEPTH; i++) begin
            check_b(contexts[i]); tick(); w_accept = 0;
        end
        b_valid = 0;
        for (int i = 0; i < DEPTH+2; i++) contexts[i].len = 1;
        for (int i = 1; i < DEPTH; i++) push_ar(contexts[i]);
        ar.response = contexts[DEPTH]; ar_valid = 1;
        r.rid       = 0; r.rlast = 0; r_valid = 1;
        check_r(contexts[0], 0);
        if (ar_ready) $fatal(1, "AR context freed before RLAST");
        tick(); r.rlast = 1;
        check_r(contexts[0], 1);
        if (!ar_ready) $fatal(1, "AR full pop/push has a bubble");
        tick(); ar_valid = 0; r_valid = 0;
        for (int i = 1; i <= DEPTH; i++) begin
            read_beat(contexts[i], 0, 0); read_beat(contexts[i], 0, 1);
        end
        if (DEPTH >= 2) begin
            contexts[0] = make_context(7, 0); contexts[0].len = 1;
            contexts[1] = make_context(8, 1); contexts[1].len = 1;
            push_ar(contexts[0], 0); push_ar(contexts[1], 1);
            read_beat(contexts[0], 0, 0); read_beat(contexts[1], 1, 0);
            r_ready = 0; r_valid = 1; r.rlast = 1;
            r.rdata = ni_params_pkg::AXI_DATA_WIDTH'(contexts[1].local_addr + 1);
            repeat (3) begin
                #1;
                if (r_in_ready || !r_out_valid || r_out.beat_index != 1 || r_out.response !== contexts[1])
                    $fatal(1, "R stalled context changed");
                tick();
            end
            r_ready = 1; check_r(contexts[1], 1); tick(); r_valid = 0;
            read_beat(contexts[0], 0, 1);
        end
        contexts[0] = make_context(12);
        aw.response = contexts[0]; aw_valid = 1;
        #1;
        if (!aw_ready) $fatal(1, "Reset preparation AW admission");
        tick(); aw_valid = 0;
        push_ar(contexts[0]);
        if (!w_valid) $fatal(1, "Reset did not cover occupied W context");
        rst_n = 0; tick();
        if (w_valid || b_out_valid || r_out_valid) $fatal(1, "Reset validity");
        rst_n = 1; tick();
        contexts[0] = make_context(13);
        push_aw(contexts[0]); b_valid = 1; check_b(contexts[0]); tick(); b_valid = 0;
        push_ar(contexts[0]); read_beat(contexts[0], 0, 0);
        $display("NSU_CONTEXT_PASS depth=%0d output_id_width=%0d b=%0d r_beats=%0d", DEPTH, OUTPUT_ID_WIDTH, b_count, r_count);
        $finish;
    end
    initial begin #20000; $fatal(1, "NSU context timeout"); end
endmodule
