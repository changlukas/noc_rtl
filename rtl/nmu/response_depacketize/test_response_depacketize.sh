#!/usr/bin/env bash
set -euo pipefail
task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
task_out=${NMU_DAT_TEST_OUTPUT:-$task_root/build/standalone/nmu/dat-ingress}
mkdir -p "$task_out"
if [[ -n "${NMU_DAT_STAGE:-}" ]]; then
    task_stage=$NMU_DAT_STAGE
else
    task_id_width=$(PYTHONPATH="$task_root/dv/scripts" python3 -B -c 'from gen_tb_top import native_param; print(native_param("noc_payload_pkg", "AXI_ID_WIDTH"))')
    make -C "$task_root/dv/tb/standalone/nmu" prepare ID_WIDTH="$task_id_width" NOC_HALF_PERIOD=5 BUFFER_DEPTH=128 R_ROB_EN=1 > "$task_out/prepare.log" 2>&1
    task_stage="$task_root/build/standalone/nmu/i${task_id_width}_n5_b128_r1/stage"
fi
cd "$task_stage"
task_common_cells=$(sed -n 's@/src/cc_pkg.sv$@@p' files.f)
[[ -f "$task_common_cells/src/cc_stream_register.sv" ]]
task_sim=${SIMULATOR:-vcs}
ulimit -c 0
task_sources=(
    repo/define/noc_header_pkg.sv
    repo/define/noc_payload_pkg.sv
    repo/define/noc_unit_params_pkg.sv
    repo/define/noc_sam_pkg.sv
    repo/rtl/common/ni_signals_pkg.sv
    repo/rtl/common/ni_types_pkg.sv
    repo/rtl/common/stream_register.sv
    "$task_common_cells"/src/cc_pkg.sv
    "$task_common_cells"/src/cc_spill_register_flushable.sv
    "$task_common_cells"/src/cc_spill_register.sv
    "$task_common_cells"/src/cc_stream_register.sv
    deps/common_cells-1.37.0/src/cf_math_pkg.sv
    deps/common_cells-1.37.0/src/lzc.sv
    deps/common_cells-1.37.0/src/rr_arb_tree.sv
    repo/rtl/nmu/response_dispatch/response_dispatch.sv
    repo/rtl/nmu/response_dispatch/read_response_arbiter.sv
    repo/rtl/nmu/response_depacketize/response_depacketize.sv
)
task_compile() {
    task_name="reg${task_reg}"
    task_wave=()
    if [[ "$task_sim" == vcs ]]; then
        task_key=$(pwd -P | tr -d '\n' | cksum | cut -d' ' -f1)
        task_cache="/tmp/noc-vcs-$(id -u)-$task_key"
        mkdir -m 700 "$task_cache" 2>/dev/null || [[ -d "$task_cache" && ! -L "$task_cache" && -O "$task_cache" ]]
        task_work="$task_cache/dat_${task_name}_wave${WAVE:-0}"
        [[ ! -L "$task_work" ]]; mkdir -p "$task_work"
        if [[ ${WAVE:-0} == 1 ]]; then
            task_pli=${PLI_DIR:-${VERDI_HOME:-/cadtools/synopsys/verdi/M-2017.03-SP1}/share/PLI/VCS/linux64}
            task_wave=(+define+DUMP_WAVE -P "$task_pli/novas.tab" "$task_pli/pli.a")
            export LD_LIBRARY_PATH="$task_pli${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
        vcs -full64 -sverilog -assert svaext -override_timescale=1ns/1ps -debug_access+all \
            "+incdir+$task_common_cells/include" "${task_sources[@]}" \
            "$task_root/rtl/nmu/response_depacketize/tb_response_depacketize.sv" \
            -top tb_nmu_response_depacketize \
            -pvalue+tb_nmu_response_depacketize.REG_TYPE="$task_reg" \
            ${task_wave[@]+"${task_wave[@]}"} -Mdir="$task_work/csrc" -o "$task_work/simv" \
            -l "$task_out/$task_name.compile.log" > "$task_out/$task_name.console.log" 2>&1
        task_binary="$task_work/simv"
        task_ext=fsdb
    else
        echo "Unsupported simulator: $task_sim" >&2; exit 1
    fi
}
for task_reg in 0 1 2; do
    task_compile
    "$task_binary" +wave_file="$task_out/$task_name.$task_ext" | tee "$task_out/$task_name.log"
    grep -q 'PASS depacketize' "$task_out/$task_name.log"
done
