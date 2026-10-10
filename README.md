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
