#!/usr/bin/env python3
"""Export current-campaign stimulus and native coverage for the verification matrix."""
import argparse
import hashlib
import json
import itertools
import re
import yaml
from axi_file_parser import _parse_read, _parse_write
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


def export(stage, out, report_dir=None):
    stage = stage.resolve()
    report_dir = (report_dir or stage / "build/coverage").resolve()
    runs = json.loads((stage / "verification-runs.json").read_text())
    results = json.loads((stage / "verification_results/results.json").read_text())
    if len({r["tag"] for r in runs}) != len(runs):
        raise ValueError("Duplicate run tag")
    completed = {r["tag"]: r for r in results}
    if set(completed) != {r["tag"] for r in runs} or len(results) != len(runs):
        raise ValueError("Regression results do not match the prepared matrix")
    topology = yaml.safe_load((stage / "topology.yml").read_text())
    regions = [(ep["name"], r) for ep in topology["endpoints"]
               for r in ep.get("addr_range", [])]
    params = dict(re.findall(r"localparam int NI_(\w+)\s*=\s*(\d+)",
                            (stage / "ni_tb_params.svh").read_text()))
    config = "R_ROB_EN={R_ROB_EN}, NUM_DAT_VC={NUM_DAT_VC}".format(**params)
    data_width = int(re.search(r"AXI_DATA_WIDTH\s*=\s*(\d+)",
        (stage / "repo/specgen/generated/sv/ni_params_pkg.sv").read_text())[1])
    matrix, transactions, run_summary, names = [], [], [], {}
    for number, run in enumerate(runs, 1):
        tag, case = run["tag"], run["case"]
        record_file = stage / "verification_results" / tag / (case + ".run.json")
        record = json.loads(record_file.read_text())
        if completed[tag]["returncode"] or not record["passed"]:
            raise ValueError("Failed run: " + tag)
        run_id = "r{}_vc{}-{:03d}".format(params["R_ROB_EN"], params["NUM_DAT_VC"], number)
        if record["case"] != case or record["simulation_seed"] != run["seed"] or record["target"] != run["target"]:
            raise ValueError("Run settings changed after simulation: " + tag)
        if yaml.safe_load(record["profile"]) != yaml.safe_load((stage / "profile.yml").read_text()):
            raise ValueError("Run hardware profile differs from stage: " + tag)
        command = record["command"]
        native_name = str(Path(record["vdb"]).with_suffix("")) + "/" + command[command.index("-cm_name")+1]
        if native_name in names:
            raise ValueError("Duplicate native test: " + native_name)
        names[native_name] = run_id
        stim = stage / run["cwd"] / "patterns" / (case + "_" + run["target"] if case == "capacity_reuse" else case)
        if (stim / "ni_tb_params.svh").read_bytes() != (stage / "ni_tb_params.svh").read_bytes():
            raise ValueError("Pattern hardware profile differs from stage: " + tag)
        for filename, digest in record["stimulus_sha256"].items():
            if hashlib.sha256((stim / filename).read_bytes()).hexdigest() != digest:
                raise ValueError("Stimulus changed after simulation: " + str(stim / filename))
        schedule = {}
        for token in (stim / "schedule.txt").read_text().split():
            key, _, value = token.lstrip("+").partition("=")
            schedule[key] = value or True
        settings = stimulus_settings(schedule)
        log = record_file.with_name(case + ".log").read_text()
        cycles = int(re.search(r"CAPACITY_PERF .*?cycles=(\d+)", log)[1])
        run_summary.append([run_id, run["item"], case, config, "PASS", cycles, settings,
                            str(record_file.relative_to(stage))])
        index = 0
        for filename, direction in (("init_write.txt", "write"), ("write.txt", "write"),
                                    ("read.txt", "read"), ("verify_read.txt", "read")):
            file = stim / filename
            if not file.exists():
                continue
            parsed = (_parse_write if direction == "write" else _parse_read)(file)
            for transaction in parsed:
                index += 1
                addr, size = transaction["addr"], transaction["size"]
                destination, region = next((name, r) for name, r in regions
                    if int(r["base"]) <= addr < int(r["base"]) + int(r["size"]))
                traffic = "control" if region["space"] == "config" else "data"
                strobe = " ".join("h" + beat.split()[1].removeprefix("0x")
                                  for beat in transaction.get("beats", []))
                fields = [run_id, index, direction, traffic, transaction["id"], "h{:x}".format(addr),
                          transaction["len"], size, transaction["burst"], strobe,
                          addr % (data_width // 8), destination]
                transactions.append(fields[:7] + [1 << size] + fields[7:] +
                    [str(file.relative_to(stage)), record["stimulus_sha256"][filename]])
                items = [run["item"]]
                end = addr + ((transaction["len"] + 1) << size)
                if items[0] in ("P05", "P06", "P07", "P08") and (
                        addr == int(region["base"]) or end == int(region["base"]) + int(region["size"]) or end % 4096 == 0):
                    items.append("P11")
                for item in items:
                    target = TARGETS[item][1]
                    if item == "P09" and direction == "read":
                        target = "transaction_cg.cp_size (read lane coverage not implemented)"
                    matrix.append([item, config] + fields + [run["seed"], settings, target,
                        "size × lane: not implemented" if item == "P09" else "", config])
    test_runs = {}
    for line in (report_dir / "tests.txt").read_text().splitlines():
        match = re.match(r"(T[0-9]+)\s+(\S+)", line)
        if match:
            test_runs[match[1]] = names[match[2]]
    if set(test_runs.values()) != set(names.values()):
        raise ValueError("Native report tests do not match the regression")
    bins = coverage_bins((report_dir / "grpinfo.txt").read_text(), "r{}_vc{}".format(
        params["R_ROB_EN"], params["NUM_DAT_VC"]), test_runs)
    if {r[0] for r in matrix} != set(TARGETS):
        raise ValueError("Not all P01-P22 patterns are represented")
    payload = dict(matrix=matrix, transactions=transactions, bins=bins, runs=run_summary)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, ensure_ascii=False))
    print(json.dumps({key: len(rows) for key, rows in payload.items()}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    export(args.stage, args.out, args.report)
