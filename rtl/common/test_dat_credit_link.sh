#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/dat-credit-link"
cc="$root/deps/common_cells-v2.0.0-beta.3"
rr="$root/deps/common_cells-1.37.0"
mkdir -p "$out"
cd "$out"
vcs -full64 -sverilog -assert svaext -override_timescale=1ns/1ps \
    "+incdir+$cc/include" "+incdir+$rr/include" \
    "$root/specgen/generated/sv/ni_params_pkg.sv" \
    "$root/specgen/generated/sv/ni_flit_pkg.sv" \
    "$cc/src/cc_pkg.sv" "$cc/src/cc_fifo.sv" "$cc/src/cc_credit_counter.sv" \
    "$rr/src/cf_math_pkg.sv" "$rr/src/lzc.sv" "$rr/src/rr_arb_tree.sv" \
    "$root/rtl/common/tx_credit_buffer.sv" "$root/rtl/common/tx_vc_arbiter.sv" \
    "$root/rtl/common/rx_credit_buffer.sv" "$root/rtl/common/tb_dat_credit_link.sv" \
    -top tb_dat_credit_link -Mdir "$out/csrc" -o "$out/simv" -l "$out/compile.log"
"$out/simv" -l "$out/sim.log"
grep -q DAT_CREDIT_LINK_PASS "$out/sim.log"
