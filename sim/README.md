# Simulation environments

Workstation directories under `/home/mingwei/noc_project/`:

| Directory | DUT / environment | Cases |
| --- | --- | --- |
| `nmu-standalone/` | NMU RTL with request/response loopback | Existing 15 patterns |
| `nsu-standalone/` | NSU context buffer and asynchronous full-top AW/W/B checks | `context`, `request` |
| `sim/` | NMU RTL, one C++ router, four NSU RTL and AXI memories | Existing 15 patterns |

NSU standalone contains the existing focused tests; it does not yet provide the full independent read/write pattern platform.

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
