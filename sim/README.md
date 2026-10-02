# Simulation environments

Workstation directories under `/home/mingwei/noc_project/`:

| Directory | DUT / environment | Cases |
| --- | --- | --- |
| `nmu-standalone/` | NMU RTL with request/response loopback | Existing 15 patterns |
| `nsu-standalone/` | NMU RTL, direct TB links, four NSU RTL and AXI memories | Existing 15 patterns |
| `sim/` | NMU RTL, one C++ router, four NSU RTL and AXI memories | Existing 15 patterns |

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
