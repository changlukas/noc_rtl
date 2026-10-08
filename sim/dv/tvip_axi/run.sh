#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
export TVIP_AXI_HOME="$root/deps/tvip-axi"
export TUE_HOME="$root/deps/tue"
export TVIP_COMMON_HOME="$root/deps/tvip-common"
work="$root/build/tvip-sideband"
mkdir -p "$work"
cd "$work"
vcs -full64 -lca -sverilog -timescale=1ns/1ps -ntb_opts uvm-1.2 \
  +define+UVM_NO_DEPRECATED+UVM_OBJECT_MUST_HAVE_CONSTRUCTO \
  -f "$TUE_HOME/compile.f" -f "$TVIP_COMMON_HOME/compile.f" \
  -f "$TVIP_AXI_HOME/compile.f" -f "$TVIP_AXI_HOME/sample/env/compile.f" \
  "$TVIP_AXI_HOME/sample/env/tvip_axi_sample_delay.sv" \
  "$TVIP_AXI_HOME/sample/env/top.sv" "$root/sim/dv/tvip_axi/sideband_test.sv" \
  -top top -top sideband_checks -l compile.log
timeout 600 ./simv +UVM_TESTNAME=sideband_test +ntb_random_seed=1 -l sideband.log
timeout 600 ./simv +UVM_TESTNAME=sideband_test +ntb_random_seed=1 +CORRUPT_AWUSER -l negative.log
for test in default request_delay response_delay ready_delay out_of_order_response read_interleave wvalid_preceding_awvalid; do
  timeout 600 ./simv -f "$TVIP_AXI_HOME/sample/work/$test/test.f" +ntb_random_seed=1 -l "$test.log"
done

for test in sideband default request_delay response_delay ready_delay out_of_order_response read_interleave wvalid_preceding_awvalid; do
  for severity in WARNING ERROR FATAL; do
    grep -Eq "^UVM_${severity}[[:space:]]*:[[:space:]]*0$" "$test.log"
  done
done
grep -Eq '^UVM_ERROR[[:space:]]*:[[:space:]]*2$' negative.log
grep -Eq '^UVM_FATAL[[:space:]]*:[[:space:]]*0$' negative.log
grep -q '\[SIDEBAND\] *2' negative.log
grep -Eq '^PORT 1 AW_STALL=[1-9][0-9]* AR_STALL=[1-9][0-9]*$' sideband.log
echo 'PASS: sideband transport, corruption detection, and seven upstream samples'
