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

Keep performance figures to plot labels, units, data annotations and legends.
Record workloads, measurement boundaries and limitations outside the figure,
in the accompanying result metadata or caption. Report physical times in ns.
Keep cycle counts where the reference figure uses cycles and preserve raw trace units.

Use existing prepared inputs and the same compile/runner path:

```sh
make perf CASE=ctrl_read_single
make perf CASE=data_write_single
```

Unicast results live in `performance/unicast/tile-to-tile/` and
`performance/unicast/mesh-traffic/`. The tile-to-tile figure and tables are
in the first directory. The combined neighbor curve is in the second, with
its inputs and FSDBs grouped by transfer size under `runs/1kib/` through
`runs/32kib/`. Other unicast collector cases use short case names under
`mesh-traffic/runs/`. Set `RESULT` to a new directory to repeat a measurement.
The seed and build hashes are recorded in the run JSON. Archived commands
and JSON paths record the original run location. For moved runs, use the
FSDB at its new location or the adjacent `view.rc` for nWave.

`SCENARIO` defaults to `unicast`; it may also
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
points. The paper-source config/plot now confirm those exact byte counts;
full traffic and monitor-window matching remain pending.

Generate this optional group with the existing generator/prepare extra-catalog
path, keeping existing inputs intact. A separately prepared directory can be
selected with `make -C sim perf CASE=perf_ctrl_read_neighbor SINGLE=<directory>`.
Each result remains a collector/calibration point until its paper conditions
and independent FSDB comparison are recorded; these initial five cases do not implement the
traffic/injection sweep or the 8/16/32 KiB logical-message split.

For larger logical transfers, `sequence: "contiguous"` in the same cases catalog
uses explicit `burst_lengths` at successive byte addresses. It accepts plain
cosim data reads/writes only, rejects conflicting pattern options, and checks
every burst against its SAM window and 4 KiB boundary. Existing burst cases
retain their start/boundary/SAM-end address coverage. The 8/32 KiB calibration
cases use 2/8 consecutive 64-beat bursts, one source and one target. Treat the
whole case's first-request-to-last-completion window as the logical transfer
runtime; `mean_latency_cycles` remains a mean over individual AXI bursts.
These additional cases remain isolated calibration inputs. The arXiv v2
config/plot confirm byte units, while monitor-window matching remains pending;
they do not establish a formal Fig.8 traffic sweep.

`source_destination_map` is an optional list in the existing cases catalog,
indexed by native source endpoint. With explicit `sources`, the generator
selects each source's target using the existing destination-order mechanism.
It accepts plain control/data reads or writes with static targets, rejecting
out-of-range targets, random/mixed traffic, a simultaneous destination_order,
and other pattern modifiers.
`perf_neighbor_read_1kib` enables all 16 native sources, each reading one
1024-byte job from its positive-x neighbor with wrap, as recorded in the
archived public generator mapping. Its byte sizes and per-source job count
match the paper-source Fig.8 wide configuration. Complete publication matching
still requires the monitor window/averaging definition; the isolated calibration
results do not become formal mesh results merely because the units are verified.

The collector records ENABLE at the first post-reset sampled AXI edge and
SOURCE_DONE when that source's existing request sequence returns. No waits or
handshakes are added. `control.perf_source_done` exposes the completion in FSDB.
Per-source monitor cycles count enabled rising-edge samples through completion,
inclusive; this differs from the elapsed first-transfer-to-last-completion job
interval. Both definitions remain explicit in `summary.json`.

Read transactions now retain first accepted R and final R timestamps separately.
`mean_latency_cycles` keeps its existing completion meaning. `source_tiles` and
`source_tile_average` add unweighted per-active-source means. Legacy traces lack
sequence completion markers and therefore report monitor-window metrics as null,
not guessed from RLAST. Setup/readback contamination also leaves them unavailable.
Source-port payload utilization is emitted only for full 512-bit transfers at
64 B/cycle; this is not a memory/device service peak, which remains unset.
No paper cluster +7-cycle adjustment is added. The exact experiment RTL revision
and its scheduling details remain an explicit comparison limitation.

For wide-size comparisons, `make -C sim perf_plot` reads the complete saved
neighbor, bit-complement, transpose, uniform and shuffle curves under `mesh-traffic/runs/`.
It rejects incomplete grids, duplicates, unsupported sizes, incompatible
platform sources/config, uncalibrated points and output collisions. PNG, SVG,
curve CSV and plot provenance are stored under `mesh-traffic/`. Use `RESULTS`
to select other inputs and `RESULT` to select the output directory. Plotting
uses workstation Matplotlib from the isolated build/perf_plot_deps environment;
its pinned wheel/version/hash manifest is retained with the curve artifacts.
The curve remains preliminary: native platform/VIP timing and the unidentified
paper experiment RTL revision are stated explicitly.

For the isolated tile-to-tile delivery, use `make -C sim perf_tile_plot`.
Use `RESULT` to select an alternate result. The figure follows the six-lane
presentation of FlooNoC Fig.7 using the actual native source/device AXI boundaries.
The one 64-bit NI0-to-NI1 read is sampled directly from its own FSDB: AXI,
NI/router local interfaces, and physical East/West router ports. The converter
command and FSDB/VCD hashes are retained; no router observer or DUT change is used.
Outputs are tile-to-tile.png/.svg plus accepted-boundary and stage CSV/JSON tables.
The figure begins at source ARVALID assertion and includes the cycles until
NI0 accepts AR. The return path separates NI0 response conversion from
RVALID assertion through R acceptance. The table also records accepted AR to
accepted R separately.
The native testbench uses VIP AXI endpoints. FlooNoC Fig. 7 includes the
cluster LSU and SPM interconnect. The initial end-to-end review is complete;
continue with the mesh traffic measurements below.


The mesh curves cover neighbor, bit-complement, transpose, uniform and shuffle. Each
wide curve requires 1/2/4/8/16/32 KiB, one logical read job per source, split
into legal AXI bursts. Each latency curve requires the isolated zero-load point
plus configured ratios 0.001/0.01/0.05/0.1/0.15/0.2/0.25/0.3/0.4/0.5,
with 32 single-beat 8-byte reads per source. These positive parameters come from
the commented narrow configuration in the saved paper source, not an active
experiment record. The complete default grid is 30 BW points and 55 latency points.

Cases use the existing source_destination_map and all 16 native sources.
Neighbor wraps positive x; bit-complement uses (x,y)->(3-x,3-y); transpose uses
(x,y)->(y,x), including local endpoints 0/5/10/15 in both traffic and averages.
Uniform follows candidate seed 42 with x-outer/y-inner traversal and one fixed
nonself destination per source, reused for every job. It is not per-packet
resampling; mapping seed 42 and simulation seed 1 are recorded separately.
Shuffle rotates the upstream index s=x*4+y, then converts the target to native
coordinates (d%4,d//4), retaining local endpoints 0/15.
Mappings are checked against the saved FlooNoC candidate gen_jobs.py.

The existing injection_ratio field reaches the VIP address start_delay through
schedule.txt and the existing sequence. Its integer [0,100] draw quantizes small
parameters: 0.001 and 0.01 both accept only draw zero. Preserve both configured
points and their actual AR interarrival rates. Do not label either zero-load.

Cases ending _zero instead use zero_load=true and no positive injection parameter.
The existing sequence shares one semaphore across all sources and retains it
until the read response completes. Thus x=0 denotes the no-contention latency
limit, not a literal zero sending rate. Every source still supplies 32 samples;
raw transactions must prove no network-wide overlap. Preserve actual nonzero
interarrival rates in the CSV. This optional scheduling does not alter the DUT.

make -C sim perf_plot and perf_latency_plot read the corresponding full grids.
RESULTS can select other saved complete curves; RESULT selects a new output
directory. Incomplete grids, duplicate points and output collisions are rejected.
Zero-load points additionally require the runtime flag and independent isolation
validation. Both figures use filled markers: neighbor circles, bit-complement
squares, transpose upward triangles, uniform diamonds and shuffle downward triangles. Output is bandwidth.png/.svg and latency.png/.svg,
with curve/source CSV and renderer provenance. Previous data and figures are kept.

Cross-build reuse checks pinned reviewed optional-injection/zero-load TB revisions,
all other compiled sources, collector, recipe, flags, coverage, clocks and seed.
Keep native platform costs; the paper's cluster +7-cycle adjustment is not added.


## Narrow/wide interference

The existing `performance_interference` catalog uses per-source
`source_overrides` for mode, count and contiguous burst length. It covers
2023 FlooNoC Fig.5: 100 single-beat narrow probe reads against 0/2/4/8/16/32
wide bursts, and 16 wide probe bursts against 0/2/4/8/16/32/64 narrow reads,
separately for one and two directions. Wide bursts contain 16 64-byte beats.

Use `make -C sim perf CASE=perf_narrow_uni_2 SINGLE=<prepared directory> SCENARIO=interference`.
Each point saves its own FSDB under `performance/interference/results/`.
After waveform and input calibration, `make -C sim perf_interference_plot`
requires the complete 26-point grid and generates the two figures and CSV tables.
The result README records native route, target and monitor-window differences.
