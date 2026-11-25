"""Rebuild the mesh narrow-read stage tables from the ten saved waveform exports."""
import argparse
import csv
import json
import sys
from collections import Counter, defaultdict, deque
from pathlib import Path


STAGES = ("source_req", "mesh_req", "device_req", "device_service",
          "device_rsp", "mesh_rsp", "source_rsp")
BOUNDARIES = ("source_ar", "req_in", "req_out", "device_ar", "device_r",
              "rsp_in", "rsp_out", "source_r")
PATTERNS = ("neighbor", "bit-complement", "transpose", "uniform", "shuffle")


def node(header, shift):
    address = (header >> shift) & 1023
    assert address >> 8 == 0 and (address & 15) < 4 and (address >> 4) < 4
    return (address >> 4) * 4 + (address & 15)


def extract(root, sample, digest, pattern, condition, point):
    result = root / point["run"]
    run, = (result / "runs").iterdir()
    wave = run / (run.name + ".fsdb")
    vcd = run / "interfaces.vcd"
    assert digest(wave) == point["waveform_sha256"]
    validation = json.loads((result / "validation.json").read_text())
    assert validation["drain"] and validation["checker_passed"]
    record = json.loads((run / (run.name + ".run.json")).read_text())
    assert record["passed"] and record["clock"] == {
        "axi_period_ps": 1000, "noc_period_ps": 1000, "noc_phase_ps": 0}

    bindings, payloads = {}, {}
    ports = ("rx_req", "tx_req", "rx_rsp", "tx_rsp")
    for port in ports:
        base = "tb_top." + port
        for tile in range(16):
            key = (port, tile)
            bindings[key] = ("noc", base + "_valid", base + "_ready", tile)
            payloads[key] = [base + "_flit[{}]".format(tile)]
    for tile in range(16):
        base = "tb_top.gen_node[{}].source_bus.".format(tile)
        # Sample each cycle with ARVALID asserted, including back-to-back requests.
        bindings["ar_active", tile] = ("axi", base + "arvalid", base + "arvalid", None)
        payloads["ar_active", tile] = [base + "araddr", base + "arready"]
    sampled = sample(vcd, bindings, payloads)
    active = {tile: deque(sampled.pop(("ar_active", tile))) for tile in range(16)}
    requests, responses = {}, defaultdict(list)
    for (port, tile), events in sampled.items():
        for e in events:
            flit, = e["payload"]
            sender, recipient = node(flit, 4), node(flit, 14)
            assert tile == (sender if port.startswith("rx") else recipient)
            assert (flit >> 24) & 1
            if port.endswith("req"):
                assert flit & 15 == 2
                addr = (flit >> 47) & ((1 << 48) - 1)
                key = (sender, recipient, addr, port)
                assert key not in requests
                requests[key] = (e["time_ps"], flit)
            else:
                assert flit & 15 == 4 and (flit >> 44) & 1
                responses[recipient, sender, port].append((e["time_ps"], flit))

    with (result / "tables/transactions.csv").open() as stream:
        transactions = list(csv.DictReader(stream))
    device = {int(r["addr"]): r for r in transactions if r["role"] == "device"}
    sources = sorted((r for r in transactions if r["role"] == "source"),
                     key=lambda r: int(r["request_ps"]))
    assert len(device) == len(sources) == 512 and len(transactions) == 1024
    assert all(r["beats"] == "1" and r["direction"] == "read" and r["size"] == "3"
               for r in transactions)
    ordinal, rows = Counter(), []
    for s in sources:
        # One AXI ID, one fixed destination per source; responses preserve issue order.
        assert s["id"] == "0" and s["phase"] == "1"
        addr, src = int(s["addr"]), int(s["endpoint"])
        d = device.pop(addr)
        dst = int(d["endpoint"])
        k = ordinal[src, dst]
        ordinal[src, dst] += 1
        req_in = requests.pop((src, dst, addr, "rx_req"))
        req_out = requests.pop((src, dst, addr, "tx_req"))
        rsp_in = responses[src, dst, "rx_rsp"][k]
        rsp_out = responses[src, dst, "tx_rsp"][k]
        assert req_in[1] == req_out[1] and rsp_in[1] == rsp_out[1]
        ts = [int(s["request_ps"]), req_in[0], req_out[0], int(d["request_ps"]),
              int(d["first_response_ps"]), rsp_in[0], rsp_out[0], int(s["first_response_ps"])]
        assert sorted(ts) == ts and ts[-1] - ts[0] == int(s["latency_ps"])
        samples = []
        while active[src] and active[src][0]["time_ps"] <= ts[0]:
            event = active[src].popleft()
            assert event["payload"][0] == addr
            samples.append((event["time_ps"], event["payload"][1]))
        assert samples and samples[-1] == (ts[0], 1)
        assert all(ready == 0 for _, ready in samples[:-1])
        assert all(b[0] - a[0] == 1000 for a, b in zip(samples, samples[1:]))
        row = dict(pattern=pattern, condition=condition, source=src, destination=dst,
                   address=addr, first_arvalid_sample_ps=samples[0][0],
                   ar_stall_cycles=len(samples)-1)
        row.update((key + "_ps", t) for key, t in zip(BOUNDARIES, ts))
        rows.append(row)
    assert len(ordinal) == 16 and set(ordinal.values()) == {32} and not requests
    assert len(responses) == 32 and all(len(v) == 32 for v in responses.values())
    assert all(not queue for queue in active.values())
    means = {stage: sum(r[b + "_ps"] - r[a + "_ps"] for r in rows) / (len(rows)*1000)
             for stage, a, b in zip(STAGES, BOUNDARIES, BOUNDARIES[1:])}
    total = sum(means.values())
    assert abs(total - float(point["mean_latency_cycles"])) < 1e-8
    summary = dict(pattern=pattern, condition=condition, transactions=len(rows))
    summary.update(means)
    stalls = [r["ar_stall_cycles"] for r in rows]
    summary.update(ar_stall_mean=sum(stalls)/len(rows), ar_stall_max=max(stalls),
                   ar_stalled_requests=sum(t > 0 for t in stalls))
    summary.update(total=total, waveform_sha256=digest(wave), vcd_sha256=digest(vcd))
    return rows, summary


def save_csv(path, rows):
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, list(rows[0]), lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def plot(rows, output):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    labels = ("Source NI (REQ)", "REQ mesh", "Destination NI (REQ)", "Device service",
              "Destination NI (RSP)", "RSP mesh", "Source NI (RSP)")
    colors = ("#b9d8ef", "#377eb8", "#78b7cd", "#d1d1d1", "#f7c887", "#df8535", "#b65d35")
    fig, ax = plt.subplots(figsize=(9.6, 5.6))
    ypos = [i * 2.5 + j for i in range(5) for j in range(2)]
    left = [0] * len(rows)
    for stage, label, color in zip(STAGES, labels, colors):
        values = [r[stage] for r in rows]
        ax.barh(ypos, values, left=left, height=.78, color=color, label=label)
        left = [a + b for a, b in zip(left, values)]
    for y, x in zip(ypos, left):
        ax.text(x + .25, y, "{:.2f}".format(x), va="center", fontsize=9)
    ax.set_yticks(ypos)
    ax.set_yticklabels(["{}   {}".format(r["pattern"].capitalize(), r["condition"]) for r in rows])
    ax.invert_yaxis()
    ax.set_xlim(0, max(left)+3)
    ax.set_xlabel("Mean time from source AR handshake [cycles]")
    ax.legend(ncol=3, frameon=False, loc="upper center", bbox_to_anchor=(.5, -.13), fontsize=9)
    ax.spines["right"].set_visible(False)
    ax.spines["top"].set_visible(False)
    fig.tight_layout()
    for ext in ("png", "svg"):
        fig.savefig(str(output / ("narrow-read-stages." + ext)), dpi=180)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", type=Path)
    parser.add_argument("output", type=Path, help="Existing output directory")
    args = parser.parse_args()
    repo = args.repo.resolve()
    sys.path.insert(0, str(repo / "dv/scripts"))
    from performance import digest, sampled_handshakes
    root = repo / "performance/unicast/mesh-traffic"
    with (root / "tables/latency.csv").open() as stream:
        points = {r["run"]: r for r in csv.DictReader(stream)}
    transactions, summaries = [], []
    for pattern in PATTERNS:
        for suffix, condition in (("zero", "Zero-load"), ("0p5", "0.5")):
            point, = [p for p in points.values() if p["pattern"].replace("_", "-") == pattern
                      and float(p["injection_ratio"]) == (0 if suffix == "zero" else .5)]
            rows, summary = extract(root, sampled_handshakes, digest, pattern, condition, point)
            transactions.extend(rows)
            summaries.append(summary)
            print(pattern, condition, *(summary[s] for s in STAGES), flush=True)
    save_csv(args.output / "narrow-read-events.csv", transactions)
    save_csv(args.output / "narrow-read-stages.csv", summaries)
    plot(summaries, args.output)


if __name__ == "__main__":
    main()
