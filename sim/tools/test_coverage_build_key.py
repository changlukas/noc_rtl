"""Coverage configuration participates in the SV build cache only."""
from pathlib import Path


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
