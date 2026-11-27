#!/usr/bin/env bash
set -euo pipefail
task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nmu-request-packetize-XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
task_common_cells=${COMMON_CELLS_DIR:-$task_root/deps/common_cells-v2.0.0-beta.3}
cd "$task_tmp"
task_sources=(
    "$task_common_cells/src/cc_pkg.sv"
    "$task_common_cells/src/cc_spill_register_flushable.sv"
    "$task_common_cells/src/cc_spill_register.sv"
    "$task_common_cells/src/cc_stream_register.sv"
    "$task_root/define/noc_header_pkg.sv"
    "$task_root/define/noc_payload_pkg.sv"
    "$task_root/define/noc_unit_params_pkg.sv"
    "$task_root/define/noc_sam_pkg.sv"
    "$task_root/rtl/common/ni_signals_pkg.sv"
    "$task_root/rtl/common/ni_types_pkg.sv"
    "$task_root/deps/common_cells-1.37.0/src/cf_math_pkg.sv"
    "$task_root/deps/common_cells-1.37.0/src/lzc.sv"
    "$task_root/deps/common_cells-1.37.0/src/rr_arb_tree.sv"
    "$task_root/rtl/common/stream_register.sv"
    "$task_root/rtl/common/packet_rr_arbiter.sv"
    "$task_root/rtl/nmu/request_dispatch/request_dispatch.sv"
    "$task_root/rtl/nmu/request_path/write_context.sv"
    "$task_root/rtl/nmu/request_packetize/request_packetize.sv"
    "$task_root/rtl/nmu/request_packetize/request_inject_tb_dut.sv"
)
task_vcs=(vcs -full64 -sverilog -assert svaext -override_timescale=1ns/1ps
    "+incdir+$task_common_cells/include")
for task_top in tb_nmu_request_packetize tb_nmu_request_packetize_stall; do
    task_tb="$task_root/rtl/nmu/request_packetize/${task_top/tb_nmu_/tb_}.sv"
    mkdir -p "$task_tmp/$task_top"
    "${task_vcs[@]}" -top "$task_top" "${task_sources[@]}" "$task_tb" \
        -Mdir="$task_tmp/$task_top/csrc" -o "$task_tmp/$task_top/simv" \
        -l "$task_tmp/$task_top.compile.log"
    if [[ "${1:-test}" == test ]]; then
        "$task_tmp/$task_top/simv"
    fi
done

if [[ "${1:-test}" == test ]]; then
    task_top=tb_nmu_request_packetize_stress
    task_tb="$task_root/rtl/nmu/request_packetize/${task_top/tb_nmu_/tb_}.sv"
    for task_reg in ${NMU_REG_TYPE:-0 1 2}; do
        task_obj="$task_tmp/stress_${task_reg}"
        mkdir -p "$task_obj"
        "${task_vcs[@]}" -top "$task_top" \
            -pvalue+${task_top}.REG_TYPE="$task_reg" \
            "${task_sources[@]}" "$task_tb" \
            -Mdir="$task_obj/csrc" -o "$task_obj/simv" -l "$task_obj.compile.log"
        "$task_obj/simv"
    done
fi
