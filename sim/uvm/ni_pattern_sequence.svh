class ni_pattern_sequence extends tvip_axi_master_sequence_base;
    tvip_axi_master_item writes[$], reads[$];
    bit concurrent_rw;
    int first_response_delay = 0;

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
