# NI 參數組態 Regression 結果

> 歷史紀錄：本頁保留首輪含 direct-link 的結果及當時的 Router 失敗。後續已修正並完成四組整合驗證，請以 [整合驗證總報告](verification-integration-results.md) 作為目前驗收結果；本頁 97.02% 不沿用。

2026-10-03。NMU／NSU RTL 的四組參數驗證；AXI／NoC 維持同頻 1 GHz。
Production RTL、C++ source 與 repository generated contracts 均未修改。
組態定義見 [參數驗證規劃](verification-parameter-plan.md)。

## 功能結果

| 組態 | 環境 | 結果 |
|---|---|---|
| 0. Baseline | NMU RTL → C++ Router → NSU RTL | 沿用既有 29 筆 PASS；另複驗 request_rand，仍為 653 cycles、PASS |
| 1. 窄 ID／小容量／Split VC | Router 整合環境 | request_rand FAIL：Router 將 DataAw 配到 write 接收範圍之外的 VC |
| 1. 同一 NI 組態 | 既有 direct-link 環境 | 11/11 PASS；不能取代上列 Router 整合驗收 |
| 2. 寬 ID／context＝1／Read ROB 關閉 | Router 整合環境 | 7/7 PASS |
| 3. 小 ROB／單 VC | Router 整合環境 | 9/9 PASS |

本輪新增 28 筆通過 run records，另有 1 筆整合失敗。公開 CASE 仍為 18 個。
Baseline 的 568 份 pattern 檔與前輪逐檔一致。

| 組態 | 實際執行項目 |
|---|---|
| 1 direct-link | request_rand；control/data 的 per-ID capacity、context capacity、same-ID/cross-ID reorder＋backpressure、HoL |
| 2 | request_rand；control/data context capacity；control/data single_id_reorder；data multi_id_out_of_order；data reset_recovery |
| 3 | request_rand；control/data ROB capacity；control/data same-ID/cross-ID reorder＋backpressure；data write/read burst |

### 目標事件

- 組態 1：per-ID＝4 的 write/read limit 與 reuse 均命中；四個 NSU 的 AW/AR context full/reuse 均命中。
- 組態 1：control/data same-ID inversion 與同一 response 的 ROB output stall 同時命中；HoL 解除前另一個 destination 已完成 response。
- 組態 2：context＝1 的 full/reuse 命中；control/data same-ID read 皆觀察到 admission wait，之後恢復接受。Read ROB 關閉時未要求不存在的 R storage 事件。
- 組態 3：B ROB＝4、R ROB＝8 均 full/reuse；control/data same-ID inversion/output-stall 關聯均命中。
- 既有 data/order/protocol checks 保持啟用，通過 runs 的 checkers 均正常 drain。

## Split VC 整合失敗

VCS 在 136500 ps 於西側 NSU RX credit buffer 觸發 `invalid channel or VC on DAT ingress`。
UCLI 在 136400 ps 讀到：

| 訊號 | 值 |
|---|---|
| s_dat_valid_i | 1 |
| dat_channel | 5，DataAw |
| dat_vc | 3 |
| DAT_VC_MASK | 0011，僅允許 write VC0／1 |

C++ Router 對 fixed_vc＝0 的 packet 使用 preferred-VC allocation；朝東／西、next-hop LOCAL 的 preferred VC 為 3（mod NUM_DAT_VC）。目前 allocation 沒有依 read/write class 限制 pool，與 NI 的 READ_WRITE_SPLIT 規則不一致。

本輪未修改 Router allocation，也未放寬 NSU 接收檢查。相同 NI 組態以既有 direct-link 複驗通過，證明仍需處理 Router 整合契約；不能將這個組態標為整合 PASS。失敗及 UCLI 中途停止的資料均未納入 accepted coverage。

## Functional coverage

使用原生 URG，僅合併 functional covergroups：

```sh
urg -full64 -metric group -flex_merge union -dir <accepted-vdbs> -report <report-dir> -format both
```

輸入為前輪兩份 accepted VDB，以及本輪四份 accepted VDB。
共 57 筆通過紀錄（29 舊＋28 新，包含 baseline request_rand 的重複確認），merge 無 warning。

| Metric | 前輪 baseline | 跨組態 union |
|---|---:|---:|
| GROUP score | 91.74% | 97.02% |
| Instance score | 91.87% | 97.05% |

GROUP 增加 5.28 個百分點。這是不同組態的 functional coverage 聯集，不代表每個組態各自達到 97.02%，也不代表規格完成率。
不同 VC、容量與 direct-link 會增加／改變被 bind 的 FIFO/credit instances；此聯集範圍比單一 baseline 大。Covergroup 定義未為本輪修改，未以 waiver 或關閉 checker 提高分數。


同名 covergroup 的具體改善（直接讀取原生 report）：

| 項目 | 前輪 | 本輪 union |
|---|---|---|
| 四個 NSU W context full/recovery | 均未命中 | 四個均命中；full/recovery 來自 depth＝1 組態，不代表預設 depth＝32 已滿載 |
| NMU TX VC0 credit group | 96.43% | 100% |
| NSU[1] TX VC0 FIFO group | 50% | 100% |
| NSU[2] RX VC0 FIFO group | 50% | 100% |

原生 report 的 group types 由 60 增為 98，包含新增 VC 與 direct-link 的 bound observers。仍有 44 個起始 byte lanes 未命中（20/64）；NSU[2] W context 的 simultaneous push/pop，以及部分 VC FIFO／credit bins 仍未命中。

## Code coverage

不同參數會改變 storage、generate hierarchy、pointer width 與 coverage objects。
直接跨組態合併出現 CMR-VCINF、UCAPI-INSTANCEMISMATCH、UCAPI-MISSINGINST，工具明確表示部分資料不合併。
因此未採用該次 merged code coverage 數字，保留原始失敗合併紀錄。

| 組態／測試集合 | Line | Condition | Branch | Toggle |
|---|---:|---:|---:|---:|
| 前輪 baseline，29 runs | 85.22% | 81.07% | 82.44% | 78.95% |
| 1 direct-link，11 runs | 84.73% | 76.15% | 80.07% | 74.70% |
| 2 Read ROB 關閉，7 runs | 83.60% | 73.30% | 79.87% | 71.77% |
| 3 小 ROB／單 VC，9 runs | 84.86% | 71.57% | 77.80% | 77.05% |

上表的硬體分母與 case 集合不同，不能用差值判定功能退步或整體 code coverage 提升。
FSM 仍未抽取；本輪未新增 MDA toggle 設定。
Code metrics 限於原有 NMU／NSU hierarchy；assertion／functional reports 的範圍與此不同。

## 實作與檢查

- 增加三份 profile：`sim/profiles/split.yml`、`robless.yml`、`small_rob.yml`；baseline 使用 `sim/profile.yml`。
- VC count/mode、credit depth 同步生成 SV/C++ constants 與匹配的 credit interface package。Active RTL NSU device width 由 TB 選擇，Router 傳輸 NoC ID。
- B/R ROB depth、Read ROB enable 接到既有 Make/TB；容量限制依使用者要求採 2^n。未改 RTL 支援範圍。
- Reorder backpressure 的 prefill 隨 response FIFO depth 調整；baseline stimulus 不變。
- IO_FIFO_DEPTH 沿用既有語意：兩端 AXI CDC FIFOs 與 NMU REQ/RSP FIFOs；NSU REQ/RSP FIFOs 保留預設。REG_TYPE 涵蓋 packetize/depacketize；SAM REG_TYPE 保留預設。
- Codegen clean、230 項 Python checks PASS；所有 accepted SV/SVH snapshots 與目前 source 一致；220 份 production 檔案 digest 未變。
- 各 profile 的 Make 最終預設值推導與實測有效參數／build key 一致。
- 新 VC／credit profile 需要匹配的 C++ build。初次隔離目錄的 YAML header 時間戳造成重編，已以 byte-identical source 核對並保留原 timestamp；後續 baseline 複驗的 C++ compile 次數為 0。沒有改 C++ source。
- 預設 sim/ 與 nsu-standalone/ 已同步，source SHA256 readback 驗證 858／694 files。既有 builds、waves、reports 保留。

## 剩餘範圍與證據

先解決 Split VC 與 Router allocation 契約，再補整合驗收。獨立 clock／phase 尚未執行；相關數值仍為 [TBD]。
Source／NoC ID width 本輪固定 3／3，不能視為所有 ID width 組合驗收。
Byte lane、未命中資源事件、SAM pipeline、其他功能與多 source 仍按原 coverage 缺口規劃，不能由本聯集分數判定完成。

工作站：
`/home/mingwei/noc_project/sim/build/parameter-regression/`

- `functional-urg/`：有效的 57-run functional union report。
- `{baseline,robless,small_rob,split_direct}/coverage/`：各組 accepted VDB、原生 report 與 run provenance。
- `split/results/`：整合失敗與 UCLI 證據。
- `merged-urg/`、`merge.log`：不相容 code merge 嘗試，**不得作為驗收數據**。

本機證據位於 `build/parameter-regression/`；下載的 reports 以 SHA256 核對。
