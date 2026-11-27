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
    """Average the saved per-source narrow-read latencies."""
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


def sampled_handshakes(path, bindings, payloads=None):
    """Read pre-edge handshakes and VALID assertions (bindings with no READY).

    Payload fields may be signal names or (name, lsb, width, required_mask).
    Conditional slices avoid reading unknown bits from inactive FIFO heads.
    """
    scope, signals, values = [], {}, {}
    events = {name: [] for name in bindings}
    payloads = payloads or {}
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
        names.update(field if isinstance(field, str) else field[0]
                     for fields in payloads.values() for field in fields)
        wanted = {signals[name][0] for name in names}

        def value(name, bit=None, field_width=1):
            code, width = signals[name]
            raw = values.get(code, "x")
            if bit is not None:
                raw = raw.rjust(width, raw[0] if raw[0].lower() in "xz" else "0")
                raw = raw[width-bit-field_width:width-bit]
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
                            event = dict(time_ps=time, mask=mask)
                            if name in payloads:
                                event["payload"] = [
                                    value(field) if isinstance(field, str) else
                                    (value(*field[:3]) if mask & field[3] else None)
                                    for field in payloads[name]]
                            events[name].append(event)
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






def bandwidth_comparison(root):
    """Compare saved 32 KiB source averages with an equal-rate capacity reference."""
    from collections import Counter
    root = root.resolve()
    points = list(csv.DictReader((root/"tables/bandwidth.csv").open()))
    rows, evidence = [], []
    for pattern in TRAFFIC:
        point, = [r for r in points if r["pattern"]==pattern and int(r["transfer_bytes"])==32768]
        result = root/point["root"]
        run, = [r for r in (result/"runs").iterdir() if r.is_dir()]
        record_path = run/(run.name+".run.json")
        record = json.loads(record_path.read_text())
        summary_path = result/"tables/summary.json"
        summary = json.loads(summary_path.read_text())
        saved_pattern, config = traffic_case(result,run.name)
        wave = run/(run.name+".fsdb")
        if (saved_pattern != pattern or digest(wave) != point["waveform_sha256"] or
                digest(wave) != record["waveform"]["sha256"] or
                digest(summary_path) != point["summary_sha256"] or summary != record["performance"]):
            raise ValueError("Original measured case changed")
        if record["clock"] != dict(axi_period_ps=1000,noc_period_ps=1000,noc_phase_ps=0):
            raise ValueError("Expected the original aligned 1 GHz platform")
        tiles = summary["source_tiles"]
        if len(tiles)!=16 or {r["endpoint"] for r in tiles}!=set(range(16)):
            raise ValueError("Expected all sixteen source averages, including local accesses")
        utils=[]
        for tile in tiles:
            window=tile["monitor_window"]
            cycles=(window["source_done_ps"]-window["first_enabled_sample_ps"])//1000+1
            measured=tile["directions"]["read"]
            if measured["useful_bytes"]!=32768 or cycles!=window["cycles"]:
                raise ValueError("Per-source workload/window differs")
            util=100*32768/(64*cycles)
            if abs(util-measured["monitor_payload_utilization_percent"])>1e-9:
                raise ValueError("Per-source utilization differs")
            utils.append(util)
        mean=sum(utils)/16
        if abs(mean-float(point["mean_utilization_percent"]))>1e-9:
            raise ValueError("Original averaged bandwidth differs")
        links, injection, ejection = Counter(), Counter(), Counter()
        paths=[]
        mapping=config["source_destination_map"]
        for source,target in enumerate(mapping):
            node=target
            route=[node]
            injection[target]+=1
            ejection[source]+=1
            while node%4 != source%4:
                other=node+(1 if node%4<source%4 else -1)
                links[(node,other)]+=1
                node=other
                route.append(node)
            while node//4 != source//4:
                other=node+(4 if node//4<source//4 else -4)
                links[(node,other)]+=1
                node=other
                route.append(node)
            paths.append(dict(source=source,target=target,dat_nodes=route))
        inter=max(links.values(),default=0)
        inj=max(injection.values())
        eject=max(ejection.values())
        maximum=max(inter,inj,eject)
        rows.append(dict(pattern=pattern,transfer_bytes=32768,
            max_inter_router_flows=inter,max_ni_injection_flows=inj,max_ni_ejection_flows=eject,
            max_channel_load=maximum,local_accesses=sum(s==d for s,d in enumerate(mapping)),
            equal_rate_reference_percent=100/maximum,measured_percent=mean))
        evidence.append(dict(pattern=pattern,result=point["root"],case=run.name,
            command=record["command"],clock=record["clock"],seed=record["seed"],
            run_record_sha256=digest(record_path),summary_sha256=digest(summary_path),
            fsdb_sha256=digest(wave),source_manifest_sha256=point["source_manifest_sha256"],
            binary_sha256=point["binary_sha256"],config_sha256=digest(result/"provenance/config.json"),
            mapping=mapping,dat_paths=paths,
            inter_router_loads=[dict(start=a,end=b,flows=n) for (a,b),n in sorted(links.items())],
            ni_injection_loads=dict(injection),ni_ejection_loads=dict(ejection)))
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig,ax=plt.subplots(figsize=(9.2,4.8))
    centers=list(range(len(rows)))
    width=.36
    for shift,field,label,color in (
        (-width/2,"equal_rate_reference_percent","Equal-rate reference","#7B3294"),
        (width/2,"measured_percent","Measured (32 KiB/source)","#009E73")):
        bars=ax.bar([x+shift for x in centers],[r[field] for r in rows],width,
                    color=color,label=label,zorder=3)
        for bar,row in zip(bars,rows):
            value=row[field]
            ax.text(bar.get_x()+bar.get_width()/2,value+1.2,
                    "{:.2f}".format(value).rstrip("0").rstrip("."),
                    ha="center",va="bottom",fontsize=8)
    ax.set(xticks=centers,xticklabels=[TRAFFIC[r["pattern"]][0] for r in rows],
           ylabel="Avg. BW Util [%]",ylim=(0,108),yticks=(0,25,50,75,100))
    ax.grid(axis="y",color="#DDDDDD",linestyle="--",linewidth=.7)
    ax.set_axisbelow(True)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.legend(loc="upper center",bbox_to_anchor=(.5,1.13),ncol=2,frameon=False,fontsize=9)
    fig.tight_layout()
    outputs=[]
    for suffix in ("png","svg"):
        p=root/"figures"/("bandwidth-comparison."+suffix)
        fig.savefig(str(p),dpi=200)
        outputs.append(p)
    plt.close(fig)
    p=root/"tables/bandwidth-comparison.csv"
    with p.open("w",newline="") as stream:
        writer=csv.DictWriter(stream,fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    outputs.append(p)
    snapshot=root/"provenance/bandwidth-comparison-performance.py"
    snapshot.write_bytes(Path(__file__).read_bytes())
    outputs.append(snapshot)
    proof=dict(
        command=["python3","-B","-c",
                 "from pathlib import Path; from performance import bandwidth_comparison; bandwidth_comparison(Path('performance/unicast/mesh-traffic'))"],
        script_sha256=digest(snapshot),
        reference_figure="https://chatgpt.com/s/w_6afc1d796fb88191b6fbf6ae2af9fb20",
        input_table_sha256=digest(root/"tables/bandwidth.csv"),
        reference_formula="100 / max channel flow count; independent device-to-source XY paths; "
                          "one 64 B flit/cycle on each inter-router and local NI injection/ejection channel",
        reference_assumption="Every source has the same persistent achieved rate; excludes pipeline/queuing costs",
        measured_formula="mean_i(100*32768/(64*inclusive_ENABLE_to_SOURCE_DONE_cycles_i)), all 16 sources",
        interpretation="Equal-rate reference is not an upper bound on the measured finite-batch mean of "
                       "per-source own-window rates. Values above the reference do not violate channel capacity.",
        cases=evidence,outputs={str(p.relative_to(root)):digest(p) for p in outputs})
    (root/"provenance/bandwidth-comparison.json").write_text(json.dumps(proof,indent=2)+"\n")
    print("Saved five-pattern grouped bandwidth comparison",rows)


def contention_example(root):
    """Pair two DAT output paths with their actual per-cycle input requests."""
    root = root.resolve()
    proof_path = root/"provenance/contention.json"
    original = json.loads(proof_path.read_text())
    case = next(r for r in original["cases"] if r["pattern"] == "bit_complement")
    if (digest(Path(case["fsdb"])) != case["fsdb_sha256"] or
            digest(Path(case["vcd"])) != case["vcd_sha256"]):
        raise ValueError("Example waveform differs from the measured case")
    period = case["clock"]["noc_period_ps"]
    if period != 1000:
        raise ValueError("Expected the original 1 GHz case")
    first, last = 50, 69
    examples = [(4, 1, 8, ((7,8), (3,12))), (1, 2, 2, ((0,15), (1,14)))]
    keys = ["DAT_{}_{}".format(node,port) for node,port,_,_ in examples]
    bindings = {k: tuple(case["signal_bindings"][k]) for k in keys+["samples"]}
    payloads = {k: case["header_slices"][k] for k in keys}
    sampled = sampled_handshakes(Path(case["vcd"]),bindings,payloads)
    begin = case["begin_ps"]
    clocks = {(e["time_ps"]-begin)//period for e in sampled["samples"]}
    if not set(range(first,last+1)).issubset(clocks):
        raise ValueError("Missing sample clock edges in the selected interval")
    rows = []
    for node,port,other,flows in examples:
        key = "DAT_{}_{}".format(node,port)
        events = {(e["time_ps"]-begin)//period:e for e in sampled[key]}
        for cycle in range(first,last+1):
            e = events.get(cycle)
            mask = e["mask"] if e else 0
            active = []
            if e:
                for i in range(5):
                    if mask & (1 << i):
                        sx,sy,sp,dx,dy,dp,kind=e["payload"][i*7:(i+1)*7]
                        if sp or dp or kind != 9:
                            raise ValueError("Unexpected DAT endpoint or packet type")
                        active.append((4*sy+sx,4*dy+dx))
            if len(active) != len(set(active)) or set(active)-set(flows):
                raise ValueError("Unexpected/ambiguous flow at the selected output")
            rows.append(dict(router=node, output="North" if port==1 else "East",
                next_router=other, cycle=cycle, time_ps=begin+cycle*period, request_mask=mask,
                flow_a="{}>{}".format(*flows[0]), flow_a_request=int(flows[0] in active),
                flow_b="{}>{}".format(*flows[1]), flow_b_request=int(flows[1] in active),
                contention=int(bin(mask).count("1")>=2)))

    routes = list(csv.DictReader((root/"tables/contention-routes.csv").open()))
    colors = ("#1665A8","#E69F00")
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch
    fig = plt.figure(figsize=(14,9.0))
    grid = fig.add_gridspec(2,2,height_ratios=(3.8,1.25),hspace=.40,wspace=.34)
    for col,(node,port,other,flows) in enumerate(examples):
        ax = fig.add_subplot(grid[0,col])
        for n in range(16):
            x,y=n%4,n//4
            if x<3:ax.plot([x,x+1],[y,y],color="#DDDDDD",lw=1,zorder=0)
            if y<3:ax.plot([x,x],[y,y+1],color="#DDDDDD",lw=1,zorder=0)
            ax.scatter(x,y,s=620,facecolor="#EEEEEE" if n==node else "white",
                       edgecolor="#333333" if n==node else "#BBBBBB",
                       linewidth=2 if n==node else 1,zorder=4)
            ax.text(x,y,str(n),ha="center",va="center",fontsize=10,zorder=5)
        # A broad gray stroke identifies the selected physical output. The
        # flow arrows remain separate; gray does not assert contention.
        ax.plot([node%4,other%4],[node//4,other//4],color="#B7B7B7",lw=9,zorder=1)
        for j,(a,b) in enumerate(flows):
            matches=[r for r in routes if r["pattern"]=="bit_complement" and r["network"]=="DAT"
                     and int(r["flow_start"])==a and int(r["flow_end"])==b]
            if len(matches)!=1:raise ValueError("Expected one saved XY path per flow")
            nodes=[int(n) for n in matches[0]["router_path"].split(";")]
            if (node,other) not in list(zip(nodes,nodes[1:])):
                raise ValueError("Selected flow does not use the observed output")
            offset=(j-.5)*.075
            for n,m in zip(nodes,nodes[1:]):
                x,y=n%4,n//4
                xx,yy=m%4,m//4
                if y==yy:y+=offset;yy+=offset
                else:x+=offset;xx+=offset
                ax.annotate("",xy=(xx,yy),xytext=(x,y),
                    arrowprops=dict(arrowstyle="-|>",color=colors[j],lw=2.3,
                                    shrinkA=14,shrinkB=14),zorder=3)
        ax.set(title="Router{} to Router{} / DAT".format(node,other),aspect="equal",
               xlim=(-.3,3.3),ylim=(-.3,3.3),xticks=[],yticks=[])
        for spine in ax.spines.values():spine.set_visible(False)
        ax.legend(handles=[Patch(color=c,label="Node{} to Node{}".format(a,b))
                           for c,(a,b) in zip(colors,flows)],
                  loc="upper center",bbox_to_anchor=(.5,-.025),ncol=2,frameon=False,fontsize=9)
        ax=fig.add_subplot(grid[1,col])
        own=[r for r in rows if r["router"]==node]
        for lane,field,color in ((0,"flow_a_request",colors[0]),(1,"flow_b_request",colors[1]),
                                 (2,"contention","#B2182B")):
            ax.axhspan(lane-.34,lane+.34,color="#F1F1F1",zorder=0)
            for r in own:
                if r[field]:
                    ax.barh(lane,.88,left=r["cycle"]-.44,height=.58,color=color,linewidth=0)
        labels=["Node{} to Node{}".format(*flows[0]),"Node{} to Node{}".format(*flows[1]),"Both requests"]
        ax.set(yticks=(0,1,2),yticklabels=labels,ylim=(2.6,-.6),
               xticks=range(first,last+1),xlim=(first-.5,last+.5),
               xlabel="Time from ENABLE [cycles]")
        ax.tick_params(axis="x",labelsize=8,length=3)
        ax.tick_params(axis="y",labelsize=9,length=0)
        for label,color in zip(ax.get_yticklabels(),colors+("#B2182B",)):label.set_color(color)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        ax.spines["left"].set_visible(False)
    fig.subplots_adjust(left=.105,right=.98,top=.95,bottom=.09)
    outputs=[]
    for suffix in ("png","svg"):
        p=root/"figures"/("contention-example."+suffix)
        fig.savefig(str(p),dpi=200)
        outputs.append(p)
    plt.close(fig)
    p=root/"tables/contention-example.csv"
    with p.open("w",newline="") as stream:
        writer=csv.DictWriter(stream,fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    outputs.append(p)
    snapshot=root/"provenance/contention-example-performance.py"
    snapshot.write_bytes(Path(__file__).read_bytes())
    outputs.append(snapshot)
    evidence=dict(
        command=["python3","-B","-c",
                 "from pathlib import Path; from performance import contention_example; contention_example(Path('performance/unicast/mesh-traffic'))"],
        script_sha256=digest(snapshot),
        case={k:case[k] for k in ("pattern","result","case","clock","seed","run_record_sha256",
                                  "source_manifest_sha256","binary_sha256","fsdb","fsdb_sha256",
                                  "vcd","vcd_sha256","begin_ps")},
        signal_bindings=bindings,header_slices=payloads,
        first_cycle=first,last_cycle=last,
        selection="Illustrative comparison: Router4 North interleaved requests vs Router1 East simultaneous requests",
        meaning="Colored cells are active current input requests to the selected output, not accepted transfers; "
                "red is popcount(req)>=2. Gray mesh stroke identifies the selected link.",
        route_table_sha256=digest(root/"tables/contention-routes.csv"),
        contention_proof_sha256=digest(proof_path),
        outputs={str(p.relative_to(root)):digest(p) for p in outputs})
    (root/"provenance/contention-example.json").write_text(json.dumps(evidence,indent=2)+"\n")
    print("Saved two path/request examples:",len(rows),"samples; contention cycles",
          {node:sum(r["contention"] for r in rows if r["router"]==node) for node,_,_,_ in examples})


def contention_heatmap(root):
    """Count cycles of simultaneous demand at each router output in 32 KiB reads."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    root = root.resolve()
    repo = Path(__file__).resolve().parents[2]
    points = list(csv.DictReader((root/"tables/bandwidth.csv").open()))
    rows, cases = [], []
    networks = ("REQ", "DAT")
    patterns = ("neighbor", "bit_complement", "transpose", "uniform", "shuffle")
    bindings = {"edges": ("noc", "tb_top.noc_rst_n", "tb_top.noc_rst_n", None)}
    signals = ["tb_top.clk", "tb_top.axi_rst_n", "tb_top.noc_clk", "tb_top.noc_rst_n"]
    for node in range(16):
        for port in range(5):
            base = "tb_top.i_router.gen_router[{}].i_router".format(node)
            for net, suffix in (("REQ", ".i_req_router.gen_output[{}].req"),
                                ("DAT", ".i_dat_router.gen_output[{}].gen_vc[1].req")):
                signal = base + suffix.format(port)
                signals.append(signal)
                bindings[(net, node, port)] = ("noc", signal, signal, None)

    for pattern in patterns:
        point, = [r for r in points if r["pattern"] == pattern and int(r["transfer_bytes"]) == 32768]
        result = root/point["root"]
        run, = [path for path in (result/"runs").iterdir() if path.is_dir()]
        record_path = run/(run.name+".run.json")
        record = json.loads(record_path.read_text())
        summary = result/"tables/summary.json"
        wave = run/(run.name+".fsdb")
        if (digest(summary) != point["summary_sha256"] or
                digest(wave) != point["waveform_sha256"] or
                point["waveform_sha256"] != record["waveform"]["sha256"]):
            raise ValueError("Run inventory mismatch: "+pattern)
        tiles = json.loads(summary.read_text())["source_tiles"]
        begin, = {t["monitor_window"]["first_enabled_sample_ps"] for t in tiles}
        end = max(t["monitor_window"]["source_done_ps"] for t in tiles)
        period = record["clock"]["noc_period_ps"]
        if len(tiles) != 16 or period != 1000:
            raise ValueError("Unexpected mesh or clock")
        expected = range(begin, end+1, period)
        cache = repo/"build/contention"/run.name
        cache.mkdir(exist_ok=True, parents=True)
        vcd = cache/"heatmap.vcd"
        cmd = ["fsdb2vcd", str(wave), "-o", str(vcd), "-bt", "0ps", "-et",
               str(end+period)+"ps", "-keep_last_time", "-s"]
        cmd.extend("/"+name.replace(".", "/") for name in signals)
        with (cache/"heatmap-export.log").open("w") as log:
            subprocess.check_call(cmd, stdout=log, stderr=subprocess.STDOUT)
        samples = sampled_handshakes(vcd, bindings)
        if [e["time_ps"] for e in samples["edges"] if begin <= e["time_ps"] <= end] != list(expected):
            raise ValueError("Incomplete NoC clock coverage: "+pattern)
        for net in networks:
            for node in range(16):
                hits = {e["time_ps"] for port in range(5) for e in samples[(net,node,port)]
                        if e["time_ps"] in expected and bin(e["mask"]).count("1") >= 2}
                rows.append(dict(pattern=pattern, network=net, router=node,
                                 contention_cycles=len(hits), window_cycles=len(expected)))
        cases.append(dict(pattern=pattern, record=str(record_path.relative_to(root)),
                          record_sha256=digest(record_path), summary_sha256=digest(summary),
                          source_manifest_sha256=point["source_manifest_sha256"], seed=record["seed"],
                          fsdb_sha256=point["waveform_sha256"], export_command=cmd, vcd_sha256=digest(vcd)))
        print(pattern, len(expected), flush=True)

    counts = {(r["pattern"], r["network"], r["router"]): r["contention_cycles"] for r in rows}
    for r in csv.DictReader((root/"tables/contention.csv").open()):
        if counts[r["pattern"],r["network"],int(r["router"])] != int(r["contention_cycles"]):
            raise ValueError("Count differs from prior per-router trace")
    table = root/"tables/contention-32kib.csv"
    with table.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=("pattern","network","router","contention_cycles","window_cycles"))
        writer.writeheader()
        writer.writerows(rows)
    fig, axes = plt.subplots(2, 6, figsize=(16,6.2), constrained_layout=True,
                             gridspec_kw={"width_ratios":[1,1,1,1,1,.06]})
    for row, net in enumerate(networks):
        peak = max(r["contention_cycles"] for r in rows if r["network"] == net)
        for col, pattern in enumerate(patterns):
            ax = axes[row,col]
            values = [counts[pattern,net,node] for node in range(16)]
            im = ax.imshow(np.reshape(values,(4,4)), origin="lower", cmap="YlOrRd", vmin=0, vmax=max(1,peak))
            for node, value in enumerate(values):
                ax.text(node%4,node//4,str(value),ha="center",va="center",
                        color="white" if value > .6*peak else "#222222")
            ax.set(xticks=range(4), yticks=range(4), xlabel="x")
            if not col:
                ax.set_ylabel(net+"   y")
            if not row:
                ax.set_title(TRAFFIC[pattern][0])
        fig.colorbar(im,cax=axes[row,-1],label="Contention [cycles]")
    outputs = [table]
    for fmt in ("png","svg"):
        out = root/"figures"/("contention-32kib."+fmt)
        fig.savefig(str(out), dpi=200)
        outputs.append(out)
    plt.close(fig)
    snapshot = root/"provenance/contention-32kib-performance.py"
    snapshot.write_bytes(Path(__file__).read_bytes())
    outputs.append(snapshot)
    proof = dict(command="PYTHONPATH=build/perf_plot_deps/site-packages:dv/scripts MPLCONFIGDIR=build/perf_plot_deps/cache python3 -B -c \"from pathlib import Path; from performance import contention_heatmap; contention_heatmap(Path('performance/unicast/mesh-traffic'))\"",
                 cases=cases, outputs={str(p.relative_to(root)):digest(p) for p in outputs})
    (root/"provenance/contention-32kib.json").write_text(json.dumps(proof,indent=2)+"\n")


def router_contention(root):
    """Locate simultaneous output requests in two existing wide-read waveforms."""
    from collections import defaultdict
    root = root.resolve()
    repo = Path(__file__).resolve().parents[2]
    point_rows = list(csv.DictReader((root/"tables/bandwidth.csv").open()))
    source_rows = list(csv.DictReader((root/"tables/bandwidth-sources.csv").open()))
    points = [r for r in point_rows if r["pattern"] in ("neighbor", "bit_complement")
              and int(r["transfer_bytes"]) == 32768]
    if len(points) != 2:
        raise ValueError("Expected Neighbor and Bit-complement at 32 KiB")
    ports = ("Local", "North", "East", "South", "West")

    def path(start, target):
        result = []
        node = start
        while node % 4 != target % 4:
            step = 1 if node % 4 < target % 4 else -1
            result.append((node, 2 if step == 1 else 4))
            node += step
        while node // 4 != target // 4:
            step = 4 if node // 4 < target // 4 else -4
            result.append((node, 1 if step == 4 else 3))
            node += step
        return result+[(target, 0)]

    node_rows, port_rows, event_rows, evidence = [], [], [], []
    timelines, rois, pairings = {}, {}, {}
    for point in sorted(points, key=lambda r: r["pattern"]):
        result = root/point["root"]
        run, = [p for p in (result/"runs").iterdir() if p.is_dir()]
        record_path = run/(run.name+".run.json")
        record = json.loads(record_path.read_text())
        pattern, case = traffic_case(result, run.name)
        pairings[pattern] = case["source_destination_map"]
        if record["clock"] != dict(axi_period_ps=1000, noc_period_ps=1000, noc_phase_ps=0):
            raise ValueError("Only aligned 1 GHz saved cases are supported")
        window = [r for r in source_rows if r["pattern"] == pattern and int(r["transfer_bytes"]) == 32768]
        if len(window) != 16 or len({r["enable_ps"] for r in window}) != 1:
            raise ValueError("Expected sixteen sources with a common ENABLE")
        begin = int(window[0]["enable_ps"])
        end = max(int(r["done_ps"]) for r in window)
        length = (end-begin)//1000+1
        rois[pattern] = length
        wave = run/(run.name+".fsdb")
        wave_hash = digest(wave)
        if wave_hash != point["waveform_sha256"] or wave_hash != record["waveform"]["sha256"]:
            raise ValueError("FSDB differs from the saved case")
        cache = repo/"build/contention"/run.name
        cache.mkdir(parents=True, exist_ok=True)
        bindings, payloads = {}, {}
        selected = ["/tb_top/clk", "/tb_top/axi_rst_n", "/tb_top/noc_clk", "/tb_top/noc_rst_n"]
        expected_routes = defaultdict(set)
        for source, target in enumerate(case["source_destination_map"]):
            for net, a, b in (("REQ", source, target), ("DAT", target, source)):
                for node, port in path(a, b):
                    expected_routes[(net, node, port)].add((a, b))
        for node in range(16):
            base = "tb_top.i_router.gen_router[{}].i_router".format(node)
            for net in ("REQ", "DAT"):
                head = (base+".i_req_router.head" if net == "REQ" else
                        base+".i_dat_router.head")

                selected.append("/"+head.replace(".", "/"))
                for port in range(5):
                    scope = (base+".i_req_router.gen_output[{}]".format(port) if net == "REQ" else
                             base+".i_dat_router.gen_output[{}].gen_vc[1]".format(port))
                    request = scope+".req"
                    selected.append("/"+request.replace(".", "/"))
                    key = "{}_{}_{}".format(net, node, port)
                    # req is a 5-bit input mask. Read only the header of each
                    # requesting input; unused FIFO heads can contain X values.
                    bindings[key] = ("noc", request, request, None)
                    payloads[key] = []
                    for i in range(5):
                        header = head+"[{}].header".format(i if net == "REQ" else i*2+1)
                        for field, width in (("src_id.x",4), ("src_id.y",4), ("src_id.port_id",2),
                                             ("dst_id.x",4), ("dst_id.y",4), ("dst_id.port_id",2),
                                             ("packet_type",4)):
                            payloads[key].append((header+"."+field, 0, width, 1 << i))
        bindings["samples"] = ("noc", "tb_top.noc_rst_n", "tb_top.noc_rst_n", None)
        vcd, receipt = cache/"heads.vcd", cache/"heads-export.json"
        command = ["fsdb2vcd", str(wave), "-o", str(vcd), "-bt", "0ps", "-et",
                   str(end+1000)+"ps", "-keep_last_time", "-s"]+selected
        if not receipt.exists():
            with (cache/"heads-export.log").open("w") as log:
                subprocess.check_call(command, cwd=str(cache), stdout=log, stderr=subprocess.STDOUT)
            receipt.write_text(json.dumps(dict(command=command, fsdb_sha256=wave_hash,
                                               vcd_sha256=digest(vcd)), indent=2)+"\n")
        exported = json.loads(receipt.read_text())
        if exported["fsdb_sha256"] != wave_hash or exported["vcd_sha256"] != digest(vcd):
            raise ValueError("Request export does not match this waveform")
        print("Sampling router requests:", pattern, flush=True)
        events = sampled_handshakes(vcd, bindings, payloads)
        clocks = [r["time_ps"] for r in events.pop("samples") if begin <= r["time_ps"] <= end]
        if clocks != list(range(begin, end+1, 1000)):
            raise ValueError("Missing NoC sample edges inside the original inclusive window")
        masks = {(net, node): [0]*length for net in ("REQ", "DAT") for node in range(16)}
        for name, samples in events.items():
            net, node, port = name.split("_")
            node, port = int(node), int(port)
            hits = set()
            for event in samples:
                time = event["time_ps"]
                if not begin <= time <= end:
                    continue
                mask = event["mask"]
                if not 0 < mask < 32 or (time-begin) % 1000:
                    raise ValueError("Invalid request mask/timestamp")
                actual_flows = []
                for i in range(5):
                    if mask & (1 << i):
                        sx, sy, sp, dx, dy, dp, kind = event["payload"][i*7:(i+1)*7]
                        if sp or dp or max(sx,sy,dx,dy) >= 4 or kind != (7 if net == "REQ" else 9):
                            raise ValueError("Unexpected endpoint/packet type at an active request")
                        flow = (4*sy+sx, 4*dy+dx)
                        if flow not in expected_routes[(net, node, port)]:
                            raise ValueError("Active request is outside its saved XY path")
                        actual_flows.append((i, flow[0], flow[1]))
                if bin(mask).count("1") < 2:
                    continue
                cycle = (time-begin)//1000
                if cycle in hits:
                    raise ValueError("Duplicate request sample at a port")
                hits.add(cycle)
                masks[(net, node)][cycle] = 1
                event_rows.append(dict(pattern=pattern, network=net, router=node, output=ports[port],
                    vc=-1 if net == "REQ" else 1, time_ps=time, cycle=cycle,
                    request_mask=mask, requesting_inputs=len(actual_flows),
                    input_flows=";".join("{}:{}>{}".format(i,a,b) for i,a,b in actual_flows)))
            port_rows.append(dict(pattern=pattern, network=net, router=node, output=ports[port],
                                  vc=-1 if net == "REQ" else 1,
                                  contention_cycles=len(hits), window_cycles=length))
        for net in ("REQ", "DAT"):
            for node in range(16):
                timeline = masks[(net, node)]
                timelines[(pattern, net, node)] = timeline
                node_rows.append(dict(pattern=pattern, network=net, router=node,
                    contention_cycles=sum(timeline), window_cycles=length))
        evidence.append(dict(pattern=pattern, result=point["root"], case=run.name,
            run_command=record["command"], seed=record["seed"], clock=record["clock"],
            run_record_sha256=digest(record_path), source_manifest_sha256=point["source_manifest_sha256"],
            binary_sha256=point["binary_sha256"], fsdb=str(wave), fsdb_sha256=wave_hash,
            vcd=str(vcd), vcd_sha256=digest(vcd), export_command=exported["command"],
            begin_ps=begin, end_ps=end, sampled_cycles=len(clocks),
            signal_bindings=bindings, header_slices=payloads))
        print(pattern, {net: sum(r["contention_cycles"] for r in node_rows
                               if r["pattern"] == pattern and r["network"] == net)
                        for net in ("REQ", "DAT")}, flush=True)

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch
    import numpy as np
    patterns, networks = ("neighbor", "bit_complement"), ("REQ", "DAT")
    titles = {"neighbor": "Neighbor", "bit_complement": "Bit-complement"}
    outputs = []
    fig, axes = plt.subplots(2, 3, figsize=(11, 9.2),
                             gridspec_kw={"width_ratios": [1, 1, .045]})
    for row, net in enumerate(networks):
        peak = max(r["contention_cycles"] for r in node_rows if r["network"] == net)
        for col, pattern in enumerate(patterns):
            ax = axes[row,col]
            grid = np.array([next(r["contention_cycles"] for r in node_rows
                                  if r["pattern"] == pattern and r["network"] == net and r["router"] == n)
                             for n in range(16)]).reshape(4,4)
            im = ax.imshow(grid, origin="lower", cmap="YlOrRd", vmin=0, vmax=max(peak,1))
            for n in range(16):
                value = int(grid[n//4,n%4])
                ax.text(n%4,n//4,"Router{}\n{}".format(n,value),ha="center",va="center",
                        fontsize=10,color="white" if peak and value > peak*.60 else "#222222")
            ax.set(title=titles[pattern]+" / "+net, xticks=[], yticks=[])
            ax.set_xticks(np.arange(-.5,4,1),minor=True)
            ax.set_yticks(np.arange(-.5,4,1),minor=True)
            ax.grid(which="minor", color="white", linewidth=2)
            ax.tick_params(which="minor",bottom=False,left=False)
            for spine in ax.spines.values(): spine.set_visible(False)
        fig.colorbar(im, cax=axes[row,2], label="Contention [cycles]")
    fig.subplots_adjust(left=.035,right=.91,top=.95,bottom=.04,wspace=.23,hspace=.22)
    for suffix in ("png","svg"):
        p=root/"figures"/("contention."+suffix)
        fig.savefig(str(p),dpi=200)
        outputs.append(p)
    plt.close(fig)

    fig, axes = plt.subplots(2, 2, figsize=(15, 9.5), sharex=True, sharey=True)
    longest = max(rois.values())
    for row, net in enumerate(networks):
        for col, pattern in enumerate(patterns):
            ax = axes[row,col]
            for node in range(16):
                active = np.flatnonzero(timelines[(pattern,net,node)])
                # Merge adjacent sample cells, preserving exact on/off cycles.
                intervals = []
                for cycle in active:
                    if intervals and cycle == intervals[-1][0]+intervals[-1][1]:
                        intervals[-1]=(intervals[-1][0],intervals[-1][1]+1)
                    else: intervals.append((int(cycle),1))
                if intervals:
                    ax.broken_barh(intervals,(node-.30,.60),facecolors="#B2182B")
            if rois[pattern] < longest:
                ax.axvspan(rois[pattern],longest,facecolor="#EEEEEE",hatch="///",
                           edgecolor="#CCCCCC",linewidth=0)
            ax.set(title=titles[pattern]+" / "+net, xlabel="Time from ENABLE [cycles]",
                   yticks=range(16),yticklabels=["Router{}".format(n) for n in range(16)],
                   ylim=(15.6,-.6),xlim=(0,longest))
            ax.tick_params(axis="y",labelleft=True,labelsize=8)
            ax.grid(axis="x",alpha=.25)
            ax.spines["top"].set_visible(False)
            ax.spines["right"].set_visible(False)
    fig.legend(handles=[Patch(color="#B2182B",label="Contention"),
                        Patch(facecolor="#EEEEEE",hatch="///",edgecolor="#CCCCCC",label="Outside window")],
               loc="lower center",ncol=2,frameon=False,bbox_to_anchor=(.5,.005))
    fig.tight_layout(rect=(0,.045,1,1))
    for suffix in ("png","svg"):
        p=root/"figures"/("contention-timeline."+suffix)
        fig.savefig(str(p),dpi=200)
        outputs.append(p)
    plt.close(fig)

    # Draw all sixteen reads, with the same requester color for REQ and DAT.
    # Parallel lanes keep flows and opposite directions visible on shared links.
    link_rows = [r for r in csv.DictReader((root/"tables/bandwidth-links.csv").open())
                 if int(r["transfer_bytes"]) == 32768]
    route_rows = []
    palette = ("#1665A8", "#E69F00", "#009E73", "#7B3294",
               "#C44E52", "#8C564B", "#CC79A7", "#008B8B",
               "#9A8700", "#253494", "#17BECF", "#AA3377",
               "#228833", "#BB5566", "#777700", "#555555")
    fig, axes = plt.subplots(2,2,figsize=(14,15.6))
    for col, pattern in enumerate(patterns):
        mapping = pairings[pattern]
        for row, net in enumerate(networks):
            ax = axes[row,col]
            edges = defaultdict(list)
            for source, target in enumerate(mapping):
                a,b = (source,target) if net == "REQ" else (target,source)
                links = path(a,b)
                observed = {(int(r["router"]),int(r["port"])) for r in link_rows
                            if r["pattern"] == pattern and r["network"] == net.lower()
                            and int(r["flow_start"]) == a and int(r["flow_end"]) == b}
                if observed != set(links):
                    raise ValueError("XY path differs from the saved per-flow FSDB link table")
                route_rows.append(dict(pattern=pattern, network=net, source=source, target=target,
                    flow_start=a, flow_end=b, hops=len(links)-1,
                    router_path=";".join(str(n) for n,_ in links),
                    output_ports=";".join(ports[p] for _,p in links)))
                for node,port in links:
                    if not port:
                        continue
                    other=node+{1:4,2:1,3:-4,4:-1}[port]
                    edges[tuple(sorted((node,other)))].append((source,node,other))
            for n in range(16):
                x,y=n%4,n//4
                if x<3: ax.plot([x,x+1],[y,y],color="#E5E5E5",lw=1,zorder=0)
                if y<3: ax.plot([x,x],[y,y+1],color="#E5E5E5",lw=1,zorder=0)
                contested = any(r["pattern"]==pattern and r["network"]==net and
                                r["router"]==n and r["contention_cycles"]>0 for r in node_rows)
                ax.scatter(x,y,s=650,facecolor="white",
                           edgecolor="#B2182B" if contested else "#999999",
                           linewidth=2 if contested else 1,zorder=4)
                ax.text(x,y,str(n),ha="center",va="center",fontsize=10,zorder=5)
            for edge, users in sorted(edges.items()):
                users.sort(key=lambda item:(item[1]>item[2],item[0]))
                for j,(source,node,other) in enumerate(users):
                    offset=(j-(len(users)-1)/2)*.07
                    x,y=node%4,node//4
                    xx,yy=other%4,other//4
                    if y==yy: y+=offset;yy+=offset
                    else: x+=offset;xx+=offset
                    ax.annotate("",xy=(xx,yy),xytext=(x,y),
                        arrowprops=dict(arrowstyle="-|>",color=palette[source],lw=1.8,
                                        shrinkA=14,shrinkB=14),zorder=3)
            ax.set(title="{} / {}".format(titles[pattern],"DAT return" if net=="DAT" else net),
                   xlim=(-.35,3.35),ylim=(-.35,3.35),aspect="equal",xticks=[],yticks=[])
            for spine in ax.spines.values():spine.set_visible(False)
        handles=[Patch(color=palette[s],label="Node{} to Node{}".format(s,d))
                 for s,d in enumerate(mapping)]
        axes[1,col].legend(handles=handles,title="Read source to target",
                           loc="upper center",bbox_to_anchor=(.5,-.035),
                           ncol=2,frameon=False,fontsize=8.5,title_fontsize=9)
    from matplotlib.lines import Line2D
    fig.legend(handles=[Line2D([0],[0],marker="o",color="none",markerfacecolor="white",
                              markeredgecolor="#B2182B",markeredgewidth=2,markersize=8,
                              label="Router with observed contention")],
               loc="lower center",bbox_to_anchor=(.5,.005),frameon=False)
    fig.subplots_adjust(left=.035,right=.965,bottom=.18,top=.965,wspace=.10,hspace=.16)
    for suffix in ("png","svg"):
        p=root/"figures"/("contention-routes."+suffix)
        fig.savefig(str(p),dpi=200)
        outputs.append(p)
    plt.close(fig)

    for name,rows in (("contention",node_rows),("contention-ports",port_rows),("contention-events",event_rows),
                      ("contention-routes",route_rows)):
        p=root/"tables"/(name+".csv")
        with p.open("w",newline="") as stream:
            writer=csv.DictWriter(stream,fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        outputs.append(p)
    snapshot=root/"provenance/contention-performance.py"
    snapshot.write_bytes(Path(__file__).read_bytes())
    outputs.append(snapshot)
    proof=dict(
        command=["python3","-B","-c",
                 "from pathlib import Path; from performance import router_contention; router_contention(Path('performance/unicast/mesh-traffic'))"],
        script_sha256=digest(snapshot),cases=evidence,
        definition="popcount(current output req)>=2; per-router cycle is the OR across all five outputs",
        networks="REQ and DAT read VC1 separately; local output included; DAT write VC0 and RSP excluded",
        window="Common source ENABLE to last SOURCE_DONE, inclusive; sample stable values before NoC rising edge",
        flow_decode="Active input header src_id/dst_id x,y,port_id and packet_type; DAT head index input*2+1",
        limitations="Counts simultaneous requests, including cycles when the output cannot accept. "
                    "Not lost cycles, automatic cause attribution, or detection of packets hidden behind one FIFO head.",
        routes=route_rows,
        route_definition="All sixteen requester/target pairs per pattern; REQ requester-to-target XY, "
                         "DAT target-to-requester XY independently; colors identify the requester",
        route_check="All 64 network paths match the existing FSDB-validated per-flow link table, including Local",
        route_link_table_sha256=digest(root/"tables/bandwidth-links.csv"),
        input_table_sha256=digest(root/"tables/bandwidth-sources.csv"),
        outputs={str(p.relative_to(root)):digest(p) for p in outputs})
    (root/"provenance/contention.json").write_text(json.dumps(proof,indent=2)+"\n")
    print("Saved contention heatmaps, routes, timelines and raw per-output events under",root)


def mesh_node_timeline(root):
    """Plot all sources and preserve overlapping AXI bursts from saved waveforms."""
    from collections import defaultdict
    root = root.resolve()
    repo = Path(__file__).resolve().parents[2]
    points = [p for p in csv.DictReader((root/"tables/bandwidth.csv").open())
              if p["pattern"] in ("neighbor", "bit_complement") and int(p["transfer_bytes"]) == 32768]
    if len(points) != 2:
        raise ValueError("Expected the two saved 32 KiB cases")

    def route(start, target):
        links = []
        node = start
        while node % 4 != target % 4:
            step = 1 if node % 4 < target % 4 else -1
            links.append((node, 2 if step == 1 else 4))
            node += step
        while node // 4 != target // 4:
            step = 4 if node // 4 < target // 4 else -4
            links.append((node, 1 if step == 4 else 3))
            node += step
        return links + [(target, 0)]

    def endpoints(flit):
        ids = [(flit >> shift) & 1023 for shift in (4, 14)]
        if any(n >> 8 or (n & 15) >= 4 or (n >> 4) >= 4 for n in ids):
            raise ValueError("Non-native endpoint")
        return tuple(4*(n >> 4)+(n & 15) for n in ids)

    def r_payload(flit):
        return ((flit >> 58) & ((1 << 512)-1), (flit >> 44) & 1)

    transactions, stages, beats, evidence = [], [], [], []
    for point in sorted(points, key=lambda p: p["pattern"]):
        result = root/point["root"]
        run, = [p for p in (result/"runs").iterdir() if p.is_dir()]
        record_path = run/(run.name+".run.json")
        record = json.loads(record_path.read_text())
        pattern, case = traffic_case(result, run.name)
        if not record["passed"] or record["clock"] != dict(
                axi_period_ps=1000, noc_period_ps=1000, noc_phase_ps=0):
            raise ValueError("Expected a saved aligned 1 GHz run")
        wave = run/(run.name+".fsdb")
        cache = repo/"build/perf-bw-analysis"/run.name
        vcd = cache/"interfaces.vcd"
        export = json.loads((cache/"export.json").read_text())
        if (digest(wave) != point["waveform_sha256"] or
                export["fsdb_sha256"] != digest(wave) or export["vcd_sha256"] != digest(vcd)):
            raise ValueError("FSDB/VCD provenance mismatch")
        if digest(result/"tables/summary.json") != point["summary_sha256"]:
            raise ValueError("Original summary changed")
        definitions = result/"provenance/source/define"
        for filename, patterns in {
            "noc_header_pkg.sv": [r"ORD_TAG_WIDTH\s*=\s*8\s*;", r"X_WIDTH\s*=\s*4\s*;",
                                 r"Y_WIDTH\s*=\s*4\s*;", r"PORT_ID_WIDTH\s*=\s*2\s*;"],
            "noc_payload_pkg.sv": [r"AXI_ID_WIDTH\s*=\s*3\s*;", r"AXI_ADDR_WIDTH\s*=\s*48\s*;",
                                  r"DATA_WIDTH\s*=\s*512\s*;", r"RUSER_WIDTH\s*=\s*8\s*;",
                                  r"DATA_R_RLAST_LSB\s*=\s*0\s*;"],
            "noc_unit_params_pkg.sv": [r"DAT_READ_VC\s*=\s*1\s*;"],
        }.items():
            text = (definitions/filename).read_text()
            if any(not re.search(check, text) for check in patterns):
                raise ValueError("Saved packet layout changed")

        bindings, payloads = {}, {}
        for node in range(16):
            for role in ("source", "device"):
                base = "tb_top.gen_node[{}].{}_bus.".format(node, role)
                for channel, fields in (("ar", ("addr", "len", "size", "id")),
                                        ("r", ("data", "last", "id"))):
                    name = "{}_{}_{}".format(role, node, channel)
                    bindings[name] = ("axi", base+channel+"valid", base+channel+"ready", None)
                    payloads[name] = [base+channel+field for field in fields]
            for channel in ("req", "dat"):
                for direction, ports in (("rx", (0,)), ("tx", range(5))):
                    for port in ports:
                        name = "{}_{}_{}_{}".format(channel, direction, node, port)
                        base = "tb_top.i_router.{}_{}".format(direction, channel)
                        index = "[{}]".format(node) if channel == "req" else "[{}][{}]".format(node, port)
                        bindings[name] = ("noc", base+"_valid"+index, base+"_ready"+index,
                                          port if channel == "req" else 1)
                        payloads[name] = [base+"_flit[{}][{}]".format(node, port)]
        print("Reading", pattern, vcd, flush=True)
        sampled = sampled_handshakes(vcd, bindings, payloads)
        packets = defaultdict(list)
        for name, events in sampled.items():
            if name.startswith(("source_", "device_")):
                continue
            channel, direction, node, port = name.split("_")
            for event in events:
                flit, = event["payload"]
                if flit & 15 != (7 if channel == "req" else 9) or not ((flit >> 24) & 1):
                    raise ValueError("Expected a single-flit DATA_AR or DATA_R packet")
                packets[(channel, direction, int(node), int(port), endpoints(flit))].append(event)
        tx = json.loads((result/"tables/transactions.json").read_text())
        sources = [t for t in tx if t["role"] == "source" and t["phase"] == 1]
        devices = [t for t in tx if t["role"] == "device"]
        if len(sources) != 128 or len(devices) != 128:
            raise ValueError("Expected eight transactions on every source/device")
        device_index = {}
        for t in devices:
            key = (t["endpoint"], t["addr"], t["beats"], t["size"], t["user"])
            if key in device_index:
                raise ValueError("Ambiguous target transaction")
            device_index[key] = t
        with (run/"axi-events.csv").open() as stream:
            raw = list(csv.DictReader(stream))
        enable_times = {int(r["time_ps"]) for r in raw
                        if r["role"] == "source" and r["channel"] == "ENABLE"}
        if len(enable_times) != 1:
            raise ValueError("Expected a common ENABLE edge")
        origin, = enable_times
        matched_devices = set()
        matched_boundaries = set()
        case_stages = []
        for node, target in enumerate(case["source_destination_map"]):
            own = sorted((t for t in sources if t["endpoint"] == node), key=lambda t: t["request_ps"])
            if len(own) != 8 or any(t["beats"] != 64 or t["size"] != 6 for t in own):
                raise ValueError("Expected eight full-width 64-beat bursts")
            target_own = [device_index[(target, t["addr"], t["beats"], t["size"], t["user"])] for t in own]
            for role, endpoint, rows in (("source", node, own), ("device", target, target_own)):
                ars = sampled["{}_{}_ar".format(role, endpoint)]
                rs = sampled["{}_{}_r".format(role, endpoint)]
                if len(ars) != 8 or len(rs) != 512:
                    raise ValueError("AXI handshake count mismatch")
                for j, t in enumerate(rows):
                    ar, rb = ars[j], rs[j*64:(j+1)*64]
                    if (ar["time_ps"] != t["request_ps"] or
                            ar["payload"] != [t["addr"], 63, 6, t["id"]] or
                            rb[0]["time_ps"] != t["first_response_ps"] or
                            rb[-1]["time_ps"] != t["completion_ps"] or
                            any(e["payload"][2] != t["id"] or e["payload"][1] != int(k == 63)
                                for k, e in enumerate(rb))):
                        raise ValueError("AXI waveform disagrees with transaction table")
                stamps = [int(r["time_ps"]) for r in raw if r["role"] == role and
                          int(r["endpoint"]) == endpoint and r["channel"] in ("AR", "R")]
                observed = sorted(e["time_ps"] for e in ars+rs)
                if sorted(stamps) != observed:
                    raise ValueError("Raw AXI timestamp mismatch")

            request_boundaries = [("req", "rx", node, 0, (node, target))]
            request_boundaries += [("req", "tx", n, p, (node, target)) for n, p in route(node, target)]
            return_boundaries = [("dat", "rx", target, 0, (target, node))]
            return_boundaries += [("dat", "tx", n, p, (target, node)) for n, p in route(target, node)]
            matched_boundaries.update(request_boundaries + return_boundaries)
            req_events = [packets[key] for key in request_boundaries]
            dat_events = [packets[key] for key in return_boundaries]
            source_r = sampled["source_{}_r".format(node)]
            device_r = sampled["device_{}_r".format(target)]
            for events in req_events:
                if len(events) != 8 or [((e["payload"][0] >> 47) & ((1 << 48)-1))
                                       for e in events] != [t["addr"] for t in own]:
                    raise ValueError("REQ addresses/order differ from the source")
            for events in dat_events:
                if len(events) != 512 or [r_payload(e["payload"][0]) for e in events] != [
                        tuple(e["payload"][:2]) for e in source_r]:
                    raise ValueError("DAT RDATA/RLAST/order mismatch")
            if [e["payload"][:2] for e in source_r] != [e["payload"][:2] for e in device_r]:
                raise ValueError("Device/source R payload mismatch")

            for j, (t, d) in enumerate(zip(own, target_own)):
                matched_devices.add((target, d["addr"], d["beats"], d["size"], d["user"]))
                req_tag = (req_events[0][j]["payload"][0] >> 26) & 255
                if any(((events[j]["payload"][0] >> 26) & 255) != req_tag for events in req_events):
                    raise ValueError("REQ tag changed along its route")
                if any(((events[k]["payload"][0] >> 26) & 255) != req_tag
                       for events in dat_events for k in range(j*64, (j+1)*64)):
                    raise ValueError("Return tag differs from its request")
                common = dict(pattern=pattern, source=node, target=target, transaction=j,
                              addr=t["addr"], origin_ps=origin)
                milestones = [("Source AR", t["request_ps"])]
                milestones.append(("REQ injection", req_events[0][j]["time_ps"]))
                for key, events in zip(request_boundaries[1:], req_events[1:]):
                    milestones.append(("REQ Router{} port{}".format(key[2], key[3]), events[j]["time_ps"]))
                milestones += [("Target AR", d["request_ps"]), ("Target first R", d["first_response_ps"]),
                               ("DAT injection", dat_events[0][j*64]["time_ps"])]
                for key, events in zip(return_boundaries[1:], dat_events[1:]):
                    milestones.append(("DAT Router{} port{}".format(key[2], key[3]), events[j*64]["time_ps"]))
                milestones.append(("Source first R", t["first_response_ps"]))
                labels = (["NI"] + ["REQ routers"]*len(route(node, target)) +
                          ["NI", "Target AR to first R", "NI"] +
                          ["DAT routers"]*len(route(target, node)) + ["NI"])
                if len(labels) != len(milestones)-1:
                    raise ValueError("Stage boundary mismatch")
                for k, ((begin, start), (end, finish), component) in enumerate(
                        zip(milestones, milestones[1:], labels)):
                    if finish < start or (finish-start) % 1000:
                        raise ValueError("Invalid stage ordering")
                    row = dict(common, stage=k, component=component, begin_event=begin, end_event=end,
                               start_ps=start, end_ps=finish, cycles=(finish-start)//1000)
                    stages.append(row)
                    case_stages.append(row)
                if sum(s["cycles"] for s in case_stages if
                       s["source"] == node and s["transaction"] == j) != t["first_response_latency_ps"]/1000:
                    raise ValueError("Stages do not sum to the original AR-to-first-R latency")
                for k in range(64):
                    i = j*64+k
                    times = [device_r[i]["time_ps"]] + [events[i]["time_ps"] for events in dat_events] + [
                        source_r[i]["time_ps"]]
                    if times != sorted(times):
                        raise ValueError("Beat appears out of order across the return path")
                    beats.append(dict(common, beat=k, rlast=int(k == 63),
                                      device_r_ps=times[0], dat_injection_ps=times[1],
                                      source_r_ps=times[-1],
                                      return_boundary_ps=";".join(str(v) for v in times[1:-1])))
                transactions.append(dict(common, source_ar_ps=t["request_ps"], target_ar_ps=d["request_ps"],
                    target_first_r_ps=d["first_response_ps"], target_last_r_ps=d["completion_ps"],
                    source_first_r_ps=t["first_response_ps"], source_last_r_ps=t["completion_ps"],
                    first_r_latency_cycles=t["first_response_latency_ps"]//1000,
                    completion_latency_cycles=t["latency_ps"]//1000,
                    source_beats=64, useful_bytes=4096))
        if len(matched_devices) != 128:
            raise ValueError("Target transactions were not matched one-to-one")
        if set(packets) != matched_boundaries:
            raise ValueError("Unexpected packets outside the mapped request/return routes")
        evidence.append(dict(pattern=pattern, result=point["root"], case=run.name,
            run_command=record["command"], clock=record["clock"], seed=record["seed"],
            fsdb_sha256=digest(wave), vcd_sha256=digest(vcd),
            vcd=str(vcd), fsdb=str(wave), export_command=export["command"],
            run_record_sha256=digest(record_path),
            source_manifest_sha256=point["source_manifest_sha256"],
            binary_sha256=point["binary_sha256"],
            transaction_table_sha256=digest(result/"tables/transactions.json"),
            raw_axi_sha256=digest(run/"axi-events.csv"), origin_ps=origin,
            signal_bindings=bindings, signal_payloads=payloads,
            routes={str(n): dict(request=route(n, d), response=route(d, n))
                    for n, d in enumerate(case["source_destination_map"])}))
        print("Validated", pattern, "128 transactions / 8192 source R beats", flush=True)

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch
    from matplotlib.lines import Line2D
    colors = {"NI": "#1665A8", "REQ routers": "#6C757D",
              "Target AR to first R": "#E69F00", "DAT routers": "#7B3294"}
    order = ("neighbor", "bit_complement")
    titles = {"neighbor": "Neighbor", "bit_complement": "Bit-complement"}
    figs = []
    fig, axes = plt.subplots(1, 2, figsize=(15, 10.6), sharex=True, sharey=True)
    xmax = max((r["source_last_r_ps"]-r["origin_ps"])/1000 for r in transactions)+8
    for ax, pattern in zip(axes, order):
        selected = [r for r in transactions if r["pattern"] == pattern]
        for row in selected:
            y = row["source"]-.35+row["transaction"]*.1
            origin = row["origin_ps"]
            start = (row["source_ar_ps"]-origin)/1000
            first = (row["source_first_r_ps"]-origin)/1000
            last = (row["source_last_r_ps"]-origin)/1000
            for segment in stages:
                if (segment["pattern"] == pattern and segment["source"] == row["source"] and
                        segment["transaction"] == row["transaction"]):
                    ax.barh(y, segment["cycles"], left=(segment["start_ps"]-origin)/1000,
                            height=.065, color=colors[segment["component"]], linewidth=0)
            ax.plot([first, last], [y, y], color="#D5D5D5", lw=.7)
            ts = [(b["source_r_ps"]-origin)/1000 for b in beats if
                  b["pattern"] == pattern and b["source"] == row["source"] and
                  b["transaction"] == row["transaction"]]
            ax.vlines(ts, y-.031, y+.031, color="#009E73", linewidth=.55)
            ax.plot(start, y, marker="|", color="#1665A8", ms=3)
            ax.plot(last, y, marker="D", color="#C44E52", ms=1.8)
        ax.set(title=titles[pattern], xlabel="Time from ENABLE [cycles]", xlim=(0, xmax),
               yticks=range(16), yticklabels=["Node{}".format(n) for n in range(16)],
               ylim=(15.6, -.6))
        ax.tick_params(axis="y", labelleft=True)
        for n in range(0, 16, 2):
            ax.axhspan(n-.48, n+.48, color="#F3F4F5", zorder=-1)
        ax.grid(axis="x", alpha=.25)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
    handles = [Patch(color=c, label=k) for k,c in colors.items()]
    handles += [Line2D([0],[0],color="#009E73",marker="|",linestyle="None",label="Accepted R beat"),
               Line2D([0],[0],color="#C44E52",marker="D",linestyle="None",ms=4,label="RLAST")]
    fig.legend(handles=handles, loc="lower center", ncol=3, frameon=False, bbox_to_anchor=(.5,.005))
    fig.tight_layout(rect=(0,.07,1,1))
    figs.append(("node-timeline", fig))
    fig, axes = plt.subplots(1, 2, figsize=(15, 9.6), sharex=True, sharey=True)
    first_stages = [r for r in stages if r["transaction"] == 0]
    xmax = max((r["end_ps"]-r["origin_ps"])/1000 for r in first_stages)+1
    for ax, pattern in zip(axes, order):
        for row in first_stages:
            if row["pattern"] != pattern:
                continue
            start = (row["start_ps"]-row["origin_ps"])/1000
            ax.barh(row["source"], row["cycles"], left=start, height=.58,
                    color=colors[row["component"]], edgecolor="white", linewidth=.35)
        ax.set(title=titles[pattern], xlabel="Time from ENABLE [cycles]",
               xlim=(0, xmax), ylim=(15.6, -.6), yticks=range(16),
               yticklabels=["Node{}".format(n) for n in range(16)])
        ax.tick_params(axis="y", labelleft=True)
        ax.grid(axis="x", alpha=.25)
        ax.set_axisbelow(True)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
    fig.legend(handles=[Patch(color=c,label=k) for k,c in colors.items()],
               loc="lower center", ncol=4, frameon=False, bbox_to_anchor=(.5,.005))
    fig.tight_layout(rect=(0,.04,1,1))
    figs.append(("node-first", fig))
    components = [("NI", "ni_cycles"), ("REQ routers", "req_router_cycles"),
                  ("Target AR to first R", "target_ar_to_first_r_cycles"),
                  ("DAT routers", "dat_router_cycles")]
    mean_rows = []
    for pattern in order:
        for node in range(16):
            own = [r for r in transactions if r["pattern"] == pattern and r["source"] == node]
            if {r["transaction"] for r in own} != set(range(8)):
                raise ValueError("Mean requires all eight transactions on each node")
            selected = [r for r in stages if r["pattern"] == pattern and r["source"] == node]
            row = dict(pattern=pattern, source=node, transactions=len(own))
            for component, field in components:
                row[field] = sum(r["cycles"] for r in selected if r["component"] == component)/len(own)
            row["latency_cycles"] = sum(r["first_r_latency_cycles"] for r in own)/len(own)
            if abs(sum(row[field] for _,field in components)-row["latency_cycles"]) > 1e-9:
                raise ValueError("Mean stage durations do not sum to mean transaction latency")
            mean_rows.append(row)
    fig, axes = plt.subplots(1, 2, figsize=(15, 9.6), sharex=True, sharey=True)
    xmax = max(r["latency_cycles"] for r in mean_rows)*1.04
    for ax, pattern in zip(axes, order):
        for row in mean_rows:
            if row["pattern"] != pattern:
                continue
            start = 0
            for component, field in components:
                ax.barh(row["source"], row[field], left=start, height=.58,
                        color=colors[component], edgecolor="white", linewidth=.35)
                start += row[field]
        ax.set(title=titles[pattern], xlabel="Latency [cycles]",
               xlim=(0, xmax), ylim=(15.6, -.6), yticks=range(16),
               yticklabels=["Node{}".format(n) for n in range(16)])
        ax.tick_params(axis="y", labelleft=True)
        ax.grid(axis="x", alpha=.25)
        ax.set_axisbelow(True)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
    fig.legend(handles=[Patch(color=colors[c],label=c) for c,_ in components],
               loc="lower center", ncol=4, frameon=False, bbox_to_anchor=(.5,.005))
    fig.tight_layout(rect=(0,.04,1,1))
    figs.append(("node-stages", fig))
    outputs = []
    for name, fig in figs:
        for suffix in ("png", "svg"):
            p = root/"figures"/(name+"."+suffix)
            fig.savefig(str(p), dpi=200)
            outputs.append(p)
        plt.close(fig)
    for name, rows in (("transactions", transactions), ("stages", stages), ("beats", beats),
                       ("mean", mean_rows)):
        p = root/"tables"/("node-timeline-"+name+".csv")
        with p.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        outputs.append(p)
    snapshot = root/"provenance/node-timeline-performance.py"
    snapshot.write_bytes(Path(__file__).read_bytes())
    outputs.append(snapshot)
    proof = dict(command=[sys.executable]+sys.argv, script_sha256=digest(snapshot),
        cases=evidence, source_transactions=len(transactions), source_accepted_r_beats=len(beats),
        stage_rows=len(stages), sampling="Stable pre-edge VALID & READY at rising AXI/NoC edge, 1 ps VCD",
        boundary="Common ENABLE origin; durations are timestamp differences, not inclusive BW windows",
        stages="All 128 bursts/case: accepted source AR to first accepted R; target AR-to-first-R includes waiting",
        figure_selection="node-stages: arithmetic mean of all eight bursts/node, durations aligned at source AR; "
                         "node-timeline: all bursts at common ENABLE; node-first: transaction 0 at common ENABLE",
        mean_formula="Each component: sum of its stage durations across all eight bursts / 8; "
                     "four components sum to mean(source first R - source AR) / clock period",
        limits="Boundary residence intervals include pipeline/waiting; no arbitration/FIFO causal attribution",
        checks="AXI payload/timestamps vs raw collector and transaction tables; one-to-one device pairing; "
               "REQ address/tag per hop; DAT RDATA/RLAST/tag/beat-order per hop; "
               "each beat chronological; stages sum to original first-R latency",
        outputs={str(p.relative_to(root)): digest(p) for p in outputs})
    (root/"provenance/node-timeline.json").write_text(json.dumps(proof, indent=2)+"\n")
    print("Saved Node0-Node15 timelines and per-transaction/per-beat evidence under", root)


def tile_to_tile(root):
    """Plot the tile-to-tile timeline at the AXI, NI and router boundaries."""
    root = root.resolve()
    if (root/"tables/bandwidth.csv").exists():
        return mesh_node_timeline(root)
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


def multicast_report(roots, output):
    """Validate saved one-row runs and report elapsed runtime, without a partial curve."""
    import tempfile
    from gen_standalone_patterns import generate
    from axi_file_parser import _parse_write
    output = output.resolve()
    points = []
    for root in roots:
        root = root.resolve()
        run, = (root/"runs").iterdir()
        record = json.loads((run/(run.name+".run.json")).read_text())
        validation = json.loads((root/"validation.json").read_text())
        if not record["passed"] or not validation["checker_passed"] or not validation["drain"]:
            raise ValueError("Failed multicast run: "+str(root))
        inputs = run/"inputs"
        manifest = json.loads((inputs/"manifest.json").read_text())
        config = manifest["multicast"]
        size, method, sender = config["message_bytes"], config["method"], config["root"]
        members = config["members"]
        if (sender != 12 or members != [0,1,2,3] or "+forwarding" not in record["command"] or
                "+preload" in record["command"] or record["clock"]["axi_period_ps"] != 1000):
            raise ValueError("Unexpected multicast platform or initialization")
        source_tree = root/"provenance/source"
        if digest(root/"provenance/SHA256SUMS") != record["source_manifest_sha256"]:
            raise ValueError("Multicast compiled-source manifest changed")
        repo = Path(__file__).resolve().parents[2]
        helpers = ("dv/scripts/gen_tb_top.py", "dv/scripts/address_map.py")
        for name in helpers:
            target = source_tree/name
            if not target.exists():
                target.parent.mkdir(parents=True,exist_ok=True)
                target.write_bytes((repo/name).read_bytes())
            if digest(target) != digest(repo/name):
                raise ValueError("Generator helper differs from saved source")
        if digest(source_tree/"dv/scripts/gen_standalone_patterns.py") != digest(repo/"dv/scripts/gen_standalone_patterns.py"):
            raise ValueError("Generator differs from this run")
        case, = [c for c in json.loads((source_tree/"dv/config/cases.json").read_text())["groups"]["performance_multicast"]
                 if c["name"] == run.name]
        reproduced = {}
        with tempfile.TemporaryDirectory(prefix="multicast-",dir=str(repo/"build")) as temp:
            generate(Path(temp), root/"config/topology.yml", manifest["id_width"], [case],
                     seed=manifest["seed"], profile="cosim")
            fresh = Path(temp)/run.name
            for p in fresh.rglob("*"):
                if p.is_file():
                    rel = p.relative_to(fresh)
                    if p.read_bytes() != (inputs/rel).read_bytes():
                        raise ValueError("Multicast input reproduction mismatch: "+str(rel))
                    reproduced[str(rel)] = digest(p)
        tx = json.loads((root/"tables/transactions.json").read_text())
        source = [t for t in tx if t["role"]=="source" and t["phase"]==1]
        devices = [t for t in tx if t["role"]=="device" and t["direction"]=="write"]
        readback = [t for t in tx if t["role"]=="source" and t["phase"]==2]
        if (any(t["direction"]!="write" or t["id"]!=0 or t["size"]!=6 for t in source) or
                set(t["endpoint"] for t in devices) != set(members) or
                sum(t["useful_bytes"] for t in readback) != len(members)*size or
                any(t["direction"]!="read" for t in readback)):
            raise ValueError("Multicast source/group/readback mismatch")
        active = sorted({t["endpoint"] for t in source})
        primary = min(active)
        transfers = {}
        for endpoint in active:
            directory = inputs if endpoint==primary else inputs/("source"+str(endpoint))
            expected = _parse_write(directory/"write.txt")
            actual = sorted((t for t in source if t["endpoint"]==endpoint),key=lambda t:t["request_ps"])
            if len(expected)!=len(actual):
                raise ValueError("Multicast source transaction count mismatch")
            for index,(a,b) in enumerate(zip(expected,actual)):
                if ((a["addr"],a["len"]+1,a["size"],a["awuser"]) !=
                        (b["addr"],b["beats"],b["size"],b["user"]) or b["useful_bytes"]!=64*b["beats"]):
                    raise ValueError("Multicast accepted request differs from input")
                transfers[endpoint,index]=b
        for endpoint in members:
            covered = set()
            for t in (d for d in devices if d["endpoint"]==endpoint):
                begin = t["addr"]-endpoint*0x100000000-config["output_offset"]
                span = set(range(begin,begin+t["useful_bytes"]))
                if covered & span:
                    raise ValueError("Duplicate multicast delivery")
                covered |= span
            if covered != set(range(size)):
                raise ValueError("Incomplete multicast recipient payload")
        for line in (inputs/"schedule.txt").read_text().splitlines():
            if line.startswith("#after "):
                _,s,i,p,j=line.split()
                if transfers[int(p),int(j)]["completion_ps"] > transfers[int(s),int(i)]["request_ps"]:
                    raise ValueError("Forwarding started before previous wave completed")
        wave = run/(run.name+".fsdb")
        if digest(wave)!=record["waveform"]["sha256"]:
            raise ValueError("Multicast waveform hash mismatch")
        vcd = run/"interfaces.vcd"
        export = run/"interfaces-export.json"
        if not vcd.exists():
            command=["fsdb2vcd",str(wave),"-o",str(vcd),"-s","/tb_top","-level","3"]
            with (run/"interfaces-export.log").open("w") as log:
                subprocess.check_call(command,stdout=log,stderr=subprocess.STDOUT)
            export.write_text(json.dumps(dict(command=command,fsdb_sha256=digest(wave),vcd_sha256=digest(vcd)),indent=2)+"\n")
        cached=json.loads(export.read_text())
        if cached["fsdb_sha256"]!=digest(wave) or cached["vcd_sha256"]!=digest(vcd):
            raise ValueError("Cached multicast waveform export changed")
        bindings={}
        for role,stem in (("source","source_bus"),("device","device_bus")):
            for endpoint in range(16):
                for channel in ("AW","W","B","AR","R"):
                    base="tb_top.gen_node[{}].{}.{}".format(endpoint,stem,channel.lower())
                    bindings["{}_{}_{}".format(role,endpoint,channel)]=("axi",base+"valid",base+"ready",None)
        start_signal="tb_top.gen_node[{}].source_bus.awvalid".format(sender)
        bindings["start"]=("axi",start_signal,None,None)
        payloads={}
        for role,stem in (("source","source_bus"),("device","device_bus")):
            for endpoint in range(16):
                base="tb_top.gen_node[{}].{}.".format(endpoint,stem)
                payloads["{}_{}_W".format(role,endpoint)]=[base+"wdata",base+"wstrb",base+"wlast"]
                payloads["{}_{}_R".format(role,endpoint)]=[base+"rdata",base+"rlast"]
        sampled=sampled_handshakes(vcd,bindings,payloads)
        raw=list(csv.DictReader((run/"axi-events.csv").open()))
        for name in bindings:
            if name=="start":
                continue
            role,endpoint,channel=name.split("_")
            stamps=[int(r["time_ps"]) for r in raw
                    if r["role"]==role and int(r["endpoint"])==int(endpoint) and r["channel"]==channel]
            if stamps != [r["time_ps"] for r in sampled[name]]:
                raise ValueError("Raw/FSDB multicast mismatch: "+name)

        def payload_beat(position):
            return sum(((((position+b)//4+1) >> (8*((position+b)%4))) & 255) << (8*b) for b in range(64))
        for role in ("source","device"):
            for endpoint in range(16):
                if role=="source":
                    directory=inputs if endpoint==primary else inputs/("source"+str(endpoint))
                    expected=_parse_write(directory/"write.txt") if endpoint in active else []
                    words=[(int(line.split()[0],16),int(line.split()[1],16),int(i==t["len"]))
                           for t in expected for i,line in enumerate(t["beats"])]
                else:
                    words=[]
                    for t in sorted((d for d in devices if d["endpoint"]==endpoint),key=lambda d:d["request_ps"]):
                        pos=t["addr"]-endpoint*0x100000000-config["output_offset"]
                        words.extend((payload_beat(pos+64*i),(1<<64)-1,int(i==t["beats"]-1)) for i in range(t["beats"]))
                if words!=[tuple(e["payload"]) for e in sampled["{}_{}_W".format(role,endpoint)]]:
                    raise ValueError("FSDB write payload mismatch at "+role+str(endpoint))
                reads=readback if role=="source" else [t for t in tx if t["role"]=="device" and t["direction"]=="read"]
                words=[]
                for t in sorted((r for r in reads if r["endpoint"]==endpoint),key=lambda r:r["request_ps"]):
                    pos=(t["addr"] & 0xffffffff)-config["output_offset"]
                    words.extend((payload_beat(pos+64*i),int(i==t["beats"]-1)) for i in range(t["beats"]))
                if words!=[tuple(e["payload"]) for e in sampled["{}_{}_R".format(role,endpoint)]]:
                    raise ValueError("FSDB readback payload mismatch at "+role+str(endpoint))
        begin=sampled["start"][0]["time_ps"]
        end=max(t["completion_ps"] for t in source)
        if (begin>min(t["request_ps"] for t in source) or
                max(t["completion_ps"] for t in devices)>end or
                min(t["request_ps"] for t in readback)<end):
            raise ValueError("Multicast runtime window or readback overlap mismatch")
        expected_source_bytes=size if method=="hw" else len(members)*size
        if sum(t["useful_bytes"] for t in source)!=expected_source_bytes:
            raise ValueError("Unexpected multicast source work")
        point=dict(case=run.name,method=method,message_bytes=size,batch_bytes=config["batch_bytes"],
            root=sender,recipients=len(members),start_ns=begin/1000,end_ns=end/1000,
            runtime_cycles=(end-begin)/record["clock"]["axi_period_ps"],
            source_bytes=expected_source_bytes,recipient_bytes=len(members)*size,
            run=os.path.relpath(str(root),str(output)),binary_sha256=record["binary_sha256"],
            source_manifest_sha256=record["source_manifest_sha256"],seed=record["seed"])
        (root/"tables/metrics.json").write_text(json.dumps(point,indent=2)+"\n")
        validation.update(scope="One-row native protocol-level multicast measurement",
            offline_calibration_comparison="passed_against_this_run_FSDB",
            input_reproduction=dict(status="passed",files=reproduced),
            runtime_boundary="root AWVALID assertion to last required source B handshake; readback excluded",
            wave_dependencies="passed",recipient_payload="all recipients verified by actual AXI readback",
            actual_device_preload=False,payload_calibration="passed_source_device_W_and_readback_R_against_FSDB",
            fsdb_sha256=digest(wave),
            calibration_script_sha256=digest(Path(__file__)))
        (root/"validation.json").write_text(json.dumps(validation,indent=2)+"\n")
        points.append(point)
    keys=[(p["method"],p["message_bytes"],p["batch_bytes"]) for p in points]
    if len(set(keys))!=len(keys) or len({p["binary_sha256"] for p in points})!=1:
        raise ValueError("Duplicate multicast points or mixed compiled builds")
    output.mkdir(parents=True,exist_ok=True)
    for folder in ("tables","provenance"):
        (output/folder).mkdir(exist_ok=True)
    points.sort(key=lambda p:(p["message_bytes"],p["method"],p["batch_bytes"]))
    speedups=[]
    for size in sorted({p["message_bytes"] for p in points}):
        cohort=[p for p in points if p["message_bytes"]==size]
        seq=[p for p in cohort if p["method"]=="seq"]
        tree,=[p for p in cohort if p["method"]=="tree"]
        hw,=[p for p in cohort if p["method"]=="hw"]
        batches={1024*2**i for i in range(6) if 1024*2**i<=size}
        if {p["batch_bytes"] for p in seq}!=batches:
            raise ValueError("Missing paper-candidate seq batches")
        best=min(seq,key=lambda p:p["runtime_cycles"])
        speedups.append(dict(message_bytes=size,seq_batch_bytes=best["batch_bytes"],
            Tseq_cycles=best["runtime_cycles"],Ttree_cycles=tree["runtime_cycles"],
            Thw_cycles=hw["runtime_cycles"],
            speedup=min(best["runtime_cycles"],tree["runtime_cycles"])/hw["runtime_cycles"]))
    with (output/"tables/points.csv").open("w",newline="") as f:
        w=csv.DictWriter(f,fieldnames=list(points[0]));w.writeheader();w.writerows(points)
    with (output/"tables/speedup.csv").open("w",newline="") as f:
        w=csv.DictWriter(f,fieldnames=list(speedups[0]));w.writeheader();w.writerows(speedups)
    (output/"provenance/performance.py").write_bytes(Path(__file__).read_bytes())
    (output/"provenance/measurement.json").write_text(json.dumps(dict(command=[sys.executable]+sys.argv,
        script_sha256=digest(Path(__file__)),cases=len(points),scope="Single-row saved measurements; 2D campaign separate",
        formula="runtime_cycles=(last required source B - root AWVALID assertion)/clock_period; no inclusive +1",
        source="picobello cacdc3ad4a3a638e68d03090781dbbc2450c73ed, Fig.4/5",
        differences=["Native root NI12 and row0 NI0..NI3","VIP push writes, no memory fetch",
                     "Zero-time local memory access; source-B wave barriers, no CPU/DMA/barrier instructions"],
        publication_result=False),indent=2)+"\n")
    print("Validated",len(points),"one-row multicast runs")


def multicast_plots(output):
    """Plot validated single-row cohorts and multicast dataflows."""
    output = output.resolve()
    points_path = output/"tables/points.csv"
    points = list(csv.DictReader(points_path.open()))
    sizes = sorted({int(p["message_bytes"]) for p in points})
    measured = {}
    for size in sizes:
        cohort = [p for p in points if int(p["message_bytes"]) == size]
        expected = {(method, size) for method in ("tree", "hw")}
        expected.update(("seq", batch) for batch in WIDE_SIZES if batch <= size)
        if len(cohort) != len(expected) or {(p["method"], int(p["batch_bytes"])) for p in cohort} != expected:
            raise ValueError("Incomplete multicast cohort: {}".format(size))
        measured[size] = {method: min(float(p["runtime_cycles"]) for p in cohort if p["method"] == method)
                          for method in ("seq", "tree", "hw")}
    configs, records = {}, []
    for point in points:
        root = output/point["run"]
        run = root/"runs"/point["case"]
        config_path = run/"inputs/manifest.json"
        config = json.loads(config_path.read_text())["multicast"]
        metrics_path = root/"tables/metrics.json"
        metrics = json.loads(metrics_path.read_text())
        validation_path = root/"validation.json"
        validation = json.loads(validation_path.read_text())
        wave = run/(point["case"]+".fsdb")
        if (any(str(metrics[key]) != value for key, value in point.items()) or
                not validation["checker_passed"] or not validation["drain"] or
                validation["offline_calibration_comparison"] != "passed_against_this_run_FSDB" or
                not wave.is_file() or wave.stat().st_size == 0):
            raise ValueError("Saved multicast evidence differs from the CSV: "+point["case"])
        if (config["root"] != 12 or config["members"] != [0, 1, 2, 3] or
                config["message_bytes"] != int(point["message_bytes"]) or config["method"] != point["method"] or
                config["batch_bytes"] != int(point["batch_bytes"]) or
                int(point["root"]) != 12 or int(point["recipients"]) != 4 or
                int(point["message_bytes"]) not in WIDE_SIZES):
            raise ValueError("Unexpected dataflow geometry or workload")
        configs[config["method"]] = config
        records.append(dict(case=point["case"], runtime_cycles=float(point["runtime_cycles"]),
            run=point["run"], seed=int(point["seed"]), binary_sha256=point["binary_sha256"],
            source_manifest_sha256=point["source_manifest_sha256"],
            manifest_sha256=digest(config_path), metrics_sha256=digest(metrics_path),
            validation_sha256=digest(validation_path), fsdb_sha256=validation["fsdb_sha256"]))

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import FancyArrowPatch, Rectangle
    figures = output/"figures"
    figures.mkdir(exist_ok=True)
    colors = dict(seq="#4477AA", tree="#CC6677", hw="#228833")
    plt.rcParams.update({"font.size": 11, "svg.fonttype": "none"})
    series = (("seq", "Pipelined sequential", "o"), ("tree", "Binary tree", "s"), ("hw", "Hardware multicast", "^"))
    for name, ylabel in (("runtime", "Runtime [cycles]"), ("speedup", "Speedup [×]")):
        fig, ax = plt.subplots(figsize=(6.7, 4.0))
        if name == "runtime":
            x = sizes
            for method, label, marker in series:
                ax.plot(x, [measured[s][method] for s in sizes], marker=marker,
                        color=colors[method], label=label, linestyle="none")
            ax.legend(frameon=False)
            ax.set_xticks([1024,4096,8192,16384,32768])
            ax.set_xlabel("Size [B]")
        else:
            x = [size//1024 for size in sizes]
            ax.plot(x, [min(measured[s]["seq"], measured[s]["tree"])/measured[s]["hw"] for s in sizes],
                    marker="o", color=colors["hw"])
            ax.set_xscale("log", base=2)
            ax.set_xticks(x)
            ax.set_xticklabels(x)
            ax.set_xlabel("Message size [KiB]")
        ax.set(ylabel=ylabel, ylim=(0,None))
        ax.grid(axis="y", linestyle="--", alpha=.25)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        fig.tight_layout()
        for suffix in ("png", "svg"):
            fig.savefig(str(figures/(name+"."+suffix)), dpi=220)
        plt.close(fig)

    fig, axes = plt.subplots(1, 3, figsize=(12.5, 3.5))
    positions = {12: (0, 0), 0: (0, 1.8), 1: (1.5, 1.8),
                 2: (3, 1.8), 3: (4.5, 1.8)}
    for ax, method, title in zip(axes, ("seq", "tree", "hw"),
                                ("Pipelined sequential", "Binary tree", "Hardware multicast")):
        config = configs[method]
        color = colors[method]
        for node, (x, y) in positions.items():
            ax.add_patch(Rectangle((x-.42, y-.26), .84, .52, zorder=3,
                facecolor="#F0F0F0" if node == 12 else "#EAF0F6",
                edgecolor="#637080", linewidth=1.1))
            ax.text(x, y, "NI"+str(node), ha="center", va="center", zorder=4)
        if method == "hw":
            ax.plot([0, 0, 4.5], [.26, .85, .85], color=color, linewidth=2)
            for member in config["members"]:
                x, y = positions[member]
                ax.add_patch(FancyArrowPatch((x, .85), (x, y-.28),
                    arrowstyle="-|>", mutation_scale=13, linewidth=2, color=color))
                ax.plot(x, .85, "o", color=color, markersize=3)
        else:
            edges = {(job["source"], job["destination"]) for job in config["jobs"]}
            for source, destination in sorted(edges):
                curved = source == 0 and destination == 2
                ax.add_patch(FancyArrowPatch(positions[source], positions[destination],
                    arrowstyle="-|>", mutation_scale=13, linewidth=2, color=color,
                    shrinkA=22 if source == 12 else 29,
                    shrinkB=22 if source == 12 else 29,
                    connectionstyle="arc3,rad=-.5" if curved else "arc3,rad=0"))
        ax.text(0, -.52, "Root", ha="center", fontsize=10)
        ax.set_title(title, fontsize=12)
        ax.set_xlim(-.65, 5.05)
        ax.set_ylim(-.72, 2.95)
        ax.axis("off")
    fig.tight_layout(w_pad=1.2)
    for suffix in ("png", "svg"):
        fig.savefig(str(figures/("data-flow."+suffix)), dpi=220)
    plt.close(fig)

    fig, axes = plt.subplots(1, 2, figsize=(13, 4.8))
    for ax, use_mask in zip(axes, (False, True)):
        for y in range(4):
            for col in range(5):
                label = "M{}".format(y) if col == 0 else "NI{}".format(4*y+col-1)
                ax.text(col, y, label, ha="center", va="center", zorder=4,
                        bbox=dict(boxstyle="round,pad=.26", facecolor="#F2F5F8", edgecolor="#617281"))
            ax.annotate("", (0.8,y), (.20,y), arrowprops=dict(arrowstyle="-|>", color="#333333"))
            if use_mask:
                ax.plot([1.12,1.24,4],[y+.12,y+.40,y+.40],color="#228833",lw=1.7)
                ax.plot([1,1.24],[y+.40,y+.40],color="#228833",lw=1.7)
                for x in (1,2,3,4):
                    ax.annotate("",(x,y+.13),(x,y+.40),arrowprops=dict(arrowstyle="-|>",color="#228833"))
            else:
                ax.add_patch(FancyArrowPatch((.90,y+.13),(1.10,y+.13),arrowstyle="-|>",
                    mutation_scale=12,color="#4477AA",lw=1.6,connectionstyle="arc3,rad=-2.2"))
                for x in (2,3,4):
                    ax.add_patch(FancyArrowPatch((1.18,y),(x-.18,y),arrowstyle="-|>",
                        mutation_scale=12,color="#4477AA",lw=1.6,connectionstyle="arc3,rad={}".format(.11*(x-2))))
        ax.set_title("Row multicast" if use_mask else "Direct unicast")
        ax.set(xlim=(-.45,4.45),ylim=(-.80,3.62))
        ax.axis("off")
    from matplotlib.lines import Line2D
    fig.legend(handles=[Line2D([0],[0],color=c,label=l) for c,l in
               (("#333333","Memory read data"),("#4477AA","Unicast"),("#228833","Multicast"))],
               loc="lower center",ncol=3,frameon=False)
    fig.tight_layout(rect=(0,.08,1,1))
    for suffix in ("png", "svg"):
        fig.savefig(str(figures/("memory-data-flow."+suffix)),dpi=220)
    plt.close(fig)

    snapshot = output/"provenance/plot-performance.py"
    snapshot.write_bytes(Path(__file__).read_bytes())
    files = [figures/(name+"."+suffix) for name in ("runtime", "speedup", "data-flow", "memory-data-flow") for suffix in ("png", "svg")]
    (output/"provenance/plot.json").write_text(json.dumps(dict(
        command=[sys.executable]+sys.argv, script_sha256=digest(snapshot),
        input_csv_sha256=digest(points_path), message_bytes=sizes, cases=records,
        geometry="Measured single-row distribution from NI12 to NI0..NI3. Branches show logical fanout.",
        memory_data_flow="Four west memories, four recipients per row including the distributing node.",
        software_edges="Unique source/destination pairs from each saved input manifest",
        runtime_boundary="root AWVALID assertion to last required source B handshake, in cycles",
        outputs={str(p.relative_to(output)): digest(p) for p in files}), indent=2)+"\n")
    print("Saved multicast runtime and logical dataflow figures under", figures)



def row_feed_report(roots, output):
    from collections import defaultdict
    from axi_file_parser import _parse_write
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    thresholds = {}
    readiness = {}
    rows = []
    for root in roots:
        run, = (root/"runs").iterdir()
        method = run.name.split("_")[-1]
        copies = {"unicast": 4, "multicast": 1}[method]
        record = json.loads((run/(run.name+".run.json")).read_text())
        wave = run/(run.name+".fsdb")
        if not record["passed"] or digest(wave) != record["waveform"]["sha256"]:
            raise ValueError("Missing valid simulation or waveform")
        clk = record["clock"]["axi_period_ps"]
        starts = defaultdict(dict)
        for batch, source, stamp in re.findall(r"^ROW_PREFETCH batch=(\d+) source=requests(\d+) time_ps=(\d+)$",
                (run/(run.name+".log")).read_text(), re.M):
            starts[int(batch)][int(source)] = int(stamp)
        if sorted(starts) != list(range(4)) or any(set(v) != {0,4,8,12} or len(set(v.values())) != 1 for v in starts.values()):
            raise ValueError("Missing common prefetch start")
        vcd = run/"interfaces.vcd"
        command = ["fsdb2vcd", str(wave.resolve()), "-o", str(vcd.resolve()), "-s", "/tb_top", "-level", "3"]
        with (run/"interfaces-export.log").open("w") as log:
            subprocess.check_call(command, stdout=log, stderr=subprocess.STDOUT)
        bindings, payload = {}, {}
        for y in range(4):
            for role, node, ch in ([("device",16+y,"ar"), ("device",16+y,"r"), ("source",4*y,"r"),
                                    ("source",4*y,"aw"), ("source",4*y,"w")] +
                                   [("device",4*y+x,c) for x in range(4) for c in ("aw","w")]):
                base = "tb_top.gen_node[{}].{}_bus.{}".format(node,role,ch)
                key = (role,node,ch)
                bindings[key] = ("axi",base+"valid",base+"ready",None)
                if ch in ("r","w"):
                    payload[key] = [base+"data", base+("strb" if ch=="w" else "resp"),base+"last"]
                else:
                    payload[key] = [base+"addr",base+"len",base+"size"]
                if role == "device" and ch == "r":
                    bindings[role,node,"rvalid"] = ("axi",base+"valid",base+"valid",None)
        events = sampled_handshakes(vcd,bindings,payload)
        raw = defaultdict(list)
        with (run/"axi-events.csv").open() as stream:
            for r in csv.DictReader(stream):
                raw[r["role"],int(r["endpoint"]),r["channel"].lower()].append(int(r["time_ps"]))
        for key in payload:
            if [e["time_ps"] for e in events[key]] != raw[key]:
                raise ValueError("FSDB/collector disagreement at "+str(key))
        batches = sorted(starts)
        ready = {}
        for y in range(4):
            source, mem = 4*y, 16+y
            inputs = run/"inputs" if y==0 else run/"inputs"/("source"+str(source))
            expected = _parse_write(inputs/"write.txt")
            def trace(role, node, channel):
                return events[role,node,channel]
            src_w = trace("source",source,"w")
            if len(src_w)!=len(batches)*32*copies or len(expected)!=len(batches)*copies:
                raise ValueError("Source burst count mismatch")
            for k in batches:
                offset = k*32
                words = [int(line.split()[0],16) for line in expected[k*copies]["beats"]]
                rbeats = [[word,0,int(j==31)] for j,word in enumerate(words)]
                wbeats = [[word,(1<<64)-1,int(j==31)] for j,word in enumerate(words)]
                for role,node in (("source",source),("device",mem)):
                    r = trace(role,node,"r")
                    if len(r)!=len(batches)*32 or [e["payload"] for e in r[offset:offset+32]]!=rbeats:
                        raise ValueError("DDR payload mismatch")
                ar = trace("device",mem,"ar")
                r = trace("device",mem,"r")
                valid = trace("device",mem,"rvalid")
                if (len(ar)!=len(batches) or len(valid)!=len(r) or valid[offset]["time_ps"]!=r[offset]["time_ps"] or
                        r[offset]["time_ps"]-ar[k]["time_ps"]!=29*clk or
                        any(r[j+1]["time_ps"]-r[j]["time_ps"]!=clk for j in range(offset,offset+31)) or
                        ar[k]["payload"]!=[0x1000000000+y*0x100000+k*2048,31,6]):
                    raise ValueError("DDR address, first-beat delay or burst service mismatch")
                aw = trace("source",source,"aw")
                if (len(aw)!=len(batches)*copies or
                        aw[k*copies]["time_ps"] < trace("source",source,"r")[offset+31]["time_ps"]):
                    raise ValueError("Write preceded memory fetch completion")
                section = src_w[offset*copies:(offset+32)*copies]
                if [e["payload"] for e in section] != wbeats*copies:
                    raise ValueError("Forwarded source payload mismatch")
                for x in range(4):
                    node=source+x
                    writes=trace("device",node,"w")
                    addresses=trace("device",node,"aw")
                    if (len(addresses)!=len(batches) or addresses[k]["payload"] != [node*0x100000000+0x4000+(k%2)*2048,31,6] or
                            len(writes)!=len(batches)*32 or [e["payload"] for e in writes[offset:offset+32]]!=wbeats):
                        raise ValueError("Incorrect recipient, address or payload at NI"+str(node))
                    end = writes[offset+31]["time_ps"]
                    begin = starts[k][source]
                    if end<=begin or (end-begin)%clk:
                        raise ValueError("Invalid recipient timing window")
                    ready[k,node]=(end-begin)//clk
                    rows.append([method,k,node,begin,end,ready[k,node]])
        # Batch 0 fills the first buffer. Batch 3 ends the run.
        steady = batches[1:-1]
        readiness[method] = [max(ready[k,n] for n in range(16)) for k in steady]
        thresholds[method] = []
        for k in steady:
            start, following = starts[k][0], starts[k+1][0]
            last_b = max(t for n in (0,4,8,12) for t in raw["source",n,"b"] if start < t <= following)
            if following != last_b or (following-start)%clk:
                raise ValueError("Prefetch barrier does not match last B")
            thresholds[method].append((following-start)//clk)
        validation = dict(case=run.name, seed=record["simulation_seed"], clock_ps=clk,
            binary_sha256=record["binary_sha256"],source_manifest_sha256=record["source_manifest_sha256"],
            fsdb_sha256=digest(wave),vcd_sha256=digest(vcd),export_command=command,
            measured_ddr_first_beat_cycles=29, measured_ddr_beat_interval_cycles=1,
            checked_batches=len(batches), recipients_per_batch=16, checked_bytes_per_recipient=2048,
            steady_batches=steady, first_fill_cycles=max(ready[0,n] for n in range(16)),
            threshold_by_node=[max(ready[k,n] for k in steady) for n in range(16)],
            all_data_ready_cycles=max(readiness[method]),
            sustained_threshold_cycles=max(thresholds[method]), prefetch_intervals_cycles=thresholds[method])
        validation.update(checker_passed=record["passed"],
                          drain="AXI_ORDERING_CHECK_DRAINED" in (run/(run.name+".log")).read_text(),
                          performance_error=record["performance_error"],
                          offline_calibration_comparison="FSDB matched accepted events, data and timing",
                          scope="Four-row 2 KiB supply model with a shared batch barrier")
        (root/"validation.json").write_text(json.dumps(validation,indent=2)+"\n")
        campaign_path=root/"campaign.json"
        campaign=json.loads(campaign_path.read_text())
        campaign.update(purpose="four-row memory distribution", publication_result=True)
        campaign_path.write_text(json.dumps(campaign,indent=2)+"\n")
    if set(thresholds)!= {"unicast","multicast"}:
        raise ValueError("Both distribution modes are required")
    with (output/"tables/row-feed.csv").open("w", newline="") as stream:
        writer=csv.writer(stream,lineterminator="\n")
        writer.writerow(["method","batch","node","prefetch_start_ps","last_accepted_w_ps","ready_cycles"])
        writer.writerows(rows)
    limit=max(max(ds) for ds in thresholds.values())
    with (output/"tables/utilization.csv").open("w",newline="") as stream:
        writer=csv.writer(stream,lineterminator="\n")
        writer.writerow(["method","compute_cycles","data_ready_model_percent","sustained_percent"])
        for method,ds in thresholds.items():
            for c in range(limit+26):
                writer.writerow([method,c]+[100*len(q)*c/sum(max(c,d) for d in q) for q in (readiness[method],ds)])
    row_feed_curve(output)


def row_feed_curve(output):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    with (output/"tables/utilization.csv").open() as stream:
        points = list(csv.DictReader(stream))
    fig, ax = plt.subplots(figsize=(6.3,3.5))
    for method,color in (("unicast","#1665a8"),("multicast","#b45818")):
        series = [r for r in points if r["method"] == method]
        x = [int(r["compute_cycles"]) for r in series]
        y = [float(r["sustained_percent"]) for r in series]
        threshold = min(c for c,u in zip(x,y) if u >= 100)
        ax.plot(x,y,label=method.capitalize(),color=color)
        ax.plot(threshold,100,"o",color=color)
        ax.annotate(str(threshold),(threshold,100),xytext=(0,5),textcoords="offset points",ha="center")
    ax.set(xlabel="Compute time per batch [cycles]",ylabel="Estimated steady-state\ncompute utilization [%]",ylim=(0,113),xlim=(0,max(x)))
    ax.grid(alpha=.22)
    ax.legend(loc="lower right")
    fig.tight_layout()
    for ext in ("png","svg"):
        fig.savefig(str(output/"figures"/("utilization."+ext)),dpi=200)
    plt.close(fig)


def row_feed_heatmap(output):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import Normalize
    from collections import defaultdict

    arrivals = defaultdict(dict)
    for row in csv.DictReader((output/"tables/row-feed.csv").open()):
        key = row["method"], int(row["node"])
        batch = int(row["batch"])
        if batch in arrivals[key]:
            raise ValueError("Duplicate node delivery")
        arrivals[key][batch] = int(row["last_accepted_w_ps"]), int(row["ready_cycles"])
    methods = ("unicast", "multicast")
    periods = {}
    delays = {}
    for method in methods:
        check = json.loads((output/"results"/("feed-"+method+"-ddr")/"validation.json").read_text())
        clk = check["clock_ps"]
        for node in range(16):
            key = method,node
            times = arrivals[key]
            steady = check["steady_batches"]
            spans = [times[k+1][0]-times[k][0] for k in steady]
            if any(p<=0 or p%clk for p in spans):
                raise ValueError("Invalid interval between complete batches")
            periods[key] = [p//clk for p in spans]
            delays[key] = [times[k][1] for k in steady]
    compute = max(periods["multicast",3])
    values = []
    fig, axes = plt.subplots(2,2,figsize=(7.8,6.9))
    fig.subplots_adjust(left=.04,right=.84,bottom=.04,top=.94,hspace=.14,wspace=.06)
    maximum_delay = max(max(d) for d in delays.values())
    for row in range(2):
        norm = Normalize(0,100 if row == 0 else maximum_delay)
        for col,method in enumerate(methods):
            ax = axes[row,col]
            numbers = []
            for node in range(16):
                intervals = periods[method,node]
                percent = 100*len(intervals)*compute/sum(max(compute,x) for x in intervals)
                steady_delays = set(delays[method,node])
                if len(steady_delays) != 1:
                    raise ValueError("Expected repeatable delivery time for the two measured batches")
                delay = steady_delays.pop()
                if row == 0:
                    values.append([method,node,compute,percent,delay])
                numbers.append(percent if row == 0 else delay)
            matrix = [numbers[i:i+4] for i in range(0,16,4)]
            im = ax.imshow(matrix,origin="lower",cmap="Blues" if row == 0 else "Oranges",norm=norm)
            for n,v in enumerate(numbers):
                label = "{:.1f}%".format(v) if row == 0 else str(v)
                ax.text(n%4,n//4,"NI{}\n{}".format(n,label),ha="center",va="center",
                        fontsize=9,color="white" if norm(v)>.65 else "black")
            ax.set(xticks=[],yticks=[])
            if row == 0:
                ax.set_title(("Direct unicast","Hardware multicast")[col])
        bar = fig.colorbar(im,cax=fig.add_axes([.86,.57 if row==0 else .10,.022,.28]))
        bar.set_label(("Estimated steady-state\ncompute utilization [%]\n({} cycles/batch)".format(compute),
                       "Time to receive one batch [cycles]")[row],fontsize=9)
    for ext in ("png","svg"):
        fig.savefig(str(output/"figures"/("node-utilization."+ext)),dpi=200,bbox_inches="tight")
    plt.close(fig)
    with (output/"tables/node-utilization.csv").open("w",newline="") as stream:
        w=csv.writer(stream,lineterminator="\n")
        w.writerow(["method","node","compute_cycles","estimated_steady_state_compute_utilization_percent","time_to_receive_one_batch_cycles"])
        w.writerows(values)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--results", nargs="+", type=Path)
    group.add_argument("--tile-to-tile", type=Path)
    group.add_argument("--latency-results", nargs="+", type=Path)
    group.add_argument("--interference-results", nargs="+", type=Path)
    group.add_argument("--cross-results", nargs="+", type=Path)
    group.add_argument("--boundary-results", nargs="+", type=Path)
    group.add_argument("--multicast-results", nargs="+", type=Path)
    group.add_argument("--row-feed-heatmap", type=Path)
    group.add_argument("--row-feed", nargs=2, type=Path)
    group.add_argument("--multicast-plot", type=Path)
    parser.add_argument("--output", type=Path, help="Directory for the combined traffic plots")
    args = parser.parse_args()
    if args.row_feed_heatmap:
        row_feed_heatmap(args.row_feed_heatmap)
        row_feed_curve(args.row_feed_heatmap)
    elif args.row_feed:
        if args.output is None:
            parser.error("--row-feed requires --output")
        row_feed_report(args.row_feed,args.output)
    elif args.multicast_plot:
        multicast_plots(args.multicast_plot)
    elif args.multicast_results:
        if args.output is None:
            parser.error("--multicast-results requires --output")
        multicast_report(args.multicast_results,args.output)
    elif args.boundary_results:
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
