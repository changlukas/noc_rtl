"""Reconstruct boundary memory reads from accepted AXI and router transfers."""
import csv
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


ROOT = Path(__file__).resolve().parents[1]
COLUMNS = """case source memory x mesh_hops transaction address source_ar_ps
src_router_req_tx_ps west_router_req_tx_ps memory_ar_ps memory_first_r_ps
memory_rlast_ps west_router_dat_tail_tx_ps src_router_dat_tail_tx_ps
source_rlast_ps""".split()
EVENTS = COLUMNS[7:]
LABELS = [
    "Source AR to first REQ TX", "REQ mesh traversal", "Last REQ TX to memory AR",
    "Memory AR to first R", "First R to memory RLAST", "Memory RLAST to first DAT TX",
    "DAT tail mesh traversal", "Last DAT TX to source RLAST",
]
COLORS = ["#556b82", "#88b0be", "#accaab", "#c27631",
          "#e1b66e", "#77639a", "#b19bc3", "#59485f"]


def read_csv(path):
    with path.open() as stream:
        yield from csv.DictReader(stream)


def reconstruct(case):
    tables = ROOT / "results" / case / "tables"
    transactions = list(read_csv(tables / "transactions.csv"))
    device_by_address = {
        row["addr"]: row for row in transactions if row["role"] == "device"
    }
    by_source = defaultdict(list)
    for row in transactions:
        if row["role"] == "source":
            by_source[int(row["endpoint"])].append(row)
    assert len(device_by_address) == sum(map(len, by_source.values()))

    transfers = defaultdict(list)
    for event in read_csv(tables / "channel-events.csv"):
        key = event["channel"], int(event["requester"]), int(event["router"])
        transfers[key].append(int(event["time_ps"]))

    for source, reads in sorted(by_source.items()):
        x = source % 4
        west = source - x
        req_first = transfers["req", source, source]
        req_last = transfers["req", source, west]
        dat_first = transfers["dat", source, west]
        dat_last = transfers["dat", source, source]
        assert len(req_first) == len(req_last) == len(reads) == 32
        assert {r["id"] for r in reads} == {"0"}
        assert len(dat_first) == len(dat_last) == sum(int(r["beats"]) for r in reads)

        # One AXI ID per source and a fixed return path preserve its burst order.
        tail_index = -1
        for index, read in enumerate(sorted(reads, key=lambda r: int(r["request_ps"]))):
            device = device_by_address[read["addr"]]
            tail_index += int(read["beats"])
            timestamps = [
                int(read["request_ps"]), req_first[index], req_last[index],
                int(device["request_ps"]), int(device["first_response_ps"]),
                int(device["completion_ps"]), dat_first[tail_index], dat_last[tail_index],
                int(read["completion_ps"]),
            ]
            assert timestamps == sorted(timestamps)
            assert timestamps[-1] - timestamps[0] == int(read["latency_ps"])
            metadata = [case, source, int(device["endpoint"]), x, x, index + 1, read["addr"]]
            yield dict(zip(COLUMNS, metadata + timestamps))


def plot_first_read(rows):
    fig, axes = plt.subplots(1, 2, figsize=(10.5, 3.25))
    for ax, case, title in zip(axes, ["read-zero-3", "read-full"], ["Zero load", "Full load"]):
        row = next(r for r in rows if r["case"] == case and r["source"] == 3 and r["transaction"] == 1)
        times = [(row[name] - row["source_ar_ps"]) / 1000 for name in EVENTS]
        for start, end, color, label in zip(times, times[1:], COLORS, LABELS):
            ax.barh([0], [end - start], left=[start], height=.35, color=color, label=label)
        ax.set_ylim(-.46, .46)
        ax.set_yticks([])
        ax.set_xlim(0, times[-1] * 1.03)
        ax.set_title("{}  |  {} cycles".format(title, int(times[-1])))
        ax.set_xlabel("Cycles from source AR")
        ax.tick_params(axis="x", labelsize=8)
        for spine in ["top", "left", "right"]:
            ax.spines[spine].set_visible(False)
    handles, names = axes[0].get_legend_handles_labels()
    fig.legend(handles, names, loc="lower center", ncol=4, fontsize=7, frameon=False)
    fig.suptitle("Node 3 to memory M0: first 4 KiB read")
    fig.subplots_adjust(bottom=.36, top=.75, wspace=.18)
    for extension in ["svg", "png"]:
        path = ROOT / "figures" / ("memory-read-stages." + extension)
        fig.savefig(str(path), dpi=180, bbox_inches="tight")
    plt.close(fig)


def main():
    cases = ["read-full"] + ["read-zero-" + str(n) for n in range(16)]
    rows = [row for case in cases for row in reconstruct(case)]
    assert len(rows) == 1024
    with (ROOT / "tables/memory-read-stages.csv").open("w") as stream:
        writer = csv.DictWriter(stream, COLUMNS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    plot_first_read(rows)


if __name__ == "__main__":
    main()
