#!/usr/bin/env python3
"""Fail closed on model, protocol and existing scoreboard diagnostics."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument("--binary", required=True)
p.add_argument("--case", required=True)
p.add_argument("--report", required=True)
p.add_argument("--mode", choices=("auto", "control", "data", "rand"), default="auto")
p.add_argument("--wave", action="store_true")
p.add_argument("--corrupt", action="store_true")
p.add_argument("--coverage", action="store_true")
a = p.parse_args()
patterns = Path("patterns")
if a.mode != "auto":
    patterns /= a.mode
cases = (patterns / "cases.list").read_text().split()
if a.case not in cases:
    p.error("Unsupported co-simulation CASE '{}'. Use make list. "
            "Available cases: {}".format(a.case, ", ".join(cases)))
stim = patterns / a.case
for name in ("schedule.txt", "read.txt", "write.txt"):
    if not (stim / name).is_file():
        p.error("Incomplete co-simulation pattern '{}': missing {}. "
                "Prepare and synchronize the co-simulation environment again.".format(a.case, stim / name))
report = Path(a.report)
report.mkdir(parents=True, exist_ok=True)
args = [str(Path(a.binary).resolve()), "+stim_dir=" + str(stim.resolve())]
args += (stim / "schedule.txt").read_text().split()
if a.coverage:
    args += ["-cm", "line+cond+fsm+tgl+branch+assert",
             "-cm_dir", str(Path(a.binary).resolve()) + ".vdb",
             "-cm_name", a.case + "_" + a.mode]
if a.wave:
    args += ["+wave_file=" + str((report / (a.case + ".fsdb")).resolve())]
if a.corrupt:
    args += ["+corrupt_rsp"]
r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
log = r.stdout.decode(errors="replace")
log_path = report / (a.case + ("_corrupt" if a.corrupt else "") + ".log")
diagnostics = re.sub(r"Warning: [^\n]*\nMacro 'FFARN' is deprecated\. Use 'FF' instead\.\n", "", log)
failed = r.returncode != 0 or bool(re.search(r"(?im)^(?:Warning:|Error:|Fatal:)|\b(?:mismatch|does not match|Assertion failed)\b", diagnostics))
if a.wave:
    wave_file = report / (a.case + ".fsdb")
    failed |= (not re.search(r"\*Verdi\*.*Create FSDB file", log) or
               not wave_file.is_file() or wave_file.stat().st_size == 0)
passed = "NMU_COSIM_COUNTS" in log and "AXI_ORDERING_CHECK_DRAINED" in log and not failed
if a.corrupt:
    errors = re.findall(r"(?m)^Error: [^\n]*\n([^\n]*)", log)
    fatals = re.findall(r"(?m)^Fatal: [^\n]*\n([^\n]*)", log)
    passed = (r.returncode in (0, 1) and "Unexpected RData" in log and
              bool(errors) and all(message == "R mismatch" for message in errors) and
              all(message == "AXI ordering checker has pending transactions" for message in fatals) and
              "i_ordering_checker" in log)
if passed:
    log += "NMU_COSIM_CORRUPTION_DETECTED\n" if a.corrupt else "NMU_COSIM_PASS\n"
log_path.write_text(log)
print(log)
if a.coverage:
    # Run provenance only. Functional coverage bins/results belong to VCS/URG.
    result = dict(case=a.case, mode=a.mode, passed=passed, command=args,
                  vdb=str(Path(a.binary).resolve()) + ".vdb",
                  source_manifest_sha256=hashlib.sha256(Path("SHA256SUMS").read_bytes()).hexdigest(),
                  profile=Path("profile.yml").read_text(),
                  stimulus_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in sorted(stim.iterdir()) if p.is_file()})
    (report / (a.case + ".run.json")).write_text(json.dumps(result, indent=2) + "\n")
if not passed:
    raise SystemExit("Co-simulation acceptance failed")
