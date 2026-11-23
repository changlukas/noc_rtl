#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
task_manifest="$task_root/deps/revisions.json"
task_revision=63b7c50d43e462b59506f69d341ff1e40202866d
task_common_cells=${COMMON_CELLS_DIR:-"$task_root/deps/common_cells-v2.0.0-beta.3"}

# Vendored dependency provenance is tracked with the source, not a nested .git.
python3 - "$task_manifest" "$task_revision" <<'PY'
import json
import sys
from pathlib import Path
entries = json.loads(Path(sys.argv[1]).read_text())
assert any(entry.get("name") == "common_cells-v2.0.0-beta.3" and
           entry.get("revision") == sys.argv[2] for entry in entries), \
    "common_cells revision does not match deps/revisions.json"
PY

task_action=${1:-test}
if (( $# )); then shift; fi
: "${VCS_BUILD_DIR:?Set VCS_BUILD_DIR to the workstation build directory}"
task_build_dir=$(realpath -m "$VCS_BUILD_DIR")
mkdir -p "$task_build_dir"
python3 -B "$task_root/dv/scripts/prepare.py" --emit-sam "$task_build_dir/topology_pkg.sv" "$@"

task_sources=(
    "$task_root/define/noc_header_pkg.sv"
    "$task_root/define/noc_payload_pkg.sv"
    "$task_root/define/noc_unit_params_pkg.sv"
    "$task_root/define/noc_sam_pkg.sv"
    "$task_build_dir/topology_pkg.sv"
    "$task_root/rtl/common/ni_signals_pkg.sv"
    "$task_root/rtl/common/ni_types_pkg.sv"
    "$task_common_cells/src/cc_pkg.sv"
    "$task_common_cells/src/cc_addr_decode_dync.sv"
    "$task_common_cells/src/cc_addr_decode.sv"
    "$task_root/rtl/common/ni_sam.sv"
    "$task_root/rtl/common/tests/tb_ni_sam.sv"
)

task_vcs=(
    "${VCS:-vcs}" -full64 -sverilog -assert svaext -timescale=1ns/1ps
    +incdir+"$task_common_cells/include" -top tb_ni_sam
    -Mdir="$task_build_dir/csrc" -o "$task_build_dir/simv"
    -l "$task_build_dir/compile.log"
)

case "$task_action" in
    compile|lint)
        cd "$task_build_dir"
        "${task_vcs[@]}" "${task_sources[@]}"
        ;;
    test)
        cd "$task_build_dir"
        "${task_vcs[@]}" "${task_sources[@]}"
        "$task_build_dir/simv" -l "$task_build_dir/simulate.log"
        ;;
    *)
        echo "usage: VCS_BUILD_DIR=<directory> $0 [compile|test]" >&2
        exit 2
        ;;
esac
