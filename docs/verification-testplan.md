# NI Functional Coverage Specification

Scope: NMU/NSU RTL and the integration coverage model in `changlukas/noc_rtl`, inspected at revision `53d0b58` on 2026-10-10.

This document defines NI verification goals, functional coverage organization, input patterns, and coverage review criteria. Coverage names and sampling below match the current code. Transaction, write-strobe, boundary, and response covergroups remain separate. Simulation results remain in the verification report and run records.

Source AXI is the NMU-facing interface. Device AXI is the NSU-facing interface. `Ax` denotes AW or AR.

## 1. Feature Description and Verification Goals

### 1.1 Address Decoding / Translation

| Sub-feature | Description | Verification goal |
|---|---|---|
| Destination selection | NMU decodes `AWADDR` / `ARADDR` through the SAM to select destination, destination port, and control/data path | NoC destination matches the SAM entry and the transaction reaches the selected NSU |
| Device address | Unicast transactions preserve the original `AWADDR` / `ARADDR` | Device `AWADDR` / `ARADDR` equals the corresponding Source address |

Collective write address replacement is outside this unicast scope. General base-offset translation is not implied.

### 1.2 Packetization / Depacketization

| Sub-feature | Description | Verification goal |
|---|---|---|
| Request conversion | NMU encodes AXI AW/W/AR into NoC REQ/DAT flits. NSU decodes them back into AXI AW/W/AR | Preserve `AxLEN`, `AxSIZE`, `AxBURST`, `WSTRB`, active `WDATA` bytes, `WLAST`, and AW/W association |
| Response conversion | NSU encodes AXI B/R into RSP/DAT flits. NMU decodes them back into AXI B/R | Preserve `BRESP`, `RRESP`, active `RDATA` bytes, and `RLAST` |

| Transaction | Request channel | Response channel |
|---|---|---|
| Control write | AW/W → REQ | B → RSP |
| Control read | AR → REQ | R → RSP |
| Data write | AW/W → DAT | B → RSP |
| Data read | AR → REQ | R → DAT |

### 1.3 ID Mapping

| Description | Verification goal |
|---|---|
| NSU remaps the Source ID to Device `AWID` / `ARID` while retaining the Source ID for response restoration | Source `BID` matches the corresponding Source `AWID`, and Source `RID` matches the corresponding Source `ARID`, including multiple Source IDs mapped to the same Device ID |

### 1.4 Outstanding Transactions

| Description | Verification goal |
|---|---|
| NI supports multiple outstanding read/write transactions across the same or different AXI IDs, subject to available tracking resources | Multiple transactions remain pending concurrently. Each accepted AW completes with one B response. Each accepted AR completes with `ARLEN+1` R beats ending in `RLAST`. Required per-ID ordering is preserved. Completion requirements apply without an intervening reset |

### 1.5 Response Reordering

| Sub-feature | Description | Verification goal |
|---|---|---|
| Write response reordering | NMU restores out-of-order same-ID B responses to Source AW acceptance order | Same-ID B responses retire in AW acceptance order |
| Read response reordering | With `R_ROB_EN=1`, NMU restores out-of-order same-ID R transactions to Source AR acceptance order | Same-ID R transactions retire in AR acceptance order and preserve beat order |

Different IDs may complete out of order. Read and write ordering are independent. With `R_ROB_EN=0`, request admission maintains read ordering.

## 2. Coverage Traceability

Coverage records occurrence. Checkers determine correctness. AXI and NoC subscribers receive interface-monitor samples. Response-arrival and reset coverage observe NMU ordering state. Arbitration assertions remain bound to RTL.

| Feature / Requirement | Coverage / Evidence |
|---|---|
| Address decoding / translation | `transaction_cg`, `boundary_cg` |
| Packetization / depacketization | `transaction_cg`, `write_strobe_cg`, `response_cg` |
| ID mapping | `transaction_cg.cp_id`, configuration records |
| Response reordering | `ordering_cg`, scoreboard ordering checks |
| Outstanding transactions | `outstanding_cg`, per-ID limit/recovery acceptance checks |
| Capacity limits and recovery | Pattern acceptance checks. No resource covergroups |
| DAT credit protocol | `credit_cg` |
| Reset recovery | `reset_cg` |
| Arbitration | `served`, `contended_grant`, `continuous_transfer`, `no_bubble`, `bounded_wait` |
| CDC | Clock configurations and end-to-end checks. Structural CDC/RDC sign-off is not claimed |

Ready/valid, credit accounting, capacity, arbitration, CDC, and reset are interface/architecture requirements rather than transaction-conversion features.

## 3. Functional Coverage Organization

Current coverage sources:

- `sim/dv/ni_coverage.svh`
- `sim/uvm/ni_axi_coverage.svh`
- `sim/uvm/ni_noc_monitor.svh`
- `sim/dv/ni_arbiter_checks.sv`

Coverage is enabled by `NI_COVERAGE`. Unless noted otherwise, sampling occurs on the observation clock rising edge with reset inactive. Covergroups use per-instance reporting.

### 3.1 Transaction: `transaction_cg`

Sampling point: accepted AW/AR reported by each AXI monitor. Five subscriber instances cover Source AXI and four Device AXI interfaces. Traffic class is decoded from `AxADDR`. Source destination is decoded through SAM. Each Device instance covers its own destination.

| Coverpoint | Bins |
|---|---|
| `cp_direction` | `write={0}, read={1}` |
| `cp_traffic` | `control={0}, data={1}` |
| `cp_id` | `id[]={[0:(1<<id_width)-1]}` for the observed interface |
| `cp_beats` | `{1,2,3,4,7,8,15,16,31,32,63,64,127,128,255,256}` |
| `cp_size` | `size[]={[0:$clog2(AXI_DATA_WIDTH/8)]}` |
| `cp_burst` | `incr={1}` |
| `cp_destination` | Source: `0..NI_NUM_NSUS-1`. Device: its endpoint index |

Crosses: `direction_traffic`, `direction_length`, `direction_destination`.

`cp_beats` samples `AxLEN+1` and does not score every length in the stimulus sweep. `cp_burst` reflects the current coverage model, not the complete RTL support contract.

Request, W-beat, and response covergroups sample their respective accepted events. No request-to-response cross is implemented.

#### 3.1.1 Write Strobes: `write_strobe_cg`

Sampling point: accepted W beat after correlation with its AW. W may arrive before AW.

| Coverpoint | Bins / Condition |
|---|---|
| `cp_strobe` | `zero={0}, partial={1}, full={2}`. Full means WSTRB equals the legal byte mask for the beat |
| `cp_lane` | Starting byte lane of each W beat, `0 .. AXI_DATA_WIDTH/8-1` |
| `cp_size` | `size[]={[0:$clog2(AXI_DATA_WIDTH/8)]}` |

Cross: `strobe_size = cp_strobe × cp_size`

Ignore: `partial × size=0`

One-hot `WSTRB` maps to `full` for a one-byte transfer and `partial` for wider transfers.

#### 3.1.2 Address Boundaries: `boundary_cg`

Sampling point: AW/AR handshake on each observed AXI interface. For aligned INCR traffic, end address is `AxADDR + ((AxLEN+1) << AxSIZE)`.

| Coverpoint | Condition |
|---|---|
| `cp_direction` | `write={0}, read={1}` |
| `cp_traffic` | `control={0}, data={1}` |
| `cp_page_end` | `(end_addr % 4096) == 0` |
| `cp_sam_start` | `AxADDR == SAM.start_addr` |
| `cp_sam_end` | `end_addr == SAM.end_addr` |

Crosses: `page_boundary`, `sam_first`, `sam_last`

Illegal boundary crossings are not covered by these points.

#### 3.1.3 Responses: `response_cg`

Sampling point: B handshake or each R beat handshake on each observed AXI interface.

| Coverpoint | Bins |
|---|---|
| `cp_read` | Automatic bins for `0` (B) and `1` (R) |
| `cp_resp` | `okay={0}, slverr={2}, decerr={3}` |

Cross: `response_type = cp_read × cp_resp`. EXOKAY is not scored.

### 3.2 Outstanding: `outstanding_cg`

Sampling point: each AXI monitor sample after AW/AR increments and B/RLAST decrements. Counts are summed across IDs separately for each interface. Reset clears the counts.

| Coverpoint | Bins |
|---|---|
| `cp_write`, `cp_read` | `idle={0}, single={1}, multiple={[2:$]}` |

Cross: `read_write = cp_write × cp_read`.

Per-ID limit and capacity recovery remain test acceptance checks, not bins in `outstanding_cg`.

### 3.3 Response Arrival Order: `ordering_cg`

Sampling point: NMU ordering-ingress B handshake or RLAST handshake on `noc_clk`.

| Coverpoint | Bins |
|---|---|
| `cp_direction` | `write={0}, read={1}` |
| `cp_same_id_inversion` | `absent={0}, observed={1}` for arrival inversion |
| `cp_cross_id_inversion` | `absent={0}, observed={1}` for arrival inversion |

Crosses: `direction_same_id`, `direction_cross_id`.

Arrival inversion means an older request of the corresponding ID relation remains pending when the response is accepted. This does not measure Source AXI retirement order.

### 3.4 Reset: `reset_cg`

Sampling point: NoC rising edge with `noc_rst_n=0`, before pending queues are cleared.

`cp_pending`: `occupied={1}` when reset occurs with pending ordering state.

Post-reset recovery is checked separately: reset must interrupt pending traffic, and fresh B and R responses must complete after reset release.

### 3.5 Credit: `credit_cg`

Sampling point: each NoC monitor sample, separately for every active VC. Ten TX/RX interface views observe five NoC links. The subscriber initializes the credit balance to `CREDIT_DEPTH`, samples the pre-update balance, then adds returned credits and subtracts accepted DAT flits.

| Coverpoint | Bins |
|---|---|
| `cp_available` | `zero={0}, nonzero={1}` |
| `cp_give` | `idle={0}, returned={1}` |
| `cp_take` | `idle={0}, sent={1}` |

Cross: `credit_return_send = cp_available × cp_give × cp_take`.

`zero × returned × sent` covers same-cycle credit return and transmission. Bins distinguish zero/nonzero balance. The subscriber also checks that the reconstructed balance remains within `0..CREDIT_DEPTH`.

### 3.6 Assertion and Cover-Property Coverage

| Object | Type | Condition / Purpose |
|---|---|---|
| `continuous_transfer` | cover property | `(valid && ready)[*4]` |
| `gen_input[i].served` | cover property | `request_i[i] && grant_i[i]` |
| `gen_input[i].gen_contention.contended_grant` | cover property | `$countones(eligible)>1 && request_i[i] && grant_i[i]` |
| `write_wrap`, `read_wrap` | cover property | Accepted push/pop at the last pointer value, followed by pointer zero on the next clock |
| `no_bubble` | assertion | When enabled and downstream ready, an available request receives a valid grant |
| `gen_input[i].bounded_wait` | assertion | `wait_count < NUM_INPUTS` |
| `gen_vc[i].gen_active.eligible` | assertion | A nonempty VC with stored or same-cycle returned credit presents valid |

FIFO pointer-wrap cover properties remain in assertion coverage. Review activation per bound instance.

### 3.7 Arbitration and CDC Verification

| Requirement | Scenario evidence | Correctness check |
|---|---|---|
| Arbitration | per-input service, eligible contention, consecutive transfers | `no_bubble`, `bounded_wait` |
| CDC | recorded AXI/NoC clock periods and phase | end-to-end field, data, count, and ordering checks |

`bounded_wait` counts eligible successful arbitration opportunities, not elapsed cycles or the exact RR sequence. Clock/reset sweeps verify simulated behavior and do not replace structural CDC/RDC analysis.

### 3.8 Coverage Instances

| Coverage object | Instances |
|---|---|
| `transaction_cg`, `write_strobe_cg`, `boundary_cg`, `response_cg`, `outstanding_cg` | One of each per AXI interface, five interfaces |
| `ordering_cg`, `reset_cg` | One of each at NMU ordering |
| `credit_cg` | One per active VC for each of ten NoC TX/RX views |

FIFO, ROB, and Stress covergroups are removed. Capacity/recovery checks and FIFO pointer-wrap cover properties remain. Assertions and cover properties are reported separately from covergroups.

## 4. Ignore / Illegal Bins

| Object | Explicit exclusion | Correctness check |
|---|---|---|
| `write_strobe_cg.strobe_size` | `byte_partial = partial × size=0` | legal byte-lane check |
| `credit_cg.credit_return_send` | `no_credit_send = zero × idle × sent` | credit assertion |

Other listed covergroups have no explicit ignore/illegal bins. INCR-only bins are a coverage-model scope choice, unlisted values are not automatically illegal or unsupported.

## 5. Coverage Review and Reporting

Maintain: requirement → verification goal → checker → coverage object → result.

| Finding | Disposition |
|---|---|
| Required modeled bin not hit | review stimulus and sampling |
| Required scenario absent from model | review existing evidence before adding coverage |
| Unreachable in a configuration | document reason and approve exclusion |
| Illegal behavior | detect with assertion/checker, independent of coverage exclusion |
| Outside scope | document the scope limit |

Group and instance scores use different aggregation. A rounded group score does not establish that every per-instance bin was hit. Report covergroup scores, assertion activation/failures, unresolved requirements, and approved exclusions separately.

## 6. Input Pattern and Coverage Matrix

`—` means no additional parameter constraint beyond the selected ID range, SAM, transfer width, and capacity.

| # | Input pattern | Hardware parameters | Coverage targets |
|---|---|---|---|
| P01 | Single control write, 1 transaction | — | `transaction_cg` |
| P02 | Single control read, 1 transaction with memory preload | — | `transaction_cg` |
| P03 | Single data write, 1 transaction | — | `transaction_cg` |
| P04 | Single data read, 1 transaction with memory preload | — | `transaction_cg` |
| P05 | Control INCR burst write, 2–256 beats | — | `transaction_cg` |
| P06 | Control INCR burst read, 2–256 beats | — | `transaction_cg` |
| P07 | Data INCR burst write, 2–64 beats | — | `transaction_cg` |
| P08 | Data INCR burst read, 2–64 beats | — | `transaction_cg` |
| P09 | Control/data read/write transfer-size sweep with legal aligned byte lanes. Control `AxSIZE=0–3`. Data `AxSIZE=0–6` | — | `transaction_cg` |
| P10 | Zero/full/partial `WSTRB`, including one-hot patterns | — | `write_strobe_cg` |
| P11 | Read/write transactions at SAM start and ending at SAM / 4 KB boundaries | — | `boundary_cg` |
| P12 | Source-ID sweep and read/write destination sweep | — | `transaction_cg` |
| P13 | Control/data single/burst with Device OKAY/SLVERR/DECERR responses | — | `response_cg` |
| P14 | Same-ID, same-destination sustained read/write traffic. Hold responses to reach and release the per-ID limit | `MAX_OUTSTANDING_PER_ID ≥ 2` | `outstanding_cg` |
| P15 | Multi-ID, same-destination sustained read/write traffic. Hold responses for NSU context full/recovery | — | `outstanding_cg` |
| P16 | Different-ID, cross-destination requests with controlled response delay to force arrival inversion | — | `ordering_cg`, `outstanding_cg` |
| P17 | Same-ID, cross-destination requests with controlled response delay to force arrival inversion | Read: `R_ROB_EN=1` | `ordering_cg` |
| P18 | Reorder-storage full/recovery using reorder-required cross-destination requests and controlled response delay | Read: `R_ROB_EN=1` | `ordering_cg`, capacity/recovery acceptance checks |
| P19 | Random control read/write: ID, destination, length, size, `WSTRB` | — | supplemental: `transaction_cg`, `outstanding_cg` |
| P20 | Random data read/write: ID, destination, length, size, `WSTRB` | — | supplemental: `transaction_cg`, `outstanding_cg`, `credit_cg`, arbiter covers |
| P21 | Mixed control/data random read/write | — | supplemental: `transaction_cg`, `outstanding_cg`, `credit_cg`, arbiter covers |
| P22 | Reset under load with pending read/write transactions, followed by fresh requests | — | `reset_cg` |

Pattern numbers identify stimulus items, not public CASE names. Sweep ranges must remain legal for the selected interface and address map.

### 6.1 Pattern Acceptance Conditions

| Patterns | Required observation |
|---|---|
| P14/P15 | read/write pending states 0, 1, and ≥2, including all nine `outstanding_cg.read_write` combinations across runs |
| P14 | per-ID limit reached with another request waiting at admission. Acceptance resumes after capacity release |
| P15 capacity variant | target AW/AR context reaches full. Insertion resumes after release |
| P16/P17 | actual response arrival inversion at ordering ingress. Source response order passes the checker |
| P18 | B/R storage full followed by successful reorder allocation after release. Confirmed by capacity/recovery acceptance checks |
| P22 | reset occurs while ordering pending queues are nonempty. Fresh requests complete after reset release |

For capacity tests, response delay must be long enough to accumulate target occupancy, but delay alone is not evidence of full. Confirm accepted allocations and verify that another resource does not block the target first.

B ROB allocates one entry per reorder-required write. R ROB reserves `ARLEN+1` entries per reorder-required read. Count accepted allocations still reserved. After release, continue retirement until a new allocation is accepted.

### 6.2 Instance Coverage Review

| Target | Review condition |
|---|---|
| AXI covergroups | Review Source and each Device instance independently using that interface's ID range and destination |
| `ordering_cg` | Same-ID and cross-ID response arrival order, separately for reads and writes |
| `credit_cg` | Review availability × return × send combinations per link direction and VC. Classify unreachable combinations before proposing exclusions |
| Arbiter cover properties | Per-input service, contention, and four consecutive transfers where reachable |
| FIFO wrap cover properties | Accepted push/pop wraps the pointer on each applicable bound instance |

Response delay alone does not prove a capacity limit was reached. Capacity tests retain explicit full/recovery acceptance checks independently of functional coverage.

### 6.3 Test Matrix Fields

`NI_Verification_Matrix.xlsx` lists the expanded stimulus and per-instance coverage bins.

| Field | Definition |
|---|---|
| `AxLEN` | AXI AWLEN / ARLEN encoding. Number of beats minus one |
| `AxSIZE` | AXI AWSIZE / ARSIZE encoding. Bytes per beat = `2**AxSIZE` |
| `AxBURST` | AXI AWBURST / ARBURST encoding |
| `WSTRB` | W-channel byte-enable mask in hexadecimal. It is not an AW/AR signal |

The matrix omits the `Boundary` column. P11 and `boundary_cg` still verify address-boundary cases. Input-file records describe generated stimulus. Monitor samples and native coverage results establish which events occurred.
