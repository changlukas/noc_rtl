#!/usr/bin/env python3
"""Run the prepared verification matrix through the existing case runner."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument("--binary", help="Defaults to the prepared COVERAGE=1 binary")
p.add_argument("--report", default="verification_results")
p.add_argument("--jobs", type=int, default=1)
a = p.parse_args()
if a.jobs < 1:
    p.error("jobs must be positive")
stage = Path.cwd()
binary = str(Path(a.binary).resolve()) if a.binary else str(Path(subprocess.check_output(
    ["make", "--no-print-directory", "print-build-dirs", "COVERAGE=1"],
    universal_newlines=True).splitlines()[-1]) / "simv")
report = Path(a.report).resolve()
report.mkdir(parents=True, exist_ok=True)
runs = json.loads((stage / "verification-runs.json").read_text())


def run_case(run):
    command = ["python3", str(stage / "run.py"), "--binary", binary,
               "--case", run["case"], "--seed", str(run["seed"]),
               "--target", run["target"], "--coverage", "--coverage-name", "spec_" + run["tag"],
               "--report", str(report / run["tag"])]
    result = subprocess.run(command, cwd=str(stage / run["cwd"]), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, universal_newlines=True)
    (report / (run["tag"] + ".driver.log")).write_text(result.stdout)
    return dict(run, returncode=result.returncode, binary=binary)


results = {}
with ThreadPoolExecutor(max_workers=a.jobs) as pool:
    for future in as_completed([pool.submit(run_case, run) for run in runs]):
        result = future.result()
        results[result["tag"]] = result
        (report / "results.json").write_text(json.dumps(
            [results[r["tag"]] for r in runs if r["tag"] in results], indent=2) + "\n")
        print(result["tag"], "PASS" if result["returncode"] == 0 else "FAIL", flush=True)
raise SystemExit(int(any(result["returncode"] != 0 for result in results.values())))
