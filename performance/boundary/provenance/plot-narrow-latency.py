"""Plot mean AXI handshake intervals for each source reading node 15."""

import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


root = Path(__file__).resolve().parents[1]
with (root / "tables/narrow-latency-breakdown.csv").open() as stream:
    rows = list(csv.DictReader(stream))

stages = [
    ("request_ns", "Source AR to destination AR", "#3979a6"),
    ("service_ns", "Destination AR to R", "#d59136"),
    ("response_ns", "Destination R to source R", "#539075"),
]
fig, axes = plt.subplots(1, 2, figsize=(10, 5.8), sharex=True, sharey=True)
for axis, load in zip(axes, ["zero", "full"]):
    data = sorted((row for row in rows if row["load"] == load),
                  key=lambda row: int(row["source"]))
    nodes = [int(row["source"]) for row in data]
    assert nodes == list(range(15))
    left = [0.0] * len(nodes)
    for column, label, color in stages:
        times = [float(row[column]) for row in data]
        axis.barh(nodes, times, left=left, label=label, color=color, height=0.7)
        left = [start + duration for start, duration in zip(left, times)]
    axis.set_title(load.capitalize() + " load")
    axis.set_xlabel("Mean read latency [ns]")
    axis.set_yticks(nodes)
    axis.spines["right"].set_visible(False)
    axis.spines["top"].set_visible(False)
axes[0].set_ylabel("Source node")
axes[0].invert_yaxis()
fig.legend(*axes[0].get_legend_handles_labels(), loc="lower center", ncol=3,
           fontsize=9, frameon=False)
fig.tight_layout(rect=(0, 0.06, 1, 1))
for suffix in ("png", "svg"):
    fig.savefig(root / ("figures/narrow-latency-breakdown." + suffix), dpi=160)
