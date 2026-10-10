"""Runner must retain acceptance checks when stimulus settings are simplified."""
import json
from pathlib import Path
import subprocess
import sys

RUNNER = Path(__file__).resolve().parents[1] / "script/run.py"


def prepare(tmp_path, acceptance=True):
    pattern = tmp_path / "patterns/example"
    pattern.mkdir(parents=True)
    (pattern.parent / "cases.list").write_text("example\n")
    (pattern / "schedule.txt").write_text("+case_name=example\n+response_hold_cycles=32\n")
    for name in ("read.txt", "write.txt"):
        (pattern / name).write_text("")
    manifest = dict(seed=1, files=[])
    if acceptance:
        manifest["acceptance"] = dict(min_outstanding=2, order="same_id")
    (pattern / "manifest.json").write_text(json.dumps(manifest))
    binary = tmp_path / "simv"
    binary.write_text("#!/usr/bin/env python3\nimport sys,json\nfrom pathlib import Path\n"
                      "Path('args.json').write_text(json.dumps(sys.argv[1:]))\n"
                      "print('NMU_COSIM_COUNTS AXI_ORDERING_CHECK_DRAINED')\n")
    binary.chmod(0o755)
    (pattern / "ni_tb_params.svh").write_text("localparam int NI_NUM_DAT_VC = 2;\n")
    (tmp_path / "ni_tb_params.svh").write_bytes((pattern / "ni_tb_params.svh").read_bytes())
    return pattern, [sys.executable, str(RUNNER), "--binary", str(binary),
                     "--case", "example", "--report", str(tmp_path / "report")]


def test_acceptance_and_optional_phases(tmp_path):
    pattern, command = prepare(tmp_path)
    for name in ("preload.mem", "init_write.txt", "verify_read.txt"):
        (pattern / name).write_text("data")
    manifest = json.loads((pattern / "manifest.json").read_text())
    manifest["files"] = ["preload.mem", "init_write.txt", "verify_read.txt"]
    (pattern / "manifest.json").write_text(json.dumps(manifest))
    subprocess.run(command + ["--seed", "17"], cwd=tmp_path, check=True, capture_output=True)
    args = json.loads((tmp_path / "args.json").read_text())
    assert "+check_min_outstanding=2" in args and "+check_order=same_id" in args
    assert all(flag in args for flag in ("+preload", "+init_phase", "+readback"))
    assert "+concurrent_rw" not in args
    assert "+ntb_random_seed=17" in args and "+reset_seed=17" in args
    assert json.loads((pattern / "manifest.json").read_text())["seed"] == 1
    assert "+response_hold_cycles=32" in args


def test_old_manifest_rejected(tmp_path):
    _, command = prepare(tmp_path, acceptance=False)
    result = subprocess.run(command, cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode != 0 and "no acceptance criteria" in result.stderr
    assert not (tmp_path / "args.json").exists()


def test_stale_optional_files_ignored(tmp_path):
    pattern, command = prepare(tmp_path)
    for filename in ("preload.mem", "init_write.txt", "verify_read.txt"):
        (pattern / filename).write_text("stale")
    subprocess.run(command, cwd=tmp_path, check=True, capture_output=True)
    args = json.loads((tmp_path / "args.json").read_text())
    assert not any(flag in args for flag in ("+preload", "+init_phase", "+readback"))


def test_uvm_error_cannot_pass_with_completion_markers(tmp_path):
    _, command = prepare(tmp_path)
    binary = tmp_path / "simv"
    with binary.open("a") as stream:
        stream.write("print('UVM_ERROR vip.svh(1) @ 10: monitor [CHECK] failure')\n")
    result = subprocess.run(command, cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode != 0


def test_zero_uvm_summary_passes(tmp_path):
    _, command = prepare(tmp_path)
    with (tmp_path / "simv").open("a") as stream:
        stream.write("print('UVM_ERROR : 0\\nUVM_FATAL : 0')\n")
    subprocess.run(command, cwd=tmp_path, check=True, capture_output=True)


def test_corruption_requires_both_checkers(tmp_path):
    _, command = prepare(tmp_path)
    with (tmp_path / "simv").open("a") as stream:
        stream.write("print('UVM_ERROR checker.svh(1) @ 10: checker [AXI_ORDER] R mismatch')\n")
    assert subprocess.run(command + ["--corrupt"], cwd=tmp_path, capture_output=True).returncode != 0
    with (tmp_path / "simv").open("a") as stream:
        stream.write("print('UVM_ERROR checker.svh(2) @ 10: checker [AXI_DATA] Unexpected RData ID: 0')\n")
    subprocess.run(command + ["--corrupt"], cwd=tmp_path, check=True, capture_output=True)
    with (tmp_path / "simv").open("a") as stream:
        stream.write("print('UVM_ERROR checker.svh(3) @ 10: checker [CREDIT] unrelated error')\n")
    assert subprocess.run(command + ["--corrupt"], cwd=tmp_path, capture_output=True).returncode != 0


def test_wrong_hardware_binary_rejected_before_execution(tmp_path):
    pattern, command = prepare(tmp_path)
    (pattern / "ni_tb_params.svh").write_text("localparam int NI_NUM_DAT_VC = 1;\n")
    result = subprocess.run(command, cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode != 0 and "does not match" in result.stderr
    assert not (tmp_path / "args.json").exists()
