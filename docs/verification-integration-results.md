# NI 整合驗證總報告

2026-10-03。四組核准組態共 **56/56 PASS**。本輪僅使用整合環境，未納入 standalone、direct-link 或舊的 coverage 資料。

## 驗證環境與變更

`AXI file master → NMU RTL → C++ Router → 四個 NSU RTL → AXI Slave／Memory`

- VCS M-2017.03-SP1；沿用 AXI file master、memory、scoreboard、axi_reorder_compare 與 protocol checks。
- AXI／NoC 同頻 1 GHz；APPL_DELAY＝0、sample delay＝200 ps。
- 修正 C++ Router 的 Split VC allocation：preferred VC 與 single-flit fallback 均限制於對應 read/write pool。固定 VC、wormhole lock、credit 計帳與路由規則保留。
- 未新增 FIFO、pipeline 或儲存狀態；Split 模式不能借用另一方向的 VC。未進行 synthesis／STA，不宣稱 Fmax 或 area 改善。
- NMU／NSU RTL、參數預設值、stimulus、coverage model 與 checkers 未修改。
- Router 修正 commit：`76634b7`。原始失敗在 DataAw 經 Router 後由 VC0 變成 VC3；本輪相同 request_rand 通過。

## 組態與結果

所有容量採 2^n。完整定義見 [參數驗證規劃](verification-parameter-plan.md)。

| 組態 | Source／NoC／Device ID width | Per-ID／Context depth | IO FIFO depth | B／R ROB depth；R enable | REG_TYPE | DAT VC；Credit depth | 結果 |
|---|---|---|---:|---|---:|---|---|
| 0. Baseline | 3／3／3 | 32／32 | 32 | 128／128；1 | 0 | 2，SHARED；8 | 29/29 PASS |
| 1. Split VC | 3／3／1 | 4／4 | 4 | 128／128；1 | 2 | 4，READ_WRITE_SPLIT；2 | 11/11 PASS |
| 2. Read ROB 關閉 | 3／3／8 | 32／1 | 4 | 128／128；0 | 1 | 2，SHARED；8 | 7/7 PASS |
| 3. 小 ROB／單 VC | 3／3／3 | 32／32 | 32 | 4／8；1 | 0 | 1，SHARED；2 | 9/9 PASS |

IO_FIFO_DEPTH 沿用現有接線：兩端 AXI CDC FIFOs 與 NMU REQ/RSP FIFOs；NSU REQ/RSP FIFOs 保留預設。REG_TYPE 涵蓋 packetize/depacketize，SAM pipeline 保留預設。

Baseline 包含全部 18 個公開 case 及選定 mode／target／backpressure／seed 變體；其餘三組只跑核准的代表項目，不代表全部 18 cases × 4 組態均已驗證。

## 性能紀錄

Baseline **29 筆 cycles 全部與修正前一致**，原有 SHARED 行為未出現 cycle 差異。
四組 request_rand 的 read.txt、write.txt、schedule.txt SHA256 相同：64 writes、64 concurrent reads，再做 64 readbacks。

| 組態 | request_rand cycles | 結果 |
|---|---:|---|
| 0. Baseline | 653 | PASS |
| 1. Split VC／窄 Device ID | 887 | PASS |
| 2. Read ROB 關閉 | 1404 | PASS |
| 3. 小 ROB／單 VC | 998 | PASS |

Cycles 使用 TB 的 CAPACITY_PERF 計數，包含該 case 的排程、等待與驗證階段；不是單筆 request latency。各組同時改變多個參數，差異不能歸因於單一參數。

## Code coverage 與 assertions

以下直接取自各組原生 URG hierarchy report。Code coverage 範圍為 NMU 與四個 NSU RTL，包含其 primitives；不包含 C++ Router。

| 組態 | Line | Condition | Branch | Toggle | Assertion failures |
|---|---:|---:|---:|---:|---:|
| 0. Baseline | 85.22% | 81.07% | 82.44% | 78.95% | 0 |
| 1. Split VC／窄 Device ID | 84.73% | 76.15% | 80.00% | 74.55% | 0 |
| 2. Read ROB 關閉 | 83.60% | 73.30% | 79.87% | 71.77% | 0 |
| 3. 小 ROB／單 VC | 84.86% | 71.57% | 77.80% | 77.05% | 0 |

- 各組 accepted VDB／report 分開保存，四組 URG 報告均無 merge warning。未產生跨組態的單一 code coverage 百分比。
- 各組硬體結構及 case 集合不同，不能平均百分比，也不能以表中差值判定性能或功能退步。
- FSM 未抽取；MDA toggle 未啟用。DUT 內的 SAM simulation checks／guards 仍包含在 code metrics。
- Assertion report 包含部分 TB／interface／package，範圍與 code coverage 不同；四組均有 2 個 without-attempts 項目。零 failure 不等於所有 assertion 觸發情境皆已覆蓋。

## Functional coverage

只合併本輪四組、56 筆 PASS 的 functional covergroups：

```sh
urg -full64 -metric group -flex_merge union -dir <四組 accepted.vdb> -report <report-dir> -format both
```

| 原生 URG metric | 本輪 Baseline | 四組整合環境 union |
|---|---:|---:|
| GROUP score | 91.74% | 97.17% |
| Instance score | 91.87% | 97.21% |
| Group types | 60 | 78 |

Merge 無 warning。GROUP 增加 5.43 個百分點；跨組態增加了 VC 等 instances，聯集範圍也擴大，因此不是預設組態的完成率或規格完成率。舊的 97.02% 含 direct-link 資料，不沿用為本輪結果。

### 已確認的情境

- Per-ID limit/reuse、B/R ROB full/reuse、HoL progress、reset recovery、同筆 inversion/output stall 均有 read/write 命中。
- Split VC：control/data capacity、reorder＋backpressure、HoL 均在 Router 整合環境通過；未放寬 DAT VC 檢查。
- Read ROB 關閉：control/data same-ID read 均觀察到 admission wait 與恢復接受。
- 四個 NSU AW/AR context 均觀察到 full/reuse；W context 的 full/recovery 也都在聯集中命中。W context 滿載包含 depth＝1 的結果，不代表預設 depth＝32 已滿載。
- AXI scoreboard、ordering compare 與完成條件通過；沒有新增 checker、waiver 或關閉檢查來提高分數。

### 剩餘 bins 與範圍

| 項目 | 尚未涵蓋 |
|---|---|
| Write strobe 起始 byte lane | 20/64 命中，仍缺 44 lanes |
| FIFO full/recovery | NSU[0] TX DAT VC3、NSU[2] RX DAT VC0、NSU[2] TX DAT VC1 |
| W context 同 cycle push/pop | NSU[3] 未命中 |
| Credit cross | 部分 NSU read VC 的 available／give／take 組合未命中，詳見原生 grpinfo.txt |
| CDC | 尚未執行獨立 clock／phase 的參數 regression；不替代 physical CDC/RDC 檢查 |
| ID／random 組合 | Source／NoC ID 固定 3／3；transaction seed 固定 1，reset timing 使用 seed 1／17／29 |
| 系統範圍 | 不包含多 source、Router RTL、multihop mesh 的整合驗收；不作為整個 NoC 的完整驗證結論 |

未命中的 bins 仍須依各組態區分缺 stimulus、不可達或不支援；本輪未新增 exclusion。
其他尚未結案項目包含 ID mapping table capacity、response-error 與 arbitration fairness，見 [testplan](verification-testplan.md) 的待補強清單。

## 測試明細

以下共 56 筆。BP＝AXI response backpressure；TARGET 只對 capacity_reuse 有效。MODE=auto 使用該 pattern 的既定模式。

### 0. Baseline

| CASE | MODE | TARGET | BP | SEED | Cycles | 結果 |
|---|---|---|---:|---:|---:|---|
| ctrl_write_single | auto | — | 0 | 1 | 27 | PASS |
| ctrl_read_single | auto | — | 0 | 1 | 26 | PASS |
| ctrl_write_burst | auto | — | 0 | 1 | 1051 | PASS |
| ctrl_read_burst | auto | — | 0 | 1 | 1036 | PASS |
| single_id_outstanding | auto | — | 0 | 1 | 98 | PASS |
| multi_id_outstanding | auto | — | 0 | 1 | 98 | PASS |
| multi_id_out_of_order | auto | — | 0 | 1 | 99 | PASS |
| multi_id_out_of_order | auto | — | 1 | 1 | 2230 | PASS |
| single_id_reorder | auto | — | 0 | 1 | 102 | PASS |
| single_id_reorder | auto | — | 1 | 1 | 2227 | PASS |
| single_id_reorder | data | — | 1 | 1 | 2231 | PASS |
| data_write_single | auto | — | 0 | 1 | 29 | PASS |
| data_write_burst | auto | — | 0 | 1 | 283 | PASS |
| data_read_single | auto | — | 0 | 1 | 28 | PASS |
| data_read_burst | auto | — | 0 | 1 | 272 | PASS |
| ctrl_rand | auto | — | 0 | 1 | 732 | PASS |
| data_rand | auto | — | 0 | 1 | 659 | PASS |
| request_rand | auto | — | 0 | 1 | 653 | PASS |
| capacity_reuse | auto | context | 0 | 1 | 17048 | PASS |
| capacity_reuse | auto | per_id | 0 | 1 | 9097 | PASS |
| capacity_reuse | auto | rob | 0 | 1 | 17221 | PASS |
| capacity_reuse | data | context | 0 | 1 | 17050 | PASS |
| capacity_reuse | data | per_id | 0 | 1 | 9103 | PASS |
| capacity_reuse | data | rob | 0 | 1 | 17230 | PASS |
| hol_blocking | auto | — | 0 | 1 | 348 | PASS |
| hol_blocking | data | — | 0 | 1 | 343 | PASS |
| reset_recovery | auto | — | 0 | 1 | 216 | PASS |
| reset_recovery | auto | — | 0 | 29 | 203 | PASS |
| reset_recovery | data | — | 0 | 17 | 216 | PASS |

### 1. Split VC／窄 Device ID

| CASE | MODE | TARGET | BP | SEED | Cycles | 結果 |
|---|---|---|---:|---:|---:|---|
| multi_id_out_of_order | control | — | 1 | 1 | 2299 | PASS |
| multi_id_out_of_order | data | — | 1 | 1 | 2303 | PASS |
| single_id_reorder | control | — | 1 | 1 | 2854 | PASS |
| single_id_reorder | data | — | 1 | 1 | 2953 | PASS |
| request_rand | auto | — | 0 | 1 | 887 | PASS |
| capacity_reuse | control | context | 0 | 1 | 17490 | PASS |
| capacity_reuse | control | per_id | 0 | 1 | 11862 | PASS |
| capacity_reuse | data | context | 0 | 1 | 17494 | PASS |
| capacity_reuse | data | per_id | 0 | 1 | 12180 | PASS |
| hol_blocking | control | — | 0 | 1 | 507 | PASS |
| hol_blocking | data | — | 0 | 1 | 519 | PASS |

### 2. Read ROB 關閉

| CASE | MODE | TARGET | BP | SEED | Cycles | 結果 |
|---|---|---|---:|---:|---:|---|
| multi_id_out_of_order | data | — | 0 | 1 | 142 | PASS |
| single_id_reorder | control | — | 0 | 1 | 444 | PASS |
| single_id_reorder | data | — | 0 | 1 | 478 | PASS |
| request_rand | auto | — | 0 | 1 | 1404 | PASS |
| capacity_reuse | control | context | 0 | 1 | 17368 | PASS |
| capacity_reuse | data | context | 0 | 1 | 17427 | PASS |
| reset_recovery | data | — | 0 | 1 | 199 | PASS |

### 3. 小 ROB／單 VC

| CASE | MODE | TARGET | BP | SEED | Cycles | 結果 |
|---|---|---|---:|---:|---:|---|
| multi_id_out_of_order | control | — | 1 | 1 | 2230 | PASS |
| multi_id_out_of_order | data | — | 1 | 1 | 2250 | PASS |
| single_id_reorder | control | — | 1 | 1 | 2374 | PASS |
| single_id_reorder | data | — | 1 | 1 | 2461 | PASS |
| data_write_burst | auto | — | 0 | 1 | 543 | PASS |
| data_read_burst | auto | — | 0 | 1 | 638 | PASS |
| request_rand | auto | — | 0 | 1 | 998 | PASS |
| capacity_reuse | control | rob | 0 | 1 | 17517 | PASS |
| capacity_reuse | data | rob | 0 | 1 | 18698 | PASS |

## 重現與證據

工作站：`/home/mingwei/noc_project/sim/build/integration-regression/`。

- `{baseline,split,robless,small_rob}/results/`：logs、commands、profile、source／stimulus digests。
- 各組 `coverage/accepted.vdb`、`coverage/urg/`：獨立原始資料及 code／functional／assertion reports。
- `functional-urg/`：56-run functional union；`functional-merge.log` 保留 merge 訊息。
- `audit.json`：各組 1423 個 manifest entries、run digests 與 cycles 已核對；傳輸另包含 SHA256SUMS 本身。

本機：[原生 reports](../build/integration-regression/reports/functional-urg/dashboard.html)、[完整來源及驗證紀錄](../build/integration-regression/)。共下載 977 個 report／log 檔案並逐檔核對 SHA256。

```sh
# 例：重現 Split VC 的 random 測試
cd /home/mingwei/noc_project/sim/build/integration-regression/split
make run CASE=request_rand COVERAGE=1

# 例：重現小 ROB 的 data capacity 測試
cd /home/mingwei/noc_project/sim/build/integration-regression/small_rob
make run CASE=capacity_reuse MODE=data TARGET=rob COVERAGE=1
```

工作站主目錄 `sim/` 已同步修正後 source，保留既有 builds／waves／reports。共建立三種必要的 C++ model build；Read ROB 關閉組態共用 Baseline library，主目錄 compile dry-run 也確認不需重編 C++。

Local codegen check、230 Python checks、728 C++ tests 全部通過。未推送遠端 Git。
