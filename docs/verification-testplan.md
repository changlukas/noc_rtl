# NI verification testplan

依據：[Verification planning and coverage guidelines](verification-guidelines.md)。

## 範圍與判定

本平台使用 15 個公開 case；目前整合組態為 MODE=auto、seed=1，
`sim/` 包含一個 NMU RTL、單個 C++ Router、四個 NSU RTL 與 AXI memories。
共用 `tb_top` 的 direct-link 環境可使用相同 coverage；本輪不重跑第二套完整矩陣。
NMU-only loopback 的歷史驗證保留，不能當作本輪整合 coverage。
Router RTL、多 NMU source、multihop、physical CDC/RDC 與 synthesis/STA 不在本輪。

- Functional PASS：既有 scoreboard、ordering compare、protocol checks 與完成條件通過。
- Scenario HIT：該 case 列出的必需事件實際發生。
- Scenario MISS：功能通過，但必要事件未發生，該驗證目標尚未完成。
- INVALID：monitor 未完整輸出、request/response 記錄未配對或觀察數與既有計數不一致。
- Functional coverage 目前是事件與值的記錄，不提供誤導性的「整份規格完成百分比」。
- 所有 transaction 覆蓋在實際 handshake 取樣；R inversion 以 RLAST completion 計算，
  不代表 read-beat interleaving coverage。

第一批 baseline 不改 stimulus，結果保留於 `verification-baseline.md`。
第二批只擴充 stimulus；DUT、參數預設、既有 driver/checker 與 C++ model 不變。

## Case 與必要事件

Machine-readable case requirements：[`sim/coverage_plan.json`](../sim/coverage_plan.json)。

| Case | 現有 stimulus／目的 | Coverage observation | 既有 checker |
|---|---|---|---|
| ctrl_write_single | 一筆 control write | AW/B、control destination decode | ordering compare、AXI protocol |
| ctrl_read_single | 一筆 control read；memory preload | AR/RLAST、control decode | scoreboard、ordering compare |
| ctrl_write_burst | 15 筆 control write burst；長度如下 | AW length、size、ID、destination、B 完成數 | ordering compare、SAM checker |
| ctrl_read_burst | 15 筆 control read burst；memory preload | AR length、R 完成數 | scoreboard、ordering compare、SAM checker |
| single_id_outstanding | same-ID 多筆 pending | write/read multiple pending | 既有 min_outstanding、ordering compare |
| multi_id_outstanding | multi-ID 多筆 pending | write/read multiple pending、實際 ID | 既有 min_unique、min_outstanding |
| multi_id_out_of_order | 跨 destination 的不同 ID response 延遲 | B/R cross-ID inversion | ordering compare、scoreboard |
| single_id_reorder | same-ID 跨 destination response 延遲 | B/R same-ID inversion、ROB retirement | ordering compare、scoreboard |
| data_write_single | 一筆 data write | AW/B、data destination decode | ordering compare、AXI protocol |
| data_write_burst | 11 筆 data write burst；長度如下 | AW length、size、ID、destination、B 完成數 | ordering compare、SAM checker |
| data_read_single | 一筆 data read；memory preload | AR/RLAST、data decode | scoreboard、ordering compare |
| data_read_burst | 11 筆 data read burst；memory preload | AR length、R 完成數 | scoreboard、ordering compare、SAM checker |
| ctrl_rand | control random、WSTRB、並行 R/W、readback | control transaction、length/size/ID/destination | scoreboard、ordering compare |
| data_rand | data random、WSTRB、並行 R/W、readback | data transaction、length/size/ID/destination | 同上 |
| request_rand | 混合 control/data random、WSTRB、並行 R/W、readback | 兩種 traffic 的 AW/AR handshake | 同上 |

Control burst length：2/3/4/7/8/15/16/31/32/63/64/127/128/255/256。
Data burst length：2/3/4/7/8/15/16/31/32/63/64。皆為 full-width INCR，
輪流從 SAM 起點、結束於第一個 4 KB 邊界、結束於 SAM 尾端發送。
write burst 不發 read；read burst 使用 memory preload，不發 write。

Random case 的 co-sim/direct profile 發送 64 write 與 64 並行 read，完成後再發
64 readback。讀寫區域互不重疊，write transaction 之間亦不重疊；memory 與
scoreboard 使用相同 preload。WSTRB 包含 full、partial、zero，保留未寫入 byte 的
預期值。NMU-only profile 仍使用既有 synthetic loopback，不宣稱 memory readback。

## Resource 與交互作用觀察

| 功能 | 取樣點／事件 | 本輪邊界 |
|---|---|---|
| FIFO capacity | 已實例化 cc_fifo 的 full、empty、push+pop、full 後再次 push | 不涵蓋所有 CDC FIFO full/recovery；不得以 aggregate 一次命中代表每個 FIFO |
| NSU context | AW/AR context queue 的 full、empty、allocate+retire、full 後 allocate | 分別記錄四個 NSU；不等於所有 source-ID collision 已測 |
| DAT credit | cc_credit_counter 的 zero、zero 時 give、give+take、zero 時 give+take | 分別記錄每個 instance/VC；沒有事件即未命中 |
| ROB | allocation、bypass allocation、由 storage retire | allocation 不等於 response 真的亂序 |
| ROB 空間 | free tail space 為零 | 現有 free_cnt 是連續尾端可配置空間，不能直接稱所有 entries occupied |
| Actual reorder | NMU ordering 接受 AW/AR 的順序，比對進入 ordering 的 B/RLAST identity | 只記錄 inversion，不另寫 data/order correctness checker |
| Outstanding | source AXI pending 數、ordering 有新 request 且已達 per-ID limit | source pending 含前後 FIFO，不等於 ordering 內部容量 |
| Reorder × backpressure | ROB 選出 response 且下游不 ready | 命名為 rob_output_stall；不直接宣稱曾發生 inversion 的同筆 transaction 被 stall |
| Read/write overlap | source pending write 與 read 同時非零 | 不等於兩個方向皆持續傳輸或性能已達標 |
| Reset pending | reset 時 observer 尚有 pending request | 不等於完整 reset recovery；本輪不新增 reset stimulus |
| HoL／公平性 | 第二／三批另建指定 destination/VC 阻塞與 eligible request 觀察 | 一般 stall／多筆 pending 不能算 HoL isolation coverage |

## Checker／assertion audit

| 規則 | 現有實作 | 本輪處理 |
|---|---|---|
| 端到端資料 | axi_scoreboard，read preload；axi_reorder_compare 的 AW/W/AR/B/R 比對 | 沿用 |
| AXI ordering 與 request/response 對應 | axi_reorder_compare、end_of_sim drain | 沿用；另外記錄 actual inversion |
| AXI payload／valid 在 stall 時穩定 | AXI_BUS_DV interface assertions；TB B/R stable assertions | 沿用；memory-side AXI_BUS 沒有相同完整 interface assertion 集合，列後續補強 |
| FIFO overflow／underflow | cc_fifo full_write/empty_read assertions | 沿用；被動 bind monitor 記錄 antecedent 所需狀態 |
| Credit overflow／underflow | cc_credit_counter CreditOverflow/CreditUnderflow | 沿用；記錄 zero/give/take 條件 |
| DAT channel/VC 合法性、RX/TX overflow | rx_credit_buffer、tx_credit_buffer runtime checks | 沿用 |
| ROB allocation bounds、idle outputs、completed payload X | nmu_reorder_storage runtime checks | 沿用；尚無完整 allocate/retire invariant closure |
| NSU B/R context 存在、burst context | nsu_context_buffer runtime checks | 沿用 |
| SAM／4 KB／burst legality | ni_sam 與 nmu_sam_burst_checker | 沿用；negative tests 的歷史紀錄不計本輪 coverage |
| Packet lock、仲裁 fairness、no-avoidable-bubble | 部分歷史 focused tests；未形成完整整合 assertion suite | 明確列後續驗證，不因資料返回正確而判完成 |

第一批盤點的主要 primitive 規則已有 assertion，因此不重複新增相同 checker。
VCS assertion coverage 與功能事件共同檢視；未觸發的 assertion 不能當作已驗證其情境。

## Code coverage 與重現

`COVERAGE=1` 是既有 run/regress 的可選觀察模式，預設關閉。
`sim/script/coverage.hier` 限定 NMU 與四個 NSU hierarchy（含實際使用的 primitive），
排除 coverage monitor；TB、memory、C++ Router 與未實例化的 library module 不列入 code metrics。
DUT hierarchy 內啟用的 SAM simulation checker 與 runtime guards 仍在本輪統計內。
Line/condition/FSM/toggle/branch/assertion 分開檢視，不合併成邏輯完整性單一百分比。
VCS 預設不含 multidimensional-array toggle；本輪不宣稱 payload memory 每個 bit 已完成 toggle。
實測 VCS 2017 的 assertion 報告仍包含 TB/interface/package assertions；
因此 code metrics 與全設計 assertion 結果分開報告，不使用混合 SCORE 當完成度。

每個 case 輸出 log 與 coverage JSON，含 binary、mode、command、source manifest digest、
profile 與實際 stimulus digest。VDB 保留在對應 content-addressed SV build 中。
比較不同參數時分組檢視，不將某一組態的 coverage 當作另一組已驗證。

分類 uncovered item：
1. 缺少 stimulus／事件未觸發。
2. 固定參數下不可達。
3. 規格不支援。
4. 已由其他環境驗證（必須附證據）。
5. 需要檢查的 RTL 邏輯。

本輪不預先加入 waiver，也不設定未經討論的 coverage signoff 百分比。

## 後續批次

目前 NSU ID 映射使用固定 key folding；context full 不等於動態 ID mapping table 用滿。
後續 ID 相關 coverage 應涵蓋不同 source identity／NoC ID 映到相同 device ID，
以及相對應 context 的保存與退休。本輪單 NMU、相同 ID width 不宣稱完成 collision coverage。

第二批已補 burst 邊界、非 2 次方長度、random write strobe 與並行 R/W，並分開 burst read/write。
結果見 [Stimulus expansion acceptance](verification-stimulus-results.md)。
Capacity/reuse 仍待補強，各容量測試需依當次參數判定真正限制資源。
WSTRB full/partial 的 active-lane monitor 分類亦未完成。

第三批：HoL destination blocking、reorder+backpressure、capacity recovery、
reset recovery、concurrent read/write。既有 directed 性能測試維持無額外 stall。
整合 reset contract 先確定後再實作。

第四批：代表性 ID／FIFO／context／ROB／REG_TYPE／clock 組態、多 seed、
coverage gap closure。不做所有參數的盲目 Cartesian product。
