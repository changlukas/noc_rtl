#!/usr/bin/env python3
"""Internal focused VCS checks for NSU context lifetime and source restoration."""
import os
from pathlib import Path
import subprocess

for width, depth in ((1, 1), (2, 3), (3, 4)):
    build = Path("build/nsu_context/i%d_d%d" % (width, depth)).resolve()
    build.mkdir(parents=True, exist_ok=True)
    binary = build / "simv"
    command = [os.environ.get("VCS", "vcs"), "-full64", "-sverilog", "-assert", "svaext",
               "-override_timescale=1ns/1ps", "-f", "files.f",
               "repo/rtl/nsu/context_buffer/tb_nsu_context_buffer.sv",
               "-top", "tb_nsu_context_buffer",
               "-pvalue+tb_nsu_context_buffer.OUTPUT_ID_WIDTH=%d" % width,
               "-pvalue+tb_nsu_context_buffer.DEPTH=%d" % depth,
               "-Mdir=" + str(build / "csrc"), "-o", str(binary),
               "-l", str(build / "compile.log")]
    subprocess.run(command, check=True)
    result = subprocess.run([str(binary)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, universal_newlines=True, timeout=60)
    (build / "run.log").write_text(result.stdout)
    print(result.stdout, flush=True)
    assert result.returncode == 0 and "NSU_CONTEXT_PASS" in result.stdout

build = Path("build/nsu_request").resolve()
build.mkdir(parents=True, exist_ok=True)
binary = build / "simv"
subprocess.run([os.environ.get("VCS", "vcs"), "-full64", "-sverilog", "-assert", "svaext",
                "-override_timescale=1ns/1ps", "-f", "files.f",
                "repo/rtl/nsu/top/tb_nsu_elaborate.sv", "-top", "tb_nsu_elaborate",
                "-Mdir=" + str(build / "csrc"), "-o", str(binary),
                "-l", str(build / "compile.log")], check=True)
result = subprocess.run([str(binary)], stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, universal_newlines=True, timeout=60)
(build / "run.log").write_text(result.stdout)
print(result.stdout, flush=True)
assert result.returncode == 0 and "NSU_REQUEST_PASS" in result.stdout
