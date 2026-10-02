"""Coverage must distinguish a passing run from an unexercised scenario."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("coverage_report", Path(__file__).parents[1] / "script/coverage_report.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
PLAN = {"cases": {"order": ["b.cross_id_inversion"]}}


def test_pass_without_inversion_is_miss():
    log = """NI_COVERAGE_BEGIN
NI_COVER scope=master event=observer_pending count=0
NI_COVERAGE_END
NMU_COSIM_COUNTS writes=0 reads=0 r_beats=0
"""
    result = module.summarize(log, "order", True, PLAN)
    assert result["functional"] == "PASS"
    assert result["scenario"] == "MISS"


def test_missing_or_inconsistent_observation_is_invalid():
    for log in ["", """NI_COVERAGE_BEGIN
NI_COVER scope=master event=observer_pending count=0
NI_COVERAGE_END
NMU_COSIM_COUNTS writes=1 reads=0 r_beats=0
"""]:
        assert module.summarize(log, "order", True, PLAN)["scenario"] == "INVALID"


def test_functional_failure_does_not_become_pass_when_event_hits():
    log = """NI_COVERAGE_BEGIN
NI_COVER scope=master event=observer_pending count=0
NI_COVER scope=master event=b.cross_id_inversion count=1
NI_COVERAGE_END
NMU_COSIM_COUNTS writes=0 reads=0 r_beats=0
"""
    result = module.summarize(log, "order", False, PLAN)
    assert result["functional"] == "FAIL"
    assert result["scenario"] == "HIT"


def test_coverage_hierarchy_invalidates_only_coverage_build(tmp_path):
    import subprocess
    import sys
    script = Path(__file__).parents[1] / "script/build_key.py"
    for name in ["files.f", "topology_pkg.sv", "coverage.hier"]:
        (tmp_path / name).write_text("")
    def key(flags):
        return subprocess.check_output([sys.executable, str(script), "sv", flags], cwd=tmp_path)
    normal = key("")
    coverage = key("-cm_hier coverage.hier")
    (tmp_path / "coverage.hier").write_text("+tree tb_top.dut 0\n")
    assert key("") == normal
    assert key("-cm_hier coverage.hier") != coverage
