class ni_pattern_sequence extends tvip_axi_master_sequence_base;
    tvip_axi_master_item writes[$], reads[$];

    typedef tvip_axi_master_item completion_queue[$];
    completion_queue dependencies[int];
    tvip_axi_address forward_address[int];
    tvip_axi_memory forwarding_memory;
    int row_copies;
    static uvm_barrier row_start = new("row_start", 4);
    bit concurrent_rw;
    int first_response_delay = 0;
    int read_outstanding_limit = 0;
    int write_outstanding_limit = 0;
    real injection_ratio = 0;
    bit zero_load;
    static semaphore zero_load_lock = new(1);

    function new(string name = "ni_pattern_sequence");
        super.new(name);
    endfunction

    function void read_file(string path, bit is_read);
        int fd, count, index = 0;
        int unsigned id, len, size, burst, lock, cache, prot, qos, region, atop;
        tvip_axi_address address;
        tvip_axi_awuser user, wuser;
        tvip_axi_master_item item;
        fd = $fopen(path, "r");
        if (!fd) `uvm_fatal("PATTERN", {"Cannot open ", path})
        while (1) begin
            count = $fscanf(fd, "%d", id);
            if (count == -1) break;
            if (count != 1) `uvm_fatal("PATTERN", $sformatf("%s: invalid ID at transaction %0d", path, index))
            count = $fscanf(fd, " 0x%h %d %d %d %d %d %d %d %d", address, len, size,
                            burst, lock, cache, prot, qos, region);
            if (count != 9) `uvm_fatal("PATTERN", $sformatf("%s: incomplete address at transaction %0d", path, index))
            atop = 0;
            if (!is_read && $fscanf(fd, "%d", atop) != 1)
                `uvm_fatal("PATTERN", {path, ": missing AWATOP"})
            if ($fscanf(fd, "%d", user) != 1)
                `uvm_fatal("PATTERN", {path, ": missing AxUSER"})
            if (len > 255 || size > 7 || burst > 2 || lock > 1 || cache > 15 ||
                    prot > 7 || qos > 15 || region > 15 || atop != 0 || (is_read && user != 0))
                `uvm_fatal("PATTERN", $sformatf("%s: unsupported field at transaction %0d", path, index))
            item = tvip_axi_master_item::type_id::create($sformatf("request%0d", index));
            item.access_type = is_read ? TVIP_AXI_READ_ACCESS : TVIP_AXI_WRITE_ACCESS;
            item.id = id;
            item.address = address;
            item.burst_length = len + 1;
            item.burst_size = 1 << size;
            item.burst_type = tvip_axi_burst_type'(burst);
            item.lock = lock;
            item.put_cache(cache);
            item.protection = tvip_axi_protection'(prot);
            item.qos = qos;
            item.region = region;
            item.awuser = user;
            item.need_response = 0;
            if (is_read) reads.push_back(item);
            else begin
                item.data = new[len+1];
                item.strobe = new[len+1];
                foreach (item.data[beat]) begin
                    if ($fscanf(fd, " 0x%h 0x%h %d", item.data[beat], item.strobe[beat], wuser) != 3 || wuser != 0)
                        `uvm_fatal("PATTERN", $sformatf("%s: invalid W beat %0d at transaction %0d", path, beat, index))
                end
                writes.push_back(item);
            end
            index++;
        end
        $fclose(fd);
    endfunction

    function void load_files(string directory, string write_name = "write.txt", string read_name = "read.txt");
        writes.delete();
        reads.delete();
        if (write_name != "") read_file({directory, "/", write_name}, 0);
        if (read_name != "") read_file({directory, "/", read_name}, 1);
    endfunction

    function int read_beats();
        int beats = 0;
        foreach (reads[i]) beats += reads[i].burst_length;
        return beats;
    endfunction

    task send_requests(ref tvip_axi_master_item items[$]);
        uvm_event phase_start;
        int outstanding_limit;
        outstanding_limit = 0;
        if (items.size() != 0) begin
            outstanding_limit = items[0].is_read() ? read_outstanding_limit : write_outstanding_limit;
            phase_start = uvm_event_pool::get_global(items[0].is_read() ? "ni_read_start" : "ni_write_start");
            phase_start.trigger();
        end
        foreach (items[i]) begin

            if (!items[i].is_read()) begin
                if (dependencies.exists(i)) begin
                    for (int d = 0; d < dependencies[i].size(); d++)
                        dependencies[i][d].wait_for_done();
                end
                if (forward_address.exists(i)) begin
                    if (forwarding_memory == null || items[i].burst_size != 64)
                        `uvm_fatal("FORWARD", "Missing full-width forwarding memory")
                    foreach (items[i].data[beat]) begin
                        tvip_axi_data data;
                        for (int b = 0; b < 64; b++) begin
                            if (!forwarding_memory.exists(1, forward_address[i]+64*beat+b, 0))
                                `uvm_fatal("FORWARD", "Forwarding data is not yet available")
                        end
                        data = forwarding_memory.get(64, forward_address[i], beat);
                        if (data !== items[i].data[beat])
                            `uvm_fatal("FORWARD", "Received payload differs from forwarding input")
                        items[i].data[beat] = data;
                    end
                end
            end
            if (outstanding_limit > 0 && i >= outstanding_limit)
                items[i-outstanding_limit].wait_for_done();
            items[i].set_context(configuration, status);
            if (!items[i].randomize(start_delay, write_data_delay, response_ready_delay))
                `uvm_fatal("PATTERN", "Invalid pattern or delay configuration")
            if (injection_ratio > 0) begin
                // The reference driver retries on each cycle after a failed random draw.
                items[i].start_delay = 0;
                while ($urandom_range(0, 100) >= injection_ratio * 100)
                    items[i].start_delay++;
            end
            if (i == 0 && first_response_delay != 0)
                items[i].response_ready_delay[0] = first_response_delay;
            if (zero_load) zero_load_lock.get(1);
            start_item(items[i]);
            finish_item(items[i]);
            if (zero_load) begin
                items[i].wait_for_done();
                zero_load_lock.put(1);
            end
            if (!items[i].is_read() && items[i].awuser[9:8] == 2'b01)
                items[i].wait_for_done();
        end
        foreach (items[i]) items[i].wait_for_done();
    endtask

    task body();
        if (row_copies > 0) begin
            if (writes.size() != reads.size()*row_copies)
                `uvm_fatal("ROW_FEED", "Read/write batch count mismatch")
            foreach (reads[k]) begin
                tvip_axi_master_item fetch[$], copies[$];
                row_start.wait_for();
                $display("ROW_PREFETCH batch=%0d source=%s time_ps=%0t", k, get_name(), $time);
                fetch.push_back(reads[k]);
                send_requests(fetch);
                for (int x = 0; x < row_copies; x++) begin
                    tvip_axi_master_item w = writes[k*row_copies+x];
                    if (w.data.size() != reads[k].data.size())
                        `uvm_fatal("ROW_FEED", "Read response length mismatch")
                    foreach (w.data[b]) begin
                        if (reads[k].response[b] != TVIP_AXI_OKAY || reads[k].data[b] !== w.data[b])
                            `uvm_fatal("ROW_FEED", "Read response data or status mismatch")
                    end
                    w.data = reads[k].data;
                    copies.push_back(w);
                end
                send_requests(copies);
            end
        end else if (concurrent_rw) begin
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
