# NI simulation

The integration entry is `sim/Makefile`. The existing UVM environment connects
sixteen NI instances through the 4x4 RTL router mesh.

## Layout

```text
dv/tb/         Top, interfaces and existing standalone fixtures
dv/env/        UVM environment, monitors, scoreboard and seq_lib/
dv/tests/      Existing test classes
dv/coverage/   NI and router functional coverage
dv/checkers/   Assertions and acceptance checks
dv/config/     Profiles, topology, case catalog and coverage hierarchy
dv/filelists/  Repository-relative compile order
dv/scripts/    Preparation, execution, synchronization and export
dv/waves/      Grouped NI/router RC template
sim/Makefile   Integration commands
build/compile/recipes/      Generated portable compile recipes
build/compile/current/     Active generated SV, files.f, simv, compile.log, VDB
build/regression/single/   Interactive inputs and case results
build/regression/<campaign>/
  verification-runs.json   Generated execution list
  inputs/<tag>/           Existing transaction files and acceptance manifest
  results/<tag>/          Simulation log and run.json
  results.json            Driver results
  coverage-tests.txt      Native test selection after all runs pass
  coverage/               Native URG report
```

Canonical RTL/dependencies are compiled from the checkout. Only the VCS 2017
`cc_fifo.sv` compatibility expression is generated in the compile directory;
the dependency source is unchanged. Build IDs hash sources, included headers,
generated hardware configuration and effective tool flags. A successful compile
record freezes binary, command, configuration and source-manifest hashes.

## Prepare and synchronize

On the development machine, with Python 3.8+ and PyYAML:

```sh
cd sim
make prepare
make sync
```

Preparation creates interactive inputs and a new coverage campaign for the existing
P01-P23, P25 and P26 matrix. It does not simulate. `verification-runs.json` is
generated data; `run_verification.py` remains in `dv/scripts/`.
`build/regression/latest.json` points to the prepared matrix campaign.

Sync sends canonical sources and prepared inputs/recipes. Divergent remote files
are rejected before writes. Workstation `FIFO_TYPE` and `sim/environment.mk`
settings are retained. The offline workstation requires Python 3.6+, VCS, URG and
the configured C++ compiler; PyYAML is only needed for preparation/export locally.

## Run existing cases

```sh
cd /home/mingwei/noc_rtl/sim
make run CASE=ctrl_write_single
make run_wave view CASE=data_write_single
make list
```

`run_wave view` runs the case and opens FSDB with the grouped NI/router RC.
nWave runs in the background, leaving the terminal available. `view` alone opens
the existing waveform. Hardware settings come from `define/` and the selected
`dv/config/profile.yml`; `FIFO_TYPE` is selected in the native parameter package.
The runner checks pattern hardware against the compiled header and requires the
existing scoreboard, ordering and completion checks to drain before PASS.

After reviewing simple cases, run the full matrix with:

```sh
make verification JOBS=3 WAVE=0
make report
```

`make regress` aliases this full prepared matrix. Each campaign executes once;
prepare a new campaign for another run. Report generation uses the campaign's
recorded binary and test selection. Failed runs retain logs/results without
producing an all-pass coverage selection. Unhit bins remain visible. The default
matrix does not generate FSDB for every case.

To export native bin attribution and transaction data, use Python 3.9+ with
PyYAML at the repository root after retaining matching compile/campaign artifacts:

```sh
python3 dv/scripts/verification_matrix.py --campaign build/regression/<campaign> --out build/regression/<campaign>/matrix.json
```

The exporter checks matrix completeness, stimulus/binary provenance and native
test attribution. It emits JSON; there is no automatic Excel generator.
Existing profiles remain under `dv/config/profiles/`. Select one with
`make prepare PROFILE=../dv/config/profiles/<name>.yml` from `sim/` and use the
same PROFILE for compile/run. Unsupported native ID/VC widths remain rejected.

Existing focused NMU and direct-link NSU fixtures remain under
`dv/tb/standalone/`; neither is a prerequisite for integration. The NSU Makefile
delegates to the same integration entry using direct-link configuration.

`make clean` at the root or in `sim/` removes only `build/compile` and
`build/regression`. Historical output trees, logs and waves elsewhere are retained.

### Integrated NI mesh

The integration TB uses a 4x4 RTL Router mesh. Each Local port connects one `ni`
containing NMU and NSU. Each node has a source agent and a device agent. Existing
NI cases use source 0. Routing, hotspot and uniform-random cases activate all
sixteen sources using the same file sequence. Devices provide memory responses. The direct-link
standalone environment keeps its four targets. `dv/config/topology/mesh_4x4.yml` defines
the mesh address map. `multicast_single`, `multicast_burst`, and `multicast_rand`
use the existing generator and file-based sequence with `MODE=control/data/rand`.

NI DAT TX uses the shared flit arbiter to select a ready write or read VC on
each transfer, then drives the shared DAT bus with ready-qualified valid. VC0 carries DATA_AW/W;
VC1 carries DATA_R. NI routes received classes directly to NMU/NSU RX
`stream_register` cuts before dispatch. REQ/RSP use conventional valid/ready.

### Write ordering

The NMU supports same-ID write outstanding on one channel. Switching REQ/DAT waits for all prior B responses of that ID to retire into the response CDC FIFO. Different IDs remain independent. Read outstanding and response reordering are unchanged.

`single_id_reorder` checks B/R response reordering. Capacity checks target per-ID outstanding limits, AW/AR context storage and B/R ROB storage. Same-ID writes may remain outstanding on one channel. Switching REQ/DAT waits for prior B retirement. DAT AW/W use fixed write VC0 at every hop; DAT R uses fixed read VC1.

The standalone `ooo_*_write_same_id` cases exercise B ROB use. Cross-ID write cases require out-of-order completion.

The system build always includes coverage and FSDB support. `WAVE=0` disables
FSDB output at runtime without recompiling. `build/compile/current` selects the
last successful compile; the underlying source fingerprint remains in metadata.

## Performance collector smoke

Use existing prepared inputs and the same compile/runner path:

```sh
make perf CASE=ctrl_read_single
make perf CASE=data_write_single
```

Each invocation creates a new `performance/<scenario>/results/<timestamp>_<case>_s<seed>/`
with the selected case under `runs/`. `SCENARIO` defaults to `unicast`; it may also
be `interference`, `boundary`, or `multicast`. Selecting a directory does not
create the corresponding paper workload: stimulus still comes from the existing
catalog/generator and prepared manifest/schedule/write/read files.

FSDB is mandatory for every performance run, including when the caller sets
`WAVE=0`. The run must pass the existing checkers/drain and produce a nonempty
FSDB and valid accepted-event trace. Existing results cannot be overwritten.
The run directory contains the waveform, RC, copied inputs, log and run JSON;
`tables/` contains paired transactions and the common-window summary. Source,
compile and actual setting snapshots are retained beside them. No scenario YAML
or independent configuration parser is used.

Phase 0 is initialization, phase 1 is the existing request sequence, and phase 2
is verification readback. Per-request phase is assigned at AW/AR; write data may
precede AW and is paired in AXI order. Latencies use source AR-to-RLAST/AW-to-B.
The shared job window begins at the first required source transfer (including W
before AW) and ends at the final required source completion. Read bytes follow
ARSIZE/address; write bytes count accepted WSTRB. Only legal, <=512-bit INCR
bursts within 4KiB are currently accepted for performance analysis.

Device bytes are reported in the same common window only when initialization or
readback from another source does not overlap it. Otherwise retain raw device
events and mark device aggregation unavailable. Device peak and utilization are
unset until the model capacity is established. These are collector smoke results,
not validated paper comparisons, injection sweeps, or publication heatmaps.

The `performance_unicast` group in the existing `dv/config/cases.json` adds
single-source reads without changing functional cases: `perf_ctrl_read_neighbor`
uses NI0 (0,0) to NI1 (1,0), `perf_ctrl_read_h3` targets NI3 (3,0), and
`perf_ctrl_read_h6` targets NI15 (3,3). Each narrow case reads one 64-bit beat.
Hop counts are inter-router edges on the native XY mesh; the measured latency
is source AR acceptance to final R acceptance, not the paper's core-to-SPM boundary.
`perf_cal_data_read_1kib` and `perf_cal_data_read_4kib` read exactly 1024 and
4096 bytes in one 512-bit INCR burst to NI1. These are byte/window calibration
points, pending verification of the paper benchmark's exact byte counts.

Generate this optional group with the existing generator/prepare extra-catalog
path, keeping existing inputs intact. A separately prepared directory can be
selected with `make -C sim perf CASE=perf_ctrl_read_neighbor SINGLE=<directory>`.
Each result remains a collector/calibration point until its paper conditions
and independent FSDB comparison are recorded; these cases do not implement the
traffic/injection sweep or the 8/16/32 KiB logical-message split.
