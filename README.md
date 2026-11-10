# NoC RTL

NMU and NSU RTL with AXI4 interfaces. The existing AXI UVM integration testbench
supports direct NMU-to-NSU links and an RTL router mesh.

## DAT link interface

NMU exposes scalar `TXREQ`, `RXRSP`, `TXDAT` and `RXDAT` streams, each with
`VLD` and `RDY`. A transfer occurs on `VLD && RDY`; valid and flit data remain
stable while stalled. NMU has no VC bank or credit ports. NSU likewise exposes scalar RXREQ, RXDAT,
TXRSP and TXDAT streams.

NMU TXREQ and TXDAT use `stream_register`, configured by `REQ_REG_TYPE` and
`DAT_REG_TYPE`: 0 bypass, 1 single register (default), 2 spill register.
The NI wrapper exposes these as `NMU_REQ_REG_TYPE` and `NMU_DAT_REG_TYPE`.
AXI CDC FIFOs and response ordering storage retain their existing capacities.
NSU merges REQ and DAT writes with Packet RR through each accepted packet tail.
The existing AW/W context remains separate from the AXI AWREADY handshake.
NSU TXRSP and TXDAT use RSP_REG_TYPE and DAT_REG_TYPE (default 1), exposed by NI
as NSU_RSP_REG_TYPE and NSU_DAT_REG_TYPE. Source-aware ID mapping, return context,
FIFO/CDC depths and B/final-RLAST context retirement remain unchanged.
The shared NI/router DAT links use valid/ready with fixed write VC0 (AW/W)
and read VC1 (R). Each router output arbitrates packets independently per class,
then selects one ready class per flit through `flit_rr_arbiter`. Input and
per-class output FIFOs retain their existing depths; there is no credit interface.

NI TX uses `flit_rr_arbiter` to select one ready flit from NMU writes or NSU
reads, then maps the selected source onto write/read class valid/ready. Its shared DAT valid is ready-qualified. NMU and NSU NoC RX cuts use the same `stream_register` as TX:
1 simple register (default), 2 spill register. REQ/RSP also support 0 bypass;
DAT requires type 1 or 2 to break the ready-qualified valid feedback path. The RX cuts are inside each unit,
before dispatch/arbitration: RSP and DAT in NMU, REQ and DAT in NSU. NI directly
wires the fixed DAT classes to these units and has no additional RX FIFO.
REQ connects NMU to NSU; RSP connects NSU to NMU. Data AR travels on REQ,
data R travels on DAT, and data AW/W travels on DAT. Read and write DAT traffic
share the physical bus.

The mesh uses the generated endpoint table for both local and boundary NI
attachments. Boundary endpoints share their host router coordinates; PORT_ID 1
selects the X boundary and PORT_ID 2 the Y boundary. SAM ranges and endpoint
locations come from the existing topology configuration.

SAM performs first-match
address-to-endpoint/network lookup. Ordinary unicast preserves the original
address without subtracting the rule base. Same-ID ordering and AW/W context
remain in the existing NMU ordering and write-context blocks.

The default read RoB stores 128 entries of 512-bit raw RDATA (8 KiB);
metadata is additional storage. Inferred arrays are not SRAM macro signoff.

## Source layout

| Directory | Content |
|---|---|
| `rtl/` | NMU, NSU and shared RTL |
| `deps/` | Vendored dependencies, licenses and pinned revisions |
| `dv/` | Testbench, UVM environment, coverage, configuration and scripts |
| `sim/` | Single integration simulation entry |
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
cd sim
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
| `rtl/` production modules | NMU/NSU design sources |
| `rtl/**/tb_*.sv`, fixtures and `test_*.sh` | Focused RTL checks invoked by the adjacent test script |
| `dv/tb/`, `dv/env/`, `dv/tests/`, `dv/checkers/`, `dv/coverage/` | UVM agents, checkers, coverage and integration TB |
| `dv/scripts/`, `dv/tb/standalone/` | Preparation, execution, report export, cleanup and focused tests |
| `dv/config/` | Stimulus definitions, hardware profiles and topology |
| `dv/filelists/`, `dv/waves/` | Compile order and waveform groups |
| `deps/` | Required library sources, include files, focused VIP test inputs and licenses |
| `docs/` | Verification rules, plan and accepted evidence |

Dependency distributions omit unused upstream CI, examples and self-tests. Pinned
revisions and subset notes are in `deps/revisions.json`.

From the repository root:

```sh
make clean
```

This removes only `build/compile/` and `build/regression/`, including their
inputs, binaries, logs, waves and coverage. Retained historical outputs elsewhere
and canonical sources/settings are untouched. Save required evidence before cleaning.
The workstation uses the same `make clean` command from its `sim/` directory.
