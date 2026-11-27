import json
import pytest
from gen_standalone_patterns import generate, REPO, load_cases
from axi_file_parser import _parse_read, _parse_write


@pytest.mark.parametrize("width", [1, 3, 8])
@pytest.mark.parametrize("mode", ["control", "data", "rand"])
def test_cases_roundtrip_and_legal_bursts(tmp_path, width, mode):
    names = generate(tmp_path, REPO / "dv/config/topology/mesh_2x2.yml", width, mode=mode)
    assert len(names) == 18
    for name in names:
        writes = _parse_write(tmp_path / name / "write.txt")
        reads = _parse_read(tmp_path / name / "read.txt")
        assert writes or reads
        if name.startswith(("ctrl_write", "data_write")):
            assert not reads
        if name.startswith(("ctrl_read", "data_read")):
            assert not writes
        for txn in writes + reads:
            assert 0 <= txn["id"] < (1 << width)
            assert txn["size"] <= (3 if txn["addr"] % (1 << 32) >= 0x2000000 else 6)
            assert txn["addr"] % (1 << txn["size"]) == 0
            if txn["burst"] == 2:
                assert txn["len"] + 1 in (2, 4, 8, 16)
        for txn in writes:
            step = 1 << txn["size"]
            span = step * (txn["len"] + 1)
            assert len(txn["beats"]) == txn["len"] + 1
            for beat, line in enumerate(txn["beats"]):
                addr = txn["addr"] if txn["burst"] == 0 else txn["addr"] + beat*step
                if txn["burst"] == 2:
                    addr = (txn["addr"] & ~(span-1)) | (addr & (span-1))
                _, strobe, _ = line.split()
                legal_strobe = ((1 << step)-1) << (addr % 64)
                assert int(strobe, 16) & ~legal_strobe == 0
    basic = _parse_write(tmp_path / "ctrl_write_single/write.txt")
    assert len(basic) == 1 and basic[0]["len"] == 0
    multi = _parse_write(tmp_path / "multi_id_outstanding/write.txt")
    assert len({t["id"] for t in multi}) == min(8, 1 << width)
    cross = _parse_read(tmp_path / "single_id_reorder/read.txt")
    assert len({t["id"] for t in cross}) == 1
    assert len({t["addr"] >> 32 for t in cross}) == 2
    if width == 8:
        full = _parse_write(tmp_path / "outstanding_full_recover/write.txt")
        assert len({t["id"] for t in full}) > 8
    before = {f.relative_to(tmp_path): f.read_bytes() for f in tmp_path.rglob("*") if f.is_file()}
    generate(tmp_path, REPO / "dv/config/topology/mesh_2x2.yml", width, mode=mode)
    assert before == {f.relative_to(tmp_path): f.read_bytes() for f in tmp_path.rglob("*") if f.is_file()}


@pytest.mark.parametrize("mode", ["control", "data", "rand"])
def test_shared_modes_preserve_scenario_and_seed(tmp_path, mode):
    generate(tmp_path, REPO / "dv/config/topology/mesh_2x2.yml", mode=mode, seed=17)
    for name in ("single_id_outstanding", "single_id_reorder"):
        txns = _parse_write(tmp_path / name / "write.txt")
        assert len({t["id"] for t in txns}) == 1
        classes = {"control" if t["addr"] % (1 << 32) >= 0x2000000 else "data" for t in txns}
        assert classes == ({"control", "data"} if mode == "rand" else {mode})
    before = (tmp_path / "request_rand/write.txt").read_bytes()
    generate(tmp_path, REPO / "dv/config/topology/mesh_2x2.yml", mode=mode, seed=18)
    assert (tmp_path / "request_rand/write.txt").read_bytes() != before


@pytest.mark.parametrize("name", ["ctrl_write_burst", "data_write_burst"])
def test_burst_patterns_cover_full_width_lengths(tmp_path, name):
    generate(tmp_path, REPO / "dv/config/topology/mesh_2x2.yml")
    txns = _parse_write(tmp_path / name / "write.txt")
    data = name.startswith("data")
    assert [t["len"] + 1 for t in txns] == ([2,3,4,7,8,15,16,31,32,63,64] if data else
                                                  [2,3,4,7,8,15,16,31,32,63,64,127,128,255,256])
    assert {t["size"] for t in txns} == {6 if data else 3}
    assert {t["burst"] for t in txns} == {1}
    import yaml
    from address_map import pack_config
    _, entries = pack_config(yaml.safe_load((REPO / "dv/config/topology/mesh_2x2.yml").read_text()))
    route = next(e for e in entries if e["space"] == ("memory" if data else "config"))
    assert any(t["addr"] == route["base"] for t in txns)
    assert any(t["addr"] + ((t["len"]+1) << t["size"]) == route["base"] + route["size"] for t in txns)
    assert any((t["addr"] + ((t["len"]+1) << t["size"])) % 4096 == 0 for t in txns)
    for t in txns:
        end = t["addr"] + ((t["len"] + 1) << t["size"]) - 1
        assert t["addr"] >> 12 == end >> 12


@pytest.mark.parametrize("width", [1, 3, 8])
def test_control_capacity_preserves_existing_recipe(tmp_path, width):
    from gen_nmu_standalone_patterns import generate as generate_legacy
    topology = REPO / "dv/config/topology/mesh_2x2.yml"
    generate_legacy(tmp_path / "legacy", topology, width)
    generate(tmp_path / "new", topology, width, case_name="outstanding_full_recover")
    for name in ("write.txt", "read.txt"):
        assert (tmp_path / "legacy" / name).read_bytes() == (tmp_path / "new/outstanding_full_recover" / name).read_bytes()


def test_in_order_performance_inputs(tmp_path):
    catalog = "in_order_perf"
    names = generate(tmp_path, REPO / "dv/config/topology/mesh_2x2.yml", catalog=catalog)
    assert len(names) == 8
    for name in names:
        writes = _parse_write(tmp_path / name / "write.txt")
        reads = _parse_read(tmp_path / name / "read.txt")
        assert bool(writes) != bool(reads)
        txns = writes + reads
        assert len(txns) == 128
        assert len({t["id"] for t in txns}) == 1
        assert len({t["addr"] >> 32 for t in txns}) == 1
        beats = 16 if name.endswith("burst") else 1
        size = 6 if "data" in name else 3
        assert all(t["len"] == beats-1 and t["size"] == size and t["burst"] == 1 for t in txns)
        for t in txns:
            assert t["addr"] >> 12 == (t["addr"] + beats*(1 << size)-1) >> 12
        schedule = (tmp_path / name / "schedule.txt").read_text()
        for key in ("response_order", "response_delay", "startup_delay", "stall_enable", "reset_warmup"):
            assert "+" + key + "=0\n" in schedule


def test_out_of_order_performance_capacity(tmp_path):
    catalog = "out_of_order_perf"
    names = generate(tmp_path, REPO / "dv/config/topology/mesh_2x2.yml", catalog=catalog)
    assert len(names) == 12
    for name in names:
        writes = _parse_write(tmp_path / name / "write.txt")
        reads = _parse_read(tmp_path / name / "read.txt")
        assert bool(writes) != bool(reads)
        txns = writes + reads
        assert len(txns) == (16 if name.endswith("mixed_id") else 8)
        assert all(t["len"] == 7 and t["burst"] == 1 for t in txns)
        ids = {t["id"] for t in txns}
        assert len(ids) == (1 if name.endswith("same_id") else 8)
        # At most all but the first request per ID need ROB entries.
        assert (len(txns) - len(ids))*8 < 128
        assert max(sum(t["id"] == i for t in txns) for i in ids) < 32
        if name.endswith("mixed_id"):
            assert any(txns[i]["addr"] >> 32 != txns[i+8]["addr"] >> 32 for i in range(8))
        schedule = (tmp_path / name / "schedule.txt").read_text()
        for key in ("response_delay", "stall_enable", "reset_warmup"):
            assert "+" + key + "=0\n" in schedule


def test_mixed_performance_inputs(tmp_path):
    catalog = "mixed_perf"
    names = generate(tmp_path, REPO / "dv/config/topology/mesh_2x2.yml", catalog=catalog)
    assert len(names) == 4
    for name in names:
        writes = _parse_write(tmp_path / name / "write.txt")
        reads = _parse_read(tmp_path / name / "read.txt")
        assert len(writes) == len(reads) == 128
        txns = writes + reads
        assert len({t["id"] for t in txns}) == 1
        assert len({t["addr"] >> 32 for t in txns}) == 1
        beats = 16 if name.endswith("burst") else 1
        size = 6 if "data" in name else 3
        assert all(t["len"] == beats-1 and t["size"] == size and t["burst"] == 1 for t in txns)
        schedule = (tmp_path / name / "schedule.txt").read_text()
        for key in ("response_order", "response_delay", "startup_delay", "stall_enable", "reset_warmup"):
            assert "+" + key + "=0\n" in schedule


@pytest.mark.parametrize("mode", ["control", "data", "rand"])
def test_cosim_memory_dependencies(tmp_path, mode):
    topology = REPO / "dv/config/topology.yml"
    names = generate(tmp_path, topology, 3, mode=mode, profile="cosim")
    assert "request_rand" in names
    assert "single_id_reorder" in names
    assert "multi_id_out_of_order" in names
    for name in names:
        writes = _parse_write(tmp_path / name / "write.txt")
        reads = _parse_read(tmp_path / name / "read.txt")
        if name.endswith("write_burst"):
            assert writes and not reads
            continue
        if name.endswith("read_burst"):
            assert reads and not writes
            words = (tmp_path / name / "preload.mem").read_text().split()
            memory = {}
            for word in words:
                if word.startswith("@"):
                    addr = int(word[1:], 16)
                else:
                    memory[addr] = int(word, 16)
                    addr += 1
            for t in reads:
                for addr in range(t["addr"], t["addr"] + ((t["len"]+1) << t["size"])):
                    assert memory[addr] == addr & 255
            continue
        if name.endswith("_rand"):
            continue  # Concurrent phase dependencies are checked below.
        if name.endswith("write_single"):
            assert len(writes) == 1 and not reads
            assert writes[0]["len"] == 0
            continue
        if name.endswith("read_single"):
            assert len(reads) == 1 and not writes
            assert reads[0]["len"] == 0
            words = (tmp_path / name / "preload.mem").read_text().split()
            assert int(words[0][1:], 16) == (reads[0]["addr"] & ~63)
            assert len(words) - 1 == 64
            assert [int(x, 16) for x in words[1:]] == [
                ((reads[0]["addr"] & ~63) + b) & 255 for b in range(64)]
            assert (tmp_path / name / "preload.mem").is_file()
            continue
        assert len(writes) == len(reads) > 0
        initialized = set()
        for write, read in zip(writes, reads):
            assert all(write[k] == read[k] for k in ("id", "addr", "len", "size", "burst"))
            assert write["burst"] == 1
            step = 1 << write["size"]
            for beat, line in enumerate(write["beats"]):
                address = write["addr"] + beat * step
                assert address >> 12 == write["addr"] >> 12
                byte_addresses = set(range(address, address + step))
                assert not (initialized & byte_addresses)
                initialized.update(byte_addresses)
                strobe = int(line.split()[1], 16)
                assert strobe == ((1 << step) - 1) << (address % 64)
            assert write["addr"] % (1 << 32) + (write["len"] + 1) * step <= (
                0x2001000 if write["addr"] % (1 << 32) >= 0x2000000 else 0x2000000)
        schedule = (tmp_path / name / "schedule.txt").read_text()
        assert "+response_delay=" not in schedule
        assert "+backpressure" not in schedule


def test_cosim_additional_memory_phases(tmp_path):
    names = generate(tmp_path, REPO / "dv/config/topology.yml", 3,
                     profile="cosim", catalog="cosim")
    assert len(names) == 8
    for name in names:
        root = tmp_path / name
        writes = _parse_write(root / "write.txt")
        reads = _parse_read(root / "read.txt")
        init = _parse_write(root / "init_write.txt") if (root / "init_write.txt").exists() else []
        verify = _parse_read(root / "verify_read.txt") if (root / "verify_read.txt").exists() else []
        memory = {}
        def apply(txns):
            for txn in txns:
                step = 1 << txn["size"]
                assert txn["burst"] == 1
                assert txn["addr"] >> 12 == (txn["addr"] + step*(txn["len"]+1)-1) >> 12
                for beat, line in enumerate(txn["beats"]):
                    data, strobe, _ = line.split()
                    address = txn["addr"] + beat*step
                    legal = ((1 << step)-1) << (address % 64)
                    assert int(strobe, 16) & ~legal == 0
                    for byte in range(step):
                        lane = address % 64 + byte
                        if int(strobe, 16) & (1 << lane):
                            memory[address+byte] = (int(data, 16) >> (8*lane)) & 255
        def addresses(txns):
            return {addr for t in txns for addr in range(t["addr"], t["addr"] + (t["len"]+1)*(1 << t["size"]))}
        apply(init)
        initial = memory.copy()
        if name.endswith("read_write"):
            assert addresses(reads) <= memory.keys()
            assert not addresses(reads) & addresses(writes)
            assert addresses(verify) == addresses(writes)
        apply(writes)
        assert addresses(reads + verify) <= memory.keys()
        if name.endswith("partial_write"):
            assert memory.keys() == initial.keys()
            assert any(memory[a] == initial[a] for a in memory)
            assert any(memory[a] != initial[a] for a in memory)
            for old, new in zip(init, writes):
                assert old["addr"] == new["addr"]
                for old_beat, new_beat in zip(old["beats"], new["beats"]):
                    assert int(old_beat.split()[0], 16) ^ int(new_beat.split()[0], 16) == (1 << 512)-1
        if name.endswith("capacity_recover"):
            lines = (root / "write.txt").read_text().splitlines()
            pos = 0
            for txn in writes:
                assert int(lines[pos + 11]) < 256
                pos += 12 + txn["len"] + 1
            assert len(writes) == len(reads) == 320
            assert sum(t["len"]+1 for t in reads) == 320 * (8 if name.startswith("data") else 4)
            assert {t["addr"] >> 32 for t in writes} == {0, 1, 2, 3}
            assert len({t["id"] for t in writes}) == 8
            for ident in {t["id"] for t in writes}:
                stream = [t for t in writes if t["id"] == ident]
                assert len(stream) > 32
                assert len({t["addr"] >> 32 for t in stream}) == 1
            assert len(addresses(writes)) == sum((t["len"]+1)*(1 << t["size"]) for t in writes)
            for t in writes:
                local = t["addr"] % (1 << 32)
                assert local + (t["len"]+1)*(1 << t["size"]) <= (0x2000000 if name.startswith("data") else 0x2001000)


@pytest.mark.parametrize("mode", ["control", "data", "rand"])
def test_cosim_reorder_destinations_and_delay_selection(tmp_path, mode):
    import yaml
    from address_map import pack_config
    topo = REPO / "dv/config/topology.yml"
    _, entries = pack_config(yaml.safe_load(topo.read_text()))
    assert {(e["dst_id"], e["port"]) for e in entries} == {(0x10, 0), (0x21, 0), (0x12, 0), (0x01, 0)}
    names = generate(tmp_path, topo, 3, mode=mode, profile="cosim")
    for name in names:
        schedule = (tmp_path / name / "schedule.txt").read_text()
        if name in ("multi_id_out_of_order", "single_id_reorder"):
            writes = _parse_write(tmp_path / name / "write.txt")
            assert {t["addr"] >> 32 for t in writes} == {0, 1, 2, 3}
            assert len({t["id"] for t in writes}) == (8 if name == "multi_id_out_of_order" else 1)
            signatures = []
            for txn in writes:
                lane = txn["addr"] % 64
                mask = (1 << (8 * (1 << txn["size"]))) - 1
                signatures.append((int(txn["beats"][0].split()[0], 16) >> (lane * 8)) & mask)
            assert len(set(signatures)) == len(signatures)
            assert "+response_delay_port=4" in schedule
            acceptance = json.loads((tmp_path / name / "manifest.json").read_text())["acceptance"]
            assert acceptance["order"] == ("cross_id" if name == "multi_id_out_of_order" else "same_id")
        else:
            assert "+response_delay_port" not in schedule
    assert "reset_recovery" not in names


def test_capacity_profile_inputs(tmp_path):
    catalog = "capacity_perf"
    names = generate(tmp_path, REPO / "dv/config/topology.yml", 8,
                     catalog=catalog, profile="cosim")
    for name in names:
        writes = _parse_write(tmp_path / name / "write.txt")
        reads = _parse_read(tmp_path / name / "read.txt")
        assert len(writes) == len(reads) == 48
        assert len({t["id"] for t in writes}) == (12 if name.endswith("active_ids") else 1)
        assert all(t["id"] >= 128 for t in writes)
        assert len({t["addr"] >> 32 for t in writes}) == 1
        assert all(t["len"] == 0 for t in writes)
        assert [(t["id"], t["addr"]) for t in writes] == [(t["id"], t["addr"]) for t in reads]
        schedule = (tmp_path / name / "schedule.txt").read_text()
        assert "+backpressure" not in schedule and "+response_delay_port" not in schedule
    with pytest.raises(ValueError, match="num_ids"):
        generate(tmp_path / "invalid", REPO / "dv/config/topology.yml", 3,
                 catalog=catalog, profile="cosim")


@pytest.mark.parametrize("seed", [1, 17, 29])
@pytest.mark.parametrize("name", ["ctrl_rand", "data_rand", "request_rand"])
def test_random_concurrent_memory_and_strobes(tmp_path, seed, name):
    generate(tmp_path, REPO / "dv/config/topology.yml", 3, profile="cosim",
             seed=seed, case_name=name)
    root = tmp_path / name
    writes = _parse_write(root / "write.txt")
    reads = _parse_read(root / "read.txt")
    verify = _parse_read(root / "verify_read.txt")
    assert len(writes) == len(reads) == len(verify) == 64
    def addresses(txns):
        return {a for t in txns for a in range(t["addr"], t["addr"] + ((t["len"]+1) << t["size"]))}
    memory = {}
    for word in (root / "preload.mem").read_text().split():
        if word.startswith("@"):
            addr = int(word[1:], 16)
        else:
            memory[addr] = int(word, 16)
            addr += 1
    assert len(addresses(writes)) == sum((t["len"]+1) << t["size"] for t in writes)
    assert not addresses(writes) & addresses(reads)
    assert addresses(writes + reads + verify) <= memory.keys()
    assert addresses(verify) == addresses(writes)
    kinds = set()
    for t in writes:
        step = 1 << t["size"]
        end = t["addr"] + step*(t["len"]+1)-1
        assert t["addr"] >> 12 == end >> 12
        assert end % (1 << 32) < (0x2001000 if name == "ctrl_rand" or t["addr"] % (1 << 32) >= 0x2000000 else 0x2000000)
        for beat, line in enumerate(t["beats"]):
            _, mask, _ = line.split()
            full = ((1 << step)-1) << ((t["addr"] + beat*step) % 64)
            mask = int(mask, 16)
            assert mask & ~full == 0
            kinds.add("zero" if mask == 0 else "full" if mask == full else "partial")
    assert kinds == {"full", "partial", "zero"}
    assert "+concurrent_rw" in (root / "schedule.txt").read_text()


@pytest.mark.parametrize("mode", ["control", "data", "rand"])
def test_stress_patterns_legal_and_distinct(tmp_path, mode):
    import json
    catalog = "stress"
    names = generate(tmp_path, REPO / "dv/config/topology.yml", 3,
                     profile="cosim", mode=mode, catalog=catalog)
    assert names == ["capacity_reuse", "reset_recovery"]
    for name in names:
        writes = _parse_write(tmp_path / name / "write.txt")
        reads = _parse_read(tmp_path / name / "read.txt")
        assert len(writes) == len(reads)
        byte_addresses = set()
        for t in writes:
            span = (t["len"]+1) << t["size"]
            addresses = set(range(t["addr"], t["addr"]+span))
            assert not byte_addresses & addresses
            byte_addresses |= addresses
            assert t["addr"] >> 12 == (t["addr"]+span-1) >> 12
        if name == "reset_recovery":
            assert (tmp_path / name / "preload.mem").exists()
    original = load_cases(catalog)[0]
    for target in ("per_id", "context", "rob"):
        path = tmp_path / (target+".json")
        path.write_text(json.dumps(dict(cases=[dict(original, capacity_target=target)])))
        generate(tmp_path / target, REPO / "dv/config/topology.yml", 3,
                 profile="cosim", mode=mode, catalog=path)
        txns = _parse_write(tmp_path / target / "capacity_reuse/write.txt")
        assert len({t["id"] for t in txns}) == (1 if target == "per_id" else 8)
        assert len({t["addr"] >> 32 for t in txns}) == (1 if target == "per_id" else 4)


@pytest.mark.parametrize("depth", [4, 32])
@pytest.mark.parametrize("mode", ["control", "data", "rand"])
def test_reorder_backpressure_prefill(tmp_path, mode, depth):
    import json
    original = dict(cases=load_cases("base"))
    case = next(c for c in original["cases"] if c["name"] == "single_id_reorder")
    catalog = tmp_path / "catalog.json"
    catalog.write_text(json.dumps(dict(cases=[dict(case, count=64, response_backpressure=True)])))
    generate(tmp_path, REPO / "dv/config/topology.yml", 3, profile="cosim", mode=mode, catalog=catalog,
             hardware={"response_fifo_depth": depth})
    txns = _parse_write(tmp_path / "single_id_reorder/write.txt")
    assert len(txns) == 64 and all(t["len"] == 0 for t in txns)
    assert all(t["addr"] >> 32 == 2 for t in txns[:depth-1])
    assert [t["addr"] >> 32 for t in txns[depth-1:depth+3]] == [1, 2, 3, 0]
    assert len({t["id"] for t in txns}) == 1


@pytest.mark.parametrize("mode,count", [("control", 120), ("data", 127)])
@pytest.mark.parametrize("mask", ["full", "partial", "zero"])
def test_lane_sweep_legal_disjoint_readback(tmp_path, mode, count, mask):
    import json
    catalog = tmp_path / "catalog.json"
    case = dict(name="request_rand", mode=mode, count=count, random=True,
                destinations="random", lane_sweep=mask)
    catalog.write_text(json.dumps(dict(cases=[case])))
    generate(tmp_path / "out", REPO / "dv/config/topology.yml", 3, catalog,
             profile="cosim")
    path = tmp_path / "out/request_rand"
    writes = _parse_write(path / "write.txt")
    reads = _parse_read(path / "read.txt")
    verify = _parse_read(path / "verify_read.txt")
    expected = {(size, lane) for size in range(4 if mode == "control" else 7)
                for lane in range(0, 64, 1 << size)}
    assert {(t["size"], t["addr"] % 64) for t in writes} == expected
    assert len(writes) == len(reads) == len(verify) == count
    used = set()
    for w, rd, vr in zip(writes, reads, verify):
        assert w["len"] == rd["len"] == vr["len"] == 0
        assert w["addr"] == vr["addr"]
        assert rd["addr"] != w["addr"]
        size = 1 << w["size"]
        span = set(range(w["addr"], w["addr"]+size))
        assert not used.intersection(span)
        used.update(span)
        actual = int(w["beats"][0].split()[1], 16)
        full = ((1 << size)-1) << (w["addr"] % 64)
        assert actual == (0 if mask == "zero" else full if mask == "full" or size == 1
                          else full & 0x5555555555555555)
    preload = (path / "preload.mem").read_text().splitlines()
    words = {int(preload[i][1:], 16): preload[i+1].split()
             for i in range(0, len(preload), 2)}
    for txn in writes + reads:
        assert len(words[txn["addr"] & ~63]) == 64


def test_high_source_ids(tmp_path):
    import json
    ids = [0, 1, 2, 3, 128, 129, 254, 255]
    catalog = tmp_path / "catalog.json"
    catalog.write_text(json.dumps(dict(cases=[dict(name="multi_id_outstanding",
        count=16, ids="multiple", num_ids=8, id_values=ids)])))
    generate(tmp_path / "out", REPO / "dv/config/topology.yml", 8, catalog, profile="cosim")
    assert {t["id"] for t in _parse_write(tmp_path / "out/multi_id_outstanding/write.txt")} == set(ids)
    assert {t["id"] for t in _parse_read(tmp_path / "out/multi_id_outstanding/read.txt")} == set(ids)


@pytest.mark.parametrize("mode", ["control", "data"])
def test_each_write_strobe_bit(tmp_path, mode):
    import json
    catalog = tmp_path / "catalog.json"
    catalog.write_text(json.dumps(dict(cases=[dict(name="request_rand", mode=mode,
        count=64, random=True, destinations="random", lane_sweep="onehot")])))
    generate(tmp_path / "out", REPO / "dv/config/topology.yml", 3, catalog, profile="cosim")
    writes = _parse_write(tmp_path / "out/request_rand/write.txt")
    assert [int(t["beats"][0].split()[1], 16) for t in writes] == [1 << i for i in range(64)]
    for t in writes:
        assert t["size"] == (3 if mode == "control" else 6)
        assert t["addr"] % (1 << t["size"]) == 0

@pytest.mark.parametrize("response", [2, 3])
@pytest.mark.parametrize("operation", ["read", "write"])
def test_response_error_maps(tmp_path, response, operation):
    import json
    case = dict(name="data_" + operation + "_burst", operation=operation,
                mode="data", count=1, burst_lengths=[64], response_error=response)
    catalog = tmp_path / "catalog.json"
    catalog.write_text(json.dumps(dict(cases=[case])))
    generate(tmp_path / "patterns", REPO / "dv/config/topology.yml", 3, catalog=catalog, profile="cosim")
    output = tmp_path / "patterns" / case["name"]
    errors = (output / ("rerr.mem" if operation == "read" else "werr.mem")).read_text().splitlines()
    assert len(errors) == 4096
    assert len({line.split()[0] for line in errors}) == 4096
    assert all(int(line.split()[1], 16) == response for line in errors)
    assert "+response_error=" + str(response) in (output / "schedule.txt").read_text()


def test_slave_response_delay_schedule(tmp_path):
    import json
    catalog = tmp_path / "catalog.json"
    catalog.write_text(json.dumps({"cases": [dict(name="single_id_outstanding", count=4,
        response_hold_cycles=4096, response_random_delay=True)]}))
    generate(tmp_path / "out", REPO / "dv/config/topology.yml", 3, catalog, profile="cosim")
    args = (tmp_path / "out/single_id_outstanding/schedule.txt").read_text().split()
    assert "+response_hold_cycles=4096" in args
    assert "+response_random_delay" in args
    assert not any(v.startswith("+hold_cycles=") for v in args)
    assert not any(v.startswith("+stall_cycles=") for v in args)


def test_all_id_destination_pairs(tmp_path):
    import json
    catalog = tmp_path / "catalog.json"
    catalog.write_text(json.dumps({"cases": [dict(name="multi_id_outstanding", count=32,
        ids="multiple", destinations="all")]}))
    generate(tmp_path / "out", REPO / "dv/config/topology.yml", 3, catalog, profile="cosim")
    txns = _parse_write(tmp_path / "out/multi_id_outstanding/write.txt")
    assert {(t["id"], t["addr"] >> 32) for t in txns} == {(i, d) for i in range(8) for d in range(4)}


@pytest.mark.parametrize("mode,max_beats", [("control", 256), ("data", 64)])
def test_complete_burst_length_sweep(tmp_path, mode, max_beats):
    import json
    catalog = tmp_path / "catalog.json"
    catalog.write_text(json.dumps({"cases": [dict(name="sweep", mode=mode, count=max_beats-1,
        burst_lengths=list(range(2, max_beats+1)), operation="write")]}))
    generate(tmp_path / "out", REPO / "dv/config/topology.yml", 3, catalog, profile="cosim")
    txns = _parse_write(tmp_path / "out/sweep/write.txt")
    assert {t["len"]+1 for t in txns} == set(range(2, max_beats+1))
    for t in txns:
        assert t["addr"] >> 12 == (t["addr"] + ((t["len"]+1) << t["size"]) - 1) >> 12


def test_cosim_acceptance_is_not_stimulus(tmp_path):
    generate(tmp_path, REPO / "dv/config/topology.yml", 3, profile="cosim")
    folder = tmp_path / "single_id_reorder"
    args = (folder / "schedule.txt").read_text().split()
    checks = json.loads((folder / "manifest.json").read_text())["acceptance"]
    assert checks["order"] == "same_id" and checks["min_outstanding"] == 2
    assert not any(v.startswith(("+min_", "+check_", "+reorder_test", "+stress_test",
                                "+capacity_test", "+data_case", "+backpressure")) for v in args)
    assert "+response_delay_port=4" in args


def test_regeneration_removes_stale_memory_phases(tmp_path):
    catalog = tmp_path / "catalog.json"
    catalog.write_text(json.dumps({"cases": [dict(name="reuse", count=4, random=True)]}))
    generate(tmp_path / "out", REPO / "dv/config/topology.yml", 3, catalog, profile="cosim")
    folder = tmp_path / "out/reuse"
    assert (folder / "verify_read.txt").is_file()
    catalog.write_text(json.dumps({"cases": [dict(name="reuse", count=1, operation="write")]}))
    generate(tmp_path / "out", REPO / "dv/config/topology.yml", 3, catalog, profile="cosim")
    assert not (folder / "verify_read.txt").exists()
    assert not (folder / "preload.mem").exists()


def test_destination_permutation_preserves_transactions(tmp_path):
    case = dict(name="data_write_burst", mode="data", count=3,
                operation="write", burst_lengths=[2, 8, 64])
    seen = set()
    for shift in range(4):
        catalog = tmp_path / "cases.json"
        catalog.write_text(json.dumps({"cases": [dict(case,
            destination_order=[(i + shift) % 4 for i in range(4)])]}))
        out = tmp_path / str(shift)
        generate(out, REPO / "dv/config/topology.yml", 3, catalog, profile="cosim")
        txns = _parse_write(out / case["name"] / "write.txt")
        assert [t["len"] + 1 for t in txns] == [2, 8, 64]
        assert len({t["addr"] >> 32 for t in txns}) == 1
        seen.update(t["addr"] >> 32 for t in txns)
        for t in txns:
            assert t["addr"] >> 12 == (t["addr"] + ((t["len"] + 1) << t["size"]) - 1) >> 12
    assert seen == {0, 1, 2, 3}


@pytest.mark.parametrize("mode", ["control", "data", "rand"])
def test_multicast_destinations_and_address_masks(tmp_path, mode):
    names = generate(tmp_path, REPO / "dv/config/topology/mesh_4x4.yml", id_width=3,
                     catalog="router",
                     mode=mode, profile="cosim", seed=17)
    assert names == ["multicast_single", "multicast_burst", "multicast_rand"]
    for name in names:
        transactions = _parse_write(tmp_path / name / "write.txt")
        assert transactions and not _parse_read(tmp_path / name / "read.txt")
        populations = set()
        for txn in transactions:
            assert (txn["awuser"] >> 8) & 3 == 1
            mask = txn["awuser"] >> 10
            assert mask and mask & ~((15) << 32) == 0
            populations.add(1 << mask.bit_count())
            assert (txn["addr"] >> 12) == ((txn["addr"] + ((txn["len"]+1) << txn["size"]) - 1) >> 12)
        assert populations == {4, 16}


def test_mesh_destination_rotation_preserves_reorder_stimulus(tmp_path):
    case = dict(next(c for c in load_cases() if c["name"] == "single_id_reorder"))
    topology = REPO / "dv/config/topology/mesh_4x4.yml"
    catalog = tmp_path / "cases.json"
    catalog.write_text(json.dumps(dict(cases=[case])))
    generate(tmp_path / "base", topology, 3, catalog, "data", profile="cosim")
    case["destination_order"] = [(i + 13) % 16 for i in range(16)]
    catalog.write_text(json.dumps(dict(cases=[case])))
    generate(tmp_path / "rotated", topology, 3, catalog, "data", profile="cosim")
    before = _parse_write(tmp_path / "base/single_id_reorder/write.txt")
    after = _parse_write(tmp_path / "rotated/single_id_reorder/write.txt")
    for a, b in zip(before, after):
        assert b["addr"] >> 32 == ((a["addr"] >> 32) + 13) % 16
        a["addr"] %= 1 << 32
        b["addr"] %= 1 << 32
        assert a == b
    assert "+response_delay_port=1" in (tmp_path / "rotated/single_id_reorder/schedule.txt").read_text()


def test_mesh_context_pressure_keeps_four_targets(tmp_path):
    case = dict(next(c for c in load_cases("stress") if c["name"] == "capacity_reuse"))
    case.update(capacity_target="context", destination_order=[(i+12)%16 for i in range(16)])
    catalog = tmp_path / "cases.json"
    catalog.write_text(json.dumps(dict(cases=[case])))
    generate(tmp_path / "out", REPO / "dv/config/topology/mesh_4x4.yml", 3, catalog, "data", profile="cosim")
    transactions = _parse_write(tmp_path / "out/capacity_reuse/write.txt")
    assert {t["addr"] >> 32 for t in transactions} == {12,13,14,15}
    assert all(sum(t["addr"] >> 32 == d for t in transactions) > 32 for d in range(12,16))
    assert "+context_target_mask=f000" in (tmp_path / "out/capacity_reuse/schedule.txt").read_text()


@pytest.mark.parametrize("mode", ["control", "data", "rand"])
def test_mesh_sources_reuse_ids_without_address_alias(tmp_path, mode):
    generate(tmp_path, REPO / "dv/config/topology/mesh_4x4.yml", 3,
             catalog="mesh", profile="cosim", mode=mode)
    for name in ("hotspot", "uniform_random"):
        occupied = set()
        ids = []
        payloads = []
        for source in range(16):
            directory = tmp_path / name
            if source: directory /= "source" + str(source)
            writes = _parse_write(directory / "write.txt")
            reads = _parse_read(directory / "read.txt")
            assert len(writes) == len(reads) == 4
            ids.append({t["id"] for t in writes})
            payloads.append(writes[0]["beats"][0].split()[0])
            for txn in writes:
                span = (txn["len"]+1) << txn["size"]
                addresses = set(range(txn["addr"], txn["addr"]+span))
                assert not occupied & addresses
                occupied |= addresses
                assert txn["addr"] >> 12 == (txn["addr"]+span-1) >> 12
                if name == "hotspot": assert txn["addr"] >> 32 == 5
        assert all(value == ids[0] for value in ids)
        assert len(set(payloads)) == 16
        assert "+source_mask=ffff" in (tmp_path / name / "schedule.txt").read_text()


def test_mesh_routing_covers_every_source_destination(tmp_path):
    generate(tmp_path, REPO / "dv/config/topology/mesh_4x4.yml", 3,
             catalog="mesh", profile="cosim", mode="control", case_name="routing")
    for source in range(16):
        directory = tmp_path / "routing"
        if source: directory /= "source" + str(source)
        for filename, parser in (("write.txt", _parse_write), ("read.txt", _parse_read)):
            transactions = parser(directory / filename)
            assert {t["addr"] >> 32 for t in transactions} == set(range(16))
            assert all(t["addr"] & 0xfff == source * 256 for t in transactions)


def test_multicast_single_root_uses_full_address_window(tmp_path):
    case = next(c for c in load_cases("router") if c["name"] == "multicast_burst")
    for root in (0, 5, 15):
        target = tmp_path / str(root)
        generate(target, REPO / "dv/config/topology/mesh_4x4.yml", 3,
                 catalog=[dict(case, sources=[root], router_dat_stall_cycles=32)],
                 profile="cosim", mode="control")
        directory = target / case["name"]
        writes = _parse_write(directory / "write.txt")
        assert len(writes) == 4
        assert max(t["len"] for t in writes) == 63
        schedule = (directory / "schedule.txt").read_text()
        assert "+source_mask=" + format(1 << root, "x") in schedule
        assert "+router_dat_stall_cycles=32" in schedule
        assert not list(directory.glob("source*"))
        for txn in writes:
            end = txn["addr"] + ((txn["len"] + 1) << txn["size"]) - 1
            assert txn["addr"] >> 12 == end >> 12


def test_router_stall_interval_rejects_invalid_value(tmp_path):
    import pytest
    for value in (0, -1, True, 1.5):
        with pytest.raises(ValueError, match="router_dat_stall_cycles"):
            generate(tmp_path, REPO / "dv/config/topology/mesh_4x4.yml", 3,
                     catalog=[dict(name="stall", count=1, router_dat_stall_cycles=value)],
                     profile="cosim")


def test_collectb_mixed_response_preserves_source_error_expectation(tmp_path):
    case = next(c for c in load_cases("router") if c["name"] == "multicast_single")
    generate(tmp_path, REPO / "dv/config/topology/mesh_4x4.yml", 3,
             catalog=[dict(case, sources=[15], count=1, multicast_masks=[51],
                           response_error=2, response_error_mask=1)], profile="cosim")
    target = tmp_path / case["name"]
    schedule = (target / "schedule.txt").read_text()
    assert "+response_error=2" in schedule
    assert "+response_error_mask=1" in schedule
    assert (target / "werr.mem").read_text().splitlines()[0].endswith(" 2")
    import pytest
    with pytest.raises(ValueError, match="full-mesh SLVERR"):
        generate(tmp_path / "invalid", REPO / "dv/config/topology/mesh_4x4.yml", 3,
                 catalog=[dict(case, multicast_masks=[3], response_error=2,
                               response_error_mask=1)], profile="cosim")


@pytest.mark.parametrize("parity", [0, 1])
def test_concurrent_mesh_source_sets_have_disjoint_memory(tmp_path, parity):
    case = next(c for c in load_cases("mesh") if c["name"] == "routing")
    sources = list(range(parity, 16, 2))
    generate(tmp_path, REPO / "dv/config/topology/mesh_4x4.yml", 3,
             catalog=[dict(case, sources=sources, burst_beats=8, concurrent_rw=True,
                           router_dat_stall_cycles=32)], profile="cosim", mode="data")
    occupied = set()
    for source in sources:
        directory = tmp_path / case["name"]
        if source != sources[0]: directory /= "source" + str(source)
        addresses = set()
        for filename, parse in (("write.txt", _parse_write), ("read.txt", _parse_read)):
            for txn in parse(directory / filename):
                addresses.update(range(txn["addr"], txn["addr"] + ((txn["len"]+1) << txn["size"])))
        assert not occupied & addresses
        occupied |= addresses


def test_control_hotspot_full_burst_fits_source_stripes(tmp_path):
    case = next(c for c in load_cases("mesh") if c["name"] == "hotspot")
    generate(tmp_path, REPO / "dv/config/topology/mesh_4x4.yml", 3,
             catalog=[dict(case, count=1, operation="write", burst_beats=32)],
             profile="cosim", mode="control")
    occupied = set()
    for source in range(16):
        directory = tmp_path / case["name"]
        if source: directory /= "source" + str(source)
        writes = _parse_write(directory / "write.txt")
        assert len(writes) == 1
        txn = writes[0]
        assert txn["len"] == 31
        end = txn["addr"] + 256
        assert txn["addr"] >> 12 == (end-1) >> 12
        addresses = set(range(txn["addr"], end))
        assert not addresses & occupied
        occupied |= addresses


@pytest.mark.parametrize("root", [0, 5, 15])
def test_one_multicast_root_competes_with_private_unicast_sources(tmp_path, root):
    case = next(c for c in load_cases("router") if c["name"] == "multicast_single")
    generate(tmp_path, REPO / "dv/config/topology/mesh_4x4.yml", 3,
             catalog=[dict(case, sources=list(range(16)), multicast_source=root, count=1,
                           burst_beats=32, multicast_masks=[51], destinations="random")],
             profile="cosim", mode="control")
    occupied = set()
    multicast_sources = []
    for source in range(16):
        directory = tmp_path / case["name"]
        if source: directory /= "source" + str(source)
        txn, = _parse_write(directory / "write.txt")
        if (txn["awuser"] >> 8) & 3 == 1:
            multicast_sources.append(source)
            targets = range(16)
        else:
            targets = [txn["addr"] >> 32]
        offset = txn["addr"] & 0xffffffff
        addresses = {(destination << 32) + byte for destination in targets
                     for byte in range(offset, offset+256)}
        assert not addresses & occupied
        occupied |= addresses
    assert multicast_sources == [root]
    assert "+source_mask=ffff" in (tmp_path / case["name"] / "schedule.txt").read_text()


def test_multicast_source_rejects_ambiguous_or_invalid_roots(tmp_path):
    case = next(c for c in load_cases("router") if c["name"] == "multicast_single")
    for root in (None, True, 16):
        with pytest.raises(ValueError, match="multicast_source"):
            generate(tmp_path, REPO / "dv/config/topology/mesh_4x4.yml", 3,
                     catalog=[dict(case, sources=[0, 1], multicast_source=root)], profile="cosim")
    with pytest.raises(ValueError, match="one multicast_source"):
        generate(tmp_path, REPO / "dv/config/topology/mesh_4x4.yml", 3,
                 catalog=[dict(case, sources=[0, 1])], profile="cosim")


def test_narrow_reset_preloads_complete_bus_words_for_write_history(tmp_path):
    case = next(c for c in load_cases("router") if c["name"] == "multicast_single")
    generate(tmp_path, REPO / "dv/config/topology/mesh_4x4.yml", 3,
             catalog=[dict(case, operation="both", burst_beats=1, multicast_masks=[51],
                           sequence="reset_recovery")], profile="cosim", mode="control")
    directory = tmp_path / case["name"]
    memory = {}
    for token in (directory / "preload.mem").read_text().split():
        if token.startswith("@"): address = int(token[1:], 16)
        else:
            memory[address] = int(token, 16)
            address += 1
    writes = _parse_write(directory / "write.txt")
    assert any(txn["addr"] % 64 == 56 for txn in writes)
    for txn in writes:
        for address in range(txn["addr"] & ~63, (txn["addr"] & ~63) + 64):
            assert memory[address] == address & 255


def test_contiguous_transfer_bytes_and_addresses(tmp_path):
    topology = tmp_path / "entries.json"
    topology.write_text(json.dumps([dict(space=space, base=base, size=65536)
                                   for space, base in (("memory", 0), ("config", 0x100000))]))
    for direction in ("read", "write"):
        for kib in (1, 2, 4, 8, 16, 32):
            lengths = [64] * (kib // 4) if kib >= 4 else [kib * 16]
            case = dict(name="transfer", mode="data", operation=direction,
                        count=len(lengths), burst_lengths=lengths, sequence="contiguous")
            out = tmp_path / (direction + str(kib))
            generate(out, topology, catalog=[case], profile="cosim")
            parser = _parse_read if direction == "read" else _parse_write
            txns = parser(out / "transfer" / (direction + ".txt"))
            assert sum((t["len"] + 1) << t["size"] for t in txns) == kib * 1024
            assert [t["addr"] for t in txns] == list(range(0, kib * 1024, 4096))
            assert all(t["size"] == 6 and t["burst"] == 1 for t in txns)
            assert all(t["addr"] >> 12 == (t["addr"] + ((t["len"] + 1) << t["size"]) - 1) >> 12
                       for t in txns)


def test_contiguous_rejects_crossing_and_conflicting_options(tmp_path):
    topology = tmp_path / "entries.json"
    topology.write_text(json.dumps([dict(space=space, base=base, size=65536)
                                   for space, base in (("memory", 0), ("config", 0x100000))]))
    base = dict(name="transfer", mode="data", operation="read", count=2,
                burst_lengths=[64, 64], sequence="contiguous")
    for changes in (dict(burst_lengths=[63, 2]), dict(burst_lengths=[65, 1]),
                    dict(burst_lengths=[True, 64]), dict(burst_lengths=[64]), dict(burst_beats=1),
                    dict(destinations="alternate"), dict(random=True), dict(mode="control")):
        try:
            generate(tmp_path / "invalid", topology, catalog=[dict(base, **changes)], profile="cosim")
        except ValueError:
            pass
        else:
            raise AssertionError("invalid contiguous transfer accepted: " + str(changes))
    entries = json.loads(topology.read_text()); entries[0]["size"] = 4096
    topology.write_text(json.dumps(entries))
    try:
        generate(tmp_path / "outside", topology, catalog=[base], profile="cosim")
    except ValueError:
        pass
    else:
        raise AssertionError("contiguous transfer exceeded the SAM window")


def test_source_destination_map_uses_native_targets(tmp_path):
    topology = tmp_path / "entries.json"
    topology.write_text(json.dumps([dict(space=space, base=node*0x100000000+offset, size=size)
                                   for space, offset, size in (("memory", 0, 0x2000000), ("config", 0x2000000, 4096))
                                   for node in range(4)]))
    case = dict(name="mapped", mode="data", operation="read", count=1,
                burst_lengths=[16], sources=[0, 1, 2, 3], source_destination_map=[1, 2, 3, 0])
    out = tmp_path / "valid"
    generate(out, topology, catalog=[case], profile="cosim", id_width=3)
    assert "+source_mask=f" in (out / "mapped/schedule.txt").read_text()
    for source, destination in enumerate(case["source_destination_map"]):
        directory = out / "mapped" if source == 0 else out / "mapped" / ("source"+str(source))
        txn, = _parse_read(directory / "read.txt")
        assert txn["addr"] == destination*0x100000000 + source*0x10000
        assert (txn["len"] + 1) << txn["size"] == 1024
    for mapping in ([1], [1, 2, 3, 4], [True, 2, 3, 0]):
        try:
            generate(tmp_path / "invalid", topology, catalog=[dict(case, source_destination_map=mapping)], profile="cosim")
        except ValueError:
            pass
        else:
            raise AssertionError("invalid source_destination_map accepted")


def test_source_destination_map_rejects_destination_modifiers(tmp_path):
    topology = tmp_path / "entries.json"
    topology.write_text(json.dumps([dict(space=space, base=node*0x100000000+offset, size=size)
                                   for space, offset, size in (("memory", 0, 0x2000000), ("config", 0x2000000, 4096))
                                   for node in range(4)]))
    base = dict(name="mapped", mode="data", operation="read", count=2,
                burst_lengths=[16, 16], sources=[0, 1], source_destination_map=[1, 2, 3, 0])
    for changes in (dict(destinations="random"), dict(destinations="all"),
                    dict(require_ooo=True), dict(require_buffered=True),
                    dict(fifo_capacity=True), dict(capacity_target="context"),
                    dict(sequence="sam_boundary"), dict(multicast_masks=[1]),
                    dict(mode="control", count=64, random=True), dict(mode="rand")):
        try:
            generate(tmp_path / "invalid", topology, catalog=[dict(base, **changes)], profile="cosim")
        except ValueError:
            pass
        else:
            raise AssertionError("destination modifier overrode a fixed mapping")


def test_zero_load_schedule_and_address_isolation(tmp_path):
    topology = tmp_path / "entries.json"
    topology.write_text(json.dumps([dict(space=space, base=node*0x100000000+offset, size=size)
                                   for space, offset, size in (("memory", 0, 0x2000000), ("config", 0x2000000, 4096))
                                   for node in range(4)]))
    case = dict(name="isolated", mode="control", operation="read", count=32,
                zero_load=True, sources=list(range(4)), source_destination_map=[1, 2, 3, 0])
    generate(tmp_path / "valid", topology, catalog=[case], profile="cosim", id_width=3)
    for source in range(4):
        directory = tmp_path / "valid/isolated"
        if source:
            directory = directory / ("source" + str(source))
        schedule = (directory / "schedule.txt").read_text()
        assert "+zero_load" in schedule and "+injection_ratio=" not in schedule
        reads = _parse_read(directory / "read.txt")
        assert len(reads) == 32
        assert all(r["len"] == 0 and r["size"] == 3 and r["burst"] == 1 for r in reads)
        first = case["source_destination_map"][source]*0x100000000 + 0x2000000 + source*0x100
        assert [r["addr"] for r in reads] == [first + n*8 for n in range(32)]
    for changes in (dict(zero_load=1), dict(injection_ratio=.1), dict(injection_ratio=0),
                    dict(mode="data"), dict(operation="write"), dict(burst_beats=2),
                    dict(concurrent_rw=True)):
        try:
            generate(tmp_path / "invalid", topology, catalog=[dict(case, **changes)], profile="cosim")
        except ValueError:
            pass
        else:
            raise AssertionError("invalid zero-load traffic was accepted")


def test_interference_sources_and_paper_counts(tmp_path):
    topology = tmp_path / "entries.json"
    topology.write_text(json.dumps([dict(space=space, base=node*0x100000000+offset, size=size)
                                   for space, offset, size in (("memory", 0, 0x2000000), ("config", 0x2000000, 4096))
                                   for node in range(16)]))
    cases = load_cases("performance_interference")
    assert len(cases) == 26
    generate(tmp_path / "valid", topology, catalog=cases, profile="cosim", id_width=3)
    for case in cases:
        for source in case["sources"]:
            work = case["source_overrides"][str(source)]
            directory = tmp_path / "valid" / case["name"]
            if source != case["sources"][0]:
                directory = directory / ("source" + str(source))
            reads = _parse_read(directory / "read.txt")
            assert len(reads) == work["count"]
            size = 3 if work["mode"] == "control" else 6
            assert all(r["size"] == size and r["len"] + 1 == work["burst_beats"] for r in reads)
            start = reads[0]["addr"]
            assert [r["addr"] for r in reads] == [start + n*work["burst_beats"]*(1 << size)
                                                  for n in range(work["count"])]
            assert all(r["addr"] >> 32 == case["source_destination_map"][source] for r in reads)
            assert all(r["addr"] >> 12 == (r["addr"] + ((r["len"] + 1) << size) - 1) >> 12 for r in reads)
        assert "+source_mask=" + format(sum(1 << n for n in case["sources"]), "x") in (
            tmp_path / "valid" / case["name"] / "schedule.txt").read_text()
    # Probe requests stay byte-identical as background sources are enabled.
    for probe, source in [("narrow", 0), ("wide", 1)]:
        baseline = tmp_path / "valid" / ("perf_" + probe + "_uni_0")
        loaded = tmp_path / "valid" / ("perf_" + probe + "_uni_2")
        if source:
            loaded = loaded / ("source" + str(source))
        assert (baseline / "read.txt").read_bytes() == (loaded / "read.txt").read_bytes()
        assert "+read_outstanding_limit=16" in (baseline / "schedule.txt").read_text()
    for case in cases:
        assert case["source_destination_map"][:4] == [2, 3, 0, 1]
        for source, work in case["source_overrides"].items():
            assert work["mode"] == ("control" if int(source) % 2 == 0 else "data")
    for limit in [0, -1, True, 1.5]:
        try:
            generate(tmp_path / "invalid_limit", topology,
                     catalog=[dict(cases[0], read_outstanding_limit=limit)], profile="cosim")
        except ValueError:
            pass
        else:
            raise AssertionError("invalid read outstanding limit accepted")
    base = cases[-1]
    for overrides in ({"9": {"count": 1}}, {"0": {"destination_order": [0]}}, {"0": {"mode": "rand"}}):
        try:
            generate(tmp_path / "invalid", topology, catalog=[dict(base, source_overrides=overrides)], profile="cosim")
        except ValueError:
            pass
        else:
            raise AssertionError("invalid source override accepted")


def test_cross_write_width_ring_and_limits(tmp_path):
    topology = tmp_path / "entries.json"
    topology.write_text(json.dumps([dict(space=space, base=node*0x100000000+offset, size=size)
        for space, offset, size in (("memory", 0, 0x2000000), ("config", 0x2000000, 4096))
        for node in range(16)]))
    cases = load_cases("performance_cross")
    assert len(cases) == 34
    out = tmp_path / "inputs"
    generate(out, topology, id_width=3, catalog=cases, profile="cosim")
    small = {1, 2, 13, 14}
    for case in cases:
        base = out / case["name"]
        assert "+write_outstanding_limit=16" in (base / "schedule.txt").read_text()
        for source in case["sources"]:
            work = case["source_overrides"][str(source)]
            directory = base if source == case["sources"][0] else base / ("source"+str(source))
            rows = _parse_write(directory / "write.txt")
            assert len(rows) == work["count"]
            assert not (directory / "read.txt").read_text()
            size = work["beat_bytes"].bit_length()-1
            assert all(r["size"] == size and r["len"]+1 == work["burst_beats"] and r["id"] == 0 for r in rows)
            assert all(r["addr"] >> 32 == case["source_destination_map"][source] for r in rows)
            for r in rows:
                assert r["addr"] >> 12 == (r["addr"]+((r["len"]+1) << size)-1) >> 12
                assert all(bin(int(b.split()[1],16)).count("1") == work["beat_bytes"] for b in r["beats"])
            if source in small:
                assert len({r["addr"] for r in rows}) == 32
                assert rows[0]["addr"] == rows[32]["addr"]
                assert (rows[0]["addr"] % 0x100000000 >= 0x2000000) == (work["mode"] == "control")
    for direction in ["uni", "bi"]:
        a = next(c for c in cases if c["name"] == "cross_split_"+direction+"_1024")
        b = next(c for c in cases if c["name"] == "cross_dat_"+direction+"_1024")
        for source in a["sources"]:
            pa = out / a["name"] / ("source"+str(source)) if source != a["sources"][0] else out / a["name"]
            pb = out / b["name"] / ("source"+str(source)) if source != b["sources"][0] else out / b["name"]
            ra, rb = _parse_write(pa/"write.txt"), _parse_write(pb/"write.txt")
            assert [(r["id"],r["len"],r["size"],r["beats"]) for r in ra] == [(r["id"],r["len"],r["size"],r["beats"]) for r in rb]
    base = dict(name="invalid", mode="data", operation="write", count=2,
                sequence="contiguous", burst_beats=1, beat_bytes=8, address_span_bytes=256)
    for change in [dict(beat_bytes=3),dict(beat_bytes=True),dict(address_span_bytes=3),
                   dict(address_span_bytes=4),dict(write_outstanding_limit=0),
                   dict(write_outstanding_limit=True),dict(operation="read",write_outstanding_limit=16)]:
        try:
            generate(tmp_path/"invalid",topology,catalog=[dict(base,**change)],profile="cosim")
        except ValueError:
            pass
        else:
            raise AssertionError("invalid cross write field accepted")


def test_boundary_memory_mapping_and_workspaces(tmp_path):
    topology = REPO / "dv/config/topology/mesh_4x4_memory.yml"
    cases = [c for c in load_cases("performance_boundary") if c["name"].endswith("_check")]
    out = tmp_path / "inputs"
    generate(out, topology, 3, catalog=cases, profile="cosim")
    for case in cases:
        base = out / case["name"]
        for source in case["sources"]:
            directory = base if source == case["sources"][0] else base / ("source" + str(source))
            rows = _parse_read(directory / "read.txt")
            assert len(rows) == 1 and rows[0]["id"] == 0
            row = rows[0]
            if case["mode"] == "data":
                expected = 0x1000000000 + (source // 4) * 0x100000 + (source % 4) * 0x20000
                assert row["addr"] == expected and row["len"] == 63 and row["size"] == 6
            else:
                assert row["addr"] == 15 * 0x100000000 + 0x2000000 + source * 0x100
                assert row["len"] == 0 and row["size"] == 3
    full = dict(cases[0], name="boundary_workspace_check", count=32)
    generate(tmp_path / "full", topology, 3, catalog=[full], profile="cosim")
    intervals = {}
    for source in full["sources"]:
        base = tmp_path / "full" / full["name"]
        directory = base if source == 0 else base / ("source" + str(source))
        rows = _parse_read(directory / "read.txt")
        assert len(rows) == 32
        for index, row in enumerate(rows):
            assert row["addr"] == 0x1000000000 + (source // 4) * 0x100000 + (source % 4) * 0x20000 + index * 4096
            assert row["addr"] % 4096 == 0
        intervals[source] = (rows[0]["addr"], rows[-1]["addr"] + 4096)
    for source, (start, end) in intervals.items():
        for other, (other_start, other_end) in intervals.items():
            if other != source:
                assert end <= other_start or other_end <= start
    invalid = dict(cases[0], source_overrides={"0": {"address_offset": -1}})
    try:
        generate(tmp_path / "invalid", topology, 3, catalog=[invalid], profile="cosim")
    except ValueError as error:
        assert "address_offset" in str(error)
    else:
        raise AssertionError("Negative source workspace accepted")


def test_boundary_formal_matrix(tmp_path):
    cases = [c for c in load_cases("performance_boundary") if not c["name"].endswith("_check")]
    by_name = {c["name"]: c for c in cases}
    expected = {"boundary_read_zero_" + str(n) for n in range(16)}
    expected |= {"boundary_narrow_zero_" + str(n) for n in range(15)}
    expected |= {"boundary_read_full", "boundary_narrow_full"}
    assert set(by_name) == expected
    out = tmp_path / "inputs"
    generate(out, REPO / "dv/config/topology/mesh_4x4_memory.yml", 3, catalog=cases, profile="cosim")
    for work, sources, beat_bytes, beats, limit in (("read", range(16), 64, 64, 16),
                                                   ("narrow", range(15), 8, 1, 1)):
        full = by_name["boundary_" + work + "_full"]
        assert full["sources"] == list(sources) and full["read_outstanding_limit"] == limit
        for source in sources:
            zero_name = "boundary_" + work + "_zero_" + str(source)
            assert by_name[zero_name]["sources"] == [source]
            directory = out / full["name"]
            if source != 0:
                directory /= "source" + str(source)
            assert (directory / "read.txt").read_bytes() == (out / zero_name / "read.txt").read_bytes()
            rows = _parse_read(directory / "read.txt")
            assert len(rows) == (32 if work == "read" else 100)
            for index, row in enumerate(rows):
                expected_base = (0x1000000000 + (source // 4) * 0x100000 + (source % 4) * 0x20000
                                 if work == "read" else 15 * 0x100000000 + 0x2000000 + source * 0x100)
                assert row["addr"] == expected_base + (index * beats * beat_bytes if work == "read" else (index % 32) * 8)
                assert row["len"] + 1 == beats and 1 << row["size"] == beat_bytes
                assert row["id"] == 0 and row["burst"] == 1
                assert row["addr"] >> 12 == (row["addr"] + beats * beat_bytes - 1) >> 12
