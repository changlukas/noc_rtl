"""Runner must retain acceptance checks when stimulus settings are simplified."""
import json
from pathlib import Path
import subprocess
import sys

_run = subprocess.run

def run(command, *args, **kwargs):
    if isinstance(command, list) and '--binary' in command:
        from build_key import finish_compile
        finish_compile(Path(command[command.index('--binary')+1]).parent)
    return _run(command, *args, **kwargs)

RUNNER = Path(__file__).with_name("run.py")


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
    (tmp_path / "SHA256SUMS").write_text("test source manifest\n")
    (tmp_path / "profile.yml").write_text("{}\n")
    from build_key import finish_compile
    (tmp_path / "config.json").write_text("{}")
    (tmp_path / "compile-command.txt").write_text("fake simulator for existing runner unit tests")
    finish_compile(tmp_path)
    return pattern, [sys.executable, str(RUNNER), "--binary", str(binary),
                     "--inputs", str(pattern.parent), "--campaign", str(tmp_path), "--case", "example", "--report", str(tmp_path / "report")]


def test_acceptance_and_optional_phases(tmp_path):
    pattern, command = prepare(tmp_path)
    for name in ("preload.mem", "init_write.txt", "verify_read.txt"):
        (pattern / name).write_text("data")
    manifest = json.loads((pattern / "manifest.json").read_text())
    manifest["files"] = ["preload.mem", "init_write.txt", "verify_read.txt"]
    (pattern / "manifest.json").write_text(json.dumps(manifest))
    run(command + ["--seed", "17"], cwd=tmp_path, check=True, capture_output=True)
    args = json.loads((tmp_path / "report/args.json").read_text())
    assert "+check_min_outstanding=2" in args and "+check_order=same_id" in args
    assert all(flag in args for flag in ("+preload", "+init_phase", "+readback"))
    assert "+concurrent_rw" not in args
    assert "+ntb_random_seed=17" in args and "+reset_seed=17" in args
    assert json.loads((pattern / "manifest.json").read_text())["seed"] == 1
    assert "+response_hold_cycles=32" in args


def test_old_manifest_rejected(tmp_path):
    _, command = prepare(tmp_path, acceptance=False)
    result = run(command, cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode != 0 and "no acceptance criteria" in result.stderr
    assert not (tmp_path / "report/args.json").exists()


def test_stale_optional_files_ignored(tmp_path):
    pattern, command = prepare(tmp_path)
    for filename in ("preload.mem", "init_write.txt", "verify_read.txt"):
        (pattern / filename).write_text("stale")
    run(command, cwd=tmp_path, check=True, capture_output=True)
    args = json.loads((tmp_path / "report/args.json").read_text())
    assert not any(flag in args for flag in ("+preload", "+init_phase", "+readback"))


def test_uvm_error_cannot_pass_with_completion_markers(tmp_path):
    _, command = prepare(tmp_path)
    binary = tmp_path / "simv"
    with binary.open("a") as stream:
        stream.write("print('UVM_ERROR vip.svh(1) @ 10: monitor [CHECK] failure')\n")
    result = run(command, cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode != 0


def test_zero_uvm_summary_passes(tmp_path):
    _, command = prepare(tmp_path)
    with (tmp_path / "simv").open("a") as stream:
        stream.write("print('UVM_ERROR : 0\\nUVM_FATAL : 0')\n")
    run(command, cwd=tmp_path, check=True, capture_output=True)


def test_corruption_requires_both_checkers(tmp_path):
    _, command = prepare(tmp_path)
    with (tmp_path / "simv").open("a") as stream:
        stream.write("print('UVM_ERROR checker.svh(1) @ 10: checker [AXI_ORDER] R mismatch')\n")
    assert run(command + ["--corrupt"], cwd=tmp_path, capture_output=True).returncode != 0
    with (tmp_path / "simv").open("a") as stream:
        stream.write("print('UVM_ERROR checker.svh(2) @ 10: checker [AXI_DATA] Unexpected RData ID: 0')\n")
    run(command + ["--corrupt"], cwd=tmp_path, check=True, capture_output=True)
    with (tmp_path / "simv").open("a") as stream:
        stream.write("print('UVM_ERROR checker.svh(3) @ 10: checker [CREDIT] unrelated error')\n")
    assert run(command + ["--corrupt"], cwd=tmp_path, capture_output=True).returncode != 0


def test_wrong_hardware_binary_rejected_before_execution(tmp_path):
    pattern, command = prepare(tmp_path)
    (pattern / "ni_tb_params.svh").write_text("localparam int NI_NUM_DAT_VC = 1;\n")
    result = run(command, cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode != 0 and "does not match" in result.stderr
    assert not (tmp_path / "report/args.json").exists()


def test_corruption_allows_only_expected_pending_fatal(tmp_path):
    _, command = prepare(tmp_path)
    with (tmp_path / "simv").open("a") as stream:
        for code, message in (("AXI_ORDER", "R mismatch"), ("AXI_DATA", "Unexpected RData ID: 0")):
            stream.write(f"print('UVM_ERROR checker.svh(1) @ 10: checker [{code}] {message}')\n")
        stream.write("print('UVM_FATAL test.svh(1) @ 20: test [PENDING] Scoreboard has pending transactions')\n")
    run(command + ["--corrupt"], cwd=tmp_path, check=True, capture_output=True)
    assert run(command, cwd=tmp_path, capture_output=True).returncode != 0
    with (tmp_path / "simv").open("a") as stream:
        stream.write("print('UVM_FATAL test.svh(2) @ 21: test [TIMEOUT] NI simulation timeout')\n")
    assert run(command + ["--corrupt"], cwd=tmp_path, capture_output=True).returncode != 0


def test_native_vcs_assertion_failure_cannot_pass_with_completion_markers(tmp_path):
    _, command = prepare(tmp_path)
    message = '"axi_intf.sv", 247: tb_top.vip.unnamed$$_35: started at 22500ps failed at 23500ps'
    with (tmp_path / "simv").open("a") as stream:
        stream.write(f"print({message!r})\n")
    result = run(command, cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode != 0
    assert json.loads((tmp_path / "report/example.run.json").read_text())["passed"] is False


def test_corruption_does_not_hide_native_assertion_failure(tmp_path):
    _, command = prepare(tmp_path)
    with (tmp_path / "simv").open("a") as stream:
        for message in (
                "UVM_ERROR checker.svh(1) @ 10: checker [AXI_ORDER] R mismatch",
                "UVM_ERROR checker.svh(2) @ 10: checker [AXI_DATA] Unexpected RData ID: 0",
                '"axi_intf.sv", 247: tb_top.vip.unnamed$$_35: started at 22500ps failed at 23500ps'):
            stream.write(f"print({message!r})\n")
    assert run(command + ["--corrupt"], cwd=tmp_path, capture_output=True).returncode != 0
