#!/usr/bin/env python3
"""Fail closed on model, protocol and existing scoreboard diagnostics."""
import argparse
from collections import Counter, defaultdict, deque
from axi_file_parser import _parse_read, _parse_write
import csv
import shutil
import hashlib
import json
from pathlib import Path
import re
import subprocess
from build_key import valid_compile


def read_performance(path, clock_ps):
    """Pair accepted AXI events. Phase belongs to AW/AR, never response timing."""
    groups = defaultdict(list)
    with path.open() as stream:
        for row in csv.DictReader(stream):
            for key in ("time_ps", "endpoint", "x", "y", "port", "phase", "id", "len", "size", "burst", "last", "resp"):
                row[key] = int(row[key])
            for key in ("addr", "strb", "user"):
                row[key] = int(row[key], 16)  # Unknown values fail closed.
            groups[(row["role"], row["endpoint"])].append(row)
    transactions = []
    for (role, endpoint), events in groups.items():
        events.sort(key=lambda e: e["time_ps"])
        aw = [e for e in events if e["channel"] == "AW"]
        ar = [e for e in events if e["channel"] == "AR"]
        writes = []
        beats = []
        for event in events:
            if event["channel"] == "W":
                beats.append(event)
                if event["last"]:
                    writes.append(beats)
                    beats = []
        if beats or len(writes) != len(aw):
            raise ValueError("Unmatched AW/W on {} {}".format(role, endpoint))
        by_id = defaultdict(deque)
        for request, data in zip(aw, writes):
            validate_burst(request)
            if len(data) != request["len"] + 1:
                raise ValueError("WLAST/beat count does not match AWLEN")
            useful = 0
            for i, beat in enumerate(data):
                address, count = read_beat(request, i)
                allowed = ((1 << count) - 1) << (address % 64)
                if beat["strb"] & ~allowed:
                    raise ValueError("WSTRB outside accepted AW byte lanes")
                useful += bin(beat["strb"]).count("1")
            by_id[request["id"]].append((request, data, useful))
        for response in (e for e in events if e["channel"] == "B"):
            if not by_id[response["id"]]:
                raise ValueError("B without matching AW")
            request, data, useful = by_id[response["id"]].popleft()
            if response["time_ps"] < max(request["time_ps"], data[-1]["time_ps"]):
                raise ValueError("B before AW or final W")
            transactions.append(perf_transaction(request, response, "write", useful,
                                                min(request["time_ps"], data[0]["time_ps"])))
        if any(by_id.values()):
            raise ValueError("Uncompleted write")
        reads = defaultdict(deque)
        for request in ar:
            validate_burst(request)
            reads[request["id"]].append(dict(request=request, beats=0, useful=0))
        for response in (e for e in events if e["channel"] == "R"):
            if not reads[response["id"]]:
                raise ValueError("R without matching AR")
            pending = reads[response["id"]][0]
            request = pending["request"]
            if response["time_ps"] < request["time_ps"]:
                raise ValueError("R before AR")
            if pending["beats"] > request["len"]:
                raise ValueError("Too many R beats")
            pending["useful"] += read_beat(request, pending["beats"])[1]
            pending["beats"] += 1
            if bool(response["last"]) != (pending["beats"] == request["len"] + 1):
                raise ValueError("RLAST does not match ARLEN")
            if response["resp"] != 0:
                raise ValueError("Non-OKAY R cannot be a performance point")
            if response["last"]:
                transactions.append(perf_transaction(request, response, "read", pending["useful"],
                                                    request["time_ps"]))
                reads[response["id"]].popleft()
        if any(reads.values()):
            raise ValueError("Uncompleted read")
        for row in (t for t in transactions if t["role"] == role and t["endpoint"] == endpoint):
            if any(e["channel"] == "RESET" and row["first_transfer_ps"] <= e["time_ps"] <= row["completion_ps"]
                   for e in events):
                raise ValueError("Reset interrupted a measured transaction")
    measured = [t for t in transactions if t["role"] == "source" and t["phase"] == 1]
    if not measured or clock_ps <= 0:
        raise ValueError("Missing measurement-phase transactions or clock")
    start = min(t["first_transfer_ps"] for t in measured)
    end = max(t["completion_ps"] for t in measured)
    if end <= start:
        raise ValueError("Empty job window")
    summary = dict(window=dict(start_ps=start, end_ps=end, clock_period_ps=clock_ps,
                               definition="first source transfer to last required source completion; phase 1 only"),
                   directions={}, device_peak=None, utilization_percent=None)
    for direction in ("read", "write"):
        rows = [t for t in measured if t["direction"] == direction]
        if rows:
            useful = sum(t["useful_bytes"] for t in rows)
            summary["directions"][direction] = dict(
                count=len(rows), useful_bytes=useful,
                mean_latency_cycles=sum(t["latency_ps"] for t in rows) / len(rows) / clock_ps,
                bytes_per_cycle=useful * clock_ps / (end - start))
    # Device events remain raw if other sources' setup/readback overlaps this job.
    excluded = [t for t in transactions if t["role"] == "source" and t["phase"] != 1]
    overlap = any(t["first_transfer_ps"] <= end and t["completion_ps"] >= start for t in excluded)
    summary["device_window_bytes"] = None
    summary["device_window_status"] = "phase overlap: raw events only" if overlap else "common job window"
    if not overlap:
        counters = {}
        for (role, endpoint), events in groups.items():
            if role != "device":
                continue
            read_pending = defaultdict(deque)
            read_bytes_by_time = []
            for event in events:
                if event["channel"] == "AR":
                    read_pending[event["id"]].append([event, 0])
                elif event["channel"] == "R":
                    request, index = read_pending[event["id"]][0]
                    read_bytes_by_time.append((event["time_ps"], read_beat(request, index)[1]))
                    read_pending[event["id"]][0][1] += 1
                    if event["last"]:
                        read_pending[event["id"]].popleft()
            counters[str(endpoint)] = dict(
                write=sum(bin(e["strb"]).count("1") for e in events
                          if e["channel"] == "W" and start <= e["time_ps"] <= end),
                read=sum(size for time, size in read_bytes_by_time if start <= time <= end))
        summary["device_window_bytes"] = counters
    return transactions, summary


def validate_burst(request):
    # The formal benchmarks use legal INCR bursts; do not guess unsupported cases.
    size = 1 << request["size"]
    aligned = request["addr"] // size * size
    if (request["burst"] != 1 or request["size"] > 6 or not 0 <= request["len"] <= 255 or
            request["addr"] // 4096 != (aligned + (request["len"] + 1) * size - 1) // 4096):
        raise ValueError("Performance requires legal <=512-bit, 4KiB-bounded INCR bursts")


def read_beat(request, index):
    size = 1 << request["size"]
    aligned = request["addr"] // size * size
    address = request["addr"] if index == 0 else aligned + index * size
    return address, size - (request["addr"] % size) if index == 0 else size


def perf_transaction(request, response, direction, useful, first):
    if response["resp"] != 0:
        raise ValueError("Non-OKAY response cannot be a performance point")
    return dict(role=request["role"], endpoint=request["endpoint"],
                x=request["x"], y=request["y"], port=request["port"],
                phase=request["phase"], direction=direction, id=request["id"],
                addr=request["addr"], beats=request["len"] + 1, size=request["size"],
                user=request["user"], request_ps=request["time_ps"],
                first_transfer_ps=first, completion_ps=response["time_ps"],
                latency_ps=response["time_ps"] - request["time_ps"], useful_bytes=useful)


def preserve_performance(report, binary, stimulus, campaign):
    """Snapshot the existing inputs/build, without another config or build entry."""
    root = report.parent.parent
    config = root / "config"
    provenance = root / "provenance"
    config.mkdir()
    provenance.mkdir()
    for name in ("tables", "figures"):
        (root / name).mkdir()
    shutil.copytree(str(stimulus), str(report / "inputs"))
    build = binary.resolve().parent
    build_config = json.loads((build / "config.json").read_text())
    for name in ("config.json", "SHA256SUMS", "compile-success.json", "compile-command.txt", "compile.log"):
        if (build / name).is_file():
            shutil.copy2(str(build / name), str(provenance / name))
    for name in ("profile.yml", "topology.yml", "ni_tb_params.svh"):
        if (campaign / name).is_file():
            shutil.copy2(str(campaign / name), str(config / name))
    (config / "recipe.json").write_text(json.dumps(build_config.get("recipe", {}), indent=2) + "\n")
    sources = provenance / "source"
    repo = Path(__file__).resolve().parents[2]
    for line in (build / "SHA256SUMS").read_text().splitlines():
        expected, name = line.split("  ", 1)
        origin = build / name.split("/", 1)[1] if name.startswith("@generated/") else repo / name
        if hashlib.sha256(origin.read_bytes().replace(b"\r\n", b"\n")).hexdigest() != expected:
            raise ValueError("Build source differs from current source: " + name)
        target = sources / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(origin), str(target))
    for name in ("dv/scripts/run.py", "dv/scripts/axi_file_parser.py", "dv/scripts/gen_standalone_patterns.py",
                 "dv/scripts/axi_file_format.py", "sim/Makefile", "dv/config/cases.json"):
        target = sources / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(repo / name), str(target))
    return report / "inputs"

p = argparse.ArgumentParser()
p.add_argument("--binary", required=True)
p.add_argument("--inputs", type=Path, required=True)
p.add_argument("--stimulus", type=Path)
p.add_argument("--campaign", type=Path, required=True)
p.add_argument("--case", required=True)
p.add_argument("--report", required=True)
p.add_argument("--mode", choices=("auto", "control", "data", "rand"), default="auto")
p.add_argument("--wave", action="store_true")
p.add_argument("--perf", action="store_true", help="Save accepted AXI events and FSDB in a new permanent result")
p.add_argument("--read-interleave", action="store_true", help="Use existing VIP beat interleaving and require actual ID switches")
p.add_argument("--aw-wait-w", action="store_true", help="Have existing slave endpoint wait for WVALID before accepting AW")
p.add_argument("--corrupt", action="store_true")
p.add_argument("--coverage", action="store_true")
p.add_argument("--coverage-name", help="Unique native coverage test name")
p.add_argument("--backpressure", action="store_true")
p.add_argument("--target", choices=("per_id", "context", "rob"), default="per_id")
p.add_argument("--seed", type=int, default=1, help="Simulation seed; transaction seed is set during pattern generation")
a = p.parse_args()
if a.perf and a.corrupt:
    p.error("Performance cannot use negative-test corruption mode")
if a.perf:
    a.wave = True
patterns = a.inputs.resolve()
if a.mode != "auto" and not a.stimulus:
    patterns /= a.mode
cases = (patterns / "cases.list").read_text().split()
if a.case not in cases:
    p.error("Unsupported co-simulation CASE '{}'. Use make list. "
            "Available cases: {}".format(a.case, ", ".join(cases)))
pattern = a.case
if a.backpressure:
    if a.case not in ("single_id_reorder", "multi_id_out_of_order"):
        p.error("BACKPRESSURE=1 requires a reorder case")
    pattern += "_backpressure"
if a.case == "capacity_reuse":
    pattern += "_" + a.target
stim = a.stimulus.resolve() if a.stimulus else patterns / pattern
if not 0 <= a.seed <= 0xffffffff:
    p.error("SEED must be an unsigned 32-bit integer")
run_name = a.coverage_name or (pattern + "_" + a.mode + "_s" + str(a.seed))
if not re.fullmatch(r"[A-Za-z0-9_]+", run_name):
    p.error("coverage name must contain only letters, digits and underscores")
for name in ("schedule.txt", "read.txt", "write.txt"):
    if not (stim / name).is_file():
        p.error("Incomplete co-simulation pattern '{}': missing {}. "
                "Prepare and synchronize the co-simulation environment again.".format(a.case, stim / name))
hardware = stim / "ni_tb_params.svh"
compiled_hardware = Path(a.binary).resolve().parent / "ni_tb_params.svh"
if not hardware.is_file() or not compiled_hardware.is_file():
    p.error("Missing ni_tb_params.svh for pattern or binary; prepare and compile the hardware profile")
if hardware.read_bytes() != compiled_hardware.read_bytes():
    p.error("Pattern hardware profile does not match the compiled binary")
if not valid_compile(Path(a.binary).resolve().parent):
    p.error("Binary has no valid successful compile record; run make compile")
report = Path(a.report).resolve()
if a.perf:
    if report.parent.name != "runs":
        p.error("Performance --report must be <new campaign>/runs/<run ID>")
    if report.parent.parent.exists():
        p.error("Performance campaign already exists; use a new result directory")
report.mkdir(parents=True, exist_ok=True)
if a.perf:
    stim = preserve_performance(report, Path(a.binary), stim, a.campaign)
args = [str(Path(a.binary).resolve()), "+stim_dir=" + str(stim.resolve())]
args += [v for v in (stim / "schedule.txt").read_text().split() if not v.startswith("+seed=")]
manifest = json.loads((stim / "manifest.json").read_text())
if "acceptance" not in manifest or "files" not in manifest:
    p.error("Pattern manifest has no acceptance criteria or file list; regenerate patterns")
args += ["+reset_seed=" + str(a.seed), "+ntb_random_seed=" + str(a.seed)]
for key, value in manifest["acceptance"].items():
    args.append("+check_" + key + "=" + str(value))
for filename, flag in (("preload.mem", "preload"), ("init_write.txt", "init_phase"),
                       ("verify_read.txt", "readback")):
    if filename in manifest["files"]:
        if not (stim / filename).is_file():
            p.error("Missing pattern file: " + str(stim / filename))
        args.append("+" + flag)
if a.coverage:
    args += ["-cm", "line+cond+fsm+tgl+branch+assert",
             "-cm_dir", str(Path(a.binary).resolve()) + ".vdb",
             "-cm_name", run_name]
if a.read_interleave:
    args += ["+read_interleave"]
if a.aw_wait_w:
    args += ["+aw_wait_w"]
if a.wave:
    args += ["+wave_file=" + str((report / (a.case + ".fsdb")).resolve())]
if a.perf:
    args += ["+perf_file=" + str(report / "axi-events.csv")]
if a.corrupt:
    args += ["+corrupt_rsp"]
try:
    r = subprocess.run(args, cwd=str(report.resolve()), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
except subprocess.TimeoutExpired as error:
    r = subprocess.CompletedProcess(args, 124, (error.stdout or b"") + b"\nFatal: simulation timed out after 180 seconds\n")
log = r.stdout.decode(errors="replace")
log_path = report / (a.case + ("_corrupt" if a.corrupt else "") + ".log")
diagnostics = re.sub(r"Warning: [^\n]*\nMacro 'FFARN' is deprecated\. Use 'FF' instead\.\n", "", log)
failed = r.returncode != 0 or bool(re.search(r"(?im)^(?:Warning:|Error:|Fatal:)|\b(?:mismatch|does not match|Assertion failed)\b", diagnostics))
# VCS 2017 reports assertions without an action block using this diagnostic.
assertion_failed = bool(re.search(r"\bstarted at\s+\S+\s+failed at\s+\S+", diagnostics))
failed |= assertion_failed
failed |= bool(re.search(r"(?m)^UVM_(?:ERROR|FATAL)(?!\s*:)|^UVM_(?:ERROR|FATAL)\s*:\s*[1-9]", diagnostics))
if a.wave:
    wave_file = report / (a.case + ".fsdb")
    failed |= (not re.search(r"\*Verdi\*.*Create FSDB file", log) or
               not wave_file.is_file() or wave_file.stat().st_size == 0)
passed = "NMU_COSIM_COUNTS" in log and "AXI_ORDERING_CHECK_DRAINED" in log and not failed
if a.corrupt:
    errors = re.findall(r"(?m)^UVM_ERROR .*?\[([^]]+)\] ([^\n]*)", log)
    fatals = re.findall(r"(?m)^UVM_FATAL(?!\s*:)[^\n]*", log)
    passed = (r.returncode in (0, 1) and not assertion_failed and "Unexpected RData" in log and
              {code for code, _ in errors} == {"AXI_ORDER", "AXI_DATA"} and
              all((code == "AXI_ORDER" and message == "R mismatch") or
                  (code == "AXI_DATA" and message.startswith("Unexpected RData")) for code, message in errors) and
              not re.search(r"(?m)^(?:Fatal:|Error:)", log) and
              all(re.search(r"\[PENDING\] Scoreboard has pending transactions$", line)
                  for line in fatals))

performance = None
performance_error = None
if a.perf and passed:
    try:
        period = re.search(r"CLOCK_CONFIG axi_period_ps=(\d+)", log)
        if not period:
            raise ValueError("Missing clock configuration")
        transactions, performance = read_performance(report / "axi-events.csv", int(period.group(1)))
        mask = next((int(v.split("=", 1)[1], 16) for v in args if v.startswith("+source_mask=")), 1)
        primary = (mask & -mask).bit_length() - 1
        expected = Counter()
        for endpoint in range(mask.bit_length()):
            if not mask & (1 << endpoint):
                continue
            directory = stim if endpoint == primary else stim / ("source" + str(endpoint))
            for direction, parser, name in (("write", _parse_write, "write.txt"), ("read", _parse_read, "read.txt")):
                count = len(parser(directory / name))
                if count:
                    expected[(endpoint, direction)] = count
        actual = Counter((t["endpoint"], t["direction"]) for t in transactions
                         if t["role"] == "source" and t["phase"] == 1)
        if expected != actual:
            raise ValueError("Performance transaction counts do not match the existing stimulus files")
        root = report.parent.parent
        (root / "tables/transactions.json").write_text(json.dumps(transactions, indent=2) + "\n")
        with (root / "tables/transactions.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(transactions[0]))
            writer.writeheader()
            writer.writerows(transactions)
        (root / "tables/summary.json").write_text(json.dumps(performance, indent=2) + "\n")
    except (OSError, ValueError, KeyError, IndexError) as error:
        passed = False
        performance_error = str(error)
if passed:
    log += "NMU_COSIM_CORRUPTION_DETECTED\n" if a.corrupt else "NMU_COSIM_PASS\n"
log_path.write_text(log)
print(log)
# The binary may be shared by several stimulus directories.
build_source = Path(a.binary).resolve().parent
# Run provenance only. Functional coverage bins/results belong to VCS/URG.
result = dict(case=a.case, mode=a.mode, target=a.target, backpressure=a.backpressure, seed=a.seed, passed=passed, command=args,
              vdb=str(Path(a.binary).resolve()) + ".vdb",
              stimulus_seed=manifest["seed"], simulation_seed=a.seed,
              source_manifest_sha256=hashlib.sha256((build_source / "SHA256SUMS").read_bytes()).hexdigest(),
              source_directory=str(build_source),
              profile=(a.campaign / "profile.yml").read_text(),
              stimulus_sha256={str(p.relative_to(stim)): hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in sorted(stim.rglob("*")) if p.is_file()})
result["compile_record"] = json.loads((build_source / "compile-success.json").read_text())
result["binary_sha256"] = hashlib.sha256(Path(a.binary).read_bytes()).hexdigest()
clock = re.search(r"CLOCK_CONFIG axi_period_ps=(\d+) noc_period_ps=(\d+)", log)
phase = re.search(r"CLOCK_PHASE noc_phase_ps=(\d+)", log)
if clock:
    result["clock"] = dict(axi_period_ps=int(clock.group(1)), noc_period_ps=int(clock.group(2)),
                           noc_phase_ps=int(phase.group(1)) if phase else 0)
if a.perf:
    wave = report / (a.case + ".fsdb")
    result["performance"] = performance
    result["performance_error"] = performance_error
    result["waveform"] = dict(path=str(wave), bytes=wave.stat().st_size if wave.is_file() else 0,
                              sha256=hashlib.sha256(wave.read_bytes()).hexdigest() if wave.is_file() else None)
(report / (a.case + ".run.json")).write_text(json.dumps(result, indent=2) + "\n")
if a.perf:
    root = report.parent.parent
    (root / "campaign.json").write_text(json.dumps(dict(case=a.case, run_id=report.name,
        scenario=root.parent.parent.name, status="passed" if passed else "failed",
        purpose="collector_smoke", publication_result=False, command=args,
        binary_sha256=result["binary_sha256"], source_manifest_sha256=result["source_manifest_sha256"],
        waveform=result["waveform"]), indent=2) + "\n")
    (root / "validation.json").write_text(json.dumps(dict(
        checker_passed=passed, drain="AXI_ORDERING_CHECK_DRAINED" in log,
        performance_error=performance_error, offline_calibration_comparison="pending",
        scope="collector smoke only; paper conditions not yet validated"), indent=2) + "\n")
if not passed:
    raise SystemExit("Co-simulation acceptance failed")
