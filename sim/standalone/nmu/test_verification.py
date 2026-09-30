#!/usr/bin/env python3
"""Focused NMU VCS acceptance; run from the synchronized standalone directory."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
os.chdir(str(root))
os.environ.setdefault("VCS_ARCH_OVERRIDE", "linux")
out = root / "build/verification"
out.mkdir(parents=True, exist_ok=True)
manifest = (root / "SHA256SUMS").read_bytes()
key = hashlib.sha256(manifest).hexdigest()[:12]
(out / "source-SHA256SUMS").write_bytes(manifest)
results = []


def execute(args, log, expected="PASS", failure=False):
    with log.open("w") as stream:
        run = subprocess.run(args, stdout=stream, stderr=subprocess.STDOUT, timeout=300)
    text = log.read_text()
    passed = expected in text and (failure or (run.returncode == 0 and
        not any(mark in text for mark in ("Fatal:", "Error:", "ASSERT FAILED"))))
    results.append(dict(command=args, log=str(log), passed=passed,
                        expected_failure=failure, coverage=[line for line in text.splitlines()
                        if line.startswith(("COVER", "CLOCK", "RESET_RECOVERY", "PASS"))]))
    (out / "results.json").write_text(json.dumps(results, indent=2))
    print(log.name, "PASS" if passed else "FAIL", flush=True)
    if not passed:
        print(text[-6000:], flush=True)
        raise SystemExit(1)


binaries = {}
for rob in (1, 0):
    work = Path("/tmp") / ("noc-verification-%d-%s-r%d" % (os.getuid(), key, rob))
    work.mkdir(parents=True, exist_ok=True)
    binary = work / "simv"
    cmd = ["vcs", "-full64", "-sverilog", "-assert", "svaext",
           "-override_timescale=1ns/1ps", "-f", "files.f", "-top", "tb_nmu_standalone",
           "-pvalue+tb_nmu_standalone.R_ROB_EN=" + str(rob),
           "-Mdir=" + str(work / "csrc"), "-o", str(binary)]
    if not binary.exists():
        execute(cmd, out / ("compile_r%d.log" % rob), expected="CPU time:")
    binaries[rob] = str(binary)

cases = [
    ("request_rand", "rand", 11, 1, []),
    ("read_interleave", "control", 13, 1, ["+read_interleave"]),
    ("read_interleave", "data", 17, 1, ["+read_interleave"]),
    ("read_interleave", "data", 19, 0, ["+read_interleave"]),
    ("reset_recovery", "control", 23, 1, []),
    ("reset_recovery", "data", 29, 1, []),
    ("reset_recovery", "data", 43, 0, []),
    ("single_id_reorder", "control", 31, 1, []),
]
for case, mode, seed, rob, extra in cases:
    label = "%s_%s_s%d_r%d" % (case, mode, seed, rob)
    catalog = "verification.json" if case == "read_interleave" else "cases.json"
    patterns = out / "patterns" / label
    subprocess.run([sys.executable, "repo/sim/tools/gen_standalone_patterns.py",
        "--out", str(patterns), "--topology", "cases/topology.json", "--catalog",
        "repo/sim/test_patterns/standalone/" + catalog, "--id-width", "8",
        "--case", case, "--mode", mode, "--seed", str(seed)], check=True)
    stim = patterns / case
    args = [binaries[rob], "+stim_dir=" + str(stim), "+async_clocks"]
    args += (stim / "schedule.txt").read_text().split() + extra
    execute(args, out / (label + ".log"), "PASS NMU standalone")
    if case == "read_interleave" and rob == 0:
        execute(args + ["+corrupt_rsp"], out / "negative_read_data.log",
                "R data/lane/order/last mismatch", failure=True)

work = Path("/tmp") / ("noc-verification-%d-%s-fifo" % (os.getuid(), key))
work.mkdir(parents=True, exist_ok=True)
binary = work / "simv"
if not binary.exists():
    execute(["vcs", "-full64", "-sverilog", "-assert", "svaext",
        "-override_timescale=1ns/1ps", "-f", "files.f",
        "repo/rtl/nmu/response_path/tb_response_path.sv", "-top", "tb_nmu_response_path",
        "-Mdir=" + str(work / "csrc"), "-o", str(binary)],
        out / "compile_fifo.log", "CPU time:")
for seed in (7, 19, 41):
    execute([str(binary), "+seed=" + str(seed)], out / ("fifo_s%d.log" % seed),
            "PASS response FIFO reset recovery")
print("PASS NMU verification acceptance", flush=True)
