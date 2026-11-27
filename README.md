# NoC RTL

NMU and NSU RTL with AXI4 interfaces. The existing AXI UVM integration testbench
supports direct NMU-to-NSU links and an RTL router mesh.

## System simulation

From the checkout root on the VCS workstation, run `make test` for the seven system checks previously verified under #23.

| Root target | Inputs and result | Reference |
|---|---|---|
| `make build` | Prepare the selected profile, topology and single-run inputs, then compile and elaborate the system testbench. Produces the active `build/compile/current/simv`. | [FlooNoC build](https://github.com/pulp-platform/FlooNoC/blob/05368bdff914f91a48b47c4ceddfc6ff266c6b3a/Makefile#L185-L192) |
| `make compile` | Use the prepared recipe. Compile when sources or tool flags have changed; reuse the matching binary otherwise. | [FlooNoC compile-vcs](https://github.com/pulp-platform/FlooNoC/blob/05368bdff914f91a48b47c4ceddfc6ff266c6b3a/Makefile#L119-L128) |
| `make sim CASE=ctrl_read_single` | Run one case using the matching compiled binary and prepared inputs. Set `WAVE=1` to save an FSDB or `WAVE=0` to skip waveform output. | [FlooNoC run-vcs-batch](https://github.com/pulp-platform/FlooNoC/blob/05368bdff914f91a48b47c4ceddfc6ff266c6b3a/Makefile#L128-L131) |
| `make test` | Build once, then run single control/data reads and writes, reset recovery, same-ID reordering with backpressure, and reorder-buffer capacity reuse. The runner returns the pass/fail status to Make. | [Smoke test with a build prerequisite](https://github.com/verilator/verilator/blob/v5.028/Makefile.in#L147-L162) · [Project runner](dv/scripts/run.py) |
| `make clean` | Remove the generated compile and regression directories. Published measurements live under `performance/`. | [FlooNoC clean-vcs](https://github.com/pulp-platform/FlooNoC/blob/05368bdff914f91a48b47c4ceddfc6ff266c6b3a/Makefile#L133-L141) · [Project cleanup paths](dv/scripts/clean.py) |

The checked-in workstation defaults in [sim/environment.mk](sim/environment.mk) select VCS, Verdi and the compatible C++ compiler. Other installations can set VCS, VERDI_HOME and VCS_EXTRA in the environment or on the Make command line.

The root targets delegate to [sim/Makefile](sim/Makefile). `make check` runs the existing Python checks. For a coverage campaign use `make -C sim prepare` followed by `make -C sim verification JOBS=3`.

## Repository tree

```text
Makefile                      User commands
define/                       Shared packet, payload, parameter and SAM packages
rtl/{common,nmu,nsu,ni,router}/   Design blocks and adjacent block-level checks
dv/config/                    Topologies, profiles and case catalogs
dv/{tb,env,tests,checkers,coverage}/   System testbench and verification sources
dv/{filelists,scripts,waves}/  Compile order, tools and waveform groups
sim/                          System Makefile, workstation settings and usage
deps/                         Pinned dependency sources and licenses
spec.pdf, spec.pptx           Design specification (PDF and editable slides)
docs/                         Verification plan, rules and results
upload-manifest.json          Historical workstation handoff record
performance/                  Published measurements grouped by workload
build/{compile,regression}/   Generated binaries, stimulus, runs and coverage
```

The system filelist selects production RTL explicitly. Block-level checks beside their design are invoked by their own scripts; shared UVM resources live in `dv/`. Comparable RTL and verification boundaries are documented in [OpenTitan directory guide](https://opentitan.org/book/doc/contributing/directory_structure.html) and [FlooNoC test source group](https://github.com/pulp-platform/FlooNoC/blob/05368bdff914f91a48b47c4ceddfc6ff266c6b3a/Bender.yml#L55-L78).

For a new measurement series, use the following layout inside its workload directory. The report, plots and comparison tables belong to the series; each run keeps the inputs and evidence needed to reproduce its point. Create directories when there is data to store. [Measurement handoff, section 7](https://github.com/changlukas/noc_rtl/issues/26)

```text
performance/<workload>/
  measurement.md
  figures/                    Published PNG/SVG
  tables/                     Cross-run CSV/JSON
  provenance/                 Analysis scripts, versions and references
  results/<campaign>/
    campaign.json             Command, configuration and run identity
    config/                   Resolved inputs and settings
    provenance/               Source and tool records
    runs/<run_id>/            Stimulus, log, waveform and run record
    validation.json           Checker, drain and calibration results
    tables/                   Transaction records and summary
    figures/                  Run-specific plots, when produced
```

Existing paths are used by the plotting scripts and waveform links. Boundary and multicast use `results/<campaign>/`, interference uses `results/cross/<campaign>/`, mesh traffic uses `unicast/mesh-traffic/runs/<campaign>/`, and `unicast/tile-to-tile/` holds a single campaign directly. Git contains the reports, published figures, summary tables and analysis records. The workstation retains the complete campaigns under `/home/mingwei/noc_rtl/performance/` with the same relative paths, including waveforms, transaction logs and validation records. Open run-level links and regenerate plots that read those files from that checkout. Use `make clean` for build cleanup; `git clean -fdx` can delete ignored campaign evidence. [Simulation and measurement commands](sim/README.md)

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

Pinned dependency revisions and subset notes are in [deps/revisions.json](deps/revisions.json).
