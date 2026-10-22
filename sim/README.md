# NI simulation

The default environment is a 4x4 RTL Router mesh with one NI (NMU + NSU) per node.
Sixteen master and sixteen slave UVM agents connect the mesh endpoints.
Their monitor analysis ports feed the scoreboard and per-interface AXI coverage subscribers.
Thirty-two passive NI-link TX/RX views feed credit coverage. Ordering/reset observations and bound
arbitration assertions retain their existing checks.

`ni_pattern_sequence` reads the text patterns and submits tvip items. `ni_test`
manages reset recovery, sequences, timeout and objections. The scoreboard checks
observed responses and transaction completion. The static top retains interface
connections, clocks, model bindings and structural assertions.

NMU loopback also uses the tvip master agent and the same file sequence. Its NoC
responder and packet checks remain in the loopback fixture. UVM execution uses VCS
with UVM 1.2. Focused RTL tests retain their existing simulator entry points.

## Prepare

Run from the repository root:

```sh
make prepare
```

This reads `sim/profile.yml` and writes `build/sim/stage/`. It does not depend on a
standalone build. `sim/rtl.f` supplies the compile order. Both SV and C++ parameters
come from the selected profile.

```text
sim/profile.yml                       Hardware settings
sim/test_patterns/cases.json          Shared input pattern definitions
sim/tools/gen_standalone_patterns.py  Shared pattern generator
                 |
                 v
build/sim/stage/
|-- ni_tb_params.svh                  Compiled hardware parameters
|-- patterns/<case>/
|   |-- ni_tb_params.svh              Same parameters beside the input files
|   |-- write.txt / read.txt          AXI transactions
|   |-- source<N>/                    Additional source transaction files
|   |-- schedule.txt                  Stimulus timing and active sources
|   `-- manifest.json                 File list and acceptance checks
|-- verification/<run>/patterns/      Expanded regression inputs
|-- verification-runs.json            Generated execution list
`-- build/                           Binaries, logs, waves and coverage
```

A pattern may also contain memory preload, initialization writes, readback or
response files. Their use follows its manifest. Generated files are not edited by
hand. Change the source pattern definition or hardware profile and prepare again.
`ni_tb_params.svh` is included by the UVM package and supplies TB hardware defaults.
The runner rejects patterns whose header differs from the compiled binary's copy.
Hardware parameter overrides that disagree with the include are rejected by the TB.

## Run

On the simulator machine, set the tool environment first. `vcs`, `urg` and `g++`
must be on PATH. Set `CXX`, `VCS_HOME`, `VERDI_HOME` or `PLI_DIR` when installation
paths require them. These machine-local settings may be saved in the stage's
`tools.mk` and are preserved by source synchronization.

```sh
cd build/sim/stage
make run CASE=ctrl_write_single
make run_wave CASE=single_id_reorder MODE=data
make view CASE=single_id_reorder MODE=data
make list
```

`view` opens an existing FSDB. CASE names and options are in [pattern_list.txt](pattern_list.txt).
Normal directed traffic has zero inserted delay, except the destination delays
needed by ordering tests. Reset, capacity and delayed-response tests retain their
explicit acceptance checks. Data and ordering checkers must drain before PASS.

## Full input matrix

From the repository root:

```sh
python3 sim/tools/prepare_ni_verification.py --profile sim/profile.yml --out build/sim/stage
cd build/sim/stage
make verification
make report
```

The default 4x4 preparation produces 82 runs for P01-P23, P25 and P26, including
capacity variants, all source/destination pairs and multi-source traffic. P24
(hol_blocking) is retired. `make regress` runs the default CASE list only and is not this
expanded matrix. `verification_results/results.json` records results and
`coverage-tests.txt` selects only successful runs from this invocation for URG.
Open `build/coverage/dashboard.html`. Code/assertion and functional coverage remain
separate report metrics. A high group score does not establish every instance bin
was hit. Existing unhit bins are retained.

For the existing Excel matrix, export its data from the same stage and native report:

```sh
python3 sim/tools/verification_matrix.py --stage build/sim/stage --out build/sim/matrix.json
```

Run this command from the repository root after retaining the stage results locally.
It verifies the run list, stimulus hashes and native test attribution. The JSON is
an intermediate for the existing workbook, not a second verification report.

## Hardware profiles

```sh
python3 sim/tools/prepare_ni_verification.py --profile sim/profiles/robless.yml --out build/robless
```

| Profile | Verification purpose |
|---|---|
| `profile.yml` | Default integration configuration |
| `profiles/single_vc_no_read_reorder.yml` | Single VC without read reorder storage |
| `profiles/robless.yml` | No read reorder storage, registered outputs and shallow context |
| `profiles/small_rob.yml` | Reorder storage capacity and recovery |
| `profiles/split.yml` | Separate read/write VC pools and skid-buffer outputs |
| `profiles/id1.yml` | One-bit Source, NoC and Device IDs |
| `profiles/id8_to_id3.yml` | Eight-bit Source/NoC IDs mapped to three-bit Device IDs |

Each profile uses a separate stage. Existing profile files are regression settings,
not recommendations for area or performance. Depth defaults are not changed by the
preparation flow. Each generated pattern carries its own `ni_tb_params.svh`.
The integrated mesh does not compile the C++ Router model. Changing SV hardware
parameters invalidates the SV build. NoC transport changes regenerate both languages.

## Offline workstation

Prepare locally, then use the existing SHA256-verified SSH synchronization.
`make sync` transfers the prepared stage without regenerating or replacing its
selected input matrix:

```sh
python3 sim/tools/sync_nmu_workstation.py --source build/sim/stage \
  --host <user>@<host> --remote-dir <work-directory>/sim --key <private-key>
```

`--ssh` selects a different SSH executable. The workstation does not need Git or
internet access. Sync updates manifest-owned sources, preserves modified retired
files and retains existing build/report directories. Run the same Make commands
inside the remote stage. No separate simulation archive is needed.

## Other environments

| Source entry | Environment |
|---|---|
| `sim/standalone/nmu/` | NMU RTL request/response loopback |
| `sim/standalone/nsu/` | Same UVM TB with direct NMU/four-NSU links |

Prepare these explicitly with `make -C <entry> prepare`. They are not prerequisites
for integration. Direct-link cycle counts are not router performance results.

## Clean

Root `make clean` removes all default generated outputs and Python caches.
`make clean` in a prepared stage removes simulator/GUI products and regression
results, not source patterns.
A stage can be removed and regenerated after its required results are retained.
Historical development artifacts are not needed for the commands above.

### Integrated NI mesh

The integration TB uses a 4x4 RTL Router mesh. Each Local port connects one `ni`
containing NMU and NSU. Each node has a source agent and a device agent. Existing
NI cases use source 0. Routing, hotspot and uniform-random cases activate all
sixteen sources using the same file sequence. Devices provide memory responses. The direct-link
standalone environment keeps its four targets. `sim/configs/mesh_4x4.yml` defines
the mesh address map. `multicast_single`, `multicast_burst`, and `multicast_rand`
use the existing generator and file-based sequence with `MODE=control/data/rand`.

NI DAT TX retains independent NMU/NSU VC FIFOs, then performs per-VC packet
arbitration and physical-link arbitration with one downstream credit counter per
VC. DAT RX uses one FIFO per VC and dispatches each head to NMU or NSU. An RX FIFO
pop returns credit. No new serial FIFO stage is inserted by the NI wrapper.

### Write ordering

The NMU supports same-ID write outstanding on one channel. Switching REQ/DAT waits for all prior B responses of that ID to retire into the response CDC FIFO. Different IDs remain independent. Read outstanding and response reordering are unchanged.

`single_id_reorder` checks B/R response reordering. Capacity checks target per-ID outstanding limits, AW/AR context storage and B/R ROB storage. Same-ID writes may remain outstanding on one channel. Switching REQ/DAT waits for prior B retirement. DAT AW/W use a stable VC per source/ID/destination at every hop, independently of `ordering_req`. `NUM_DAT_VC=1` shares VC 0. Larger even counts split the lower half for writes and upper half for reads. `dat_vc_mode` is no longer a profile setting.

The standalone `ooo_*_write_same_id` cases exercise B ROB use. Cross-ID write cases require out-of-order completion.
