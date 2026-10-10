# NoC RTL

NMU and NSU RTL with AXI4 interfaces. The integration testbench connects one NMU,
one C++ router and four NSUs to five AXI UVM agents. The router is a reference model,
not router RTL.

## Source layout

| Directory | Content |
|---|---|
| `rtl/` | NMU, NSU and shared RTL |
| `specgen/` | Signal/packet definitions and SV/C++ generation |
| `ref_model/` | C++ reference models and router DPI support |
| `deps/` | Vendored dependencies, licenses and pinned revisions |
| `sim/` | UVM testbench, pattern generation and simulation commands |
| `docs/` | Verification plan, guidelines and accepted results |
| `build/` | Generated inputs, compiled binaries, logs and coverage. Not source |

## Requirements

Preparation and checks: Linux, Python 3.10 or later, GNU Make and the packages in
`requirements-dev.txt`. No dependency download is needed for the RTL or UVM sources.
VCS simulation: VCS with UVM 1.2, a compatible C++17 compiler and URG. FSDB viewing
also requires Verdi. The validated versions and scope are recorded in
[verification results](docs/verification-integration-results.md).

```sh
python3 -m pip install -r requirements-dev.txt
make check
make prepare
```

Then follow [simulation usage](sim/README.md) for local execution or offline
workstation synchronization. Do not copy a previous build directory to prepare a
new checkout.

## Release scope

This is an RTL/DV source release. It provides reproducible functional simulation,
not silicon sign-off. Physical CDC/RDC, synthesis, STA and complete code/assertion
coverage closure are not claimed. See the [verification plan](docs/verification-testplan.md)
and [results](docs/verification-integration-results.md) for remaining scope.

Dependencies retain their own licenses. See `LICENSE` and `deps/revisions.json`.

## File ownership and cleanup

| Files | Required use |
|---|---|
| `rtl/` production modules, `Bender.yml` | NMU/NSU design and compile dependencies |
| `rtl/**/tb_*.sv`, fixtures and `test_*.sh` | Focused RTL checks invoked by the adjacent test script |
| `sim/uvm/`, `sim/dv/`, `sim/tb_top.sv` | UVM agents, checkers, coverage and integration TB |
| `sim/script/`, `sim/tools/`, `sim/standalone/` | Preparation, execution, report export, cleanup and focused tests |
| `sim/test_patterns/`, `sim/profiles/`, `sim/topology.yml` | Stimulus definitions, hardware settings and integration topology |
| `sim/configs/` | SAM/topology fixtures used by model tests and standalone generation |
| `ref_model/` | Router DPI and NI reference-model unit tests |
| `specgen/source/`, `generated/`, `ni_spec/`, `tools/` | Protocol contracts, checked generated interfaces and code generation |
| `specgen/tests/`, `examples/` | Contract tests, golden references and compile checks |
| `deps/` | Required library sources, include files, focused VIP test inputs and licenses |
| `docs/` | Verification rules, plan and accepted evidence |

Dependency distributions omit unused upstream CI, examples and self-tests. Pinned
revisions and subset notes are in `deps/revisions.json`. Project model tests use
GoogleTest, not GoogleMock. They can be configured with
`cmake -S ref_model/c_model -B build/cmodel` and run with CTest after building.

From the repository root:

```sh
make clean
```

This removes generated stages, all builds under `build/`, standalone `output/`,
generated pattern directories, logs, waves, coverage and Python caches. Tracked
sources, specgen contracts, `tools.mk` and the local `build/backlog.md` are retained.
Save any required reports outside these output directories before cleaning.

On the offline workstation, run `make clean` inside the deployed simulation
stage. It removes VCS/Verdi products, coverage and run results, while retaining the
supplied source and stimulus files. An explicitly selected output directory outside
the checkout must be cleaned from its own stage.
