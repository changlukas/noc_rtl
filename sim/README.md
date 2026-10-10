# NI simulation

The default environment is Source AXI -> NMU RTL -> C++ router -> four NSU RTL ->
Device AXI memories. One active master and four active slave UVM agents drive AXI.
Their monitor analysis ports feed the scoreboard and five AXI coverage subscribers.
Ten passive NoC views feed credit coverage. Ordering/reset observations and bound
arbitration assertions retain their existing checks.

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
sim/test_patterns/*/*.json            Input pattern definitions
sim/tools/gen_standalone_patterns.py  Shared pattern generator
                 |
                 v
build/sim/stage/
|-- ni_tb_params.svh                  Compiled hardware parameters
|-- patterns/<case>/
|   |-- ni_tb_params.svh              Same parameters beside the input files
|   |-- write.txt / read.txt          AXI transactions
|   |-- schedule.txt                  Stimulus timing
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
make verification JOBS=3
make report
```

The default preparation produces 168 runs covering P01-P22, including the six
capacity variants. `make regress` runs the default CASE list only and is not this
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
Changing only patterns does not invalidate a C++ build. Changing SV hardware
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

`make clean` in a prepared stage removes simulator/GUI products, not source patterns.
A stage can be removed and regenerated after its required results are retained.
Historical development artifacts are not needed for the commands above.
