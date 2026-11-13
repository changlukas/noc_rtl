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
    clock_period_ns = context[1]["axi_period_ps"] / 1000
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
        display_unit="cycles", clock_period_ns=clock_period_ns,
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
    total_ns = total * period / 1000
    previous = 0
    for bar in bars:
        row = lanes.index(bar["lane"])
        begin = (times[bar["begin_event"]] - start) / 1000
        duration_ns = bar["end_ns"] - bar["start_ns"]
        if row != previous:
            ax.vlines(begin, min(previous,row), max(previous,row), colors="gray", linestyles="--", linewidth=0.8)
        if bar["cycles"]:
            ax.barh(row, duration_ns, left=begin, height=0.62, color=colors[bar["component"]])
            ax.text(begin+duration_ns/2, row, bar["label"]+"\n{:g}".format(duration_ns),
                    ha="center", va="center", color="black" if bar["component"] == "AXI/device" else "white", fontsize=9)
        else:
            ax.plot(begin, row, marker="D", color=colors[bar["component"]], markersize=5)
            ax.annotate(bar["label"]+": 0", (begin,row), xytext=(6,-14), textcoords="offset points", fontsize=8)
        previous = row
    ax.set(yticks=range(6), yticklabels=lanes, xlabel="Time [ns]",
           title="Tile-to-tile access latency",
           xlim=(-0.2,total_ns+0.2), ylim=(5.6,-0.65))
    ax.set_xticks(sorted(set(range(0,int(total_ns)+1,2)) | {total_ns}))
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
        total_cycles=total,axi_round_trip_cycles=axi_round_trip,display_unit="ns",publication_result=False),indent=2)+"\n")
    print("Saved Fig.7-style tile-to-tile PNG/SVG, events and stage tables under",root)



def interference_curve(roots, output):
    """Fig.5 native-platform narrow/wide measurements from archived AXI events."""
    points, source_rows, manifests = [], [], set()
    binaries, layouts, probe_requests = set(), set(), {}
    expected_grid = {(probe, direction, count)
                     for probe, counts in (("narrow", (0, 2, 4, 8, 16, 32)),
                                           ("wide", (0, 2, 4, 8, 16, 32, 64)))
                     for direction in ("uni", "bi") for count in counts}
    seen = set()
    for root in roots:
        run, = (root / "runs").iterdir()
        match = re.fullmatch(r"perf_(narrow|wide)_(uni|bi)_(\d+)", run.name)
        if not match:
            raise ValueError("Unexpected interference case: " + run.name)
        probe, direction, count = match.groups()
        count = int(count)
        key = probe, direction, count
        if key not in expected_grid or key in seen:
            raise ValueError("Unexpected or duplicate interference point: " + str(key))
        seen.add(key)
        record = json.loads((run / (run.name + ".run.json")).read_text())
        validation = json.loads((root / "validation.json").read_text())
        if not record["passed"] or not validation["checker_passed"] or not validation["drain"]:
            raise ValueError("Failed run: " + str(root))
        if (validation.get("offline_calibration_comparison") != "passed_against_this_run_FSDB" or
                validation.get("central_link_calibration", {}).get("status") != "passed_against_this_run_FSDB" or
                validation.get("marker_calibration", {}).get("status") != "passed_against_this_run_FSDB" or
                validation.get("input_reproduction") != "passed"):
            raise ValueError("Missing waveform/input calibration: " + str(root))
        wave = run / (run.name + ".fsdb")
        if digest(wave) != record["waveform"]["sha256"]:
            raise ValueError("FSDB hash mismatch")
        manifests.add(record["source_manifest_sha256"])
        binaries.add(record["binary_sha256"])
        period = record["clock"]["axi_period_ps"]
        if record["clock"] != dict(axi_period_ps=1000, noc_period_ps=1000, noc_phase_ps=0):
            raise ValueError("Unexpected interference clocks")
        groups = json.loads((root / "provenance/source/dv/config/cases.json").read_text())["groups"]
        case = next(c for c in groups["performance_interference"] if c["name"] == run.name)
        mapping = case["source_destination_map"]
        separate = mapping == [2, 3, 0, 1] + list(range(4, 16))
        if separate:
            layouts.add("separate-targets")
            probes = ([0] if direction == "uni" else [0, 2]) if probe == "narrow" else (
                      [1] if direction == "uni" else [1, 3])
            others = ([1] if direction == "uni" else [1, 3]) if probe == "narrow" else (
                     [0] if direction == "uni" else [0, 2])
            if (case.get("read_outstanding_limit") != 16 or
                    "+read_outstanding_limit=16" not in record["command"] or
                    validation.get("stimulus_outstanding_calibration", {}).get("limit") != 16):
                raise ValueError("Missing fixed stimulus outstanding limit")
        elif mapping == [3, 3, 0, 0] + list(range(4, 16)):
            layouts.add("shared-target")
            probes = [0] if direction == "uni" else [0, 3]
            others = [1] if direction == "uni" else [1, 2]
        else:
            raise ValueError("Unsupported interference endpoint map")
        backgrounds = others if count else []
        active = sorted(probes + backgrounds)
        if case["sources"] != active or case["operation"] != "read":
            raise ValueError("Incorrect sources or operation")
        transactions = json.loads((root / "tables/transactions.json").read_text())
        source = [r for r in transactions if r["role"] == "source" and r["phase"] == 1]
        devices = {r["addr"]: r for r in transactions if r["role"] == "device"}
        summary = json.loads((root / "tables/summary.json").read_text())
        tiles = {t["endpoint"]: t for t in summary["source_tiles"]}
        first_enabled = min(tiles[n]["monitor_window"]["first_enabled_sample_ps"] for n in active)
        all_done = max(tiles[n]["monitor_window"]["source_done_ps"] for n in active)
        cycles = (all_done - first_enabled) // period + 1
        latencies, probe_bytes = [], 0
        for endpoint in active:
            is_probe = endpoint in probes
            mode = probe if is_probe else ("wide" if probe == "narrow" else "narrow")
            number = (100 if probe == "narrow" else 16) if is_probe else count
            beats, size = (1, 3) if mode == "narrow" else (16, 6)
            destination = mapping[endpoint]
            rows = [r for r in source if r["endpoint"] == endpoint]
            if (len(rows) != number or case["source_destination_map"][endpoint] != destination or
                    any(r["direction"] != "read" or r["beats"] != beats or r["size"] != size or
                        r["id"] != 0 or r["addr"] >> 32 != destination for r in rows)):
                raise ValueError("Transaction condition mismatch: " + run.name)
            changes = {}
            for r in rows:
                changes[r["request_ps"]] = changes.get(r["request_ps"], 0) + 1
                changes[r["completion_ps"]] = changes.get(r["completion_ps"], 0) - 1
            outstanding = peak = 0
            for time in sorted(changes):
                outstanding += changes[time]
                peak = max(peak, outstanding)
            if outstanding != 0:
                raise ValueError("Undrained source")
            if separate:
                observed = validation["stimulus_outstanding_calibration"]["observed"]
                if peak > 16 or observed.get(str(endpoint)) != peak:
                    raise ValueError("Accepted outstanding limit mismatch")
            if is_probe:
                signature = [(r["addr"], r["id"], r["size"], r["beats"]) for r in rows]
                signature_key = probe, endpoint
                if probe_requests.setdefault(signature_key, signature) != signature:
                    raise ValueError("Probe requests changed across background counts")
            mean_ns = sum(r["first_response_latency_ps"] for r in rows) / number / 1000
            payload = sum(r["useful_bytes"] for r in rows)
            source_rows.append(dict(case=run.name, source=endpoint, destination=destination,
                workload="probe" if is_probe else "background", mode=mode, transactions=number,
                bytes=payload, first_ar_ns=min(r["request_ps"] for r in rows)/1000,
                last_ar_ns=max(r["request_ps"] for r in rows)/1000,
                first_r_ns=min(r["first_response_ps"] for r in rows)/1000,
                last_r_ns=max(r["completion_ps"] for r in rows)/1000,
                max_outstanding=peak, avg_latency_ns=mean_ns,
                source_done_ns=tiles[endpoint]["monitor_window"]["source_done_ps"]/1000,
                mean_request_segment_ns=sum(devices[r["addr"]]["request_ps"]-r["request_ps"]
                                            for r in rows)/number/1000,
                mean_target_axi_segment_ns=sum(devices[r["addr"]]["first_response_ps"]-
                                               devices[r["addr"]]["request_ps"] for r in rows)/number/1000,
                mean_response_segment_ns=sum(r["first_response_ps"]-
                                             devices[r["addr"]]["first_response_ps"] for r in rows)/number/1000,
                monitor_cycles=cycles, bw_util_percent=100*payload/((1 << size)*cycles)))
            if is_probe:
                latencies.extend(r["first_response_latency_ps"]/1000 for r in rows)
                probe_bytes += payload
        if len(source) != sum(r["transactions"] for r in source_rows if r["case"] == run.name):
            raise ValueError("Unexpected active source")
        points.append(dict(case=run.name, probe=probe, direction=direction,
            background_count=count, avg_latency_ns=sum(latencies)/len(latencies),
            avg_bw_util_percent=100*probe_bytes/((8 if probe=="narrow" else 64)*cycles*len(probes)),
            first_enabled_ns=first_enabled/1000, all_done_ns=all_done/1000, monitor_cycles=cycles))
    if seen != expected_grid or len(manifests) != 1 or len(binaries) != 1 or len(layouts) != 1:
        raise ValueError("Incomplete Fig.5 matrix or mixed builds/layouts: " + str(expected_grid-seen))
    points.sort(key=lambda p:(p["probe"],p["direction"],p["background_count"]))
    for directory in ("tables", "figures", "provenance"):
        (output/directory).mkdir(parents=True, exist_ok=True)
    for name, rows in (("points", points), ("sources", source_rows)):
        with (output/"tables"/(name+".csv")).open("w", newline="") as stream:
            writer=csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    for probe, name, field, xlabel, ylabel in (
            ("narrow", "latency", "avg_latency_ns", "Num. Wide Bursts", "Avg. Latency [ns]"),
            ("wide", "bandwidth", "avg_bw_util_percent", "Num. Narrow Transactions", "Avg. BW Util [%]")):
        fig, ax=plt.subplots(figsize=(5.2,3.4))
        counts=sorted({p["background_count"] for p in points if p["probe"]==probe})
        for direction, label, color, marker in (("uni","Unidirectional","#1665a8","o"),
                                                 ("bi","Bidirectional","#E69F00","s")):
            curve=sorted((p for p in points if p["probe"]==probe and p["direction"]==direction),
                         key=lambda p:p["background_count"])
            ax.plot(range(len(counts)),[p[field] for p in curve],color=color,marker=marker,
                    markersize=7 if direction=="uni" else 4, linewidth=1.4,
                    linestyle="-" if direction=="uni" else "--", label=label)
        ax.set_xticks(range(len(counts)))
        ax.set_xticklabels(counts)
        ax.set(xlabel=xlabel,ylabel=ylabel)
        if probe == "narrow":
            ax.set_ylim(bottom=0)
        else:
            ax.set_ylim(50, 100)
        ax.ticklabel_format(axis="y", style="plain", useOffset=False)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        ax.grid(axis="y",alpha=.2)
        ax.legend(frameon=False)
        fig.tight_layout()
        for suffix in ("png","svg"):
            fig.savefig(str(output/"figures"/(name+"."+suffix)),dpi=180)
        plt.close(fig)
    snapshot=output/"provenance/performance.py"
    snapshot.write_bytes(Path(__file__).read_bytes())
    (output/"provenance/plot.json").write_text(json.dumps(dict(
        command=[sys.executable]+sys.argv, script_sha256=digest(snapshot),
        compiled_source_manifest_sha256=next(iter(manifests)),
        binary_sha256=next(iter(binaries)), endpoint_layout=next(iter(layouts)),
        stimulus_read_outstanding_limit=16 if layouts=={"separate-targets"} else None,
        comparison_scope="Fig.5 workload shape on native platform; exact FlooNoC runtime reproduction unconfirmed",
        reference_differences=[
            "Native VIP reads, without DMA local writeback",
            ("Native 2-hop pairs with distinct target AXI ports and shared central edge, instead of candidate 2-chimney cut TB"
             if layouts=={"separate-targets"} else
             "Historical native 3-hop probes and 2-hop backgrounds share target AXI ports"),
            "Native common inclusive ENABLE-to-all-SOURCE_DONE window; candidate fixed 100ns startup/tail waits are absent",
            "Native bidirectional mean averages both probe endpoints; candidate script extracts monitor 0"],
        inputs={str(root):digest(root/"tables/transactions.json") for root in roots},
        grid_points=len(points),
        formula=dict(latency="mean(first accepted R - accepted AR), ns",
            utilization="100 * probe useful bytes / (probe port bytes per cycle * common enabled cycles * directions)",
            window="first enabled AXI edge through all active source sequence completions, inclusive"),
        reference="FlooNoC arXiv:2305.08562v2 Fig.5; native platform adaptation"),indent=2)+"\n")
    print("Saved 26 interference points and Fig.5-style PNG/SVG under",output)



CROSS_SIZES = (64, 128, 256, 512, 1024)
CROSS_ROI = (64, 576)


def cross_measurement(root, calibrated=True):
    """Accepted-AW cohort in a fixed half-open ROI, with every B followed to completion."""
    from collections import defaultdict
    run, = (root/"runs").iterdir()
    match = re.fullmatch(r"cross_(narrow_split|narrow_dat|split|dat|data)_(uni|bi)(?:_(64|128|256|512|1024))?",run.name)
    if not match:
        raise ValueError("Unknown cross case: "+run.name)
    kind,direction,payload = match.groups()
    payload = int(payload) if payload else None
    if (payload is None) != kind.startswith("narrow_"):
        raise ValueError("Cross size/kind mismatch")
    cfg = next(c for c in json.loads((root/"provenance/source/dv/config/cases.json").read_text())["groups"]["performance_cross"]
               if c["name"]==run.name)
    bulk = {0:3,4:7,8:11,12:15}
    small = {1:13,2:14}
    if direction=="bi":
        bulk.update({b:a for a,b in list(bulk.items())})
        small.update({b:a for a,b in list(small.items())})
    if kind.startswith("narrow_"):
        bulk = {}
    if kind=="data":
        small = {}
    mapping = dict(bulk)
    mapping.update(small)
    if cfg["sources"]!=sorted(mapping) or cfg["operation"]!="write" or cfg.get("write_outstanding_limit")!=16:
        raise ValueError("Cross source/operation/limit mismatch")
    record = json.loads((run/(run.name+".run.json")).read_text())
    validation = json.loads((root/"validation.json").read_text())
    if not record["passed"] or not validation["checker_passed"] or not validation["drain"]:
        raise ValueError("Failed cross simulation")
    if record["clock"]!=dict(axi_period_ps=1000,noc_period_ps=1000,noc_phase_ps=0):
        raise ValueError("Cross clocks changed")
    if "+write_outstanding_limit=16" not in record["command"]:
        raise ValueError("Missing write limit")
    if calibrated:
        for field in ("offline_calibration_comparison","input_reproduction"):
            expected = "passed_against_this_run_FSDB" if field=="offline_calibration_comparison" else "passed"
            if validation.get(field)!=expected:
                raise ValueError("Cross calibration incomplete: "+field)
        for field in ("marker_calibration","channel_calibration","write_cohort_calibration"):
            if validation.get(field,{}).get("status")!="passed_against_this_run_FSDB":
                raise ValueError("Cross calibration incomplete: "+field)
    wave = run/(run.name+".fsdb")
    if not wave.is_file() or not wave.stat().st_size or digest(wave)!=record["waveform"]["sha256"]:
        raise ValueError("Cross FSDB missing or changed")
    summary = json.loads((root/"tables/summary.json").read_text())
    tiles = {t["endpoint"]:t for t in summary["source_tiles"]}
    if set(tiles)!=set(mapping):
        raise ValueError("Cross active tiles mismatch")
    enable = {t["monitor_window"]["first_enabled_sample_ps"] for t in tiles.values()}
    if len(enable)!=1:
        raise ValueError("Cross enable edges differ")
    start = next(iter(enable))+CROSS_ROI[0]*1000
    end = next(iter(enable))+CROSS_ROI[1]*1000
    tx = json.loads((root/"tables/transactions.json").read_text())
    source = [t for t in tx if t["role"]=="source" and t["phase"]==1]
    if any(t["direction"]!="write" or t["phase"]!=1 for t in tx if t["role"]=="source"):
        raise ValueError("Cross includes non-measurement or read traffic")
    devices = defaultdict(list)
    for t in tx:
        if t["role"]=="device":
            devices[t["endpoint"]].append(t)
    events = list(csv.DictReader((run/"axi-events.csv").open()))
    source_rows,cohort_rows = [],[]
    signatures = {}
    counts = {}
    last_cohort_b = start
    for endpoint,destination in sorted(mapping.items()):
        is_small = endpoint in small
        mode = ("data" if kind in ("dat","narrow_dat") else "control") if is_small else "data"
        beats = 1 if is_small else payload//64
        beat_bytes = 8 if is_small else 64
        expected_count = 512 if is_small else (1024+beats)//(beats+1)
        work = cfg["source_overrides"][str(endpoint)]
        if (cfg["source_destination_map"][endpoint]!=destination or work["mode"]!=mode or
                work.get("beat_bytes")!=beat_bytes or work["burst_beats"]!=beats or work["count"]!=expected_count):
            raise ValueError("Cross workload config mismatch")
        own = sorted((t for t in source if t["endpoint"]==endpoint),key=lambda t:t["request_ps"])
        target = sorted(devices[destination],key=lambda t:t["request_ps"])
        if len(own)!=expected_count or len(target)!=expected_count:
            raise ValueError("Cross transaction counts differ")
        signatures[str(endpoint)] = []
        changes = defaultdict(int)
        pairs = []
        for index,(a,b) in enumerate(zip(own,target)):
            expected_size = 3 if is_small else 6
            if (a["id"]!=0 or a["beats"]!=beats or a["size"]!=expected_size or
                    a["useful_bytes"]!=beats*beat_bytes or a["addr"]>>32!=destination):
                raise ValueError("Cross AXI shape/bytes mismatch")
            offset = a["addr"]%(1<<32)
            if (offset>=0x2000000)!=(mode=="control"):
                raise ValueError("Cross SAM class changed")
            if any(a[k]!=b[k] for k in ("addr","user","beats","size","useful_bytes")):
                raise ValueError("Cross source/device AW FIFO mismatch")
            if not a["request_ps"]<=b["request_ps"]<=b["completion_ps"]<=a["completion_ps"]:
                raise ValueError("Cross timing segment order")
            changes[a["request_ps"]]+=1
            changes[a["completion_ps"]]-=1
            signatures[str(endpoint)].append((a["addr"],a["id"],a["size"],a["beats"],a["user"]))
            pairs.append((index,a,b))
        pending=peak=0
        for time in sorted(changes):
            pending+=changes[time]
            if pending<0:
                raise ValueError("Negative cross outstanding")
            peak=max(peak,pending)
        if pending or peak>16:
            raise ValueError("Cross outstanding violated")
        cohort = [(i,a,b) for i,a,b in pairs if start<=a["request_ps"]<end]
        if not cohort:
            raise ValueError("Empty cross AW cohort")
        counts[endpoint]=len(cohort)
        last_b = max(a["completion_ps"] for _,a,_ in cohort)
        last_cohort_b=max(last_cohort_b,last_b)
        w = [r for r in events if r["role"]=="source" and int(r["endpoint"])==endpoint and r["channel"]=="W"]
        times=sorted(int(r["time_ps"]) for r in w)
        if not times or not times[0]<start<end<times[-1]:
            raise ValueError("Source accepted W does not cover ROI")
        for r in events:
            if r["role"]=="source" and int(r["endpoint"])==endpoint and r["channel"]=="B" and int(r["resp"]):
                raise ValueError("Non-OKAY cross B")
        count=len(cohort)
        sums = [sum(b["request_ps"]-a["request_ps"] for _,a,b in cohort),
                sum(b["completion_ps"]-b["request_ps"] for _,a,b in cohort),
                sum(a["completion_ps"]-b["completion_ps"] for _,a,b in cohort)]
        source_rows.append(dict(case=run.name,source=endpoint,destination=destination,
          workload="small" if is_small else "bulk",mode=mode,transactions=expected_count,
          cohort_count=count,crossing_roi_end=sum(a["completion_ps"]>=end for _,a,_ in cohort),unfinished=0,
          avg_latency_ns=sum(a["latency_ps"] for _,a,_ in cohort)/count/1000,max_outstanding=peak,
          first_w_ns=times[0]/1000,last_w_ns=times[-1]/1000,cohort_last_b_ns=last_b/1000,
          roi_w_bytes=sum(bin(int(r["strb"],16)).count("1") for r in w if start<=int(r["time_ps"])<end),
          request_segment_ns=sums[0]/count/1000,target_segment_ns=sums[1]/count/1000,
          response_segment_ns=sums[2]/count/1000))
        for index,a,b in cohort:
            cohort_rows.append(dict(case=run.name,source=endpoint,destination=destination,index=index,
               workload="small" if is_small else "bulk",aw_ps=a["request_ps"],b_ps=a["completion_ps"],
               latency_ps=a["latency_ps"],crosses_roi_end=a["completion_ps"]>=end,
               device_aw_ps=b["request_ps"],device_b_ps=b["completion_ps"]))
    # Even the latest sampled B must see all streams still sending W.
    if any(r["first_w_ns"]*1000>=start or r["last_w_ns"]*1000<=last_cohort_b for r in source_rows):
        raise ValueError("A stream ended before sampled cohort drained")
    point=dict(case=run.name,kind=kind,direction=direction,burst_bytes=payload,
      roi_start_ns=start/1000,roi_end_ns=end/1000,cohort_last_b_ns=last_cohort_b/1000)
    for name in ("small","bulk"):
        rows=[r for r in cohort_rows if r["workload"]==name]
        point[name+"_samples"]=len(rows)
        point[name+"_latency_ns"]=sum(r["latency_ps"] for r in rows)/len(rows)/1000 if rows else None
    if len(source)!=sum(r["transactions"] for r in source_rows):
        raise ValueError("Unexpected cross source")
    return dict(point=point,sources=source_rows,cohort=cohort_rows,signatures=signatures,
                binary_sha256=record["binary_sha256"],manifest_sha256=record["source_manifest_sha256"],
                last_cohort_b_ps=last_cohort_b,roi_ps=[start,end])


def cross_curve(roots,output):
    results=[cross_measurement(root) for root in roots]
    points=[r["point"] for r in results]
    expected={("split","uni",size) for size in CROSS_SIZES}
    keys=[(p["kind"],p["direction"],p["burst_bytes"]) for p in points]
    if len(keys)!=len(set(keys)) or set(keys)!=expected:
        raise ValueError("Incomplete cross grid: "+str(expected-set(keys)))
    if len({r["manifest_sha256"] for r in results})!=1 or len({r["binary_sha256"] for r in results})!=1:
        raise ValueError("Cross mixed compiled builds")
    for source in (1,2):
        if len({json.dumps(r["signatures"][str(source)]) for r in results})!=1:
            raise ValueError("Small traffic changed across DAT burst sizes")
    output.mkdir(parents=True,exist_ok=True)
    for folder in ("tables","figures","provenance"):
        (output/folder).mkdir(exist_ok=True)
    for name,rows in (("points",points),("sources",[s for r in results for s in r["sources"]]),
                      ("cohort",[s for r in results for s in r["cohort"]])):
        with (output/"tables"/(name+".csv")).open("w",newline="") as f:
            w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig,ax=plt.subplots(figsize=(6.2,4.5))
    curve=sorted((p for p in points if p["kind"]=="split" and p["direction"]=="uni"),
                 key=lambda p:p["burst_bytes"])
    for work,label,color,marker in (("small","Narrow req","#2463A5","o"),
                                    ("bulk","DAT req","#D97706","s")):
        ax.plot(range(len(CROSS_SIZES)),[p[work+"_latency_ns"] for p in curve],
                label=label,color=color,marker=marker,markersize=6)
    ax.set_xticks(range(len(CROSS_SIZES)));ax.set_xticklabels(CROSS_SIZES)
    ax.set(xlabel="DAT Burst Size [B]",ylabel="Avg. Latency [ns]")
    ax.set_ylim(bottom=0)
    ax.ticklabel_format(axis="y",style="plain",useOffset=False)
    ax.spines["top"].set_visible(False);ax.spines["right"].set_visible(False)
    ax.grid(axis="y",alpha=.18)
    ax.legend(frameon=False)
    fig.tight_layout()
    for suffix in ("png","svg"):
        fig.savefig(str(output/"figures"/("latency."+suffix)),dpi=180)
    plt.close(fig)
    snapshot=output/"provenance/performance.py";snapshot.write_bytes(Path(__file__).read_bytes())
    (output/"provenance/plot.json").write_text(json.dumps(dict(
      command=[sys.executable]+sys.argv,script_sha256=digest(snapshot),cases=len(points),
      manifest_sha256=results[0]["manifest_sha256"],binary_sha256=results[0]["binary_sha256"],
      roi_cycles=CROSS_ROI,window="half-open from first ENABLE; AW cohort followed to every B",
      formula="mean(accepted B - accepted AW)/1000 [ns]; no completed-within-window truncation",
      diagnostic_bw="sum accepted source WSTRB bytes inside ROI only",
      cases_and_transactions={str(root):digest(root/"tables/transactions.json") for root in roots},
      geometry="4 row bulk writes, 2 straight middle-column small writes; corner nodes bulk only; all-node version pending",
      mapping="Small writes AW/W on REQ, bulk writes AW/W on DAT; B responses on RSP",
      reference_scope="Native cross traffic and actual burst-size sweep; not exact FlooNoC Fig.5 runtime or full wide-only hardware",
      plotted_cases=[p["case"] for p in curve],
      plotted_series={"Narrow req":"small_latency_ns","DAT req":"bulk_latency_ns"},
      plotted_workload="Single-direction split mapping: small on REQ/RSP, bulk on DAT; one axes, two series",
      traffic="Four left-to-right rows and two straight top-to-bottom columns"),
      indent=2)+"\n")
    print("Saved cross-traffic tables and two-series latency PNG/SVG under",output)


def boundary_measurement(root, calibrated=True):
    from collections import defaultdict, deque
    run, = (root/"runs").iterdir()
    match = re.fullmatch(r"boundary_(read|narrow)_(full|zero_(\d+))", run.name)
    if not match:
        raise ValueError("Unexpected boundary case")
    kind, load, isolated = match.groups()
    load = "full" if load == "full" else "zero"
    active = list(range(16 if kind == "read" else 15)) if load == "full" else [int(isolated)]
    count, beats, size, limit = (32, 64, 6, 16) if kind == "read" else (100, 1, 3, 1)
    cfg = next(c for c in json.loads((root/"provenance/source/dv/config/cases.json").read_text())["groups"]["performance_boundary"] if c["name"] == run.name)
    expected_map = [16+i//4 for i in range(16)]+list(range(16,20)) if kind == "read" else [15]*16
    if (cfg["sources"] != active or cfg["count"] != count or cfg["operation"] != "read" or
            cfg["source_destination_map"] != expected_map or cfg["read_outstanding_limit"] != limit or
            cfg["mode"] != ("data" if kind == "read" else "control")):
        raise ValueError("Boundary workload mismatch")
    record = json.loads((run/(run.name+".run.json")).read_text())
    validation = json.loads((root/"validation.json").read_text())
    if not record["passed"] or not validation["checker_passed"] or not validation["drain"]:
        raise ValueError("Failed boundary run")
    if record["clock"] != dict(axi_period_ps=1000,noc_period_ps=1000,noc_phase_ps=0) or record["seed"] != 1:
        raise ValueError("Boundary clock/seed changed")
    if "+read_outstanding_limit="+str(limit) not in record["command"]:
        raise ValueError("Missing boundary outstanding limit")
    if any(a.startswith(("+response_hold", "+response_delay_port=", "+request_random_delay",
                         "+response_random_delay", "+source_response_hold", "+injection_ratio", "+zero_load")) for a in record["command"]):
        raise ValueError("Boundary service or injection changed")
    wave = run/(run.name+".fsdb")
    if not wave.is_file() or not wave.stat().st_size or digest(wave) != record["waveform"]["sha256"]:
        raise ValueError("Boundary waveform missing or changed")
    if digest(root/"provenance/SHA256SUMS") != record["source_manifest_sha256"]:
        raise ValueError("Boundary source manifest changed")
    if calibrated:
        if validation.get("input_reproduction") != "passed" or validation.get("offline_calibration_comparison") != "passed_against_this_run_FSDB":
            raise ValueError("Boundary input/AXI calibration incomplete")
        for field in ("marker_calibration", "channel_calibration", "job_window_calibration"):
            if validation.get(field,{}).get("status") != "passed_against_this_run_FSDB":
                raise ValueError("Boundary calibration incomplete")
    if json.loads((root/"tables/summary.json").read_text()) != record["performance"]:
        raise ValueError("Boundary summary changed")
    tx = json.loads((root/"tables/transactions.json").read_text())
    source = [r for r in tx if r["role"]=="source" and r["phase"]==1]
    if len(source) != len(active)*count or any(r["phase"]!=1 for r in tx if r["role"]=="source"):
        raise ValueError("Boundary transaction count/phase mismatch")
    start = min(r["request_ps"] for r in source)
    last = max(r["completion_ps"] for r in source)
    if (last-start)%1000:
        raise ValueError("Non-integral boundary job window")
    cycles = (last-start)//1000+1
    devices = defaultdict(deque)
    for r in sorted((r for r in tx if r["role"]=="device"),key=lambda r:r["request_ps"]):
        devices[(r["endpoint"],r["addr"],r["beats"],r["size"])].append(r)
    with (run/"axi-events.csv").open() as stream:
        raw = list(csv.DictReader(stream))
    rows, signatures, windows = [], {}, []
    for endpoint in active:
        current = sorted((r for r in source if r["endpoint"]==endpoint),key=lambda r:r["request_ps"])
        if len(current)!=count:
            raise ValueError("Boundary source sample count mismatch")
        base = (0x1000000000+(endpoint//4)*0x100000+(endpoint%4)*0x20000 if kind=="read"
                else 15*0x100000000+0x2000000+endpoint*0x100)
        for i,r in enumerate(current):
            expected_addr = base+(i*4096 if kind=="read" else (i%32)*8)
            if (r["direction"]!="read" or r["id"]!=0 or r["beats"]!=beats or r["size"]!=size or
                    r["addr"]!=expected_addr or r["useful_bytes"]!=beats*(1<<size) or
                    r["latency_ps"]!=r["completion_ps"]-r["request_ps"]):
                raise ValueError("Boundary accepted request differs from workload")
            device = devices[(expected_map[endpoint],r["addr"],beats,size)].popleft()
            if not r["request_ps"]<=device["request_ps"]<=device["completion_ps"]<=r["completion_ps"]:
                raise ValueError("Boundary device/source pairing timing mismatch")
            if device["useful_bytes"]!=r["useful_bytes"]:
                raise ValueError("Boundary device/source payload mismatch")
        changes = defaultdict(int)
        for r in raw:
            if r["role"]=="source" and int(r["endpoint"])==endpoint and int(r["phase"])==1:
                if r["channel"]=="AR": changes[int(r["time_ps"])]+=1
                if r["channel"]=="R" and int(r["last"]): changes[int(r["time_ps"])]-=1
        outstanding, peak = 0,0
        for t in sorted(changes):
            outstanding += changes[t]
            if outstanding<0: raise ValueError("Boundary response without request")
            peak=max(peak,outstanding)
        if outstanding or not 1<=peak<=limit:
            raise ValueError("Boundary outstanding/drain mismatch")
        first, end = current[0]["request_ps"],max(r["completion_ps"] for r in current)
        windows.append((first,end))
        useful=sum(r["useful_bytes"] for r in current)
        source_cycles=(end-first)//1000+1
        rows.append(dict(case=run.name,kind=kind,load=load,source=endpoint,x=endpoint%4,y=endpoint//4,
            target=expected_map[endpoint],transactions=count,useful_bytes=useful,first_ar_ns=first/1000,
            last_r_ns=end/1000,source_cycles=source_cycles,common_start_ns=start/1000,common_last_r_ns=last/1000,common_cycles=cycles,
            mean_latency_ns=sum(r["latency_ps"] for r in current)/count/1000,max_outstanding=peak,
            read_gb_s=useful/source_cycles if kind=="read" else None,
            bw_util_percent=useful/(64*source_cycles)*100 if kind=="read" else None))
        signatures[endpoint]=[(r["id"],r["addr"],r["beats"],r["size"],r["user"]) for r in current]
    if any(devices.values()):
        raise ValueError("Unmatched boundary device requests")
    if max(w[0] for w in windows)-min(w[0] for w in windows)>1000:
        raise ValueError("Boundary full sources did not launch together")
    device_rows = []
    if kind=="read":
        for endpoint in sorted({expected_map[n] for n in active}):
            accepted=[r for r in raw if r["role"]=="device" and int(r["endpoint"])==endpoint and r["channel"]=="R"]
            if any(not start<=int(r["time_ps"])<=last for r in accepted):
                raise ValueError("Device R outside common job window")
            useful=len(accepted)*64
            attributed=sum(r["useful_bytes"] for r in rows if r["target"]==endpoint)
            if useful!=attributed:
                raise ValueError("Memory/tile byte conservation failed")
            device_rows.append(dict(case=run.name,load=load,memory=endpoint,row=endpoint-16,
                useful_bytes=useful,common_start_ns=start/1000,common_last_r_ns=last/1000,
                common_cycles=cycles,read_gb_s=useful/cycles,bw_util_percent=useful/(64*cycles)*100))
    if any(not 0<=r["bw_util_percent"]<=100 for r in rows+device_rows if r["bw_util_percent"] is not None):
        raise ValueError("Boundary bandwidth exceeds calibrated peak")
    return dict(point=dict(case=run.name,kind=kind,load=load,isolated_source=int(isolated) if isolated is not None else None,
        sources=len(active),transactions=len(source),useful_bytes=sum(r["useful_bytes"] for r in source),
        common_start_ns=start/1000,common_last_r_ns=last/1000,common_cycles=cycles,
        overlap_start_ns=max(w[0] for w in windows)/1000,overlap_end_ns=min(w[1] for w in windows)/1000),
        sources=rows,devices=device_rows,signatures=signatures,
        binary_sha256=record["binary_sha256"],source_manifest_sha256=record["source_manifest_sha256"])


def boundary_plots(roots, output):
    import math
    from copy import copy
    expected = {("read","zero",n) for n in range(16)} | {("narrow","zero",n) for n in range(15)}
    expected |= {("read","full",None),("narrow","full",None)}
    results = [boundary_measurement(root) for root in roots]
    keys = [(r["point"]["kind"],r["point"]["load"],r["point"]["isolated_source"]) for r in results]
    if len(keys)!=len(set(keys)) or set(keys)!=expected:
        raise ValueError("Incomplete boundary grid: "+str(expected-set(keys)))
    if len({(r["binary_sha256"],r["source_manifest_sha256"]) for r in results})!=1:
        raise ValueError("Boundary plots mix compiled builds")
    lookup = {key:r for key,r in zip(keys,results)}
    for kind in ("read","narrow"):
        full = lookup[(kind,"full",None)]
        for source,signature in full["signatures"].items():
            if signature != lookup[(kind,"zero",source)]["signatures"][source]:
                raise ValueError("Zero/full boundary requests differ")
    for folder in ("tables","figures","provenance"):
        (output/folder).mkdir(parents=True,exist_ok=True)
    for name,rows in (("points",[r["point"] for r in results]),
                      ("sources",[row for r in results for row in r["sources"]]),
                      ("devices",[row for r in results for row in r["devices"]])):
        with (output/"tables"/(name+".csv")).open("w",newline="") as stream:
            writer=csv.DictWriter(stream,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    for kind,field,label,cmap_name,name in (("read","bw_util_percent","Avg. BW Util [%]","Blues","bandwidth"),
                                           ("narrow","mean_latency_ns","Avg. Latency [ns]","YlOrBr","latency")):
        maximum = 100 if kind=="read" else math.ceil(max(row[field] for r in results if r["point"]["kind"]==kind for row in r["sources"]))
        cmap=copy(plt.get_cmap(cmap_name))
        cmap.set_bad("#E4E4E4")
        fig,axes=plt.subplots(1,2,figsize=(8.8,4.4))
        for ax,load,title in zip(axes,("zero","full"),("Zero-load","Full-load")):
            matrix=np.full((4,4),np.nan)
            group=[r for r in results if r["point"]["kind"]==kind and r["point"]["load"]==load]
            for result in group:
                for row in result["sources"]:
                    if not np.isnan(matrix[row["y"],row["x"]]):
                        raise ValueError("Duplicate boundary heatmap tile")
                    matrix[row["y"],row["x"]]=row[field]
            image=ax.imshow(matrix,origin="lower",vmin=0,vmax=maximum,cmap=cmap)
            for source in range(16):
                x,y=source%4,source//4;value=matrix[y,x]
                content="N/A" if np.isnan(value) else format(value,".1f" if kind=="read" else ".2f")
                rgba=cmap(0 if np.isnan(value) else value/maximum)
                color="black" if np.isnan(value) or sum(a*b for a,b in zip(rgba,(.299,.587,.114)))>.55 else "white"
                ax.text(x,y,"NI"+str(source)+"\n"+content,ha="center",va="center",fontsize=10,color=color)
            ax.set_title(title,fontsize=12)
            ax.set_xticks([]);ax.set_yticks([])
            for spine in ax.spines.values():spine.set_visible(False)
            ax.set_xticks(np.arange(-.5,4,1),minor=True);ax.set_yticks(np.arange(-.5,4,1),minor=True)
            ax.grid(which="minor",color="white",linewidth=1.5);ax.tick_params(which="minor",bottom=False,left=False)
        fig.subplots_adjust(left=.02,right=.87,bottom=.02,top=.92,wspace=.08)
        bar=fig.colorbar(image,cax=fig.add_axes([.90,.15,.025,.65]))
        bar.set_label(label)
        for suffix in ("png","svg"):
            fig.savefig(str(output/"figures"/(name+"."+suffix)),dpi=180)
        plt.close(fig)
    snapshot=output/"provenance/performance.py";snapshot.write_bytes(Path(__file__).read_bytes())
    (output/"provenance/plot.json").write_text(json.dumps(dict(
        command=[sys.executable]+sys.argv,script_sha256=digest(snapshot),cases=len(results),
        source_rows=sum(len(r["sources"]) for r in results),device_rows=sum(len(r["devices"]) for r in results),
        binary_sha256=results[0]["binary_sha256"],source_manifest_sha256=results[0]["source_manifest_sha256"],
        common_cycles="(latest source RLAST-earliest source AR)/1000+1; memory device aggregate window",
        source_cycles="(own source lastRLAST-own firstAR)/1000+1; per-tile BW window, as paper per-hart cycle normalization",
        tile_util_percent="source useful R bytes/(64*source_cycles)*100; each source own firstAR through own lastRLAST including edge cycles; memory-channel peak",
        device_util_percent="device accepted R bytes in the same window/(64*common_cycles)*100",
        latency_ns="mean(accepted source RLAST-accepted AR)/1000 for every transaction; no truncation or CPU correction",
        full_load="All sources start together, finite batches; source windows/overlap are in CSV, not steady-state",
        zero_load="Separate single-source runs; heatmap collage is not one simultaneous aggregate",
        window_scope="Each tile uses its own job window, as paper per-hart cycles; memory devices use one common per-run window. Do not sum tile percentages across different windows",
        geometry="Native y increases upwards; sourceID=y*4+x; memory16+y west; narrow target15 is N/A, BW15 measured",
        reference="FlooNoC2025 Fig11; source scripts select32x4096B fromHBM; narrow num_iters100",
        timing_evidence_boundary="Paper normalizes each hart separately; original benchmark section start/end markers are unavailable. Native firstAR through lastRLAST is not proven identical to paper cycles",
        differences="Native4x4/ideal64GB/s VIP/oneAXI source per tile/limits16,1/AXI timing versus8x4/HBM57.6GB/s/9cores/full core trace minus3cycles",
        reference_files={str(p.relative_to(output)):digest(p) for p in (output/"provenance/reference").rglob("*") if p.is_file()},
        transactions={str(root):digest(root/"tables/transactions.json") for root in roots},
        publication_result=False),indent=2)+"\n")
    print("Saved33-run boundary BW/latency heatmaps and62-source tables under",output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--results", nargs="+", type=Path)
    group.add_argument("--tile-to-tile", type=Path)
    group.add_argument("--latency-results", nargs="+", type=Path)
    group.add_argument("--interference-results", nargs="+", type=Path)
    group.add_argument("--cross-results", nargs="+", type=Path)
    group.add_argument("--boundary-results", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, help="Directory for the combined traffic plots")
    args = parser.parse_args()
    if args.boundary_results:
        if args.output is None:
            parser.error("--boundary-results requires --output")
        boundary_plots(args.boundary_results,args.output)
    elif args.cross_results:
        if args.output is None:
            parser.error("--cross-results requires --output")
        cross_curve(args.cross_results,args.output)
    elif args.interference_results:
        if args.output is None:
            parser.error("--interference-results requires --output")
        interference_curve(args.interference_results, args.output)
    elif args.tile_to_tile:
        tile_to_tile(args.tile_to_tile)
    elif args.latency_results:
        if args.output is None:
            parser.error("--latency-results requires --output")
        narrow_curve(args.latency_results, args.output)
    else:
        if args.output is None:
            parser.error("--results requires --output")
        wide_curve(args.results, args.output)
