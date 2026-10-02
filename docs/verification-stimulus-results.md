# NI stimulus expansion acceptance

Historical snapshot: the custom event-count/HIT-MISS flow used here has been replaced by native SystemVerilog covergroups. These results are retained unchanged; current coverage definitions are in verification-testplan.md.

Date: 2026-10-02. This extends the initial coverage baseline; it does not replace its historical measurements.

## Changes

- Public suite remains 15 cases. Single cases remain one transaction in one direction.
- Control burst: 15 transactions, lengths 2/3/4/7/8/15/16/31/32/63/64/127/128/255/256.
- Data burst: 11 transactions, lengths 2/3/4/7/8/15/16/31/32/63/64.
- Burst read/write are separate. Read cases preload memory and scoreboard without AXI writes.
- Full-width INCR accesses include SAM start, exact 4 KB end and SAM end; no boundary crossing.
- Random co-sim/direct cases use the existing concurrent file master: 64 writes and 64 reads to disjoint regions, then 64 verification reads. Write transactions use disjoint addresses to avoid cross-ID same-address ambiguity.
- Random WSTRB includes full, partial and zero. Preload preserves defined expected values for bytes excluded by WSTRB.
- Production RTL, parameters, C++ model, driver and correctness checkers are unchanged.

## Router integration results

VCS M-2017.03-SP1, MODE=auto, seed=1, existing 1 GHz clocks and profile.
All seven affected cases are Functional PASS and required Scenario HIT.

| Case | Write / read transactions | Cycles |
|---|---:|---:|
| ctrl_write_burst | 15 / 0 | 1051 |
| ctrl_read_burst | 0 / 15 | 1036 |
| data_write_burst | 11 / 0 | 283 |
| data_read_burst | 0 / 11 | 272 |
| ctrl_rand | 64 / 128 | 732 |
| data_rand | 64 / 128 | 659 |
| request_rand | 64 / 128 | 653 |

Read totals for random include the 64 verification reads.
Changed transaction counts/phases prevent direct performance comparison with the old patterns.

| Random case | Cycles with pending read and write | Accepted zero-strobe W beats |
|---|---:|---:|
| ctrl_rand | 391 | 80 |
| data_rand | 327 | 77 |
| request_rand | 310 | 83 |

All required burst lengths were observed. Existing ordering checker drained in all cases.
Full/partial strobe legality is tested in the generator and transported W beats are checked by the existing end-to-end comparator; active-lane full/partial classification is not yet a monitor coverage bin.

## Other environments

The direct-link environment passes data_read_burst (267 cycles) and request_rand
(649 cycles), with both checkers drained. These are representative checks, not a
second full regression.
NMU loopback passes ctrl_read_burst (15 read transactions) and data_write_burst
(11 write transactions), both with zero injected stalls.
All three workstation source snapshots were synchronized and SHA256 verified:
187 NMU, 561 direct-link and 725 router-integration files.

## Validation scope

Codegen and 224 Python checks pass, including random dependency/legality checks for seeds 1/17/29.
Only seed 1 was simulated in this campaign. Eight unaffected public cases have identical stimulus hashes to the preceding 15-case baseline and were not rerun.
C++ DPI file sizes and modification times are unchanged.

Raw logs, coverage JSON, stimulus hashes, source audit and verified downloads are retained under local `build/stimulus-expansion/`. Historical baseline downloads remain under `build/coverage-baseline/`.
The latest report directory contains eight retained baseline cases and seven fresh cases; it is not a newly executed 15-case regression.

Capacity/reuse, HoL isolation, reorder with backpressure, integrated reset recovery, multi-seed VCS regression and representative parameter configurations remain open. No new overall code-coverage percentage or signoff claim is made.
