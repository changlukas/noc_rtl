# NI and Router Functional Coverage Specification

Scope: NMU/NSU, REQ/RSP/DAT routers, and the existing integration verification environment in `changlukas/noc_rtl`. Router coverage belongs to migration issue #23. Code and sampling definitions below are not coverage results.

This document defines NI verification goals, functional coverage organization, input patterns, and coverage review criteria. Sections describing existing NI covergroups identify their implemented sampling. Section 7 defines the router coverage code and the validation checkpoint required before regression. New router coverage has not yet been validated by a full regression. Transaction, write-strobe, boundary, and response covergroups remain separate. Simulation results remain in the verification report and run records.

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
| DAT ready-qualified valid and fixed write/read classes | Existing class assertions and `DAT_VC_TRAFFIC` counters; router coverage requirements in Section 7 |
| Reset recovery | `reset_cg` |
| Arbitration | `served`, `contended_grant`, `continuous_transfer`, `no_bubble`, `bounded_wait` |
| CDC | Clock configurations and end-to-end checks. Structural CDC/RDC sign-off is not claimed |

Ready/valid, capacity, arbitration, CDC, and reset are interface/architecture requirements rather than transaction-conversion features.

## 3. Functional Coverage Organization

Current coverage sources:

- `dv/coverage/ni_coverage.svh`
- `dv/coverage/ni_axi_coverage.svh`
- `dv/env/ni_noc_monitor.svh`
- `dv/checkers/ni_arbiter_checks.sv`
- `dv/coverage/router_coverage.sv`
- `dv/coverage/router_coverage.svh`

Coverage is enabled by `NI_COVERAGE`. Unless noted otherwise, sampling occurs on the observation clock rising edge with reset inactive. Covergroups use per-instance reporting.

### 3.1 Transaction: `transaction_cg`

Sampling point: accepted AW/AR reported by each AXI monitor. Subscriber instances cover every Source and Device AXI interface; the default mesh has 16 of each. Traffic class is decoded from `AxADDR`. Source destination is decoded through SAM. Each Device instance covers its own destination.

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

### 3.5 NoC Interface Observation

The migrated `ni_noc_coverage` subscriber reports accepted DAT flit counts per fixed class through `DAT_VC_TRAFFIC`. These counters are traffic evidence, not functional covergroups or a coverage percentage.

Transfers are sampled on `valid && ready`, separately for each DAT VC. VC0 carries DATA_AW/DATA_W; VC1 carries DATA_R. DAT output valid is ready-qualified: downstream blockage can leave valid low while internal traffic is pending. Observe internal pending state for DAT stall coverage; do not require AXI-style hold-valid behavior at this interface. REQ/RSP use conventional ready/valid.

### 3.6 Assertion and Cover-Property Coverage

| Object | Type | Condition / Purpose |
|---|---|---|
| `continuous_transfer` | cover property | `(valid && ready)[*4]` |
| `gen_input[i].served` | cover property | `request_i[i] && grant_i[i]` |
| `gen_input[i].gen_contention.contended_grant` | cover property | `$countones(eligible)>1 && request_i[i] && grant_i[i]` |
| `write_wrap`, `read_wrap` | cover property | Accepted push/pop at the last pointer value, followed by pointer zero on the next clock |
| `no_bubble` | assertion | When enabled and downstream ready, an available request receives a valid grant |
| `gen_input[i].bounded_wait` | assertion | `wait_count < NUM_INPUTS` |

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
| `transaction_cg`, `write_strobe_cg`, `boundary_cg`, `response_cg`, `outstanding_cg` | One of each per observed Source and Device AXI interface; 16 + 16 in the default mesh |
| `ordering_cg`, `reset_cg` | One of each at the currently instrumented source-0 NMU ordering |
| `DAT_VC_TRAFFIC` | Accepted-flit counters per DAT class in each existing NI NoC subscriber; not covergroups |

Capacity/recovery checks and FIFO pointer-wrap cover properties remain. Assertions and cover properties are reported separately from covergroups.

## 4. Ignore / Illegal Bins

| Object | Explicit exclusion | Correctness check |
|---|---|---|
| `write_strobe_cg.strobe_size` | `byte_partial = partial × size=0` | legal byte-lane check |

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
| P20 | Random data read/write: ID, destination, length, size, `WSTRB` | — | supplemental: `transaction_cg`, `outstanding_cg`, `DAT_VC_TRAFFIC`, arbiter covers |
| P21 | Mixed control/data random read/write | — | supplemental: `transaction_cg`, `outstanding_cg`, `DAT_VC_TRAFFIC`, arbiter covers |
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
| AXI covergroups | Review each Source and Device instance independently using that interface's ID range and destination |
| `ordering_cg` | Same-ID and cross-ID response arrival order, separately for reads and writes |
| DAT class traffic | Review accepted VC0/VC1 traffic independently; counters alone do not cover arbitration, blockage, or recovery |
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


## 7. Router Functional Coverage Definition (#23)

### 7.1 Status and Implementation Boundary

Router covergroups and passive observers are defined in `dv/coverage/router_coverage.sv`, with mesh wiring in `dv/coverage/router_coverage.svh`. Existing router cover properties remain. AXI covergroups and NI DAT counters do not establish internal router coverage; review the router instances separately.

The router coverage files use the existing verification environment and `NI_COVERAGE` switch. Reuse existing cases, agents, scoreboard, and native VCS/URG reporting. No new TB, testcase, public Make option, or parallel reporting framework is introduced. Do not change DUT behavior to create coverage hits. Preserve existing assertions and cover properties.

Coverage samples use NoC rising-edge values before sequential updates. Except for reset coverage, suppress sampling while reset is asserted. Count a transfer only when valid and ready are both asserted. A combinational route decision or selected-but-blocked request is not a transfer.

### 7.2 Required Coverage Objects and Sampling

The names below identify implemented groups and observations. Instantiate only applicable channel/class/resource combinations; retain router coordinates and port identity in native instance paths.

| Object | Sampling point | Required bins / crosses |
|---|---|---|
| `router_link_cg` | Each connected router RX/TX port handshake | Direction RX/TX, physical port Local/North/East/South/West, legal packet type, tail. Cross direction / port / packet type; cross packet type / tail using legal packet forms only |
| `router_route_cg` | Accepted switch traversal, separately for each granted input and output branch | Input port, output port, network, DAT class where applicable, unicast/multicast. Cover each reachable input-to-output pair per network/class. For RSP CollectB, distinguish the merged requester from ordinary inputs; do not count the representative payload selection as one-to-one forwarding of every merged input |
| `router_arb_cg` | Each packet-arbiter acceptance and each DAT flit-arbiter acceptance | Winning input/class and eligible contender count: one, two, three-or-more where supported. Cross winner / contender count. Sample packet arbitration at accepted tails for ownership handoff; retain flit service evidence separately |
| `router_buffer_cg` | Each applicable input FIFO and DAT per-output/class FIFO on every active clock | Occupancy empty, partial, full; accepted push/pop: neither, push-only, pop-only, both. Cross occupancy / push-pop with pre-edge occupancy and actual primitive acceptance semantics. Also cover full-to-space followed by a new accepted push |
| `router_packet_cg` | Packet-arbiter owner while a packet is active | Owner retained over a body transfer, an owner request gap (including multicast branch coordination), and a downstream stall; accepted tail followed by another waiting owner. Distinguish body-stall and tail-stall followed by progress. RSP and DAT-read packets are single-flit and have no body/request-gap requirement |
| `router_dat_cg`, `router_flit_cg` | DAT output FIFO pending/ready state and physical output handshake | Both classes pending; each class winning when both are eligible (flit cross only); write progress with pending read blocked and read progress with pending write blocked; blocked class later resumes. The `write_to_read` and `read_to_write` cover properties observe consecutive successful grants while both classes remain eligible at both sampled edges. Payload packet type must be observed on the accepted class, not inferred from ready alone |
| `router_multicast_cg`, `router_merge_cg`, `router_fanin_cg`, `router_merge_resp_cg` | Accepted multicast branches and accepted CollectB merge | REQ/DAT multicast one/multiple selected branches, partial branch acceptance followed by completion; RSP merge waiting, acceptance, and stall/recovery. Accepted merge response bins cover all contributors OKAY, SLVERR from the nominal source, and nominal OKAY with SLVERR selected from another contributor. Cross applicable network / single-or-multiple branches. Preserve the approved overlapping-multicast restriction |
| `router_reset_cg`, `router_recovery_cg` | Reset assertion using state before reset clears it; subsequent active clocks | Reset with input FIFO occupied, active packet/route state, DAT output FIFO occupied, multicast branch pending, or merge pending. Cover fresh traffic progress after reset release separately from discarded pre-reset traffic |

Input FIFO occupancy may use the existing primitive's internal count through passive observation; its currently unconnected `usage_o` is not evidence of zero occupancy. DAT route spill-register occupancy also contributes to reset-pending observations. Do not introduce a second transaction scoreboard to implement route or buffer coverage.

Packet-type scope is explicit: REQ = NARROW_AW/W/AR and DATA_AR; RSP = NARROW_B/R and DATA_B; DAT write VC0 = DATA_AW/W; DAT read VC1 = DATA_R. RSP and AR are single-flit. AW/W tails follow packet framing, not an automatic Cartesian product of packet types and both tail values. Class and packet-type violations remain checker failures.

For DAT output blockage, use nonempty per-class output FIFO and deasserted class ready. `TXDATVLD && !TXDATRDY` cannot establish blocked-pending coverage because output valid is ready-qualified. For packet switch arbitration, sample the actual request/grant and output-FIFO availability, separately from the final physical-port flit arbiter.

### 7.3 Reachability and Coverage Denominators

Use the selected topology, endpoint attachments, fixed DAT class mapping, packet framing, and routing algorithm to define reachable bins. Do not require every input/output pair or every packet type on every network. XY unicast routing, multicast replication, and CollectB merging have different reachable combinations. Disconnected boundary ports are not active links; an explicitly attached boundary endpoint is active.

Review each router instance and each applicable port/class, not only a merged group percentage. Keep these outcomes distinct: implemented and hit, implemented and unhit, not yet implemented, structurally unreachable, and reachable but unsupported by current stimulus. Record each exclusion with its configuration and reason before accepting it. Missing stimulus is not an unreachable bin and must not be hidden by an ignore bin.

### 7.4 Existing Cases and Regression Gate

| Existing case / family | Coverage purpose; actual native hits still required |
|---|---|
| `data_write_single`, `ctrl_read_single` | Local transfer and packet-type sampling smoke checks |
| `single_id_reorder`, `multi_id_out_of_order` | Multi-hop traversal, packet framing, and destination diversity; retain ordering checks |
| `routing` | Reachable injection, transit, turns, and ejection across the mesh |
| `hotspot`, `uniform_random` | Contention, winner diversity, sustained traffic, and buffer activity |
| Existing backpressure cases | FIFO blockage/recovery, packet stalls, and DAT class progress where generated |
| Existing multicast cases | Replication, partial completion, and CollectB merge where generated |
| `reset_recovery` | Occupied-state reset and fresh post-reset completion where generated |

Before the full regression: implement and independently review this coverage model, check that coverage-enabled VCS compile succeeds, and use a few existing cases to confirm native covergroup/instance/bin collection and sampling. Inspect gaps against the existing approved matrix. A case name or generated stimulus record alone is not coverage evidence; unsupported scenarios remain explicit gaps without silently adding a testcase.

The full regression must use the current source/configuration and retain command, commit plus dirty-source hash, seed, drain result, checker result, and native coverage database/report provenance. Evaluate correctness failures separately from coverage holes. New checkers, if required, need fault-injection evidence under #23; passive covergroups do not replace checkers. Neither functional nor code coverage establishes synthesis, timing, CDC/RDC, or PPA sign-off.


### 7.5 Code Organization and Validation Checkpoint

- `dv/coverage/router_coverage.sv`: router-only passive observer modules and covergroups. Small local histories cover packet/branch/resource recovery; they do not check correctness or duplicate transaction tracking. Blocking updates in these nonsynthesizable observers record edge observations. FIFO full-to-reuse remains a cover property.
- `dv/coverage/router_coverage.svh`: observer instances beside each `router_mesh.gen_router[n].i_router`, enabled only by `NI_COVERAGE`. Instance paths identify node, physical port, network and DAT class; separate unicast/multicast group instances identify operation. Explicit observer inputs expose the actual DUT sampling points. No NI coverage file is extended.
- `dv/tb/router_mesh.sv`: includes router observer wiring. Existing FIFO capacity values are explicitly forwarded to the DUT and observers together; architecture defaults are unchanged.
- `dv/scripts/prepare.py`: lists the coverage files in the generated compile recipe only for mesh builds. Direct-link builds do not instantiate or compile router observers. `dv/config/coverage.hier` already includes the complete mesh tree. Observer/header bytes participate in the existing SV content key.
- `dv/scripts/verification_matrix.py`: existing plan IDs reference router coverage objects; native URG bin results still establish actual hits.

Route groups sample each actual accepted switch grant. Ordinary input identity is not reconstructed from RX/TX timing; the RSP merge requester has its own index 5. Packet arbitration coverage samples accepted tails with the effective locked request snapshot exposed as the project-owned `packet_rr_arbiter.req_next`. New requests during a packet do not increase that packet decision's contender count. Link and route groups retain individual-flit service observations. RSP and DAT-read omit body/request-gap requirements but retain tail-stall recovery and handoff.

`request_gap_resume` observes a gap in the packet owner's branch request and its later resumption. A multicast branch that already accepted a flit may wait for the remaining branches; this counts as a request gap even when the input FIFO is nonempty. It is not a source-FIFO starvation measure. Existing FIFO-empty cover properties retain their own scope.

DAT winner evidence is sampled by `router_flit_cg`. The two consecutive-grant cover properties show that continuous dual eligibility and a change of winner occurred. They are activation evidence, not fairness assertions or a replacement for the existing bounded-wait checks.

`router_merge_resp_cg` samples only accepted CollectB merges, using the actual contributor mask, input BRESPs, nominal representative, and selected representative. Samples require known masks and one-hot nominal/selected representatives that belong to the accepted contributor set. `all_okay` requires every contributor's BRESP to be OKAY. `slverr_nominal` requires the selected nominal source to provide SLVERR. `slverr_other` requires a nominal OKAY source and a different selected SLVERR contributor; it is excluded when only one contributor is reachable. DECERR-only or unknown responses do not count as all-OKAY, and no new DECERR priority rule is introduced. Merge events cover waiting, acceptance, stall, and resumption.

Existing unicast `response_slverr` runs do not establish CollectB error-select coverage. The current multicast catalog does not request mixed contributor BRESPs. Unless an existing run actually produces the required responses, retain this as a stimulus gap and leave the corresponding bins unhit; do not add a testcase or ignore the missing bin. Native hits still need to be checked.

Topology helpers exclude disconnected ports and unreachable XY input/output combinations. Multicast fanout depends on the input direction: vertical transit continues vertically or ejects locally; horizontal transit may also branch vertically. CollectB fan-in depends on the output and merge-mask geometry, including horizontal contributors at a vertical output. Endpoint injection/ejection is distinguished from mesh links. Filter single-branch/single-contributor instances accordingly; missing stimulus does not justify an exclusion.

Reset samples real FIFO, route-register, multicast/merge, route-lock and packet-arbiter snapshot state before reset NBAs clear it. New post-reset output handshakes establish recovery per network after an occupied reset; history from abandoned packets is cleared. This mesh fixture uses the current REQ/RSP output-register bypass defaults; optional stored REQ/RSP output-register configurations need additional occupancy observation before claiming reset coverage for those configurations.

Before full regression: independently review the model against #23 and current RTL, compile with coverage enabled on workstation VCS, then run a few existing cases to check native group/instance/bin collection and sampling. Use local transfer, multi-hop/contended routing, backpressure, multicast, and reset cases as applicable. Report reachable holes left by existing cases; do not add cases or hide gaps with ignore bins. A compile result does not establish functional coverage hits.

The historical integration-results document describes an earlier campaign and is not the current architecture definition or current regression evidence. Do not edit its historical commands, configuration, or PASS claims during cleanup.
