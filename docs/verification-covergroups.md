# Native functional coverage acceptance

The event-count/HIT-MISS flow is replaced by SystemVerilog covergroups.
VCS collects native coverpoint/cross bins in VDB; URG generates the report.
Run JSON contains provenance only. Existing data/order/protocol checkers are unchanged.

## Integration validation

VCS M-2017.03-SP1, existing profile, MODE=auto, seed=1. Six cases pass:

| Case | Cycles |
|---|---:|
| data_read_single | 28 |
| ctrl_write_burst | 1051 |
| data_read_burst | 272 |
| request_rand | 653 |
| multi_id_out_of_order | 99 |
| single_id_reorder | 102 |

Cycles match the corresponding pre-migration runs. C++ DPI cache size/mtime is unchanged.
All 436 generated pattern files are byte-identical. DUT, parameters, reference model,
dependencies, shared case catalog and correctness checkers are unchanged.
Codegen and 221 Python checks pass; obsolete event-parser tests were removed with that parser.

## Direct-link validation

The shared model also compiles and passes request_rand in nsu-standalone with
COVERAGE=1, 649 cycles (unchanged). Its VDB/report is kept separately under that
environment's build/covergroup-migration directory. This is one smoke test, not
a full direct-link coverage regression.

## Native report observations

URG reports 58 covergroup types with per-instance coverage, including both B/R ROB
instances and bound FIFO/context/credit instances.

- Zero-strobe bin:83 hits.
- Direction x same-ID inversion:write3/read44 observed hits.
- Direction x cross-ID inversion:write14/read91 observed hits.
- Outstanding cross:8/9 bins hit; one pending write with multiple pending reads is unhit.
- Reset pending bin:0 hits, correctly uncovered.
- Credit return/send crosses and FIFO/context instance bins appear in the native report.

These are six-case migration checks, not a full regression or functional signoff.
The reported GROUP score57.26 and instance score56.86 are tool-weighted scores for
this coverage model, not percentages of the NI specification. Raw WSTRB population
still differs from full/partial active-lane coverage; unmodeled requirements remain
listed in verification-testplan.md. No new stimulus is added to raise scores.

Native integration report:
`/home/mingwei/noc_project/sim/build/covergroup-migration/urg/dashboard.html`

VDB:
`/home/mingwei/noc_project/sim/build/vcs_wave0_c849a054211c/simv.vdb`

Reproduction inputs, downloaded native reports and source audit:
local `build/covergroup-migration/`. Existing historical reports are preserved.
No Verdi GUI session or waveform campaign is claimed.
