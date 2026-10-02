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

Use the existing commands with `COVERAGE=1` to collect passive NI observations and
VCS code/assertion coverage, for example `make run CASE=single_id_reorder COVERAGE=1`.
The default remains off. Coverage builds reuse the unchanged C++ DPI cache and
write logs/JSON under `build/report_coverage_wave0` (or the selected wave/mode).
The VDB is stored beside the corresponding coverage simv binary.

Functional PASS and scenario HIT/MISS are reported separately. A passing simulation
with no required inversion is a coverage gap, not completed ordering verification.
Observations do not modify stimulus, DUT timing or the existing checkers.
See `docs/verification-testplan.md` in the development repository for scope and limits.
