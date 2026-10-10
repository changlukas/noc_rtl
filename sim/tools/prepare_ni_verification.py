#!/usr/bin/env python3
"""Prepare P01-P22 stimulus variants using the shared AXI file generator."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import shutil
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare import prepare, ROOT
from gen_standalone_patterns import generate
from verification_matrix import metadata


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--profile")
    parser.add_argument("--capacity", choices=("all", "per_id", "context", "rob"), default="all",
                        help="Prepare the full matrix by default, or only one capacity test")
    args = parser.parse_args()
    out = Path(args.out).resolve()
    prepare(ROOT / "sim/standalone/nmu/output/i8_n5_b128_r1/stage", out, args.profile)
    import yaml
    profile = yaml.safe_load((out / "profile.yml").read_text())
    cases = {c["name"]: c for c in json.loads((ROOT / "sim/test_patterns/standalone/cases.json").read_text())["cases"]}
    rows = []

    def add(item, case, mode="auto", seed=1):
        # Repeat directed AXI sweeps at each endpoint, retaining the same payloads.
        sweep = item in ("P01", "P02", "P03", "P04", "P05", "P06", "P07", "P08", "P09", "P10", "P13")
        for destination in range(4 if sweep else 1):
            variant = dict(case)
            if destination:
                variant["destination_order"] = [(i + destination) % 4 for i in range(4)]
            add_run(item, variant, mode, seed)

    def add_run(item, case, mode="auto", seed=1):
        index = len(rows)
        suffix = ""
        if args.capacity == "all" and case["name"] == "capacity_reuse":
            target = case["capacity_target"]
            index = sum(row["case"] == "capacity_reuse" and row["target"] == target for row in rows)
            suffix = "_" + target
        tag = item + "_" + mode + "_s" + str(seed) + "_" + str(index) + suffix
        directory = out / "verification" / tag
        directory.mkdir(parents=True, exist_ok=True)
        catalog = directory / "cases.json"
        catalog.write_text(json.dumps({"cases": [case]}, indent=2) + "\n")
        generate(directory / "patterns", out / "topology.yml", profile.get("input_id_width", 3),
                 catalog, mode, seed, profile="cosim")
        if case["name"] == "capacity_reuse":
            shutil.copytree(directory / "patterns" / case["name"], directory / "patterns" / (case["name"] + "_" + case["capacity_target"]), dirs_exist_ok=True)
        shutil.copyfile(out / "profile.yml", directory / "profile.yml")
        rows.append(dict(item=item, coverage_items=[item] + (["P11"] if item in ("P05", "P06", "P07", "P08") else []),
                         tag=tag, case=case["name"], seed=seed, conditions=case, mode=mode,
                         **metadata(item),
                         cwd=str(directory.relative_to(out)), target=case.get("capacity_target", "per_id")))

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
            add("P12", dict(name="multi_id_outstanding", count=32, ids="multiple",
                            destinations="all", min_unique=2), mode)
        for mode in ("control", "data"):
            for destination in range(4):
                add("P15", dict(name=mode.replace("control", "ctrl") + "_read_write",
                    mode=mode, count=16, burst_beats=1, ids="multiple", concurrent_rw=True,
                    response_hold_cycles=512,
                    destination_order=[(i + destination) % 4 for i in range(4)]), mode)
        for destination in range(4):
            add("P20", dict(name="data_read_write", mode="data", count=128,
                burst_beats=8, ids="multiple", concurrent_rw=True,
                source_response_hold_cycles=4096, response_backpressure=True,
                response_random_delay=True,
                destination_order=[(i + destination) % 4 for i in range(4)]), "data")
        for error in (2, 3):
            catalog = ROOT / "sim/test_patterns/sweeps" / ("response_slverr.json" if error == 2 else "response_decerr.json")
            for case in json.loads(catalog.read_text())["cases"]:
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
    shutil.copyfile(ROOT / "sim/script/run_verification.py", out / "run_verification.py")
    (out / "verification-runs.json").write_text(json.dumps(rows, indent=2) + "\n")
    files = sorted(p for p in out.rglob("*") if p.is_file() and p.name != "SHA256SUMS" and "build" not in p.relative_to(out).parts)
    (out / "SHA256SUMS").write_text("".join(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + str(p.relative_to(out)) + "\n" for p in files))
    print("Prepared", len(rows), "runs")


if __name__ == "__main__":
    main()
