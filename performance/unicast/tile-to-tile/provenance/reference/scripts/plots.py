import os
import json
import argparse
from pathlib import Path
from typing import OrderedDict

import numpy as np
import os
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import seaborn as sns

from plot_params import *
import re
import pandas as pd

NUM_X = 4
NUM_Y = 8
OCCAMY_X_DIM = 8
OCCAMY_Y_DIM = 5
NUM_HBM_CHANNELS = NUM_Y
NUM_CORES_PER_CLUSTER = 9
NUM_CLUSTERS_PER_QUADRANT = 4
NUM_QUADRANTS = 6
NUM_CLUSTERS = NUM_CLUSTERS_PER_QUADRANT * NUM_QUADRANTS

NARROW_WORD_SIZE = 8
WIDE_WORD_SIZE = 64

FLOOCCAMY_DIR = Path("/scratch/fischeti/flooccamy")
OCCAMY_DIR = Path("/scratch/fischeti/occamy/target/sim")
FLOONOC_DIR = Path("/scratch/fischeti/floo_noc")

SOC_CLK_FREQ = 1e9  # 1 GHz
SOC_CLK_PERIOD = 1 / SOC_CLK_FREQ

HBM_CLOCK_FREQ = 1.8e9  # 1.8 GHz
HBM_LANES_PER_CHANNEL = 128
HBM_DDR = 2  # DDR
HBM_BW_PER_CHANNEL = (
    HBM_CLOCK_FREQ * HBM_LANES_PER_CHANNEL * HBM_DDR / 8
)  # 1.8 GHz * 128 * 2 / 8 = 57.6 GB/s
HBM_BW_TOTAL = HBM_BW_PER_CHANNEL * NUM_HBM_CHANNELS  # 57.6 GB/s * 8 = 460.8 GB/s


def run_dir(benchmark: str, direction: str, num_trans: int, trans_size: int, **_kwargs):
    """Return the simulation run directory for the given parameters."""
    return f"{benchmark}_{direction}_t{num_trans}_s{trans_size}"


def logs_dir_path(system_path: Path, **kwargs):
    """Return the logs directory for the given parameters."""
    return system_path / run_dir(**kwargs) / "logs"


def extract_dramsys_bw(transcript: Path):
    """Extract the DRAMSys bandwidth of each channel"""
    bws = []
    with open(transcript, "r") as file:
        lines = file.readlines()
        # Find the line containing the bandwidth
        for line in lines:
            if "AVG BW\\IDLE" in line:
                # Extract the percentage value from the line and convert it to float
                try:
                    percent_value = float(line.split("|")[-1].strip().replace("%", ""))
                    # Add the percentage value to the list
                    bws.append(percent_value)
                # Fail if the percentage value cannot be converted to float
                except ValueError:
                    continue
    return bws


def extract_perf_stats(directory: Path):
    """Extract the performance statistics from the *_perf.json files in the directory."""
    data = []
    harts = []
    # Loop through each file in the folder
    for file_path in directory.iterdir():
        if file_path.name.endswith("_perf.json"):
            with file_path.open("r") as file:
                data.append(json.load(file))
                harts.append(int(file_path.name.split("_")[1], 16))
    return data, harts


def extract_cycles(sections, clk_period_ns, preheat: int = 1):
    """Extract the cycles from the measurement sections of the data."""
    cycles, start, end = [], [], []
    # Only consider harts with multiple sections
    if len(sections) > 1:
        # Every second section is a measurement section
        sections = sections[1::2]
        # If preheat, skip the first sections
        if preheat:
            sections = sections[preheat:]
        cycles += [stats["cycles"] for stats in sections]
        start += [stats["tstart"] / clk_period_ns for stats in sections]
        end += [stats["tend"] / clk_period_ns for stats in sections]
    return cycles, start, end


def get_xy_coords(core_id: int):
    cluster_id = core_id // NUM_CORES_PER_CLUSTER
    x = (cluster_id) // NUM_Y
    y = (cluster_id) % NUM_Y
    return x, y


def get_occamy_coords(core_id: int, mirror_x: bool = False, mirror_y: bool = False):
    core_id = core_id - 1
    cluster_id = core_id // NUM_CORES_PER_CLUSTER
    quadrant_id = cluster_id // NUM_CLUSTERS_PER_QUADRANT
    x_base = ((quadrant_id) % 3) * 3
    y_base = ((quadrant_id) // 3) * 3
    x = x_base + (cluster_id % NUM_CLUSTERS_PER_QUADRANT) % 2
    y = y_base + (cluster_id % NUM_CLUSTERS_PER_QUADRANT) // 2
    if mirror_x:
        x = OCCAMY_X_DIM - x - 1
    if mirror_y:
        y = OCCAMY_Y_DIM - y - 1
    return x, y


def measure_cluster2cluster(data, preheat=True):
    for hart_sections in data:
        if len(hart_sections) > 1:
            sections = hart_sections[1::2]
            if preheat:
                sections = sections[1:]
            cycles = [stats["cycles"] for stats in sections]
            print(f"Got {len(cycles)} measurements:")
            print(f"Minimum cycles: {np.min(cycles)}")
            print(f"Maximum cycles: {np.max(cycles)}")
            print(f"Average cycles: {np.mean(cycles)}")
            print(f"Standard deviation: {np.std(cycles)}")
            print("\n".join(map(str, cycles)))  # Print cycle list with newlines


def measure_cluster2hbm(data, preheat=True):
    cycles = []
    for hart_sections in data:
        if len(hart_sections) > 1:
            sections = hart_sections[1::2]
            if preheat:
                sections = sections[1:]
            cycles += [stats["cycles"] for stats in sections]
    print(f"Got {len(cycles)} measurements:")
    print(f"Minimum cycles: {np.min(cycles)}")
    print(f"Maximum cycles: {np.max(cycles)}")
    print(f"Average cycles: {np.mean(cycles)}")
    print(f"Standard deviation: {np.std(cycles)}")
    print("\n".join(map(str, cycles)))  # Print cycle list with newlines


def floo_hbm_heatmap(data, harts):
    latencies = np.zeros((NUM_X, NUM_Y, NUM_HBM_CHANNELS))

    for hart_sections, hart in zip(data, harts):
        if len(hart_sections) > 1:
            sections = hart_sections[1::2]
            cycles = [stats["cycles"] for stats in sections]
            x, y = get_xy_coords(hart)
            for i, cycle in enumerate(cycles):
                latencies[x, y, i] = cycle

    fig, ax = plt.subplots()

    avg_latencies = np.mean(latencies, axis=2)

    cax = ax.matshow(avg_latencies.T, cmap="viridis", vmin=100, vmax=150, aspect=0.5)

    # Optional: Add a title to each subplot for clarity
    ax.set_title(f"Read from HBM")

    # Set ticks and labels for each subplot
    ax.set_xticks([])
    # Set ticks
    ax.set_xticks([])
    ax.set_yticks(range(NUM_Y))

    # Invert the y-axis to place channel zero at the bottom for each subplot
    ax.invert_yaxis()

    # Display the latency values as integers within each cell for each subplot
    for i in range(NUM_Y):
        for j in range(NUM_X):
            ax.text(
                j, i, f"{int(avg_latencies[j, i])}", ha="center", va="center", color="w"
            )

    # Adjust layout to prevent overlap
    plt.tight_layout()

    # Add a color bar at the right of the figure
    fig.colorbar(cax, ax=ax, orientation="vertical")

    plt.show()


def occamy_hbm_heatmap(data, harts):
    latencies = np.zeros((6 + 2, 4 + 1, NUM_HBM_CHANNELS))

    for hart_sections, hart in zip(data, harts):
        if len(hart_sections) > 1:
            sections = hart_sections[1::2]
            cycles = [stats["cycles"] for stats in sections]
            x, y = get_occamy_coords(hart)
            for i, cycle in enumerate(cycles):
                latencies[x, y, i] = cycle

    num_rows = 2
    num_cols = NUM_HBM_CHANNELS // 2
    fig, ax = plt.subplots()  # Adjust figsize as needed

    avg_latencies = np.mean(latencies, axis=2)
    data_to_plot = np.ma.masked_where(avg_latencies.T == 0, avg_latencies.T)
    cax = ax.matshow(data_to_plot, cmap="viridis", vmin=100, vmax=150)

    # Optional: Add a title to each subplot for clarity
    ax.set_title("Read from HBM")

    # Set ticks and labels for each subplot
    ax.set_xticks([])
    # Set ticks
    ax.set_xticks([])
    ax.set_yticks(
        [i / 8 * 5 for i in range(8)]
    )  # Set ticks for all channels for consistency

    # Invert the y-axis to place channel zero at the bottom for each subplot
    ax.invert_yaxis()

    # # Display the latency values as integers within each cell for each subplot
    for x in range(6 + 2):
        for y in range(4 + 1):
            if avg_latencies[x, y] != 0:
                ax.text(
                    x,
                    y,
                    f"{int(avg_latencies[x, y])}",
                    ha="center",
                    va="center",
                    color="w",
                )

    # Adjust layout to prevent overlap
    plt.tight_layout()

    # Add a color bar at the right of the figure
    fig.colorbar(cax, ax=ax, orientation="vertical")

    plt.show()

def plot_bw_heatmap(is_occamy: bool = False, preheat: int = 0):

    if is_occamy:
        bw_util_zero_load = np.zeros((OCCAMY_X_DIM, OCCAMY_Y_DIM))
        bw_util_full_load = np.zeros((OCCAMY_X_DIM, OCCAMY_Y_DIM))
        directories = OCCAMY_DIR
    else:
        bw_util_zero_load = np.zeros((NUM_X, NUM_Y))
        bw_util_full_load = np.zeros((NUM_X, NUM_Y))
        directories = FLOOCCAMY_DIR

    directories = [
        name
        for name in directories.iterdir()
        if name.is_dir() and name.name.startswith("bench_bw_from_hbm") and name.name.endswith("t32_s4096")
    ]

    for directory in directories:
        data_list, hart_list = extract_perf_stats(directory / "logs")
        is_zero_load = "zero_load" in directory.name
        is_full_load = "full_load" in directory.name
        trans_size = int(directory.name.split("_s")[-1])
        num_trans = int(directory.name.split("_t")[-1].split("_s")[0])

        for data, hart in zip(data_list, hart_list):
            if len(data) > 1:
                sections = data[1::2]
                sections = sections[preheat:]
                avg_cycles = np.mean([stats["cycles"] for stats in sections])
                bw_util = num_trans * trans_size / WIDE_WORD_SIZE / avg_cycles * 100
                hbm_bw_util = num_trans * trans_size * SOC_CLK_FREQ / avg_cycles / HBM_BW_PER_CHANNEL * 100
                if is_occamy:
                    x, y = get_occamy_coords(hart)
                else:
                    x, y = get_xy_coords(hart)

                if is_zero_load:
                    bw_util_zero_load[x, y] = hbm_bw_util
                elif is_full_load:
                    bw_util_full_load[x, y] = hbm_bw_util

    # Determine the color range
    vmin = 0
    vmax = 100

    mask_zero_load = (bw_util_zero_load.T == 0)
    mask_full_load = (bw_util_full_load.T == 0)

    # Create a figure
    fig = plt.figure(figsize=(10, 5))

    # Define the GridSpec layout with space for a shared color bar
    gs = gridspec.GridSpec(1, 3, width_ratios=[1, 1, 0.05])

    # Create the first heatmap
    ax1 = plt.subplot(gs[0])
    sns.heatmap(
        bw_util_zero_load.T,
        ax=ax1,
        cmap="viridis",
        vmin=vmin, vmax=vmax,
        annot=True,
        fmt=".0f",
        annot_kws={"size": 24},
        cbar=False,
        mask=mask_zero_load,
        linewidths=0.5
    )
    ax1.set_title("Zero-load HBM BW Util. [%]", fontsize=20)
    ax1.set_xticks([])
    ax1.set_yticks([])
    ax1.invert_yaxis()

    ax2 = plt.subplot(gs[1])
    cbar_ax = plt.subplot(gs[2])
    sns.heatmap(
        bw_util_full_load.T,
        ax=ax2,
        cmap="viridis",
        vmin=vmin, vmax=vmax,
        annot=True,
        fmt=".0f",
        annot_kws={"size": 24},
        cbar=True,
        cbar_ax=cbar_ax,
        mask=mask_full_load,
        linewidths=0.5
    )
    ax2.set_title("Full-load HBM BW Util. [%]", fontsize=20)
    ax2.set_xticks([])
    ax2.set_yticks([])
    ax2.invert_yaxis()

    # Adjust the layout
    plt.tight_layout()

    # Show the plot
    plot_name = "bw_heatmap_occamy" if is_occamy else "bw_heatmap_flooccamy"
    plt.savefig(f"../figures/{plot_name}.pdf")


def plot_lat_heatmap(is_occamy: bool = False):

    if is_occamy:
        latencies_zero_load = np.zeros((6 + 2, 4 + 1))
        latencies_full_load = np.zeros((6 + 2, 4 + 1, NUM_CORES_PER_CLUSTER))
        directories = OCCAMY_DIR
    else:
        latencies_zero_load = np.zeros((NUM_X, NUM_Y))
        latencies_full_load = np.zeros((NUM_X, NUM_Y, NUM_CORES_PER_CLUSTER))
        directories = FLOOCCAMY_DIR

    # Get all directories
    directories = [
        name
        for name in directories.iterdir()
        if name.is_dir() and name.name.startswith("bench_latency_to_tile")
    ]

    for directory in directories:
        data_list, hart_list = extract_perf_stats(directory / "logs")
        is_zero_load = "zero_load" in directory.name
        is_full_load = "full_load" in directory.name
        for data, hart in zip(data_list, hart_list):
            if len(data) > 1:
                sections = data[1::2]
                avg_cycles = np.mean([stats["cycles"] for stats in sections])
                # Subtract the move, and mcycle instructions
                avg_cycles -= 3
                if is_occamy:
                    x, y = get_occamy_coords(hart, mirror_x=True, mirror_y=True)
                else:
                    x, y = get_xy_coords(hart)
                if is_zero_load:
                    latencies_zero_load[x, y] = avg_cycles
                elif is_full_load:
                    latencies_full_load[x, y, hart % NUM_CORES_PER_CLUSTER] = avg_cycles
                else:
                    raise ValueError("Invalid measurement type")

    latencies_full_load = np.mean(latencies_full_load, axis=2)

    # Determine the color range
    vmin = 0
    vmax = 400

    # Create a figure
    fig = plt.figure(figsize=(10, 5))

    # Define the GridSpec layout with space for a shared color bar
    gs = gridspec.GridSpec(1, 3, width_ratios=[1, 1, 0.05])

    mask_zero_load = (latencies_zero_load.T == 0)
    mask_full_load = (latencies_full_load.T == 0)
    mask_idx_zero_load = np.where(latencies_zero_load == 0)
    mask_idx_full_load = np.where(latencies_full_load == 0)

    font_size_zero_load = 24
    font_size_full_load = 24

    if is_occamy:
        mask_idx_zero_load = (OCCAMY_Y_DIM-1, OCCAMY_X_DIM-1)
        mask_idx_full_load = (OCCAMY_Y_DIM-1, OCCAMY_X_DIM-1)
        mask_zero_load[mask_idx_zero_load] = True
        mask_full_load[mask_idx_full_load] = True
        font_size_zero_load = 20 if np.max(latencies_zero_load) > 100 else 24
        font_size_full_load = 20 if np.max(latencies_full_load) > 100 else 24

    # Create the first heatmap
    ax1 = plt.subplot(gs[0])
    sns.heatmap(
        latencies_zero_load.T,
        ax=ax1,
        cmap="viridis",
        vmin=vmin, vmax=vmax,
        annot=True,
        fmt=".0f",
        annot_kws={"size": font_size_zero_load},
        cbar=False,
        mask=mask_zero_load,
        linewidths=0.5
    )
    ax1.add_patch(plt.Rectangle((mask_idx_zero_load[1], mask_idx_zero_load[0]), 1, 1, fill=True, edgecolor='red', facecolor='none', hatch='/', lw=2))
    if is_occamy:
        ax1.add_patch(plt.Rectangle((0, 2), 8, 1, fill=True, facecolor='lightgrey'))
        ax1.add_patch(plt.Rectangle((2, 0), 1, 5, fill=True, facecolor='lightgrey'))
        ax1.add_patch(plt.Rectangle((5, 0), 1, 5, fill=True, facecolor='lightgrey'))
        ax1.text(4, 2.5, "interconnect", fontsize=25, ha='center', va='center')
    ax1.set_title("Zero-load latency [cycles]", fontsize=24)
    ax1.set_xticks([])
    ax1.set_yticks([])
    ax1.invert_yaxis()

    ax2 = plt.subplot(gs[1])
    cbar_ax = plt.subplot(gs[2])
    sns.heatmap(
        latencies_full_load.T,
        ax=ax2,
        cmap="viridis",
        vmin=vmin, vmax=vmax,
        annot=True,
        fmt=".0f",
        annot_kws={"size": font_size_full_load},
        cbar=True,
        cbar_ax=cbar_ax,
        mask=mask_full_load,
        linewidths=0.5
    )
    ax2.add_patch(plt.Rectangle((mask_idx_zero_load[1], mask_idx_zero_load[0]), 1, 1, fill=True, edgecolor='red', facecolor='none', hatch='/', lw=2))
    ax2.set_title("Full-load latency [cycles]", fontsize=24)
    ax2.set_xticks([])
    ax2.set_yticks([])
    ax2.invert_yaxis()

    # Adjust the layout
    plt.tight_layout()

    # Show the
    plot_name = "lat_heatmap_occamy" if is_occamy else "lat_heatmap_flooccamy"
    plt.savefig(f"../figures/{plot_name}.pdf")


def plot_hbm_bw():

    # Get all directories
    directories = [name for name in FLOOCCAMY_DIR.iterdir() if name.is_dir()]
    directories += [name for name in OCCAMY_DIR.iterdir() if name.is_dir()]

    # Filter directories that start with "bench"
    bench_directories = [
        name for name in directories if name.name.startswith("bench_bw_to_hbm") and name.name.endswith("t32_s1024")
    ]

    flooccamy_avg_1ch_read_bw, flooccamy_avg_1ch_write_bw = {}, {}
    flooccamy_avg_allch_read_bw, flooccamy_avg_allch_write_bw = {}, {}
    occamy_avg_1ch_read_bw, occamy_avg_1ch_write_bw = {}, {}
    occamy_avg_allch_read_bw, occamy_avg_allch_write_bw = {}, {}

    # Iterate through the bench directories
    for directory in bench_directories:
        trans_size = int(directory.name.split("_s")[-1])
        num_trans = int(directory.name.split("_t")[-1].split("_s")[0])
        is_flooccamy = directory.is_relative_to(FLOOCCAMY_DIR)
        clk_period_ns = 10 if is_flooccamy else 1
        is_read = "read" in directory.name
        is_single_ch = "single_channel" in directory.name
        cycles, starts, ends = {}, {}, {}
        data_list, hart_list = extract_perf_stats(directory / "logs")
        for data, hart in zip(data_list, hart_list):
            hart_cycles, hart_starts, hart_ends = extract_cycles(
                data, clk_period_ns, preheat=2
            )
            if len(hart_cycles) == 0:
                continue
            cycles[hart] = hart_cycles
            starts[hart] = hart_starts
            ends[hart] = hart_ends
        # Calculate the bandwidth in GB/s
        if is_single_ch:
            assert (
                len(cycles) == 1
            ), "Single channel measurement should only have one hart"
            bw = (
                num_trans
                * trans_size
                / (np.mean(list(cycles.values())) * SOC_CLK_PERIOD)
            )
        else:
            assert (
                len(cycles) == NUM_CLUSTERS
            ), "All channel measurement should have all harts"
            print(
                np.max(list(starts.values()), axis=0)
                - np.min(list(starts.values()), axis=0),
                "flooccamy" if is_flooccamy else "occamy",
                directory.name,
            )
            duration = np.mean(
                np.max(list(ends.values()), axis=0)
                - np.min(list(starts.values()), axis=0)
            )
            bw = (
                np.mean(num_trans * trans_size / (duration * SOC_CLK_PERIOD))
                * NUM_CLUSTERS
            )

        match (is_flooccamy, is_read, is_single_ch):
            case (True, True, True):
                flooccamy_avg_1ch_read_bw[trans_size] = bw
            case (True, False, True):
                flooccamy_avg_1ch_write_bw[trans_size] = bw
            case (False, True, True):
                occamy_avg_1ch_read_bw[trans_size] = bw
            case (False, False, True):
                occamy_avg_1ch_write_bw[trans_size] = bw
            case (True, True, False):
                flooccamy_avg_allch_read_bw[num_trans] = bw
            case (True, False, False):
                flooccamy_avg_allch_write_bw[num_trans] = bw
            case (False, True, False):
                occamy_avg_allch_read_bw[num_trans] = bw
            case (False, False, False):
                occamy_avg_allch_write_bw[num_trans] = bw

    # Sort the dictionaries by key and transform into lists
    trans_sizes = list(sorted(flooccamy_avg_1ch_read_bw.keys()))
    flooccamy_avg_1ch_read_bw = np.array(
        [flooccamy_avg_1ch_read_bw[size] for size in trans_sizes]
    )
    flooccamy_avg_1ch_write_bw = np.array(
        [flooccamy_avg_1ch_write_bw[size] for size in trans_sizes]
    )
    occamy_avg_1ch_read_bw = np.array(
        [
            occamy_avg_1ch_read_bw[size]
            for size in trans_sizes
            if size in occamy_avg_1ch_read_bw
        ]
    )
    occamy_avg_1ch_write_bw = np.array(
        [
            occamy_avg_1ch_write_bw[size]
            for size in trans_sizes
            if size in occamy_avg_1ch_write_bw
        ]
    )

    num_trans = list(sorted(flooccamy_avg_allch_read_bw.keys()))
    flooccamy_avg_allch_read_bw = np.array(
        [flooccamy_avg_allch_read_bw[trans] for trans in num_trans]
    )
    flooccamy_avg_allch_write_bw = np.array(
        [flooccamy_avg_allch_write_bw[trans] for trans in num_trans]
    )
    occamy_avg_allch_read_bw = np.array(
        [occamy_avg_allch_read_bw[trans] for trans in num_trans]
    )
    occamy_avg_allch_write_bw = np.array(
        [occamy_avg_allch_write_bw[trans] for trans in num_trans]
    )

    _, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4))
    plt.subplots_adjust(wspace=0.5)

    xticks = range(1, len(trans_sizes) + 1)

    ax1.plot(xticks, flooccamy_avg_1ch_read_bw / 1e9, "x--", label="Flooccamy Read")
    ax1.plot(xticks, flooccamy_avg_1ch_write_bw / 1e9, "x--", label="Flooccamy Write")
    ax1.plot(xticks, occamy_avg_1ch_read_bw / 1e9, "x--", label="Occamy Read")
    ax1.plot(xticks, occamy_avg_1ch_write_bw / 1e9, "x--", label="Occamy Write")

    # Set xtick labels to actual values
    ax1.set_xticks(xticks)
    ax1.set_xticklabels([size // 1024 for size in trans_sizes])  # Convert to KB
    ax1.set_ylim(0, HBM_BW_PER_CHANNEL / 1e9)

    ax1.set_xlabel("Transfer size [KB]")
    ax1.set_ylabel("Effective BW [GB/s]")

    # Creating a twin axis for the utilization
    ax1_2 = ax1.twinx()
    ax1_2.set_ylabel("HBM BW Util [%]")
    ax1_2.set_ylim(0, 100)

    ax1.set_title("Zero-load & single-channel HBM BW")
    ax1.legend()

    xticks = range(1, len(num_trans) + 1)

    ax2.plot(xticks, flooccamy_avg_allch_read_bw / 1e9, "x--", label="Flooccamy Read")
    ax2.plot(xticks, flooccamy_avg_allch_write_bw / 1e9, "x--", label="Flooccamy Write")
    ax2.plot(xticks, occamy_avg_allch_read_bw / 1e9, "x--", label="Occamy Read")
    ax2.plot(xticks, occamy_avg_allch_write_bw / 1e9, "x--", label="Occamy Write")

    # Set xtick labels to actual values
    ax2.set_xticks(xticks)
    ax2.set_xticklabels(num_trans)
    ax2.set_ylim(0, HBM_BW_TOTAL / 1e9)

    ax2.set_xlabel("#outstanding 1KB transactions per cluster")
    ax2.set_ylabel("Effective BW [GB/s]")

    # Creating a twin axis for the utilization
    ax2_2 = ax2.twinx()
    ax2_2.set_ylabel("HBM BW Util [%]")
    ax2_2.set_ylim(0, 100)

    ax2.set_title("Full-load & all-channel HBM BW")
    ax2.legend()

    plt.savefig("../figures/hbm_bw_plot.pdf")

def plot_lat_gantt():

    # Define the tasks and durations
    tasks = [
        ("Cluster 1", 2, 'LSU to AXI', PULPRed),
        ("NI 1", 1, 'AXI to flit', PULPPurple),
        ("Router 1", 2, 'Router Hop', PULPGreen),
        ("Router 2", 2, 'Router Hop', PULPGreen),
        ("NI 2", 1, 'flit to AXI', PULPPurple),
        ("Cluster 2", 5, 'TCDM Access', PULPRed),
        ("Router 2", 2, 'Router Hop', PULPGreen),
        ("Router 1", 2, 'Router Hop', PULPGreen),
        ("NI 1", 1, 'flit to AXI', PULPPurple),
        ("Cluster 1", 4, 'AXI to LSU', PULPRed)
    ]

    # Prepare data for plotting
    bars = []
    current_time = 0
    task_positions = {}
    position_counter = 0

    for task, duration, text, color in tasks:
        if task not in task_positions:
            task_positions[task] = position_counter
            position_counter += 1
        bars.append({
            "row_label": task,
            "row_idx": task_positions[task],
            "start": current_time,
            "end": current_time + duration,
            "duration": duration,
            "text": text,
            "color": color,
        })
        current_time += duration

    # Create figure and axis
    fig, ax = plt.subplots(figsize=(6, 3.5))

    last_task = None
    handles = {}  # To store legend handles

    # Plot each task
    for i, bar in enumerate(bars):
        bar_handle = ax.barh(bar['row_label'], bar['duration'], left=bar['start'], color=bar['color'], align='center')

        # Save the handle for legend
        if bar['row_label'].split()[0] not in handles:  # Use only the first word of each task as category
            handles[bar['row_label'].split()[0]] = bar_handle

        # Add text to the plot
        text_x = bar['end'] + 0.5 if i != len(bars) - 1 else bar['start'] - 0.5
        ha = 'left' if i != len(bars) - 1 else 'right'
        ax.text(text_x, bar['row_idx'], f"{bar['text']}", va='center', ha=ha)

        if i != 0:
            ymin = min(bar['row_idx'], last_task['row_idx'])
            ymax = max(bar['row_idx'], last_task['row_idx'])
            ax.vlines(x=bar['start'], ymin=ymin - 0.5, ymax=ymax + 0.5, colors='gray', linestyles='dashed', linewidth=1)
        last_task = bar

    # Add a legend
    legend_labels = {'Cluster': PULPRed, 'NI': PULPPurple, 'Router': PULPGreen}
    ax.legend([handles['Cluster'], handles['NI'], handles['Router']], ['Cluster', 'NI', 'Router'])

    # Highlight the top three bars' background
    ax.axhspan(-0.7, 2.5, color=PULPGray, alpha=0.3)

    # Set custom y-tick positions and labels
    ax.set_yticks([1, 4])  # Positioned at the middle of each group
    ax.set_yticklabels(['Src Tile', 'Dst Tile'], rotation=90, verticalalignment='center', horizontalalignment='right')  # Custom labels rotated by 90 degrees

    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)

    # Set labels
    ax.set_xlabel('Cycles')
    ax.set_xlim(0, current_time)
    ax.set_ylim(-0.7, 5.7)
    ax.set_title('Tile to Tile access latency')
    # Set ticks every integer
    ax.set_xticks(np.arange(0, current_time+1, 2))
    # Disable grid
    ax.grid(False)
    # Invert y-axis
    ax.invert_yaxis()

    plt.tight_layout()

    # Save the plot
    plt.savefig("../figures/lat_gantt.pdf")

def plot_traffic_patterns():
    # Plot the traffic patterns
    file_re = re.compile(r"(?P<pattern>\w+)_(?P<operation>read|write)_l(?P<burst_length>\d+)_r(?P<inj_ratio>\dp\d+)\.log")
    monitor_re = re.compile(
        r"# \[Monitor (?P<nw>wide|narrow)_dma_(?P<x>\d)_(?P<y>\d)\]\[(Read)\] "
        + r"Latency: (?P<latency>\d+.\d+) \+- (\d+.\d+), BW: (?P<bw>\d+.\d+) Bits/cycle, Util: (?P<util>\d+.\d+)%"
    )

    entries = []

    for logs in [FLOONOC_DIR / "logs"]:
        for log_file in logs.iterdir():
            match = file_re.match(log_file.name)
            assert match, f"Invalid log file name: {log_file.name}"
            with log_file.open("r") as file:

                pattern = match.group("pattern")
                if pattern == "bit_complement":
                    pattern = "bit-compl"
                inj_ratio = float(match.group("inj_ratio").replace("p", "."))

                for line in file:
                    monitor_match = monitor_re.search(line)
                    if monitor_match:
                        x = int(monitor_match.group("x"))
                        y = int(monitor_match.group("y"))
                        latency = float(monitor_match.group("latency"))
                        burst_length = int(match.group("burst_length"))
                        bw_util = float(monitor_match.group("util"))
                        nw = monitor_match.group("nw")

                        # Populate the dataframe
                        entries.append({
                            "pattern": pattern,
                            "nw": nw,
                            "burst_length": burst_length,
                            "transfer_size": burst_length * 64 / 1024,
                            "inj_ratio": inj_ratio,
                            "latency": latency + 7, # Add 7 cycles for cluster internal latency
                            "bw_util": bw_util,
                            "x": x,
                            "y": y
                        })

    df = pd.DataFrame(entries)

    # Filter dataframe by nw == "narrow" and burst_length > 1
    # df = df[(df["nw"] == "narrow") & (df["burst_length"] == 1)]

    # Group by pattern and injection ratio, then calculate the average latency
    df = df.groupby(["nw", "pattern", "inj_ratio", "burst_length", "transfer_size"]).agg(
        avg_lats=("latency", "mean"),
        avg_bw_util=("bw_util", "mean"),
    ).reset_index()

    # Sort the dataframe by pattern and injection ratio
    # df = df.sort_values(by=["pattern", "inj_ratio"])

    lat_df = df[(df["nw"] == "narrow") & (df["burst_length"] == 1)].sort_values(by=["pattern", "inj_ratio"])
    bw_df = df[(df["nw"] == "wide") & (df["burst_length"] > 1)].sort_values(by=["pattern", "burst_length"])

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(5, 4))

    # Plot bandwidth
    for i, pattern in enumerate(bw_df["pattern"].unique()):
        pattern_data = bw_df[bw_df["pattern"] == pattern]
        ax1.plot(pattern_data["transfer_size"], pattern_data["avg_bw_util"], marker='x', label=pattern, color=colors[i])

    ax1.set_xlabel("Transfer Size [kB]")
    ax1.set_ylabel("Avg. BW Util [%]")
    ax1.grid(True, which='both', linestyle='--', linewidth=0.5)
    ax1.set_xlim(0, 32)
    ax1.set_ylim(0, 100)
    ax1.set_xticks(bw_df["transfer_size"].unique())

    # Plot latency
    for i, pattern in enumerate(lat_df["pattern"].unique()):
        pattern_data = lat_df[lat_df["pattern"] == pattern]
        ax2.plot(pattern_data["inj_ratio"], pattern_data["avg_lats"], marker='x', label=pattern, color=colors[i])

    ax2.set_xlabel("Injection Ratio")
    ax2.set_ylabel("Avg. Lat. [cycles]")
    ax2.grid(True, which='both', linestyle='--', linewidth=0.5)
    ax2.set_xlim(0.0, 0.5)
    ax2.set_ylim(0, 70)


    # Add a single legend on top of the two plots
    handles, labels = ax1.get_legend_handles_labels()
    fig.legend(handles, labels, loc='upper center', ncol=len(labels))

    plt.tight_layout(rect=[0, 0, 1, 0.95])
    plt.savefig("../figures/traffic_patterns.pdf")
    plt.show()



def main():
    # Create an argument parser
    parser = argparse.ArgumentParser(description="Process performance measurements")
    parser.add_argument(
        "-d", default=Path.cwd(), help="folder containing the *_perf.json files"
    )
    parser.add_argument("-m", default="cluster2cluster", help="measurement type")
    parser.add_argument("-s", default="flooccamy", help="system type")
    args = parser.parse_args()

    if not os.listdir(args.d):
        raise FileNotFoundError(f"No files found in {args.d}")

    data = []
    harts = []
    # Loop through each file in the folder
    for filename in os.listdir(args.d):
        if filename.endswith("_perf.json"):
            file_path = os.path.join(args.d, filename)
            with open(file_path, "r") as file:
                data.append(json.load(file))
                harts.append(int(filename.split("_")[1], 16))

    match args.m:
        case "cluster2cluster":
            measure_cluster2cluster(data)
        case "cluster2hbm":
            measure_cluster2hbm(data)
        case "floo_hbm_heatmap":
            floo_hbm_heatmap(data, harts)
        case "occamy_hbm_heatmap":
            occamy_hbm_heatmap(data, harts)
        case "hbm_bw":
            plot_hbm_bw()
        case "lat_heatmap":
            plot_lat_heatmap(is_occamy=args.s == "occamy")
        case "bw_heatmap":
            plot_bw_heatmap(is_occamy=args.s == "occamy")
        case "lat_gantt":
            plot_lat_gantt()
        case "traffic_patterns":
            plot_traffic_patterns()
        case _:
            raise ValueError("Invalid measurement type")


if __name__ == "__main__":
    main()
