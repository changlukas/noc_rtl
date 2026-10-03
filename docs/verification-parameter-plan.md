# NI 參數驗證組態

採用現有 baseline 加 3 組代表性組態，沿用目前 test cases。所有容量／深度設定僅使用 2^n；context depth＝1 為 2^0。不規劃非 2 次方容量測試。REG_TYPE 與 mode 是功能選擇，不屬於容量限制。

本文件記錄核准的測試組態；同頻 regression 已執行，結果與 Split VC 整合限制見文末連結。RTL 預設值未修改；未列出的參數維持 baseline。

## 硬體組態

| 組態 | 參數設定 | 主要驗證 |
|---|---|---|
| 0. Baseline | Source／NoC／Device ID width＝3／3／3；MAX_OUTSTANDING_PER_ID＝32；CONTEXT_DEPTH＝32；IO_FIFO_DEPTH＝32；B_ROB_DEPTH＝128；R_ROB_DEPTH＝128；R_ROB_EN＝1；REG_TYPE＝0；NUM_DAT_VC＝2；SHARED；CREDIT_DEPTH＝8 | 同寬 ID、一般容量、register bypass、SHARED 多 VC；沿用既有結果 |
| 1. 窄 ID／小容量／Split VC | DEVICE_ID_WIDTH＝1；CONTEXT_DEPTH＝4；MAX_OUTSTANDING_PER_ID＝4；IO_FIFO_DEPTH＝4；REG_TYPE＝2；NUM_DAT_VC＝4；READ_WRITE_SPLIT；CREDIT_DEPTH＝2 | ID collision、context reuse、per-ID admission limit、spill register、read/write VC 分流與仲裁 |
| 2. 寬 ID／單筆 Context／關閉 Read ROB | DEVICE_ID_WIDTH＝8；CONTEXT_DEPTH＝1；IO_FIFO_DEPTH＝4；REG_TYPE＝1；R_ROB_EN＝0 | 寬 ID 還原、depth＝1 邊界、simple register、無 Read ROB 時的 ordering |
| 3. 小 ROB／單 VC | B_ROB_DEPTH＝4；R_ROB_DEPTH＝8；NUM_DAT_VC＝1；SHARED；CREDIT_DEPTH＝2；CONTEXT_DEPTH／MAX_OUTSTANDING_PER_ID 維持 32 | ROB full/reuse、R burst 空間不足、單 VC 仲裁與 credit backpressure |

小 ROB 組態保留較大的 context／per-ID 容量，避免上游先阻塞，使 ROB 無法填滿。若某目標事件被其他限制擋住，僅針對該缺口拆出補測組態。

## Case 選擇

| 組態 | 主要 case |
|---|---|
| 1 | request_rand、capacity_reuse TARGET=per_id、capacity_reuse TARGET=context、single_id_reorder／multi_id_out_of_order BACKPRESSURE=1、hol_blocking |
| 2 | request_rand、capacity_reuse TARGET=context、single_id_reorder、multi_id_out_of_order、reset_recovery |
| 3 | capacity_reuse TARGET=rob、single_id_reorder／multi_id_out_of_order BACKPRESSURE=1、data_write_burst、data_read_burst、request_rand |

各組先同頻通過，再追加 CDC 時序。不重跑所有 18 cases。

## CDC 時序

| 硬體組態 | Clock 設定 | 驗證重點 |
|---|---|---|
| 1 | AXI 比 NoC 快，且有 phase offset；頻率／phase [TBD] | Request CDC FIFO 累積與 backpressure |
| 2 | NoC 比 AXI 快，且有 phase offset；頻率／phase [TBD] | Response CDC FIFO 累積與 backpressure |

沿用 request_rand、適用的 ordering＋backpressure、reset_recovery。Clock 分離與取樣需先接入共用 TB。

## 執行條件

1. Stress stimulus 依組態調整。目前 reorder＋backpressure 固定 31 筆 prefill，對應原本 32-depth response FIFO；小 FIFO 不直接照搬。
2. 小 R ROB 的需重排 burst 不超過可容納的 beats；以多筆合法交易觸發剩餘空間不足與恢復。一般 bypass burst 不以 ROB 容量一律限縮。
3. R_ROB_EN＝0 時確認同 ID read 順序、必要的 request admission stall 與恢復，不要求不存在的 R storage full 或同 ID R response inversion。
4. 組態 2 要實際形成同 ID 跨 destination pending requests，避免 context＝1 遮蔽 NMU ordering 等待條件。
5. Device ID、context、FIFO、REG_TYPE 已有 Make/TB 選項；ROB、VC、credit 必須一致地接到相依電路。Generated contract 與 C++ Router 使用匹配組態及 build，未變更的 C++ cache 繼續沿用。
6. 各組態分開保存 report／VDB、參數、source digest、stimulus 與 seed，避免相同 case 覆寫結果。不同 elaboration 先各自分析，確認資料庫相容後再彙整。

## 驗收範圍

每組須通過既有 data／ordering／protocol checks，並確認目標 bins 實際命中。涵蓋 REG_TYPE＝0／1／2、Device ID 窄／相同／寬、context depth＝1／4／32、per-ID limit、ROB full/reuse、Read ROB enabled／disabled、單／多 VC、SHARED／READ_WRITE_SPLIT、credit backpressure 及獨立 clocks。

參數測試不等於完整 functional coverage；byte lane、W context full、其他未命中分支仍須依報告補 stimulus。不預先承諾 coverage 百分比。

## Regression status

The same-clock campaign is complete. Split-VC Router integration failed; the same NI profile passed direct-link tests. Independent-clock tests remain pending. See [results](verification-parameter-results.md).
