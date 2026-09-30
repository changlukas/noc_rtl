import re
from pathlib import Path

import pytest
import yaml
from tools.elaborate.profile import emit

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("depth", [2, 8, 32])
def test_credit_profile_matches_both_languages(tmp_path, depth):
    constants = yaml.safe_load((ROOT / "specgen/source/constants.yaml").read_text())
    constants["noc"]["CREDIT_DEPTH"]["default"] = depth
    emit(ROOT, tmp_path, constants, 3)
    for language, filename in [("sv", "ni_params_pkg.sv"), ("cpp", "ni_params.h")]:
        text = (tmp_path / "repo/specgen/generated" / language / filename).read_text()
        assert int(re.search(r"\bCREDIT_DEPTH\s*=\s*(\d+)", text)[1]) == depth
        # Non-credit FIFOs remain independent when the DAT profile changes.
        for symbol in ["NOC_FIFO_DEPTH", "NOC_ROUTER_OUTPUT_FIFO_DEPTH"]:
            assert int(re.search(r"\b" + symbol + r"\s*=\s*(\d+)", text)[1]) == 8
        assert "NOC_ROUTER_VC_DEPTH" not in text
        assert "NOC_NI_DAT_RX_VC_DEPTH" not in text
