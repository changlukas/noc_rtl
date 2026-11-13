#!/usr/bin/env python3
"""Render saved NoC measurements; no stimulus or simulation entry."""
import argparse
import csv
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def neighbor_curve(results, output):
    output = output.resolve()
    points = []
    context = None
    for root in results:
        root = root.resolve()
        runs = list((root / "runs").iterdir())
        if len(runs) != 1:
            raise ValueError("Expected one run per result: " + str(root))
        run = runs[0]
        record = json.loads((run / (run.name + ".run.json")).read_text())
        validation = json.loads((root / "validation.json").read_text())
        summary = json.loads((root / "tables/summary.json").read_text())
        if (not record["passed"] or not validation["drain"] or
                validation["offline_calibration_comparison"] != "passed_against_this_run_FSDB" or
                validation.get("marker_calibration", {}).get("status") != "passed_against_this_run_FSDB"):
            raise ValueError("Uncalibrated result: " + str(root))
        if summary != record["performance"]:
            raise ValueError("Summary does not match the actual run record")
        wave = run / (run.name + ".fsdb")
        if not wave.stat().st_size or digest(wave) != record["waveform"]["sha256"]:
            raise ValueError("Waveform hash mismatch")
        current = (record["binary_sha256"], record["source_manifest_sha256"],
                   record["seed"], record["clock"], digest(root / "config/recipe.json"))
        if context is not None and current != context:
            raise ValueError("Curve points use different build/clock/seed/config")
        context = current
        tiles = summary["source_tiles"]
        if sorted(t["endpoint"] for t in tiles) != list(range(16)):
            raise ValueError("Neighbor curve requires all 16 native sources")
        if any(t["monitor_window"] is None or t["monitor_window"]["cycles"] <= 0 for t in tiles):
            raise ValueError("Missing per-tile monitor window")
        sizes = {t["directions"]["read"]["useful_bytes"] for t in tiles}
        if len(sizes) != 1 or any(set(t["directions"]) != {"read"} for t in tiles):
            raise ValueError("Expected equal read jobs at every tile")
        size, = sizes
        if run.name != "perf_neighbor_read_{}kib".format(size // 1024):
            raise ValueError("Expected the matching neighbor case, not another traffic pattern")
        mean = summary["source_tile_average"]["read"]["monitor_payload_utilization_percent"]
        if mean is None or not 0 <= mean <= 100:
            raise ValueError("Missing full-width monitor utilization")
        points.append(dict(root=os.path.relpath(str(root), str(output)), run_id=root.name, transfer_bytes=size,
                           mean_utilization_percent=mean, source_tiles=16,
                           summary_sha256=digest(root / "tables/summary.json"),
                           waveform_sha256=record["waveform"]["sha256"]))
    points.sort(key=lambda p: p["transfer_bytes"])
    if [p["transfer_bytes"] for p in points] != [1024, 2048, 4096, 8192, 16384, 32768]:
        raise ValueError("Expected the six paper transfer sizes exactly once")
    destinations = [output / "figures/neighbor-wide.png", output / "figures/neighbor-wide.svg",
                    output / "tables/neighbor-wide-curve.csv", output / "provenance/neighbor-wide-plot.json"]
    if any(path.exists() for path in destinations):
        raise ValueError("Refuse to overwrite existing curve artifacts")
    for path in destinations:
        path.parent.mkdir(parents=True, exist_ok=True)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy
    fig, ax = plt.subplots(figsize=(6.4, 4.5))
    ax.plot([p["transfer_bytes"] / 1024 for p in points],
            [p["mean_utilization_percent"] for p in points], "o-", color="#1665a8",
            linewidth=1.7, label="Neighbor")
    ax.set(xlabel="Transfer size [KiB]", ylabel="Avg. BW Util [%]",
           xlim=(0, 33), ylim=(0, 100))
    ax.legend(frameon=False)
    ax.set_xticks([1, 2, 4, 8, 16, 32])
    ax.set_yticks([0, 50, 100])
    ax.grid(True, linestyle="--", alpha=0.35)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    fig.tight_layout()
    fig.savefig(str(destinations[0]), dpi=180)
    fig.savefig(str(destinations[1]))
    plt.close(fig)
    with destinations[2].open("x", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(points[0]))
        writer.writeheader()
        writer.writerows(points)
    provenance = dict(command=[sys.executable] + sys.argv, script_sha256=digest(Path(__file__)),
                      python=sys.version, matplotlib=matplotlib.__version__, numpy=numpy.__version__,
                      points=points, publication_result=False,
                      metric="Mean full-width source payload utilization across the 16 native tiles",
                      traffic="One neighbor read job per source on the native 4x4 mesh",
                      limitation="Native platform and VIP; exact FlooNoC experiment RTL revision is unverified")
    with destinations[3].open("x") as stream:
        json.dump(provenance, stream, indent=2)
        stream.write("\n")
    print("Saved PNG/SVG and curve data under", output)


def narrow_curve(results, output):
    """Average the saved per-source narrow read latency, as in FlooNoC Fig.8."""
    output = output.resolve()
    points, sources = [], []
    context = None
    for root in results:
        root = root.resolve()
        run, = (root / "runs").iterdir()
        record = json.loads((run / (run.name + ".run.json")).read_text())
        validation = json.loads((root / "validation.json").read_text())
        summary = json.loads((root / "tables/summary.json").read_text())
        transfers = json.loads((root / "tables/transactions.json").read_text())
        if (not record["passed"] or not validation["drain"] or summary != record["performance"] or
                validation["offline_calibration_comparison"] != "passed_against_this_run_FSDB" or
                validation.get("marker_calibration", {}).get("status") != "passed_against_this_run_FSDB"):
            raise ValueError("Uncalibrated narrow result: " + str(root))
        current = (record["binary_sha256"], record["source_manifest_sha256"],
                   record["seed"], record["clock"], digest(root / "config/recipe.json"))
        if context is not None and current != context:
            raise ValueError("Latency points use different build/clock/seed/config")
        context = current
        wave = run / (run.name + ".fsdb")
        if not wave.stat().st_size or digest(wave) != record["waveform"]["sha256"]:
            raise ValueError("Waveform hash mismatch")
        ratio, = [float(arg.split("=", 1)[1]) for arg in record["command"]
                  if arg.startswith("+injection_ratio=")]
        if not 0 < ratio <= 0.5 or not run.name.startswith("neighbor_"):
            raise ValueError("Expected a neighbor injection point in (0, 0.5]")
        tiles = summary["source_tiles"]
        if sorted(tile["endpoint"] for tile in tiles) != list(range(16)):
            raise ValueError("Expected all 16 source tiles")
        begin = len(sources)
        for tile in tiles:
            endpoint = tile["endpoint"]
            rows = [t for t in transfers if t["role"] == "source" and
                    t["phase"] == 1 and t["endpoint"] == endpoint]
            target = (endpoint // 4) * 4 + (endpoint + 1) % 4
            if (len(rows) != 32 or any(t["direction"] != "read" or t["beats"] != 1 or
                    t["size"] != 3 or t["useful_bytes"] != 8 or t["addr"] >> 32 != target for t in rows)):
                raise ValueError("Expected 32 single-beat neighbor reads per source")
            first = min(t["request_ps"] for t in rows)
            last = max(t["request_ps"] for t in rows)
            period = record["clock"]["axi_period_ps"]
            sources.append(dict(run=os.path.relpath(str(root), str(output)),
                injection_ratio=ratio, endpoint=endpoint, x=tile["x"], y=tile["y"],
                transfers=len(rows), first_ar_ns=first / 1000, last_ar_ns=last / 1000,
                last_r_ns=max(t["completion_ps"] for t in rows) / 1000,
                mean_latency_cycles=tile["directions"]["read"]["mean_first_response_latency_cycles"],
                actual_injection_ratio=(len(rows) - 1) * period / (last - first)))
        measured = sources[begin:]
        points.append(dict(run=os.path.relpath(str(root), str(output)),
            injection_ratio=ratio, mean_latency_cycles=sum(t["mean_latency_cycles"] for t in measured) / 16,
            actual_injection_ratio=sum(t["actual_injection_ratio"] for t in measured) / 16,
            source_tiles=16, reads_per_source=32, waveform_sha256=record["waveform"]["sha256"]))
    points.sort(key=lambda point: point["injection_ratio"])
    if len({point["injection_ratio"] for point in points}) != len(points):
        raise ValueError("Duplicate injection ratios")
    paths = [output / "figures/neighbor-latency.png", output / "figures/neighbor-latency.svg",
             output / "tables/neighbor-latency.csv", output / "tables/neighbor-latency-sources.csv",
             output / "provenance/neighbor-latency-plot.json"]
    if any(path.exists() for path in paths):
        raise ValueError("Refuse to overwrite existing latency artifacts")
    for path in paths:
        path.parent.mkdir(parents=True, exist_ok=True)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(6.4, 4.5))
    ax.plot([p["injection_ratio"] for p in points], [p["mean_latency_cycles"] for p in points],
            "o-", color="#1665a8", linewidth=1.7, label="Neighbor")
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
        injection="Configured Bernoulli parameter on x axis; realized AR interarrival ratio in CSV",
        differences=["Native 4x4/VIP platform", "Paper adds 7 cluster cycles; native values use AXI boundaries",
                     "Public candidate driver quantizes probability through an integer draw in [0,100]",
                     "Exact experiment RTL revision is unverified"], points=points,
        publication_result=False), indent=2) + "\n")
    print("Saved neighbor latency PNG/SVG and tables under", output)


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
    parser.add_argument("--output", type=Path, help="Directory for the combined neighbor curve")
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
        neighbor_curve(args.results, args.output)
