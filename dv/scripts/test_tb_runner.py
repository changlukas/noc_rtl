"""Runner must retain acceptance checks when stimulus settings are simplified."""
import json
from pathlib import Path
import subprocess
import sys

_run = subprocess.run

def run(command, *args, **kwargs):
    # The workstation uses Python 3.6; preserve subprocess semantics there.
    if kwargs.pop("capture_output", False):
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
    if "text" in kwargs:
        kwargs["universal_newlines"] = kwargs.pop("text")
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

def prepare_perf(tmp_path, rows, wave=True):
    """Exercise the real runner with an accepted-event stream from a test stub."""
    import csv
    import io
    pattern, command = prepare(tmp_path)
    (tmp_path / "SHA256SUMS").write_text("")
    report = tmp_path / "perf_result/runs/example"
    command[command.index("--report") + 1] = str(report)
    # Existing file format is the runner's independent expected-count reference.
    requests = [r for r in rows if r["role"] == "source" and r["endpoint"] == 0 and r["phase"] == 1]
    for channel, filename in (("AW", "write.txt"), ("AR", "read.txt")):
        content = []
        for r in requests:
            if r["channel"] != channel:
                continue
            fields = [str(r["id"]), "0x" + r["addr"], str(r["len"]), str(r["size"]), "1"]
            fields += ["0"] * (7 if channel == "AW" else 6)
            content += fields
            if channel == "AW":
                content += ["0x0 0x0 0"] * (r["len"] + 1)
        (pattern / filename).write_text("\n".join(content) + ("\n" if content else ""))
    fields = "time_ps role endpoint x y port phase channel id addr len size burst strb last resp user".split()
    stream = io.StringIO()
    writer = csv.DictWriter(stream, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
    with (tmp_path / "simv").open("a") as script:
        script.write("print('CLOCK_CONFIG axi_period_ps=10 noc_period_ps=10')\n")
        script.write("trace=next(v.split('=',1)[1] for v in sys.argv if v.startswith('+perf_file='))\n")
        script.write("Path(trace).write_text(" + repr(stream.getvalue()) + ")\n")
        if wave:
            script.write("wave=next(v.split('=',1)[1] for v in sys.argv if v.startswith('+wave_file='))\n")
            script.write("Path(wave).write_bytes(b'waveform test stub')\n")
            script.write("print('*Verdi* : Create FSDB file')\n")
    return command + ["--perf"], report


def perf_event(time, channel, **values):
    row = dict(time_ps=time, role="source", endpoint=0, x=0, y=0, port=0,
               phase=1, channel=channel, id=0, addr="0", len=0, size=3,
               burst=1, strb="0", last=0, resp=0, user="0")
    row.update(values)
    return row


def test_perf_write_data_before_aw_and_mandatory_wave(tmp_path):
    rows = [perf_event(10, "W", strb="ffffffffffffffff", last=1),
            perf_event(20, "AW", size=6), perf_event(50, "B", phase=2)]
    command, report = prepare_perf(tmp_path, rows)
    run(command, cwd=tmp_path, check=True, capture_output=True)
    result = json.loads((report / "example.run.json").read_text())
    summary = result["performance"]
    assert summary["window"]["start_ps"] == 10
    assert summary["directions"]["write"]["useful_bytes"] == 64
    assert summary["directions"]["write"]["mean_latency_cycles"] == 3
    assert result["waveform"]["bytes"] > 0
    assert (report / "inputs/manifest.json").is_file()


def test_perf_interleaved_read_ids_and_bursts(tmp_path):
    rows = [perf_event(10, "AR", len=1),
            perf_event(11, "AR", id=1, size=2, addr="100"),
            perf_event(20, "R"), perf_event(21, "R", id=1, last=1),
            perf_event(30, "R", last=1)]
    command, report = prepare_perf(tmp_path, rows)
    run(command, cwd=tmp_path, check=True, capture_output=True)
    summary = json.loads((report / "example.run.json").read_text())["performance"]
    assert summary["directions"]["read"]["count"] == 2
    assert summary["directions"]["read"]["useful_bytes"] == 20
    assert summary["directions"]["read"]["mean_latency_cycles"] == 1.5


def test_perf_initialization_and_readback_excluded(tmp_path):
    rows = [perf_event(1, "AW", phase=0), perf_event(1, "W", phase=0, strb="ff", last=1),
            perf_event(5, "B", phase=0), perf_event(10, "AR"),
            perf_event(20, "R", last=1), perf_event(21, "AR", phase=2),
            perf_event(30, "R", phase=2, last=1)]
    command, report = prepare_perf(tmp_path, rows)
    run(command, cwd=tmp_path, check=True, capture_output=True)
    summary = json.loads((report / "example.run.json").read_text())["performance"]
    assert summary["window"]["start_ps"] == 10 and summary["window"]["end_ps"] == 20
    assert "write" not in summary["directions"]
    assert summary["directions"]["read"]["count"] == 1


def test_perf_missing_waveform_cannot_pass(tmp_path):
    command, report = prepare_perf(tmp_path, [perf_event(10, "AR"), perf_event(20, "R", last=1)], wave=False)
    assert run(command, cwd=tmp_path, capture_output=True).returncode != 0
    assert json.loads((report / "example.run.json").read_text())["passed"] is False


def test_perf_premature_rlast_cannot_pass(tmp_path):
    command, report = prepare_perf(tmp_path, [perf_event(10, "AR", len=1), perf_event(20, "R", last=1)])
    assert run(command, cwd=tmp_path, capture_output=True).returncode != 0
    result = json.loads((report / "example.run.json").read_text())
    assert result["passed"] is False and "RLAST" in result["performance_error"]


def test_perf_result_reuse_rejected_without_overwrite(tmp_path):
    command, report = prepare_perf(tmp_path, [perf_event(10, "AR"), perf_event(20, "R", last=1)])
    run(command, cwd=tmp_path, check=True, capture_output=True)
    before = (report / "example.run.json").read_bytes()
    assert run(command, cwd=tmp_path, capture_output=True).returncode != 0
    assert (report / "example.run.json").read_bytes() == before


def test_perf_unaligned_read_counts_only_valid_bytes(tmp_path):
    rows = [perf_event(10, "AR", addr="3", size=2, len=1),
            perf_event(20, "R"), perf_event(30, "R", last=1)]
    command, report = prepare_perf(tmp_path, rows)
    run(command, cwd=tmp_path, check=True, capture_output=True)
    summary = json.loads((report / "example.run.json").read_text())["performance"]
    assert summary["directions"]["read"]["useful_bytes"] == 5


def test_perf_overlapping_setup_leaves_device_aggregate_unavailable(tmp_path):
    rows = [perf_event(1, "AW", endpoint=1, phase=0),
            perf_event(1, "W", endpoint=1, phase=0, strb="ff", last=1),
            perf_event(10, "AR"), perf_event(20, "R", last=1),
            perf_event(25, "B", endpoint=1, phase=0)]
    command, report = prepare_perf(tmp_path, rows)
    run(command, cwd=tmp_path, check=True, capture_output=True)
    summary = json.loads((report / "example.run.json").read_text())["performance"]
    assert summary["device_window_bytes"] is None


def test_perf_illegal_4k_burst_cannot_pass(tmp_path):
    rows = [perf_event(10, "AR", addr="fff", size=3, len=1),
            perf_event(20, "R"), perf_event(30, "R", last=1)]
    command, report = prepare_perf(tmp_path, rows)
    assert run(command, cwd=tmp_path, capture_output=True).returncode != 0
    assert "4KiB" in json.loads((report / "example.run.json").read_text())["performance_error"]


def test_perf_corruption_mode_rejected_before_execution(tmp_path):
    command, report = prepare_perf(tmp_path, [perf_event(10, "AR"), perf_event(20, "R", last=1)])
    assert run(command + ["--corrupt"], cwd=tmp_path, capture_output=True).returncode != 0
    assert not report.exists()


def test_perf_missing_transaction_in_trace_cannot_pass(tmp_path):
    command, report = prepare_perf(tmp_path, [perf_event(10, "AR"), perf_event(20, "R", last=1)])
    pattern = tmp_path / "patterns/example/read.txt"
    pattern.write_text(pattern.read_text() * 2)
    assert run(command, cwd=tmp_path, capture_output=True).returncode != 0
    result = json.loads((report / "example.run.json").read_text())
    assert result["passed"] is False and "counts" in result["performance_error"]
