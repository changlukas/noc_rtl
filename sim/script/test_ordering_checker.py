#!/usr/bin/env python3
"""Focused VCS checks for legal overtaking and rejected ordering/data faults."""
import os
from pathlib import Path
import re
import subprocess

build = Path("build/ordering_checker").resolve()
build.mkdir(parents=True, exist_ok=True)
binary = build / "simv"
subprocess.run([os.environ.get("VCS", "vcs"), "-full64", "-sverilog", "-assert", "svaext",
                "-override_timescale=1ns/1ps", "-f", "files.f", "repo/sim/dv/tb_axi_reorder_compare.sv",
                "-top", "tb_axi_reorder_compare", "-Mdir=" + str(build / "csrc"),
                "-o", str(binary), "-l", str(build / "compile.log")], check=True)
for fault, expected in [(0, None), (1, "AW mismatch or same-ID request reordered"),
                        (2, "AR mismatch or same-ID request reordered"),
                        (3, "W mismatch"), (4, "R mismatch"), (5, None), (6, "R mismatch"),
                        (7, None), (8, "B mismatch"), (9, "R mismatch")]:
    result = subprocess.run([str(binary), "+fault=" + str(fault)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, timeout=180)
    (build / ("fault_%d.log" % fault)).write_text(result.stdout)
    if expected is None:
        assert result.returncode == 0 and "CHECKER_TEST_DONE" in result.stdout, result.stdout
        assert not re.search(r"(?m)^(Error|Fatal|Warning):", result.stdout), result.stdout
    else:
        assert expected in result.stdout and "Error:" in result.stdout, result.stdout
    print("CHECKER_TEST_PASS fault=%d expected=%s" % (fault, expected or "none"), flush=True)
