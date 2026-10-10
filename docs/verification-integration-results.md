# NI Verification Report

## Source release validation — 2026-10-10

驗證對象為 NMU RTL、四個 NSU RTL 與 C++ router 的 UVM 整合環境。
Source AXI 與四個 Device AXI monitors 連接 scoreboard 與 AXI coverage。
NoC monitors 觀察五條 link 的 TX/RX 與 credit。

本次整理不修改 production RTL、hardware defaults、coverage bins 或 C++ model。
正式入口見 [simulation usage](../sim/README.md)，功能與 sampling 定義見
[verification plan](verification-testplan.md)。

| Tool | Validated version |
|---|---|
| VCS / URG | M-2017.03-SP1, UVM 1.2 |
| Verdi / FSDB | M-2017.03-SP1 |
| Workstation C++ compiler | GCC 9.3 |
| Workstation runner | Python 3.6 |
| Preparation / local checks | Python 3.10+, Docker image `noc-dev:verilator-5.048` |

## Configuration

| Parameter | Regression | Alternate-profile smoke |
|---|---:|---:|
| `INPUT_ID_WIDTH` / `OUTPUT_ID_WIDTH` / `DEVICE_ID_WIDTH` | 3 / 3 / 3 | 3 / 3 / 3 |
| `R_ROB_EN` | 1 | 0 |
| `NUM_DAT_VC` | 2 | 1 |
| `NOC_DAT_VC_MODE` | 0 | 0 |
| `B_ROB_DEPTH` / `R_ROB_DEPTH` | 128 / 128 | 128 / 128 |
| `MAX_OUTSTANDING_PER_ID` | 32 | 32 |
| `CONTEXT_DEPTH` / `IO_FIFO_DEPTH` | 32 / 32 | 32 / 32 |
| `CREDIT_DEPTH` | 8 | 8 |
| `OUTPUT_REG_TYPE` | 0 | 0 |
| AXI / NoC clock period | 1000 / 1000 ps | 1000 / 1000 ps |

Profiles: `sim/profile.yml` and `sim/profiles/single_vc_no_read_reorder.yml`. The generated
`ni_tb_params.svh` records the effective hardware parameters beside every input pattern.

## Validation results

| Check | Result |
|---|---|
| Code generation and Python checks | 269 PASS |
| Fresh checkout preparation | PASS, no existing build or standalone stage required |
| Input reproducibility | 168 run settings and 1,149 stimulus files match the retained campaign |
| Pattern / binary mismatch | Rejected before simulation on the workstation |
| VCS regression, P01–P22 | Pending |
| Alternate-profile smoke | 4 PASS: control single read/write and data burst read/write |
| Checker positive / negative tests | 13 PASS, deliberate read corruption detected by data and ordering checkers |
| FSDB generation | PASS, `single_id_reorder MODE=data` |
| Native URG report | PASS, 153 selected tests, zero URG warnings |

The retained full input matrix contains 21,996 input-file records and 24,540 matrix rows.
P11 reuses boundary transactions from P05–P08. Counts describe generated inputs,
not monitor handshake counts. The Excel retains the expanded transaction fields
and native per-instance coverage attribution.

Source preparation was validated from a clean checkout. The 153-run execution
used the source manifest recorded in its run records. Subsequent fixes affect only
tool selection, report test names and documentation. RTL and coverage model bytes
are unchanged. The workstation source sync verified 2,749 files.

## Native coverage

This release check uses only the 153 completed runs. Interrupted runs, earlier
invocations and deliberate checker failures are excluded by the URG test selection.
The existing full-matrix Excel and coverage report remain unchanged. This partial
rerun validates the release workflow and does not replace their verification scope.

## Evidence and reproduction

The stage contains `verification-runs.json`, `verification_results/results.json`,
per-run logs and `.run.json` records. Each run records source-manifest, binary and
stimulus SHA256 values, seed, hardware profile and clocks. `coverage-tests.txt`
selects accepted test names, including the database path, for URG.
The commands below reproduce the complete matrix when a full rerun is required.
This release check was intentionally stopped before completing that matrix.

```sh
python3 sim/tools/prepare_ni_verification.py --profile sim/profile.yml --out build/sim/stage
cd build/sim/stage
make verification JOBS=3
make report
```

The native report is `build/coverage/dashboard.html` inside the stage.
Failed/debug runs, checker self-tests and alternate-profile smoke tests are not
included in the baseline coverage report.

## Remaining verification scope

- Four hardware combinations have not all completed the current UVM input matrix.
  Alternate-profile smoke is not a full parameter regression.
- Multi-source traffic, read-data interleaving, collective traffic, router RTL and
  multihop integration are outside this single-source unicast campaign.
- The input sweep uses aligned INCR transfers. FIXED/WRAP, exclusive access,
  unaligned transfers, all sideband combinations and SAM miss behavior are not
  established by this campaign.
- Code coverage and assertion activation still require closure. Structural CDC/RDC,
  synthesis and STA are separate sign-off work.
- The external ordering checker cannot distinguish already-available same-ID B
  responses with identical payloads. Identical remapped request headers from
  different Source IDs can also be ambiguous. Generated tests use distinct addresses.

No new coverage exclusion is introduced for this release.
