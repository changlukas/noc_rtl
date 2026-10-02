#!/usr/bin/env python3
"""Summarize observed events separately from functional acceptance."""
import argparse
import hashlib
import json
from pathlib import Path
import re

EVENT = re.compile(r"^NI_COVER scope=(\S+) event=(\S+) count=(\d+)$", re.M)


def summarize(log, case, passed, plan):
    records = EVENT.findall(log)
    observed = {}
    totals = {}
    for scope, event, value in records:
        if event in observed.setdefault(scope, {}):
            raise ValueError("Duplicate coverage record: {} {}".format(scope, event))
        observed[scope][event] = int(value)
        totals[event] = totals.get(event, 0) + int(value)
    master = observed.get("master", {})
    counts = re.search(r"NMU_COSIM_COUNTS writes=(\d+) reads=(\d+) r_beats=(\d+)", log)
    valid = ("NI_COVERAGE_BEGIN" in log and "NI_COVERAGE_END" in log and counts is not None
             and master.get("observer_pending") == 0
             and master.get("observer_unmatched", 0) == 0)
    if counts:
        writes, reads, beats = map(int, counts.groups())
        valid &= (master.get("aw", 0) == master.get("b", 0) == writes and
                  master.get("ar", 0) == master.get("r.transaction", 0) == reads and
                  master.get("r.beat", 0) == beats)
    required = plan["cases"][case]
    missing = [event for event in required if master.get(event, 0) == 0]
    return {
        "case": case,
        "functional": "PASS" if passed else "FAIL",
        "observation_valid": bool(valid),
        "scenario": "INVALID" if not valid else ("MISS" if missing else "HIT"),
        "required_events": required, "missing_events": missing,
        "totals": totals, "instances": observed,
    }


def write_case(log, case, passed, stim, report, binary, mode, command):
    plan = json.loads(Path("coverage_plan.json").read_text())
    result = summarize(log, case, passed, plan)
    result["coverage_plan_sha256"] = hashlib.sha256(Path("coverage_plan.json").read_bytes()).hexdigest()
    result["mode"] = mode
    result["binary"] = str(binary)
    result["command"] = command
    result["stimulus_sha256"] = {
        p.name: hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(stim.iterdir()) if p.is_file()
    }
    result["source_manifest_sha256"] = hashlib.sha256(Path("SHA256SUMS").read_bytes()).hexdigest()
    result["profile"] = Path("profile.yml").read_text()
    (report / (case + ".coverage.json")).write_text(json.dumps(result, indent=2) + "\n")
    print("NI_SCENARIO {} {}".format(case, result["scenario"]))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--plan", type=Path, default=Path("coverage_plan.json"))
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    cases = []
    for case in plan["cases"]:
        path = args.report / (case + ".coverage.json")
        if path.exists():
            result = json.loads(path.read_text())
            log_path = args.report / (case + ".log")
            if log_path.exists():
                result.update(summarize(log_path.read_text(), case,
                                       result["functional"] == "PASS", plan))
                result["coverage_plan_sha256"] = hashlib.sha256(args.plan.read_bytes()).hexdigest()
                path.write_text(json.dumps(result, indent=2) + "\n")
            cases.append(result)
        else:
            cases.append({"case": case, "functional": "NOT_RUN", "scenario": "NOT_RUN"})
    output = {"cases": cases, "scope": plan["scope"], "not_measured": plan["not_measured"]}
    (args.report / "coverage-summary.json").write_text(json.dumps(output, indent=2) + "\n")
    lines = ["| Case | Functional | Scenario | Missing events |",
             "|---|---|---|---|"]
    for row in cases:
        lines.append("| {} | {} | {} | {} |".format(row["case"], row["functional"],
                     row["scenario"], ", ".join(row.get("missing_events", []))))
    (args.report / "coverage-summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
