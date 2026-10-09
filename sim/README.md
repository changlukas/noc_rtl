# Simulation environments

Workstation directories under `/home/mingwei/noc_project/`:

| Directory | DUT / environment | Cases |
| --- | --- | --- |
| `nmu-standalone/` | NMU RTL with request/response loopback | Existing 15 patterns |
| `nsu-standalone/` | NMU RTL, direct TB links, four NSU RTL and AXI memories | 15 baseline + 3 stress cases |
| `sim/` | NMU RTL, one C++ router, four NSU RTL and AXI memories | 15 baseline + 3 stress cases |

NSU standalone and router integration share the same stimulus, memories and checkers. Direct TB links use per-VC FIFOs and downstream credit counters to connect the four destinations without a router model. Direct-link cycle counts are not router performance measurements.

```sh
cd /home/mingwei/noc_project/sim
make run CASE=request_rand
make run_wave CASE=single_id_reorder MODE=data
make view CASE=single_id_reorder MODE=data
make list
make clean
```

`view` opens an existing waveform. `clean` removes simulation products only in the selected environment.

Repository source entry points: `sim/standalone/nmu/`, `sim/standalone/nsu/`, and `sim/`. Run `make prepare` or `make sync` from the repository root to prepare or synchronize all three environments. Shared patterns remain under `sim/test_patterns/`.

## UVM structure

The shared integration/direct-link testbench uses an active Source AXI agent and
four active Device AXI agents. The agents own all AXI stimulus and responses.
Monitor analysis ports feed `ni_scoreboard` and per-interface AXI coverage. The scoreboard reuses
independent memory/history and end-to-end ordering algorithms. Each observation
contains the clock's channel handshakes, retaining W-before-AW and per-beat R checks.
The five AXI agents share ACLK. The scoreboard processes same-clock observations
in source-request, device-request, device-response, source-response order.
The file-master parser reads existing patterns without driving a bus.
NoC monitors observe ten unidirectional views of the five bidirectional NI links.
Internal ROB/FIFO/arbitration observations remain supplemental static coverage/SVA.

```text
sim/
|-- tb_top.sv                    Clock/reset, DUT, interfaces, static checks
|-- uvm/
|   |-- ni_test_pkg.sv           Package
|   |-- ni_test.svh              Sequences, reset coordination, end-of-test
|   |-- ni_env.svh               Agents, scoreboard and coverage connections
|   |-- ni_axi_monitor.svh       Upstream monitor extension for channel observations
|   |-- ni_scoreboard.svh        Data and end-to-end ordering checks
|   |-- ni_data_checker.svh      Existing data checker adapter
|   |-- ni_axi_coverage.svh      AXI coverage subscriber
|   |-- ni_noc_if.sv             Passive NoC interface views
|   |-- ni_noc_monitor.svh       NoC monitor and credit coverage
|   |-- ni_pattern_sequence.svh  Existing pattern records to upstream items
|   |-- ni_slave_sequence.svh    Finite response hold through upstream hook
|   `-- axi_vip_connect.svh      Interface signal-name assignments
|-- dv/                         Existing checkers and covergroups, VIP self-test
|-- test_patterns/              Shared input patterns
|-- profiles/                   Hardware configurations
|-- script/                     VCS build/run/coverage
|-- tools/                      Pattern generation and result export
`-- standalone/                 NMU loopback and direct NMU/NSU environment
```

Upstream agents, driver, monitors, memory and response scheduling remain under
`deps/tvip-axi`, `deps/tue` and `deps/tvip-common`, with pinned revisions and licenses.
UVM completion waits for sequence completion, UVM scoreboard drain and scenario checks.
The UVM integration regression passed 60/60 runs with R_ROB_EN=1 and NUM_DAT_VC=2.
Checker self-tests passed 10/10. Deliberate R-data corruption was detected by both
data and ordering checks. Other hardware configurations are not covered by this run.

## Coverage

Use the existing commands with `COVERAGE=1`, for example:

```sh
make run CASE=request_rand COVERAGE=1
```

VCS collects SystemVerilog covergroups and code/assertion coverage in the selected
build's `simv.vdb`. Functional covergroups use per-instance bins and focused crosses.
Existing scoreboards still determine functional PASS/FAIL. The default is coverage off.

Use the VDB path recorded in `build/report_coverage_wave0/request_rand.run.json`
(or the selected wave/mode directory) with the native report generator:

```sh
urg -full64 -dir <path-to-simv.vdb> -report build/coverage -format both
```

Open `build/coverage/dashboard.html` for the native report. Group/instance/bin
coverage is separate from RTL line/branch/condition/toggle/FSM coverage.
Verdi Coverage can also inspect the VDB; nWave's FSDB is the waveform database.

The run JSON stores command, profile and source/stimulus digests only. It does not
calculate coverage. The former event-count parser and HIT/MISS report are retired;
old reports remain historical artifacts. See `docs/verification-testplan.md` for
the model's scope, sampling conditions and remaining coverage gaps.

## Directed stress

The original fifteen defaults remain stall-free except for the existing destination
response delay in reorder tests. These options use the shared integration/direct-link TB:

```sh
make run COVERAGE=1 CASE=single_id_reorder BACKPRESSURE=1 MODE=control
make run COVERAGE=1 CASE=multi_id_out_of_order BACKPRESSURE=1 MODE=data
make run COVERAGE=1 CASE=capacity_reuse TARGET=per_id MODE=control
make run COVERAGE=1 CASE=capacity_reuse TARGET=context MODE=control
make run COVERAGE=1 CASE=capacity_reuse TARGET=rob MODE=data
make run COVERAGE=1 CASE=hol_blocking MODE=data
make run COVERAGE=1 CASE=reset_recovery MODE=control SEED=17
```

`BACKPRESSURE=1` selects 64 transactions, a source response hold, and Device AW/W/AR ready delays through the upstream VIP.
Ordinary directed tests configure zero request delay. Native cover properties record stall/recovery at each NSU slave AXI port.
The same-ID variant first fills 31 of the default 32 response FIFO entries, then
delays the next destination while later responses arrive. Acceptance requires the
same inverted transaction to encounter ROB output backpressure in both directions.
`capacity_reuse` uses 320 single-beat writes followed by reads; TARGET selects
per-ID admission, NSU context storage, or NMU ROB storage. The stimulus must reach
and recover from the selected resource limit or the test fails. It does not change
hardware depths. Larger configurations may require more stimulus.

`hol_blocking` sends 80 single-beat transactions. It withholds north memory
responses until that NSU context is full, then requires a west response to complete
at source AXI while north remains blocked. It finally releases north and drains.
IDs use separate destinations; shared-resource HoL and arbitrary-VC isolation are
not implied.

`reset_recovery` resets the whole test system with pending reads/writes, discards
pre-reset checker records, checks a quiet interval for stale responses, then runs
fresh writes/readback. The C++ router instance is recreated during reset; this is
NI reset acceptance, not a Router RTL reset test. Memory bytes persist across reset.
SEED changes reset timing only; transaction stimulus keeps its manifest seed.

Run variants retain separate report directories and native coverage test names.
The three new stress cases are not added to the NMU-only response-loopback TB.

## Parameter profiles

`sim/profiles/` holds the three approved parameter variants; `sim/profile.yml`
retains the baseline. Pass a profile to `sim/prepare.py --profile <file> --out <stage>`
and synchronize that isolated stage. Prepared `profile.mk` supplies the existing
Make variables; `make run CASE=... COVERAGE=1` stays unchanged.

Profiles select device ID width, context and per-ID capacity, IO FIFO depth,
REG_TYPE, B/R ROB depths and read ROB enable. DAT VC count/mode and credit depth
are emitted together into SV/C++ sources and the matching credit interface package.
The RTL device width is selected at the TB; the Router transports unchanged NoC IDs.
IO_FIFO_DEPTH controls both NI AXI CDC FIFOs and NMU REQ/RSP FIFOs; NSU REQ/RSP
FIFOs retain their defaults. REG_TYPE controls packetize/depacketize outputs; SAM
register settings retain their defaults.
All capacity values in this campaign are powers of two. Production defaults are
unchanged. Parameterized response-prefill patterns are generated in the profile
stage, preserving the baseline patterns.

Use separate report/VDB directories per profile. A read-ROB-disabled same-ID
reorder run requires admission wait and recovery, while ordinary data/order checks
remain enabled. See `docs/verification-parameter-plan.md` for scope and case selection.

The Split VC profile currently fails Router integration because Router VC reassignment
does not preserve the NI read/write VC pools. The identical NI profile passes the
existing direct-link environment. See `docs/verification-parameter-results.md`;
this is an open integration issue, not a waived check.

### Stimulus and acceptance

Generated `schedule.txt` contains timing and sequence controls. `manifest.json`
contains acceptance criteria such as minimum outstanding count, response arrival
order, and the capacity to exercise. The runner applies these checks automatically.
Regenerate patterns when updating the TB. Old manifests without acceptance criteria
are rejected.

Memory preload, initialization writes, and readback follow the generated file list
in the manifest. Unlisted files left by previous synchronizations are ignored. Read/write concurrency does not implicitly enable readback. Source response
hold and Device response hold are independent. Device hold uses a fixed number of
AXI clocks and does not wait for DUT buffer state.

Source B/R per-beat delay uses the upstream UVM master configuration. Normal
directed cases use zero delay. The AXI file master is used only to parse existing
pattern files. Generator seed is recorded in the manifest. The run record
separately records the simulation seed used by UVM randomization and reset timing.
