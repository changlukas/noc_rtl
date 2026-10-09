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
p.add_argument("--coverage-name", help="Unique native coverage test name")
p.add_argument("--backpressure", action="store_true")
p.add_argument("--target", choices=("per_id", "context", "rob"), default="per_id")
p.add_argument("--seed", type=int, default=1, help="Simulation seed; transaction seed is set during pattern generation")
a = p.parse_args()
patterns = Path("patterns")
if a.mode != "auto":
    patterns /= a.mode
cases = (patterns / "cases.list").read_text().split()
if a.case not in cases:
    p.error("Unsupported co-simulation CASE '{}'. Use make list. "
            "Available cases: {}".format(a.case, ", ".join(cases)))
pattern = a.case
if a.backpressure:
    if a.case not in ("single_id_reorder", "multi_id_out_of_order"):
        p.error("BACKPRESSURE=1 requires a reorder case")
    pattern += "_backpressure"
if a.case == "capacity_reuse":
    pattern += "_" + a.target
stim = patterns / pattern
if not 0 <= a.seed <= 0xffffffff:
    p.error("SEED must be an unsigned 32-bit integer")
run_name = a.coverage_name or (pattern + "_" + a.mode + "_s" + str(a.seed))
if not re.fullmatch(r"[A-Za-z0-9_]+", run_name):
    p.error("coverage name must contain only letters, digits and underscores")
for name in ("schedule.txt", "read.txt", "write.txt"):
    if not (stim / name).is_file():
        p.error("Incomplete co-simulation pattern '{}': missing {}. "
                "Prepare and synchronize the co-simulation environment again.".format(a.case, stim / name))
report = Path(a.report)
report.mkdir(parents=True, exist_ok=True)
args = [str(Path(a.binary).resolve()), "+stim_dir=" + str(stim.resolve())]
args += [v for v in (stim / "schedule.txt").read_text().split() if not v.startswith("+seed=")]
manifest = json.loads((stim / "manifest.json").read_text())
if "acceptance" not in manifest or "files" not in manifest:
    p.error("Pattern manifest has no acceptance criteria or file list; regenerate patterns")
args += ["+reset_seed=" + str(a.seed), "+ntb_random_seed=" + str(a.seed)]
for key, value in manifest["acceptance"].items():
    args.append("+check_" + key + "=" + str(value))
for filename, flag in (("preload.mem", "preload"), ("init_write.txt", "init_phase"),
                       ("verify_read.txt", "readback")):
    if filename in manifest["files"]:
        if not (stim / filename).is_file():
            p.error("Missing pattern file: " + str(stim / filename))
        args.append("+" + flag)
if a.coverage:
    args += ["-cm", "line+cond+fsm+tgl+branch+assert",
             "-cm_dir", str(Path(a.binary).resolve()) + ".vdb",
             "-cm_name", run_name]
if a.wave:
    args += ["+wave_file=" + str((report / (a.case + ".fsdb")).resolve())]
if a.corrupt:
    args += ["+corrupt_rsp"]
r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
log = r.stdout.decode(errors="replace")
log_path = report / (a.case + ("_corrupt" if a.corrupt else "") + ".log")
diagnostics = re.sub(r"Warning: [^\n]*\nMacro 'FFARN' is deprecated\. Use 'FF' instead\.\n", "", log)
failed = r.returncode != 0 or bool(re.search(r"(?im)^(?:Warning:|Error:|Fatal:)|\b(?:mismatch|does not match|Assertion failed)\b", diagnostics))
failed |= bool(re.search(r"(?m)^UVM_(?:ERROR|FATAL)(?!\s*:)|^UVM_(?:ERROR|FATAL)\s*:\s*[1-9]", diagnostics))
if a.wave:
    wave_file = report / (a.case + ".fsdb")
    failed |= (not re.search(r"\*Verdi\*.*Create FSDB file", log) or
               not wave_file.is_file() or wave_file.stat().st_size == 0)
passed = "NMU_COSIM_COUNTS" in log and "AXI_ORDERING_CHECK_DRAINED" in log and not failed
if a.corrupt:
    errors = re.findall(r"(?m)^UVM_ERROR .*?\[([^]]+)\] ([^\n]*)", log)
    fatals = re.findall(r"(?m)^Fatal: [^\n]*\n([^\n]*)", log)
    passed = (r.returncode in (0, 1) and "Unexpected RData" in log and
              {code for code, _ in errors} == {"AXI_ORDER", "AXI_DATA"} and
              all((code == "AXI_ORDER" and message == "R mismatch") or
                  (code == "AXI_DATA" and message.startswith("Unexpected RData")) for code, message in errors) and
              not re.search(r"(?m)^UVM_FATAL(?!\s*:)|^Error:", log) and
              all(message == "AXI ordering checker has pending transactions" for message in fatals))

if passed:
    log += "NMU_COSIM_CORRUPTION_DETECTED\n" if a.corrupt else "NMU_COSIM_PASS\n"
log_path.write_text(log)
print(log)
if a.coverage:
    # The binary may be shared by several stimulus directories.
    build_source = next((parent for parent in Path(a.binary).resolve().parents
                         if (parent / "files.f").is_file() and
                            (parent / "SHA256SUMS").is_file()), Path.cwd())
    # Run provenance only. Functional coverage bins/results belong to VCS/URG.
    result = dict(case=a.case, mode=a.mode, target=a.target, backpressure=a.backpressure, seed=a.seed, passed=passed, command=args,
                  vdb=str(Path(a.binary).resolve()) + ".vdb",
                  stimulus_seed=manifest["seed"], simulation_seed=a.seed,
                  source_manifest_sha256=hashlib.sha256((build_source / "SHA256SUMS").read_bytes()).hexdigest(),
                  source_directory=str(build_source),
                  profile=Path("profile.yml").read_text(),
                  stimulus_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in sorted(stim.iterdir()) if p.is_file()})
    result["binary_sha256"] = hashlib.sha256(Path(a.binary).read_bytes()).hexdigest()
    clock = re.search(r"CLOCK_CONFIG axi_period_ps=(\d+) noc_period_ps=(\d+)", log)
    phase = re.search(r"CLOCK_PHASE noc_phase_ps=(\d+)", log)
    if clock:
        result["clock"] = dict(axi_period_ps=int(clock.group(1)), noc_period_ps=int(clock.group(2)),
                               noc_phase_ps=int(phase.group(1)) if phase else 0)
    (report / (a.case + ".run.json")).write_text(json.dumps(result, indent=2) + "\n")
if not passed:
    raise SystemExit("Co-simulation acceptance failed")
