#!/usr/bin/env python3
"""Render saved NoC measurements; no stimulus or simulation entry."""
import argparse
import csv
import hashlib
import json
import os
import re
import random
import subprocess
import sys
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


TRAFFIC = {
    "neighbor": ("Neighbor", "#1665a8", "o"),
    "bit_complement": ("Bit-complement", "#E69F00", "s"),
    "transpose": ("Transpose", "#009E73", "^"),
    "uniform": ("Uniform", "#7B3294", "D"),
    "shuffle": ("Shuffle", "#C44E52", "v"),
}


WIDE_SIZES = (1024, 2048, 4096, 8192, 16384, 32768)
INJECTION_RATIOS = (0, 0.001, 0.01, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5)


def require_curve_grid(points, field, expected):
    if not points:
        raise ValueError("No measured curve points")
    for pattern in {point["pattern"] for point in points}:
        actual = {point[field] for point in points if point["pattern"] == pattern}
        if actual != set(expected):
            raise ValueError("Incomplete " + pattern + " curve: missing " +
                             str(sorted(set(expected) - actual)) +
                             "; unexpected " + str(sorted(actual - set(expected))))


def traffic_case(root, name):
    groups = json.loads((root / "provenance/source/dv/config/cases.json").read_text())["groups"]

    def resolve(case):
        if "extends" not in case:
            return dict(case)
        group, parent = case["extends"].split("/", 1)
        base = resolve(next(row for row in groups[group] if row["name"] == parent))
        base.update({key: value for key, value in case.items() if key != "extends"})
        return base

    case = resolve(next(row for row in groups["performance_unicast"] if row["name"] == name))
    if name.startswith(("perf_neighbor_read_", "neighbor_")):
        pattern = "neighbor"
        expected = [4 * (n // 4) + (n + 1) % 4 for n in range(16)]
    elif name.startswith("bit_complement_"):
        pattern = "bit_complement"
        expected = list(range(15, -1, -1))
    elif name.startswith("transpose_"):
        pattern = "transpose"
        expected = [4 * (n % 4) + n // 4 for n in range(16)]
    elif name.startswith("uniform_"):
        pattern = "uniform"
        generator = random.Random(42)
        expected = [None] * 16
        for x in range(4):
            for y in range(4):
                while True:
                    dx, dy = generator.randint(0, 3), generator.randint(0, 3)
                    if (dx, dy) != (x, y):
                        break
                expected[4 * y + x] = 4 * dy + dx
    elif name.startswith("shuffle_"):
        pattern = "shuffle"
        expected = []
        for n in range(16):
            source = 4 * (n % 4) + n // 4
            expected.append(2 * source if source < 8 else 2 * source - 15)
    else:
        raise ValueError("Unsupported traffic case: " + name)
    if case.get("sources") != list(range(16)) or case.get("source_destination_map") != expected:
        raise ValueError("Traffic mapping differs from the saved reference rule")
    return pattern, case


INJECTION_TB_REVISIONS = [
    {
        "dv/env/seq_lib/ni_pattern_sequence.svh": "f5530ea6cfb72daf721bba581ab63848ff6da0ad59966feaff64f90dfb5417a9",
        "dv/tests/ni_test.svh": "eafc6fbe7fecd5af2d033e0f1d0db260acd5151a23a7fc4e98144820a005f95e"
    },
    {
        "dv/env/seq_lib/ni_pattern_sequence.svh": "04a0d4fbf4e5552d5db79f5c81837c35623289a052e425cae2f0c59a3eded770",
        "dv/tests/ni_test.svh": "87fdcfc6ba8cd8a4596d23808cb84956d169105ed46fd0a60ddddb5068ad9128"
    },
    {
        "dv/env/seq_lib/ni_pattern_sequence.svh": "11c5f84b1160c8f6a34a1cb392b77d4d95f5d9de4608b7b7a9b780cfafc21314",
        "dv/tests/ni_test.svh": "5713d8bbb2a2521644b52af38b6ab26bff2a9ea3ac34dd0b8e2420e5b0b4ed52"
    }
]

def platform_context(root, record):
    # These reviewed TB revisions differ only by optional injection or isolated zero-load scheduling.
    manifest = root / "provenance/SHA256SUMS"
    if digest(manifest) != record["source_manifest_sha256"]:
        raise ValueError("Compiled source manifest does not match the run")
    compiled, testbench = [], {}
    for line in manifest.read_text().splitlines():
        sha, name = line.split("  ", 1)
        if name in INJECTION_TB_REVISIONS[0]:
            testbench[name] = sha
        else:
            compiled.append((name, sha))
    if testbench not in INJECTION_TB_REVISIONS:
        raise ValueError("Unreviewed injection TB revision")
    config = json.loads((root / "provenance/config.json").read_text())
    return (record["seed"], record["clock"], digest(root / "config/recipe.json"),
            config["flags"], config["coverage"], tuple(sorted(compiled)))


def wide_curve(results, output):
    """Plot the available Fig.8 wide points, grouped by saved traffic pattern."""
    output = output.resolve()
    points, contexts = [], {}
    platform = None
    for root in results:
        root = root.resolve()
        run, = (root / "runs").iterdir()
        record = json.loads((run / (run.name + ".run.json")).read_text())
        pattern, case = traffic_case(root, run.name)
        if "injection_ratio" in case or any(arg.startswith("+injection_ratio=") for arg in record["command"]):
            raise ValueError("Wide transfers must use the unthrottled workload")
        validation = json.loads((root / "validation.json").read_text())
        summary = json.loads((root / "tables/summary.json").read_text())
        transfers = json.loads((root / "tables/transactions.json").read_text())
        if (not record["passed"] or not validation["drain"] or
                validation["offline_calibration_comparison"] != "passed_against_this_run_FSDB" or
                validation.get("marker_calibration", {}).get("status") != "passed_against_this_run_FSDB"):
            raise ValueError("Uncalibrated result: " + str(root))
        if summary != record["performance"]:
            raise ValueError("Summary does not match the actual run record")
        wave = run / (run.name + ".fsdb")
        if not wave.stat().st_size or digest(wave) != record["waveform"]["sha256"]:
            raise ValueError("Waveform hash mismatch")
        current = (record["binary_sha256"], record["source_manifest_sha256"])
        if pattern in contexts and current != contexts[pattern]:
            raise ValueError("One traffic curve uses mixed builds")
        contexts[pattern] = current
        current_platform = platform_context(root, record)
        if platform is not None and current_platform != platform:
            raise ValueError("Traffic curves use different RTL, collector, clock, seed or config")
        platform = current_platform
        tiles = summary["source_tiles"]
        if sorted(tile["endpoint"] for tile in tiles) != list(range(16)):
            raise ValueError("Expected all 16 native sources")
        if any(tile["monitor_window"] is None or tile["monitor_window"]["cycles"] <= 0 for tile in tiles):
            raise ValueError("Missing per-tile monitor window")
        sizes = {tile["directions"]["read"]["useful_bytes"] for tile in tiles}
        if len(sizes) != 1 or any(set(tile["directions"]) != {"read"} for tile in tiles):
            raise ValueError("Expected equal read jobs at every tile")
        size, = sizes
        if size not in (1024, 2048, 4096, 8192, 16384, 32768) or case["mode"] != "data":
            raise ValueError("Expected one of the six full-width paper transfer sizes")
        for tile in tiles:
            rows = [t for t in transfers if t["role"] == "source" and
                    t["endpoint"] == tile["endpoint"] and t["phase"] == 1]
            if (len(rows) != case["count"] or
                    any(t["direction"] != "read" or t["size"] != 6 or
                        t["addr"] >> 32 != case["source_destination_map"][tile["endpoint"]] for t in rows)):
                raise ValueError("Accepted wide traffic differs from the saved case")
        mean = summary["source_tile_average"]["read"]["monitor_payload_utilization_percent"]
        if mean is None or not 0 <= mean <= 100:
            raise ValueError("Missing full-width monitor utilization")
        points.append(dict(pattern=pattern, root=os.path.relpath(str(root), str(output)),
            run_id=root.name, transfer_bytes=size, mean_utilization_percent=mean, source_tiles=16,
            binary_sha256=record["binary_sha256"], source_manifest_sha256=record["source_manifest_sha256"],
            summary_sha256=digest(root / "tables/summary.json"), waveform_sha256=record["waveform"]["sha256"]))
    points.sort(key=lambda point: (list(TRAFFIC).index(point["pattern"]), point["transfer_bytes"]))
    if len({(p["pattern"], p["transfer_bytes"]) for p in points}) != len(points):
        raise ValueError("Duplicate traffic/size points")
    require_curve_grid(points, "transfer_bytes", WIDE_SIZES)
    paths = [output / "figures/bandwidth.png", output / "figures/bandwidth.svg",
             output / "tables/bandwidth.csv", output / "provenance/bandwidth-plot.json"]
    if any(path.exists() for path in paths):
        raise ValueError("Refuse to overwrite existing bandwidth artifacts")
    for path in paths:
        path.parent.mkdir(parents=True, exist_ok=True)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(6.4, 4.5))
    for pattern, (label, color, marker) in TRAFFIC.items():
        curve = [point for point in points if point["pattern"] == pattern]
        if curve:
            ax.plot([p["transfer_bytes"] / 1024 for p in curve],
                    [p["mean_utilization_percent"] for p in curve], color=color,
                    linestyle="-", marker=marker, markerfacecolor=color,
                    markersize=5.5, markeredgewidth=1.2, linewidth=1.7, label=label)
    ax.set(xlabel="Transfer size [KiB]", ylabel="Avg. BW Util [%]", xlim=(0, 33), ylim=(0, 100))
    ax.set_xticks([1, 2, 4, 8, 16, 32])
    ax.set_yticks([0, 50, 100])
    ax.legend(frameon=False)
    ax.grid(True, linestyle="--", alpha=0.35)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    fig.tight_layout()
    fig.savefig(str(paths[0]), dpi=180)
    fig.savefig(str(paths[1]))
    plt.close(fig)
    with paths[2].open("x", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(points[0]))
        writer.writeheader()
        writer.writerows(points)
    paths[3].write_text(json.dumps(dict(command=[sys.executable] + sys.argv,
        script_sha256=digest(Path(__file__)), reference="arXiv:2409.17606v2 Fig.8",
        metric="Mean full-width source payload utilization across the 16 native tiles",
        build_policy="One build per traffic curve; identical compiled sources except pinned reviewed injection/zero-load TB revisions; same collector/recipe/flags/coverage/clock/seed across curves",
        limitation="Native platform/VIP and inclusive monitor window; exact paper experiment revision and monitor scheduling are unverified",
        required_transfer_bytes=[1024, 2048, 4096, 8192, 16384, 32768],
        points=points, publication_result=False), indent=2) + "\n")
    print("Saved bandwidth PNG/SVG and curve data under", output)


def narrow_curve(results, output):
    """Average the saved per-source narrow read latency, as in FlooNoC Fig.8."""
    output = output.resolve()
    points, sources = [], []
    context = None
    for root in results:
        root = root.resolve()
        run, = (root / "runs").iterdir()
        record = json.loads((run / (run.name + ".run.json")).read_text())
        pattern, case = traffic_case(root, run.name)
        validation = json.loads((root / "validation.json").read_text())
        summary = json.loads((root / "tables/summary.json").read_text())
        transfers = json.loads((root / "tables/transactions.json").read_text())
        if (not record["passed"] or not validation["drain"] or summary != record["performance"] or
                validation["offline_calibration_comparison"] != "passed_against_this_run_FSDB" or
                validation.get("marker_calibration", {}).get("status") != "passed_against_this_run_FSDB"):
            raise ValueError("Uncalibrated narrow result: " + str(root))
        current = platform_context(root, record)
        if context is not None and current != context:
            raise ValueError("Latency points use different reviewed RTL/TB, collector, clock, seed or config")
        context = current
        wave = run / (run.name + ".fsdb")
        if not wave.stat().st_size or digest(wave) != record["waveform"]["sha256"]:
            raise ValueError("Waveform hash mismatch")
        if case.get("zero_load"):
            if ("+zero_load" not in record["command"] or case.get("injection_ratio") is not None or
                    any(arg.startswith("+injection_ratio=") for arg in record["command"]) or
                    validation.get("zero_load_isolation", {}).get("status") != "passed"):
                raise ValueError("Zero-load requires a validated isolated transaction mode")
            ordered = sorted((t for t in transfers if t["role"] == "source" and t["phase"] == 1),
                             key=lambda t: t["request_ps"])
            if (not ordered or any(t["direction"] != "read" for t in ordered) or
                    any(a["completion_ps"] >= b["request_ps"] for a, b in zip(ordered, ordered[1:]))):
                raise ValueError("Zero-load source transactions overlap")
            ratio = 0.0
        else:
            ratio, = [float(arg.split("=", 1)[1]) for arg in record["command"]
                      if arg.startswith("+injection_ratio=")]
            if not 0 < ratio <= 0.5 or ratio != case.get("injection_ratio") or "+zero_load" in record["command"]:
                raise ValueError("Expected the saved injection parameter in (0, 0.5]")
        tiles = summary["source_tiles"]
        if sorted(tile["endpoint"] for tile in tiles) != list(range(16)):
            raise ValueError("Expected all 16 source tiles")
        begin = len(sources)
        for tile in tiles:
            endpoint = tile["endpoint"]
            rows = [t for t in transfers if t["role"] == "source" and
                    t["phase"] == 1 and t["endpoint"] == endpoint]
            target = case["source_destination_map"][endpoint]
            if (len(rows) != 32 or any(t["direction"] != "read" or t["beats"] != 1 or
                    t["size"] != 3 or t["useful_bytes"] != 8 or t["addr"] >> 32 != target for t in rows)):
                raise ValueError("Expected 32 single-beat reads per source at the saved destination")
            first = min(t["request_ps"] for t in rows)
            last = max(t["request_ps"] for t in rows)
            period = record["clock"]["axi_period_ps"]
            sources.append(dict(pattern=pattern, run=os.path.relpath(str(root), str(output)),
                injection_ratio=ratio, endpoint=endpoint, x=tile["x"], y=tile["y"],
                transfers=len(rows), first_ar_ns=first / 1000, last_ar_ns=last / 1000,
                last_r_ns=max(t["completion_ps"] for t in rows) / 1000,
                mean_latency_cycles=tile["directions"]["read"]["mean_first_response_latency_cycles"],
                actual_injection_ratio=(len(rows) - 1) * period / (last - first)))
        measured = sources[begin:]
        points.append(dict(pattern=pattern, run=os.path.relpath(str(root), str(output)),
            injection_ratio=ratio, mean_latency_cycles=sum(t["mean_latency_cycles"] for t in measured) / 16,
            actual_injection_ratio=sum(t["actual_injection_ratio"] for t in measured) / 16,
            source_tiles=16, reads_per_source=32, waveform_sha256=record["waveform"]["sha256"]))
    points.sort(key=lambda point: (list(TRAFFIC).index(point["pattern"]), point["injection_ratio"]))
    if len({(point["pattern"], point["injection_ratio"]) for point in points}) != len(points):
        raise ValueError("Duplicate traffic/injection points")
    require_curve_grid(points, "injection_ratio", INJECTION_RATIOS)
    paths = [output / "figures/latency.png", output / "figures/latency.svg",
             output / "tables/latency.csv", output / "tables/latency-sources.csv",
             output / "provenance/latency-plot.json"]
    if any(path.exists() for path in paths):
        raise ValueError("Refuse to overwrite existing latency artifacts")
    for path in paths:
        path.parent.mkdir(parents=True, exist_ok=True)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(6.4, 4.5))
    for pattern, (label, color, marker) in TRAFFIC.items():
        curve = [point for point in points if point["pattern"] == pattern]
        if curve:
            ax.plot([p["injection_ratio"] for p in curve], [p["mean_latency_cycles"] for p in curve],
                    color=color, linestyle="-", marker=marker, markerfacecolor=color,
                    markersize=5.5, markeredgewidth=1.2, linewidth=1.7, label=label, clip_on=False)
    ax.set(xlabel="Injection Ratio", ylabel="Avg. Lat. [cycles]", xlim=(0, 0.5), ylim=(0, None))
    ax.legend(frameon=False)
    ax.grid(True, linestyle="--", alpha=0.35)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    fig.tight_layout()
    fig.savefig(str(paths[0]), dpi=180)
    fig.savefig(str(paths[1]))
    plt.close(fig)
    for path, rows in ((paths[2], points), (paths[3], sources)):
        with path.open("x", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
    paths[4].write_text(json.dumps(dict(command=[sys.executable] + sys.argv,
        script_sha256=digest(Path(__file__)), reference="arXiv:2409.17606v2 Fig.8",
        metric="Unweighted mean of per-source AR handshake to first R handshake latency",
        injection="Positive configured Bernoulli parameter; x=0 is the isolated zero-load limit, not a literal zero sending rate; realized AR interarrival ratios in CSV",
        required_injection_ratios=list(INJECTION_RATIOS),
        differences=["Native 4x4/VIP platform", "Paper adds 7 cluster cycles; native values use AXI boundaries",
                     "Public candidate driver quantizes probability through an integer draw in [0,100]",
                     "Exact experiment RTL revision is unverified"], points=points,
        publication_result=False), indent=2) + "\n")
    print("Saved latency PNG/SVG and tables under", output)


def sampled_handshakes(path, bindings):
    """Read pre-edge handshakes and VALID assertions (bindings with no READY)."""
    scope, signals, values = [], {}, {}
    events = {name: [] for name in bindings}
    with path.open() as stream:
        header = []
        for line in stream:
            header.append(line)
            fields = line.split()
            if not fields:
                continue
            if fields[0] == "$scope":
                scope.append(fields[2])
            elif fields[0] == "$upscope":
                scope.pop()
            elif fields[0] == "$var":
                # fsdb2vcd writes unpacked indices and packed ranges together.
                indices = "".join(re.findall(r"\[\d+\]", "".join(fields[5:-1])))
                signals[".".join(scope + [fields[4] + indices])] = (fields[3], int(fields[2]))
            elif fields[0] == "$enddefinitions":
                break
        if "1ps" not in "".join(header).replace(" ", ""):
            raise ValueError("Tile timeline requires a 1ps VCD timescale")
        domains = {"axi": ("tb_top.clk", "tb_top.axi_rst_n"),
                   "noc": ("tb_top.noc_clk", "tb_top.noc_rst_n")}
        names = {name for clock_reset in domains.values() for name in clock_reset}
        names.update(signal for _, valid, ready, _ in bindings.values()
                     for signal in (valid, ready) if signal is not None)
        wanted = {signals[name][0] for name in names}

        def value(name, bit=None):
            code, width = signals[name]
            raw = values.get(code, "x")
            if bit is not None:
                raw = raw.rjust(width, raw[0] if raw[0].lower() in "xz" else "0")[-1-bit]
            if any(c in raw.lower() for c in "xz"):
                raise ValueError("Unknown sampled value: " + name)
            return int(raw, 2)

        def sample(time, updates):
            for name, (domain, valid, ready, bit) in bindings.items():
                clock, reset = domains[domain]
                if values.get(signals[reset][0]) != "1":
                    continue
                if ready is None:
                    valid_code = signals[valid][0]
                    if values.get(valid_code) == "0" and updates.get(valid_code) == "1":
                        events[name].append(dict(time_ps=time, mask=1))
                    continue
                clock_code = signals[clock][0]
                if values.get(clock_code) == "0" and updates.get(clock_code) == "1":
                    mask = value(valid, bit)
                    if mask:
                        mask &= value(ready, bit)
                        if mask:
                            events[name].append(dict(time_ps=time, mask=mask))
            values.update(updates)

        time, updates = 0, {}
        for line in stream:
            line = line.strip()
            if not line or line.startswith("$"):
                continue
            if line.startswith("#"):
                sample(time, updates)
                time, updates = int(line[1:]), {}
            elif line[0] in "bB":
                raw, code = line[1:].split()
                if code in wanted:
                    updates[code] = raw
            elif line[0] in "01xXzZ" and line[1:] in wanted:
                updates[line[1:]] = line[0]
        sample(time, updates)
    return events


def tile_to_tile(root):
    """FlooNoC Fig.7 presentation, with native AXI/NI/router boundaries."""
    root = root.resolve()
    case = "perf_ctrl_read_neighbor"
    run = root / "runs" / case
    record = json.loads((run / (case + ".run.json")).read_text())
    transfers = json.loads((root / "tables/transactions.json").read_text())
    source = [t for t in transfers if t["role"] == "source" and t["phase"] == 1]
    device = [t for t in transfers if t["role"] == "device"]
    if (not record["passed"] or len(transfers) != 2 or len(source) != 1 or len(device) != 1 or
            source[0]["endpoint"] != 0 or device[0]["endpoint"] != 1 or
            any(t["direction"] != "read" or t["useful_bytes"] != 8 or t["beats"] != 1 or t["size"] != 3 for t in transfers) or
            source[0]["addr"] != device[0]["addr"]):
        raise ValueError("Fig.7 requires an isolated NI0-to-NI1 single-beat 64-bit read")
    clock = record["clock"]
    period = clock["axi_period_ps"]
    if period != clock["noc_period_ps"] or clock["noc_phase_ps"] != 0:
        raise ValueError("This timeline requires aligned native AXI/NoC clocks")
    outputs = [root / "figures/tile-to-tile.png", root / "figures/tile-to-tile.svg",
               root / "tables/tile-to-tile-events.csv", root / "tables/tile-to-tile-breakdown.csv",
               root / "tables/tile-to-tile.json", root / "provenance/tile-to-tile-plot.json"]
    if any(path.exists() for path in outputs):
        raise ValueError("Refuse to overwrite existing tile-to-tile artifacts")
    wave = run / (case + ".fsdb")
    if not wave.stat().st_size or digest(wave) != record["waveform"]["sha256"]:
        raise ValueError("FSDB does not match the actual run")
    vcd, export = run / "tile-to-tile.vcd", root / "provenance/tile-to-tile-export.json"
    if not vcd.exists():
        command = ["fsdb2vcd", str(wave), "-o", str(vcd), "-s", "/tb_top", "-level", "3"]
        with (run / "tile-to-tile-export.log").open("x") as log:
            subprocess.check_call(command, cwd=str(run), stdout=log, stderr=subprocess.STDOUT)
        export.write_text(json.dumps(dict(command=command, fsdb_sha256=digest(wave), vcd_sha256=digest(vcd)), indent=2) + "\n")
    exported = json.loads(export.read_text())
    if exported["fsdb_sha256"] != digest(wave) or exported["vcd_sha256"] != digest(vcd):
        raise ValueError("Cached VCD provenance mismatch")
    # Physical router vectors use Local,N,E,S,W; native EAST/WEST bits are 2/4.
    pkg = (root / "provenance/source/define/noc_unit_params_pkg.sv").read_text()
    if any(not re.search(r"\b"+name+r":\s*return\s+"+str(bit)+r";", pkg)
           for name, bit in (("LOCAL", 0), ("EAST", 2), ("WEST", 4))):
        raise ValueError("Router physical port mapping changed")
    bindings = {}
    for name, endpoint, channel in (("source_ar", 0, "ar"), ("source_r", 0, "r"),
                                     ("target_ar", 1, "ar"), ("target_r", 1, "r")):
        role = "source_bus" if name.startswith("source") else "device_bus"
        base = "tb_top.gen_node[{}].{}.{}".format(endpoint, role, channel)
        bindings[name] = ("axi", base+"valid", base+"ready", None)
    for name, index, channel in (("source_req", 0, "req"), ("target_req", 3, "req"),
                                 ("target_rsp", 2, "rsp"), ("source_rsp", 1, "rsp")):
        base = "tb_top.noc_observe[{}].{}_".format(index, channel)
        bindings[name] = ("noc", base+"valid", base+"ready", None)
    for name, channel, direction, node, bit in (("r0_req_east", "req", "tx", 0, 2),
            ("r1_rsp_west", "rsp", "tx", 1, 4), ("r0_req_local", "req", "rx", 0, 0),
            ("r1_req_local", "req", "tx", 1, 0), ("r1_rsp_local", "rsp", "rx", 1, 0),
            ("r0_rsp_local", "rsp", "tx", 0, 0)):
        base = "tb_top.i_router.{}_{}_".format(direction, channel)
        bindings[name] = ("noc", base+"valid[{}]".format(node), base+"ready[{}]".format(node), bit)
    for channel in ("req", "rsp"):
        bindings["all_"+channel] = ("noc", "tb_top.rx_"+channel+"_valid", "tb_top.rx_"+channel+"_ready", None)
    for channel in ("source_ar", "source_r"):
        bindings[channel + "_valid"] = ("axi", bindings[channel][1], None, None)
    events = sampled_handshakes(vcd, bindings)
    if any(len(rows) != 1 for rows in events.values()):
        raise ValueError("Timeline is ambiguous: expected one event per boundary")
    times = {name: rows[0]["time_ps"] for name, rows in events.items()}
    if events["all_req"][0]["mask"] != 1 or events["all_rsp"][0]["mask"] != 2:
        raise ValueError("Unexpected additional source/target traffic")
    for a, b in (("source_req", "r0_req_local"), ("target_req", "r1_req_local"),
                 ("target_rsp", "r1_rsp_local"), ("source_rsp", "r0_rsp_local")):
        if times[a] != times[b]:
            raise ValueError("NI/router boundary disagreement")
    expected = dict(source_ar=source[0]["request_ps"], source_r=source[0]["completion_ps"],
                    target_ar=device[0]["request_ps"], target_r=device[0]["completion_ps"])
    if any(times[name] != time for name, time in expected.items()):
        raise ValueError("FSDB and collector AXI timestamps disagree")
    stages = [("Source AXI", "AXI/device", "AR", "source_ar_valid", "source_ar"),
              ("NI 0", "NI", "AR->REQ", "source_ar", "source_req"),
              ("Router 0", "Router", "REQ", "source_req", "r0_req_east"),
              ("Router 1", "Router", "REQ", "r0_req_east", "target_req"),
              ("NI 1", "NI", "REQ->AR", "target_req", "target_ar"),
              ("Device AXI", "AXI/device", "AR->R", "target_ar", "target_r"),
              ("NI 1", "NI", "R->RSP", "target_r", "target_rsp"),
              ("Router 1", "Router", "RSP", "target_rsp", "r1_rsp_west"),
              ("Router 0", "Router", "RSP", "r1_rsp_west", "source_rsp"),
              ("NI 0", "NI", "RSP→R", "source_rsp", "source_r_valid"),
              ("Source AXI", "AXI/device", "R", "source_r_valid", "source_r")]
    bars = []
    for lane, component, label, begin, end in stages:
        duration = (times[end] - times[begin]) / period
        if duration < 0 or not duration.is_integer():
            raise ValueError("Invalid stage timing")
        bars.append(dict(lane=lane, component=component, label=label, start_ns=times[begin] / 1000,
                         end_ns=times[end] / 1000, cycles=duration, begin_event=begin, end_event=end))
    start = times["source_ar_valid"]
    total = (times["source_r"] - start) / period
    axi_round_trip = (times["source_r"] - times["source_ar"]) / period
    if sum(bar["cycles"] for bar in bars) != total:
        raise ValueError("Stage durations do not sum to the measured round trip")
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch
    lanes = ["Source AXI", "NI 0", "Router 0", "Router 1", "NI 1", "Device AXI"]
    colors = {"AXI/device": "#E69F00", "NI": "#0072B2", "Router": "#4D4D4D"}
    fig, ax = plt.subplots(figsize=(8.4, 4.8))
    ax.axhspan(-0.5, 2.5, color="#ABABAB", alpha=0.18)
    previous = 0
    for bar in bars:
        row = lanes.index(bar["lane"])
        begin = (times[bar["begin_event"]] - start) / period
        if row != previous:
            ax.vlines(begin, min(previous,row), max(previous,row), colors="gray", linestyles="--", linewidth=0.8)
        if bar["cycles"]:
            ax.barh(row, bar["cycles"], left=begin, height=0.62, color=colors[bar["component"]])
            ax.text(begin+bar["cycles"]/2, row, bar["label"]+"\n{:g}".format(bar["cycles"]),
                    ha="center", va="center", color="black" if bar["component"] == "AXI/device" else "white", fontsize=9)
        else:
            ax.plot(begin, row, marker="D", color=colors[bar["component"]], markersize=5)
            ax.annotate(bar["label"]+": 0", (begin,row), xytext=(6,-14), textcoords="offset points", fontsize=8)
        previous = row
    ax.set(yticks=range(6), yticklabels=lanes, xlabel="Cycles",
           title="Tile-to-tile access latency",
           xlim=(-0.2,total+0.2), ylim=(5.6,-0.65))
    ax.set_xticks(sorted(set(range(0,int(total)+1,2)) | {int(total)}))
    ax.text(-0.18, 0.75, "Src tile", rotation=90, transform=ax.transAxes, ha="center", va="center")
    ax.text(-0.18, 0.25, "Dst tile", rotation=90, transform=ax.transAxes, ha="center", va="center")
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    fig.legend(handles=[Patch(color=color,label=name) for name,color in colors.items()],
               loc="lower center", bbox_to_anchor=(0.53,0.015), ncol=3, frameon=False, fontsize=9)
    fig.tight_layout(rect=(0.05,0.09,1,1))
    fig.savefig(str(outputs[0]),dpi=180)
    fig.savefig(str(outputs[1]))
    plt.close(fig)
    event_rows = [dict(event=name,time_ns=rows[0]["time_ps"] / 1000,mask=rows[0]["mask"],
                       clock_domain=bindings[name][0],valid_signal=bindings[name][1],
                       ready_signal=bindings[name][2],physical_port_bit=bindings[name][3]) for name,rows in events.items()]
    for path, rows in ((outputs[2],event_rows),(outputs[3],bars)):
        with path.open("x",newline="") as stream:
            writer=csv.DictWriter(stream,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
    data = dict(source=0,destination=1,source_xy=[0,0],destination_xy=[1,0],inter_router_edges=1,
                bytes=8,clock_period_ns=period / 1000,total_cycles=total,
                axi_round_trip_cycles=axi_round_trip,stages=bars,
                component_cycles={name:sum(b["cycles"] for b in bars if b["component"]==name) for name in colors},
                reference="FlooNoC arXiv:2409.17606v2 Fig.7; source archive plot_lat_gantt()",
                boundary="native source ARVALID assertion through source R acceptance; target is existing VIP",
                differences="Paper includes cluster/LSU and SPM interconnect costs; totals have different endpoint boundaries")
    outputs[4].write_text(json.dumps(data,indent=2)+"\n")
    outputs[5].write_text(json.dumps(dict(command=[sys.executable]+sys.argv,script_sha256=digest(Path(__file__)),
        fsdb_sha256=digest(wave),vcd_sha256=digest(vcd),collector_table_sha256=digest(root/"tables/transactions.json"),
        sampled="Source ARVALID and RVALID rising transitions and stable pre-edge valid & ready handshakes",
        total_cycles=total,axi_round_trip_cycles=axi_round_trip,publication_result=False),indent=2)+"\n")
    print("Saved Fig.7-style tile-to-tile PNG/SVG, events and stage tables under",root)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--results", nargs="+", type=Path)
    group.add_argument("--tile-to-tile", type=Path)
    group.add_argument("--latency-results", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, help="Directory for the combined traffic plots")
    args = parser.parse_args()
    if args.tile_to_tile:
        tile_to_tile(args.tile_to_tile)
    elif args.latency_results:
        if args.output is None:
            parser.error("--latency-results requires --output")
        narrow_curve(args.latency_results, args.output)
    else:
        if args.output is None:
            parser.error("--results requires --output")
        wide_curve(args.results, args.output)
