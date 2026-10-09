#!/usr/bin/env python3
"""Export current-campaign stimulus and native coverage for the verification matrix."""
import argparse
import csv
import json
import itertools
import re
import yaml
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# Existing verification-plan item IDs and implemented coverage objects.
TARGETS = {
    "P01": ("AXI-01, NI-02", "transaction_cg; response_cg"),
    "P02": ("AXI-01, NI-02", "transaction_cg; response_cg"),
    "P03": ("AXI-01, NI-02", "transaction_cg; response_cg"),
    "P04": ("AXI-01, NI-02", "transaction_cg; response_cg"),
    "P05": ("AXI-01, NI-02", "transaction_cg; boundary_cg"),
    "P06": ("AXI-01, NI-02", "transaction_cg; boundary_cg"),
    "P07": ("AXI-01, NI-02", "transaction_cg; boundary_cg"),
    "P08": ("AXI-01, NI-02", "transaction_cg; boundary_cg"),
    "P09": ("AXI-02", "transaction_cg.cp_size; write_strobe_cg.cp_size; write_strobe_cg.cp_lane"),
    "P10": ("AXI-03", "write_strobe_cg"),
    "P11": ("AXI-02, NI-01", "boundary_cg; transaction_cg"),
    "P12": ("NI-01, NI-03", "transaction_cg"),
    "P13": ("AXI-05", "response_cg"),
    "P14": ("AXI-06, NI-04", "outstanding_cg"),
    "P15": ("AXI-06, NI-04", "outstanding_cg"),
    "P16": ("AXI-07, NI-11", "ordering_cg; outstanding_cg"),
    "P17": ("AXI-07, NI-11", "ordering_cg"),
    "P18": ("NI-04, NI-11", "ordering_cg"),
    "P19": ("AXI-01/02/03/06", "transaction_cg; write_strobe_cg; outstanding_cg"),
    "P20": ("AXI-01/02/03/06, NI-05/10", "transaction_cg; write_strobe_cg; outstanding_cg; credit_cg; arbiter covers"),
    "P21": ("AXI-01/02/03/06, NI-05/10", "transaction_cg; write_strobe_cg; outstanding_cg; credit_cg; arbiter covers"),
    "P22": ("NI-09", "reset_cg"),
}

def metadata(item):
    req, targets = TARGETS[item]
    return dict(requirement_ids=req, coverage_targets=targets)


def coverage_bins(text, report, test_runs=None):
    """Read native per-instance bin tables, never infer hits from stimulus."""
    result = []
    group = instance = point = None
    table = False
    domains = {}
    for line in text.splitlines():
        if line.startswith("Group : "):
            group = line.split(" : ", 1)[1].strip()
            instance = None
            domains = {}
        if line.startswith("Group Instance : "):
            instance = line.split(" : ", 1)[1].strip()
            domains = {}
        if line.startswith("Summary for Variable ") or line.startswith("Summary for Cross "):
            point = line.split(" ", 3)[3].strip()
            table = False
        fields = re.findall(r"\[[^\]]*\]|\S+", line)
        if "COUNT" in fields and "AT" in fields and "LEAST" in fields:
            table = True
            count_index = fields.index("COUNT")
            axes = fields[:count_index]
            continue
        if line.startswith("---") or "Excluded/Illegal bins" in line:
            table = False
        if not (instance and point and table and len(fields) >= 3):
            continue
        if any(value == "*" or value.startswith("[") for value in fields[:count_index]):
            options = [domains[axis] if value == "*" else
                       [v.strip() for v in value[1:-1].split(",")] if value.startswith("[") else
                       [value] for axis, value in zip(axes, fields)]
            combinations = list(itertools.product(*options))
            if len(combinations) != int(fields[-1]):
                raise ValueError("Native compact cross bin count mismatch")
            for values in combinations:
                count = int(fields[count_index]) if fields[count_index].isdigit() else None
                goal = int(fields[count_index+1]) if fields[count_index+1].isdigit() else None
                result.append([report, group, instance, point, " / ".join(values), count, goal, "Uncovered"] + ([""] if test_runs is not None else []))
            continue
        if len(fields) > count_index + 1 and fields[count_index].isdigit() and fields[count_index+1].isdigit():
            count, goal = int(fields[count_index]), int(fields[count_index+1])
            if axes == ["NAME"]:
                domains.setdefault(point, []).append(fields[0])
            row = [report, group, instance, point, " / ".join(fields[:count_index]),
                   count, goal, "Covered" if count >= goal else "Uncovered"]
            if test_runs is not None:
                witnesses = []
                for token, hits in zip(fields[count_index+2::2], fields[count_index+3::2]):
                    if re.fullmatch(r"T[0-9]+", token):
                        witnesses.append(test_runs[token] + " (" + hits + ")")
                row.append(", ".join(witnesses))
            result.append(row)
    if not result:
        raise ValueError("No per-instance native coverage bins found")
    keys = [tuple(r[1:5]) for r in result]
    if len(set(keys)) != len(keys):
        raise ValueError("Duplicate native bin identity")
    summaries = text.split("Summary for Group Instance ")[1:]
    if summaries:
        expected = missing = 0
        for summary in summaries:
            summary = summary.split("Variables for Group Instance")[0].split("Crosses for Group Instance")[0]
            for match in re.finditer(r"^(?:Variables|Crosses)\s+(\d+)\s+(\d+)\s+(\d+)", summary, re.M):
                expected += int(match[1])
                missing += int(match[2])
        if expected != len(result) or missing != sum(row[7] == "Uncovered" for row in result):
            raise ValueError("Exported bins differ from native per-instance summary")
    return result



def stimulus_settings(schedule):
    # Checks, phase selection and seeds are recorded separately from timing controls.
    controls = ("concurrent_rw", "source_response_delay", "source_response_hold_cycles",
                "request_random_delay", "response_random_delay", "response_hold_cycles",
                "response_hold_port", "response_delay_port", "response_error",
                "hold_cycles", "stall_cycles")  # Retain explicit settings in older run records.
    return " ".join(k + "=" + str(schedule[k]) for k in controls
                    if schedule.get(k) not in (None, "", 0, "0", False))


def export(campaign, out, data_dir=None):
    data_dir = data_dir or ROOT / "docs/data"
    runs = list(csv.DictReader((data_dir / "verification-runs.csv").open()))
    runs = {r["run_id"]: r for r in runs if ("build/" + campaign + "/") in r["run_record"]}
    if not runs:
        raise ValueError("Campaign has no run records")
    raw = [r for r in csv.DictReader((data_dir / "verification-transactions.csv").open()) if r["run_id"] in runs]
    matrix, transactions, run_summary = [], [], []
    config = "R_ROB_EN=0/1 × NUM_DAT_VC=1/2; default depths"
    for run_id, run in runs.items():
        schedule = json.loads(run["schedule"])
        match = re.search(r"/(P[0-9]{2})_", schedule["stim_dir"])
        if not match:
            raise ValueError("Pattern ID missing: " + run_id)
        record = json.loads((ROOT / run["run_record"]).read_text())
        profile = yaml.safe_load(record["profile"])
        run["configuration"] = "R_ROB_EN={}, NUM_DAT_VC={}".format(
            profile.get("r_rob_en", "not recorded"), profile.get("num_dat_vc", "not recorded"))
        run["pattern_id"] = match[1]
        run["stimulus_conditions"] = stimulus_settings(schedule)
        run_summary.append([run_id,run["pattern_id"],run["case"],run["config"],run["run_result"],int(run["cycles"]),run["stimulus_conditions"],run["run_record"]])
    for r in raw:
        run = runs[r["run_id"]]
        size = int(r["bytes_per_beat"]).bit_length()-1
        fields = [r["run_id"],r["phase"],int(r["transaction_index"]),r["direction"],r["traffic"],int(r["axi_id"]),r["address"],int(r["beats"]),int(r["bytes_per_beat"]),size,int(r["burst"]),r["wstrb"],int(r["start_lane"]),r["destination"]]
        transactions.append(fields+[r["pattern_file"],r["pattern_sha256"]])
        items = [run["pattern_id"]]
        if items[0] in ("P05","P06","P07","P08") and r["boundary"] not in ("", "interior"):
            items.append("P11")
        for item in items:
            targets=TARGETS[item][1]
            if item == "P09" and r["direction"] == "read":
                targets="transaction_cg.cp_size (read lane coverage not implemented)"
            applicable=run["configuration"]
            if item in ("P17", "P18") and r["direction"] == "read":
                if r["config"].startswith("r0_"):
                    targets = "ordering_cg; outstanding_cg (read ordering without read reorder storage)"
            matrix.append([TARGETS[item][0],item,applicable]+fields+[int(r["run_seed"]),r["boundary"],run["stimulus_conditions"],targets,"size × lane: not implemented" if item=="P09" else "",r["config"]])
    report=campaign+"/functional_fresh"
    report_dir = ROOT / "build" / campaign / "evidence/reports/functional_fresh"
    test_runs = None
    if (report_dir / "tests.txt").exists():
        names = {}
        for run_id, run in runs.items():
            record = json.loads((ROOT / run["run_record"]).read_text())
            command = record["command"]
            name = str(Path(record["vdb"]).with_suffix("")) + "/" + command[command.index("-cm_name")+1]
            if name in names:
                raise ValueError("Duplicate native test: " + name)
            names[name] = run_id
        test_runs = {}
        for line in (report_dir / "tests.txt").read_text().splitlines():
            match = re.match(r"(T[0-9]+)\s+(\S+)", line)
            if match:
                test_runs[match[1]] = names[match[2]]
        if set(test_runs.values()) != set(runs):
            raise ValueError("Native report tests do not match campaign runs")
    bins = coverage_bins((report_dir / "grpinfo.txt").read_text(), report, test_runs)
    if set(r[1] for r in matrix)!=set(TARGETS):
        raise ValueError("Not all P01-P22 patterns are represented")
    out.mkdir(parents=True,exist_ok=True)
    payload=dict(matrix=matrix,transactions=transactions,bins=bins,runs=run_summary,campaign=campaign)
    (out/"matrix.json").write_text(json.dumps(payload,ensure_ascii=False))
    print(json.dumps({k:len(payload[k]) for k in ("matrix","transactions","bins","runs")}))

if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--campaign",required=True)
    parser.add_argument("--out",type=Path,required=True)
    parser.add_argument("--data-dir",type=Path)
    args=parser.parse_args()
    export(args.campaign,args.out,args.data_dir)
