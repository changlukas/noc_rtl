# NI Verification Report

文件與功能敘述 review：2026-10-05。沿用既有 **147 accepted VCS PASS**、**28,245 input transaction records**，本輪只整理文件，未新增模擬或修改 coverage model。

現有原生 functional GROUP／instance coverage 均為 **100%**。模型包含 top-level 與 internal coverage，不能視為新版 [Verification Plan](verification-testplan.md) 全部 interface goals 已完成。Issue [#7](https://github.com/changlukas/noc_rtl/issues/7) 保持開啟。

## Environment and Evidence

`AXI file master → NMU RTL → C++ Router → 四個 NSU RTL → AXI Slave／Memory`

- Simulator：VCS M-2017.03-SP1。沿用 AXI file master、memory、scoreboard、axi_reorder_compare、protocol checks。
- 組態定義見 [C0～C6](verification-testplan.md#驗證組態)。C0 包含全部 18 cases 及選定變體，其他組態為選定 cases。
- 本批 code 最後整理於 `4babe4f`。歷史 runs 使用不同 build stages，個別版本以 source manifest digest 為準。
- Accepted coverage 排除 failed/debug runs、standalone、direct-link 與 checker self-tests。
- [Run records](data/verification-runs.csv)：147 筆，包含 case、組態、seed、clock、cycles、結果與證據路徑。
- [Transaction records](data/verification-transactions.csv)：28,245 筆，包含 address、ID、size、length、WSTRB、destination、stimulus hash。

Transaction records 由輸入檔取得。PASS 屬於 run 結果，不能把每筆 record 視為獨立 coverage hit。Reset 中斷後會重送，因此 record 數不等於所有實際 handshakes。

## Plan Item Results

「已驗證」僅限表中所列條件。「部分驗證」仍缺觀察點、cross 或情境。完整 requirement／coverage closure 尚未宣告完成。

### Generic AXI

| Item | 已有證據 | 尚缺／限制 | 判定 |
|---|---|---|---|
| AXI-01 | C0 control read/write 各 2～256 beats，data 各 2～64 beats，single 各一筆。Checks 通過 | Full-width、aligned INCR。cp_beats 只有代表性 lengths，其他 lengths 用輸入與完成紀錄佐證 | 所列 sweep 已驗證 |
| AXI-02 | Control 1/2/4/8 bytes，data 1/2/4/8/16/32/64 bytes，4 KB 與 SAM 邊界測試 PASS | 未完整交叉 size × lane × length，read lane 專用 coverage 缺少 | 部分驗證 |
| AXI-03 | W lane 64/64、strobe × size 20/20，control/data one-hot 補測 PASS。Readback checker 通過 | One-hot 無獨立 bin，未掃所有合法 masks 與全部交叉 | 所列 strobe sweep 已驗證 |
| AXI-04 | Source B/R backpressure，四 NSU AW/W/AR stall→recovery 12/12 cover properties 命中 | 尚無完整五 channel／AW-W 相對時序 bins。12 個 covers 的 recovery window 為 1～64 cycles | 部分驗證 |
| AXI-05 | OKAY traffic PASS。SLVERR/DECERR 共 16/16 variants，56 B responses、2,516 R beats 比對 PASS | 驗證 Device error 傳回 Source。未驗證 SAM miss 自行產生 DECERR，EXOKAY／exclusive 待確認 | 所列 responses 已驗證 |
| AXI-06 | Single/multi-ID outstanding、read/write pending cross 命中，random seeds 1/17/29 PASS | multiple bin 為 depth≥2，未分每 ID 深度與 ID 數交叉 | 部分驗證 |
| AXI-07 | Ordering cases 與 mixed seeds PASS，checker 正反向 self-test 10/10。hol_blocking 補充不同 ID／destination 的 response 完成情境 | Inversion covergroup 觀察內部 ordering ingress。Top-level arrival／retirement cross 待補，R beat interleaving 未驗。hol_blocking 不證明 OoO 或 HoL bypass | 部分驗證 |

### NI Functions

| Item | 已有證據 | 尚缺／限制 | 判定 |
|---|---|---|---|
| NI-01 | 四 destinations、SAM 起點／尾端，端到端 checker 與 boundary bins 通過 | Destination coverpoint 由 Source address 推導，實際 AXI／NoC route cross 待補。本平台未啟用 NSU address rebasing，非零 address translation 未驗證 | 部分驗證 |
| NI-02 | Control/data read/write、single/burst、random 的端到端 checks PASS | 未獨立計量 channel mapping、packet VC 保持與 REQ/DAT 同時傳輸 | 部分驗證 |
| NI-03 | C1/C0/C2 Device ID width 1/3/8，C5/C6 Source width 1/8。C6 全部 256 IDs 各一筆 read/write PASS | Source × Device ID mapping cross 缺少，multi-source 未驗 | 部分驗證 |
| NI-07 | Same-ID request 按 destination/region 檢查。Mixed seeds 及 C2/C4 無 read reordering 的選定 cases PASS | Request 的 destination/region/order 組合未完整計量，不能用 response inversion bins 代替 | 所列條件已驗證 |
| NI-11 | 與 AXI-07 共用 ordering cases、checker 與 ordering_cg 證據 | 同 AXI-07，尚缺 top-level arrival／retirement cross。不另計 run 或 coverage hit | 部分驗證 |

### Architecture and Interface Requirements

| Item | 已有證據 | 尚缺／限制 | 判定 |
|---|---|---|---|
| NI-04 | Per-ID/context/ROB capacity tests PASS，內部 full/reuse 命中 | Interface-only limit/recovery model 待補。C0 W context depth=32 full 未命中 | 部分驗證 |
| NI-05 | Shared/split、單／多 VC PASS，internal credit crosses 命中，credit assertions failure=0 | 外部 credit-balance monitor 與 VC × direction cross 待補 | 部分驗證 |
| NI-08 | C0 T0/T1/T2 共 12 項 PASS | 未交叉全部 C0～C6。不是 physical CDC/RDC | 所列 clock sweep 已驗證 |
| NI-09 | Pending reset、quiet interval、fresh traffic checks PASS | Pending bin 從內部取樣。僅全平台 reset，非獨立 domain／局部 reset | 部分驗證 |
| NI-10 | Internal RR、no-bubble、credit-forward assertions failure=0，端到端 packet/data checks PASS | 部分 instance contention／continuous-transfer 未命中。端口觀察不能辨識每次內部可仲裁機會 | 部分驗證 |

## Existing Coverage Model

| Sampling boundary | 已實作物件 | 對應 items |
|---|---|---|
| Source AXI | transaction_cg、write_strobe_cg、boundary_cg、response_cg、outstanding_cg | AXI-01/02/03/05/06，NI-01/02/03 |
| Device AXI | aw_stall_recover、w_stall_recover、ar_stall_recover | AXI-04 |
| Internal／mixed | ordering_cg、rob_cg、stress_cg、reset_cg | AXI-07，NI-04/07/09/11 |
| Internal primitives | fifo_cg、credit_cg、arbiter／credit-forward assertions | NI-04/05/10 |

Bins、cross、sample condition 與 exclusions 見 [Functional Coverage Plan](verification-testplan.md#functional-coverage-plan)，source links 見 [Coverage Source Index](verification-testplan.md#coverage-source-index)。Report 保留內部證據，但不以其取代尚未實作的 interface coverpoints。

## 組態與結果

組態定義集中於 [testplan](verification-testplan.md#驗證組態)，本報告只引用編號。

| 組態 | 結果 |
|---|---|
| C0 | 88/88 PASS |
| C1 | 24/24 PASS |
| C2 | 7/7 PASS |
| C3 | 9/9 PASS |
| C4 | 7/7 PASS |
| C5 | 6/6 PASS |
| C6 | 6/6 PASS |

C0 包含18個公開 case及選定變體，其他組執行testplan指定項目。未宣稱全部 cases × 全部組態皆已驗證。

## 性能紀錄

C0 **29 筆 cycles 全部與修正前一致**，原有 SHARED 行為未出現 cycle 差異。
四組 request_rand 的 read.txt、write.txt、schedule.txt SHA256 相同：64 writes、64 concurrent reads，再做 64 readbacks。

| 組態 | request_rand cycles | 結果 |
|---|---:|---|
| C0 | 653 | PASS |
| C1 | 887 | PASS |
| C2 | 1404 | PASS |
| C3 | 998 | PASS |

Cycles 使用 TB 的 CAPACITY_PERF 計數，包含該 case 的排程、等待與驗證階段。不是單筆 request latency。各組同時改變多個參數，差異不能歸因於單一參數。

## Code coverage 與 assertions

以下取自最新原生 URG hierarchy report。範圍為 NMU 與四個 NSU RTL，包含 primitives，不包含 C++ Router。

| 組態 | Line | Condition | Branch | Toggle | Assertion failures |
|---|---:|---:|---:|---:|---:|
| C0 | 85.61% | 84.78% | 83.17% | 80.52% | 0 |
| C1 | 84.97% | 77.09% | 80.25% | 77.34% | 0 |
| C2 | 83.60% | 73.30% | 79.87% | 71.77% | 0 |
| C3 | 84.86% | 71.57% | 77.80% | 77.05% | 0 |
| C4 | 84.32% | 66.72% | 77.03% | 74.77% | 0 |
| C5 | 84.34% | 68.46% | 76.88% | 67.42% | 0 |
| C6 | 84.66% | 66.08% | 77.33% | 75.47% | 0 |

各組 code coverage 分開保存，不平均或合成單一百分比。FSM 未抽取，MDA toggle 未啟用。Assertion report 包含部分 TB/interface/package，與 code coverage 範圍不同。零 failure 不代表全部 assertion 情境已觸發。

## Functional Coverage

原生合併使用 `urg -metric group -flex_merge union`，精確 command 與 VDB 清單保留於 native reports／sources.json。

| Metric | C0 | C0～C6 union |
|---|---:|---:|
| GROUP score | 95.43% | 100.00% |
| Instance score | 95.51% | 100.00% |
| Group types | 61 | 79 |
| Merge warnings | 0 | 0 |

Union 的分母是實際 VDB 中已定義的模型，含內部 resource bins。Missing interface cross 不在分母中。C2/C3 沿用早期 evidence，未加入後續新 monitor，不可推定每個組態均驗到新增情境。

### 最新 assertion activation

| 組態 | Assertions | Uncovered | Without attempts | Failures | Cover properties matched/total |
|---|---:|---:|---:|---:|---:|
| C0 | 693 | 32 | 3 | 0 | 144/165 |
| C1 | 696 | 84 | 2 | 0 | 135/193 |
| C2 | 588 | 43 | 2 | 0 | 未加入新 monitor |
| C3 | 488 | 60 | 2 | 0 | 未加入新 monitor |
| C4 | 533 | 62 | 2 | 0 | 42/108 |
| C5 | 648 | 92 | 2 | 0 | 18/153 |
| C6 | 648 | 77 | 2 | 0 | 57/153 |

取自各組 `asserts.txt`。Without attempts 包含在 uncovered 中。C2/C3 沿用既有已通過證據，不為新增觀察器重跑。Cover properties 與 covergroup 是不同指標，不能用 GROUP 100% 取代 assertion activation review。

- `flush_valid`：對應 primitive 的 flush 固定為0。
- `wrap_boundary` 與 `check_byte`：本批 INCR traffic 不呼叫 WRAP helper，scoreboard 使用既有 transaction check 路徑。
- W context `full_write`：C0 depth=32 未滿載，保留未觸發結果。Depth=1 full/recovery 與 depth=32 pointer wrap 分別驗證。
- Split 模式未使用的 read/write VC inputs，不要求出現 grant／contention。
- 其餘未命中的 contention 與 continuous-transfer properties 保留於各 instance report，不宣稱不可達。單 NMU 的 AW→W 排程限制可提供的 AW 競爭序列。

## Clock Sweep

| Timing | AXI／NoC period | NoC phase | request_rand | control reorder + BP | data reorder + BP | reset_recovery |
|---|---|---|---:|---:|---:|---:|
| T0 | 1000／1000 ps | 0 ps | 653 | 2227 | 2231 | 220 |
| T1 | 1000／2000 ps | 250 ps | 1277 | 2265 | 2273 | 322 |
| T2 | 2000／1000 ps | 250 ps | 516 | 2207 | 2209 | 191 |

12/12 PASS，cycles 為各自 AXI clock 的計數，跨 timing 比較需換算時間。

## Checker and Implementation Notes

- Requests 按 Source ID 與 control/data address region 保序。同 Source ID、同 NSU、不同 region 可超車。Source same-ID B/R responses 仍按原次序返回。
- `axi_reorder_compare` 以 10 個正反向 self-tests 驗證 ordering、W 配對與 reset 行為。預期失敗的 self-tests 不納入 DUT coverage。
- Ordering checker 無法區分已可返回且 payload 完全相同的 same-ID B responses。ID mapping 後若不同 Source IDs 的 request headers 完全相同，外部配對有歧義。目前 generated cases 使用不同 addresses。
- Error response 比對每個 B 與 R beat。Error read 不宣稱 RDATA 有正常 memory read 語意。
- Router split VC 修正為 `76634b7`，preferred VC 與 single-flit fallback 限於 read/write pool。C0 原 29 筆 cycles 不變。
- 最後 backpressure 補測沿用 `axi_delayer`，只在 BACKPRESSURE=1 啟用。無 stall 的 request_rand 仍為 653 cycles。
- 本輪文件更新未變更 RTL、參數、stimulus 或 covergroups，未重跑 regression。

## Open Coverage and Release Items

| 項目 | 所需處置 |
|---|---|
| NI requirement baseline | interface_handshake.json 的通用 req/rsp credit 描述與現行 REQ/RSP ready-valid、DAT credit ports 不一致，需另行確認來源定義。此次未修改該檔 |
| Interface coverage | 依 Plan Item Results review 待補項目，優先確認外部 arrival/order、packet/VC、credit、stall/recovery 的觀察方式 |
| AXI／address support | 確認 FIXED/WRAP、unaligned、exclusive、sideband、SAM miss 的行為與必要驗證範圍 |
| Code／assertion closure | 逐組處理未覆蓋 condition／toggle 與未觸發 properties。Module／statement 分類完成，完整 bin review 未完成 |
| C0 W context | Depth=32 pointer wrap 已命中，full 未命中。單 source AW→W 排程限制 occupancy 的分析尚未核准為 exclusion |
| Out-of-scope | Multi-source、R interleave、multicast 後續整合仍由 issue #6 追蹤。Router RTL、multihop、physical CDC/RDC、STA／synthesis 另案 |
| Release | 確認 configuration、revision、已知限制、原生 evidence package 與核准 exclusions |

沒有新增 DUT exclusions。合法 traffic 未觸發 fatal guard 不能視為 negative testing 完成。固定接線、固定參數與未使用 API 的缺口保留理由，不自動當成 waived。

## Evidence Locations and Reproduction

| Artifact | 位置 |
|---|---|
| 本機最新 URG | `build/issue7-closure/final-r9-evidence/reports/`，包含 C0～C6、functional-urg |
| 工作站最新 URG | `/home/mingwei/noc_project/sim/build/issue7-coverage-r9/` |
| 本機新增 run evidence | `build/issue7-closure/run-evidence/reports/` |
| 原始 run／stimulus | 逐筆 CSV 的 run_record、log、pattern_file、pattern_sha256 |
| Build audit | 最新 report 目錄的 sources.json、build-audit.json 與 SHA256 記錄 |

原生 report 共 1,335 檔、run evidence 共 109 檔已核對 SHA256。上述 build artifacts 未納入 Git，本 branch 提供 evidence indexes。Release 時需另攜對應 logs、manifests、VDB／URG，不能只交 CSV。

一般執行方式如下。精確重現歷史 run 時，使用 CSV 對應的 source stage、profile、stimulus 與 seed。

```sh
cd /home/mingwei/noc_project/sim
make run CASE=request_rand COVERAGE=1
make run CASE=single_id_reorder MODE=data BACKPRESSURE=1 COVERAGE=1
urg -full64 -dir <run-record中的VDB路徑> -report build/coverage -format both
```

## hol_blocking Test Scope

`hol_blocking` 的實際 stimulus 與驗收條件如下。

1. ID 0 的第一筆 request 送 west，後續其他 IDs 送 north。
2. TB 延遲 north memory 的 B/R，讓 north 有未完成 transactions。
3. 在 north 恢復前，west response 必須返回 Source。既有檢查另要求 north context full。
4. 恢復 north responses，確認全部 transactions 完成。

這份證據確認不同 ID／destination 在選定阻塞條件下仍可返回 response。West request 先接受，不能由 west 先完成推定 OoO。它也沒有把一筆可前進的 request 放在 blocked head 後方來驗證 HoL bypass，或驗證任意 VC／destination 的隔離。本輪只修正描述，保留原 case 名稱與測試結果。

## Documentation Audit

本輪另依 NoC flow control／ordering 概念核對 NI 功能分類，檢查 channel mapping、packet lock、ID mapping、request/response ordering 與 backpressure 的必要條件。NMU／NSU ports、covergroup 名稱、sample code、Device AXI cover properties、CSV counts 與原生結果摘要保留原核對結果。17 個 verification items 均有本報告對應列，包含協定、NI 功能及架構與介面要求。NI-11 共用 AXI-07 證據。原 NI-06 併入 AXI-07 的測試對照。未新增 covergroups，未將待補項目標成已命中。

| 原 objective | 現行對應 |
|---|---|
| V01/V02 | AXI-01/02/03、NI-01 |
| V03 | AXI-06 |
| V04/V05 | AXI-07、NI-07 |
| V06/V07/V08/V09 | NI-03/04 |
| V10 | NI-05 |
| V11 | AXI-07 的 hol_blocking 補充情境，不作為 OoO 證據 |
| V12/V14 | NI-08/09 |
| V13/V17 | 驗證組態、NI-03/07/08 |
| V15/V16 | AXI-05、NI-10 |
| V18 | Code coverage／assertion activation、Open Coverage and Release Items |
| V19 | 現行固定 source-aware ID mapping 無 dynamic mapping table，NI-03/04 驗實際 ID/context 行為 |
| V20 | Out-of-scope |
