#!/usr/bin/env python3
"""Prepare shared AXI and router verification patterns."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import shutil
sys.path.insert(0, str(Path(__file__).resolve().parent))
from prepare import prepare, attach_hardware, recipe_path, write_text, ROOT
import subprocess
from gen_standalone_patterns import generate, load_cases
from verification_matrix import metadata


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--profile")
    parser.add_argument("--capacity", choices=("all", "per_id", "context", "rob"), default="all",
                        help="Prepare the full matrix by default, or only one capacity test")
    args = parser.parse_args()
    out = Path(args.out).resolve()
    recipe = prepare(out, args.profile, patterns=False)
    import yaml
    profile = yaml.safe_load((out / "profile.yml").read_text())
    cases = {c["name"]: c for c in load_cases("base")}
    import yaml
    from address_map import pack_config
    _, entries = pack_config(yaml.safe_load((out / "topology.yml").read_text()))
    num_destinations = sum(e["space"] == "memory" for e in entries)
    hardware = dict(response_fifo_depth=profile.get("io_fifo_depth", 32),
                    context_depth=profile.get("context_depth", 32))
    rows = []

    def add(item, case, mode="auto", seed=1):
        add_run(item, dict(case), mode, seed)

    def add_run(item, case, mode="auto", seed=1):
        index = len(rows)
        suffix = ""
        if args.capacity == "all" and case["name"] == "capacity_reuse":
            target = case["capacity_target"]
            index = sum(row["case"] == "capacity_reuse" and row["target"] == target for row in rows)
            suffix = "_" + target
        tag = item + "_" + mode + "_s" + str(seed) + "_" + str(index) + suffix
        directory = out / "inputs" / tag
        directory.mkdir(parents=True, exist_ok=True)
        catalog = directory / "cases.json"
        catalog.write_text(json.dumps({"cases": [case]}, indent=2) + "\n")
        generate(directory / "patterns", out / "topology.yml", profile.get("input_id_width", 3),
                 catalog, mode, seed, profile="cosim", hardware=hardware)
        if case["name"] == "capacity_reuse":
            shutil.copytree(directory / "patterns" / case["name"], directory / "patterns" / (case["name"] + "_" + case["capacity_target"]), dirs_exist_ok=True)
        attach_hardware(recipe, directory / "patterns")
        shutil.copyfile(out / "profile.yml", directory / "profile.yml")
        rows.append(dict(item=item, coverage_items=[item] + (["P11"] if item in ("P05", "P06", "P07", "P08") else []),
                         tag=tag, case=case["name"], seed=seed, conditions=case, mode=mode,
                         **metadata(item),
                         stimulus=str((directory / "patterns" / (case["name"] + "_" + case["capacity_target"] if case["name"] == "capacity_reuse" else case["name"])).relative_to(out)), target=case.get("capacity_target", "per_id")))

    if args.capacity != "all":
        case = dict(name="capacity_reuse", count=320, burst_beats=1, ids="multiple",
                    sequence="capacity_reuse", capacity_target=args.capacity,
                    response_hold_cycles=4096)
        for mode in ("control", "data"):
            add({"per_id": "P14", "context": "P15", "rob": "P18"}[args.capacity], case, mode)
    else:
        for item, name in enumerate(("ctrl_write_single", "ctrl_read_single", "data_write_single", "data_read_single",
                                    "ctrl_write_burst", "ctrl_read_burst", "data_write_burst", "data_read_burst"), 1):
            case = dict(cases[name])
            if "burst_lengths" in case:
                case["burst_lengths"] = list(range(2, 65 if case["mode"] == "data" else 257))
                case["count"] = len(case["burst_lengths"])
            add("P%02d" % item, case)
            if "burst_lengths" in case:
                boundary = dict(case, burst_lengths=[2, 3, max(case["burst_lengths"])] * num_destinations,
                                count=3*num_destinations, sequence="sam_boundary")
                add("P11", boundary)
        for mode in ("control", "data"):
            for lane in ("full", "partial", "zero", "onehot"):
                add("P09" if lane == "full" else "P10",
                    dict(name="ctrl_read_write" if mode == "control" else "data_read_write",
                         count=64 if lane == "onehot" else (127 if mode == "data" else 120),
                         lane_sweep=lane, ids="multiple", random=True, destinations="random"), mode)
            for item, name in (("P14", "single_id_outstanding"), ("P15", "multi_id_outstanding"),
                               ("P16", "multi_id_out_of_order"), ("P17", "single_id_reorder")):
                case = dict(cases[name])
                if item in ("P16", "P17"):
                    case["response_random_delay"] = True
                add(item, case, mode)
        for mode in ("control", "data"):
            add("P12", dict(next(c for c in load_cases("mesh") if c["name"] == "routing")), mode)
        for mode in ("control", "data"):
            for destination in range(1):
                add("P15", dict(name=mode.replace("control", "ctrl") + "_read_write",
                    mode=mode, count=16, burst_beats=1, ids="multiple", concurrent_rw=True,
                    response_hold_cycles=512,
                    destination_order=[(i + destination) % num_destinations for i in range(num_destinations)]), mode)
        for destination in range(1):
            add("P20", dict(name="data_read_write", mode="data", count=128,
                burst_beats=8, ids="multiple", concurrent_rw=True,
                source_response_hold_cycles=4096, response_backpressure=True,
                response_random_delay=True,
                destination_order=[(i + destination) % num_destinations for i in range(num_destinations)]), "data")
        for error in (2, 3):
            catalog = "response_slverr" if error == 2 else "response_decerr"
            for case in load_cases(catalog):
                add("P13", case)
        for item, name in (("P19", "ctrl_rand"), ("P20", "data_rand"), ("P21", "request_rand")):
            for seed in (1, 17, 29):
                add(item, dict(cases[name]), seed=seed)
        for seed in (1, 17, 29):
            add("P22", dict(name="reset_recovery", count=8, burst_beats=4, ids="multiple",
                           destinations="alternate", sequence="reset_recovery"), seed=seed)
    if args.capacity == "all":
        for target, item in (("per_id", "P14"), ("context", "P15"), ("rob", "P18")):
            case = dict(name="capacity_reuse", count=320, burst_beats=1, ids="multiple",
                        sequence="capacity_reuse", capacity_target=target,
                        response_hold_cycles=4096)
            for mode in ("control", "data"):
                add(item, case, mode)
    if args.capacity == "all":
        for case in load_cases("router"):
            for mode in ("control", "data", "rand"):
                add("P23", dict(case), mode)
    if args.capacity == "all":
        for item, name in (("P25", "hotspot"), ("P26", "uniform_random")):
            case = next(c for c in load_cases("mesh") if c["name"] == name)
            for mode in ("control", "data", "rand"):
                add(item, dict(case), mode)
    if args.capacity == "all":
        # Each collective root runs alone; simultaneous overlapping trees are unsupported.
        multicast = next(c for c in load_cases("router") if c["name"] == "multicast_burst")
        for root in range(num_destinations):
            for mode in ("control", "data"):
                add("P23", dict(multicast, sources=[root], router_dat_stall_cycles=32), mode)
        single = next(c for c in load_cases("router") if c["name"] == "multicast_single")
        from address_map import router_array
        mesh_x, mesh_y = router_array(yaml.safe_load((out / "topology.yml").read_text()))
        error_mask = sum(1 << node for node in range(num_destinations)
                         if (node % mesh_x + node // mesh_x) % 2 == 0)
        for root in range(num_destinations):
            for mask in (error_mask, ((1 << num_destinations)-1) ^ error_mask):
                add("P23", dict(single, sources=[root], count=1,
                                multicast_masks=[(mesh_x-1) | ((mesh_y-1) << 4)],
                                response_error=2, response_error_mask=mask), "control")
        for mode in ("control", "data"):
            for seed in (1, 17, 29):
                add("P22", dict(single, operation="both", multicast_masks=[51],
                                burst_beats=16, sequence="reset_recovery",
                                router_dat_stall_cycles=32), mode, seed)
        mixed = dict(name="data_read_write", count=64, burst_beats=8, ids="multiple",
                     concurrent_rw=True, destinations="all", router_dat_stall_cycles=32)
        for root in (0, num_destinations-1):
            add("P20", dict(mixed, sources=[root]), "data")
        routing = next(c for c in load_cases("mesh") if c["name"] == "routing")
        add("P26", dict(routing, burst_beats=8, router_dat_stall_cycles=32), "data")
        # Alternate source sets leave the existing read/write address stripes disjoint.
        for parity in (0, 1):
            add("P26", dict(routing, sources=list(range(parity, num_destinations, 2)),
                            burst_beats=8, concurrent_rw=True, router_dat_stall_cycles=32), "data")
        hotspot = next(c for c in load_cases("mesh") if c["name"] == "hotspot")
        for destination in (5, 10):
            add("P25", dict(hotspot, count=1, operation="write", burst_beats=32,
                            destination_order=[destination] + [n for n in range(num_destinations)
                                                               if n != destination]), "control")
        read_stress = dict(cases["ctrl_read_burst"])
        read_stress.pop("burst_lengths", None)
        add("P15", dict(read_stress, count=num_destinations, burst_beats=32,
                        ids="same", num_ids=1, destinations="all",
                        source_response_hold_cycles=4096), "control")
        # One collective tree competes with ordinary traffic from the other NIs.
        for root in (0, 5, 10, 15):
            for seed in (1, 17):
                add("P23", dict(single, sources=list(range(num_destinations)),
                                multicast_source=root, count=1, burst_beats=32,
                                multicast_masks=[51], destinations="random"), "control", seed)
        for parity in (0, 1):
            add("P26", dict(routing, sources=list(range(parity, num_destinations, 2)),
                            burst_beats=8, concurrent_rw=True, router_dat_stall_cycles=8,
                            response_random_delay=True), "data", 17)
        # Short packets let responses enter the merge tree before the existing reset window.
        for mode in ("control", "data"):
            for seed in (17, 29):
                add("P22", dict(single, operation="both", multicast_masks=[51],
                                burst_beats=1, sequence="reset_recovery"), mode, seed)
        for root in (0, 5, 10, 15):
            for seed in (1, 17):
                add("P23", dict(single, sources=list(range(num_destinations)),
                                multicast_source=root, count=1, burst_beats=32,
                                multicast_masks=[3 if seed == 1 else 48],
                                destinations="random", operation="both"),
                    "control", seed)
    (out / "verification-runs.json").write_text(json.dumps(rows, indent=2) + "\n")
    (out / "campaign.json").write_text(json.dumps(dict(recipe=recipe_path(args.profile or ROOT / "dv/config/profile.yml").relative_to(ROOT).as_posix(), commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()), indent=2)+"\n")
    write_text(ROOT / "build/regression/latest.json", json.dumps(dict(campaign=out.relative_to(ROOT).as_posix()))+"\n")
    print("Prepared", len(rows), "runs")


if __name__ == "__main__":
    main()
