#!/usr/bin/env python3
"""VCS SAM boundary, timing-cut and generated-width contract checks."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
os.chdir(str(root))
report = root / "build/sam_check"
report.mkdir(parents=True, exist_ok=True)
lines = (root / "files.f").read_text().splitlines()
leaf_names = ("ni_params_pkg.sv", "ni_signals_pkg.sv", "ni_flit_pkg.sv", "topology_pkg.sv",
              "ni_types_pkg.sv", "cc_pkg.sv", "cc_addr_decode_dync.sv", "cc_addr_decode.sv",
              "cc_spill_register_flushable.sv", "cc_spill_register.sv", "cc_stream_register.sv",
              "stream_register.sv", "ni_sam.sv", "sam.sv", "axi_pkg.sv", "nmu_sam_burst_checker.sv")
leaf = report / "leaf.f"
leaf.write_text("\n".join(x for x in lines if x.startswith(("+incdir+", "+define+")) or x.endswith(leaf_names)) + "\n")

def run(name, command, expected=None):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            universal_newlines=True, timeout=300)
    (report / (name + ".log")).write_text(result.stdout)
    if expected:
        assert expected in result.stdout and "Invalid burst was not detected" not in result.stdout, name
    else:
        assert result.returncode == 0 and "Fatal:" not in result.stdout, name
    print("PASS " + name, flush=True)

with tempfile.TemporaryDirectory(prefix="nmu-sam-") as work:
    def compile_top(top, source, filelist, parameter=None):
        target = Path(work) / (top + (str(parameter) if parameter is not None else ""))
        target.mkdir()
        command = ["vcs", "-full64", "-sverilog", "-assert", "svaext", "-override_timescale=1ns/1ps", "-f", str(filelist),
                   "-top", top, "-Mdir=" + str(target / "csrc"), "-o", str(target / "simv")]
        if source: command.append(source)
        if parameter is not None: command.append("-pvalue+%s.INVALID_WIDTH=%d" % (top, parameter))
        run("compile_" + target.name, command)
        return str(target / "simv")
    binary = compile_top("tb_nmu_sam_boundary", "repo/rtl/nmu/sam/tb_sam_boundary.sv", leaf)
    run("boundary_legal", [binary])
    for case in range(1, 7):
        run("boundary_invalid_%d" % case, [binary, "+invalid_case=%d" % case],
            "burst crosses 4 KB boundary" if case <= 2 else "invalid AXI burst attributes")
    for case in (1, 2):
        run("ar_boundary_invalid_%d" % case, [binary, "+invalid_case=%d" % case, "+ar_only"],
            "AR burst crosses 4 KB boundary")
    binary = compile_top("tb_nmu_sam", "repo/rtl/nmu/sam/tb_sam.sv", leaf)
    run("timing_cuts", [binary])
    for case in range(4):
        binary = compile_top("tb_nmu_elaborate", None, root / "files.f", case)
        run("width_%d" % case, [binary],
            "AXI address/data/user widths must match the generated package" if case else None)
print("PASS: SAM closeout checks")
