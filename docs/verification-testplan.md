# NI verification testplan

依據：[Verification planning and coverage guidelines](verification-guidelines.md)。

## 範圍與判定

整合平台：一個 NMU RTL、單個 C++ Router、四個 NSU RTL 與 AXI memories。
Direct-link 平台共用 tb_top、pattern 與 checker，不包含 C++ Router。
NMU-only loopback 保留既有驗證，尚未移植這份 covergroup model。

- Functional PASS：既有 scoreboard、axi_reorder_compare、protocol checks 與完成條件通過。
- Functional coverage：SystemVerilog covergroup／coverpoint／cross，由 VCS 寫入 VDB，URG 或 Verdi Coverage 檢視。
- Code coverage：VCS 的 line／branch／condition／toggle／FSM，與 functional coverage 分開報告。
- Bin 命中只代表情境發生，不代表結果正確；case PASS 也不代表所有 bin 已命中。
- 不設定自製 HIT／MISS 判定或規格完成百分比。工具百分比的分母是目前定義的 bins。

## 既有 15 個 case

| Case | 測試內容 | 主要 checker |
|---|---|---|
| ctrl_write_single | 一筆 control write | ordering compare、AXI protocol |
| ctrl_read_single | 一筆 control read；memory preload | scoreboard、ordering compare |
| ctrl_write_burst | 15 筆 control write burst | ordering compare、SAM checker |
| ctrl_read_burst | 15 筆 control read burst；memory preload | scoreboard、ordering compare、SAM checker |
| single_id_outstanding | same-ID 多筆 pending | min_outstanding、ordering compare |
| multi_id_outstanding | multi-ID 多筆 pending | min_unique、min_outstanding、ordering compare |
| multi_id_out_of_order | 不同 ID、跨 destination 的 response 亂序 | ordering compare、scoreboard |
| single_id_reorder | same-ID、跨 destination 的 response 亂序 | ordering compare、scoreboard |
| data_write_single | 一筆 data write | ordering compare、AXI protocol |
| data_write_burst | 11 筆 data write burst | ordering compare、SAM checker |
| data_read_single | 一筆 data read；memory preload | scoreboard、ordering compare |
| data_read_burst | 11 筆 data read burst；memory preload | scoreboard、ordering compare、SAM checker |
| ctrl_rand | control random、WSTRB、並行 R/W、readback | scoreboard、ordering compare |
| data_rand | data random、WSTRB、並行 R/W、readback | 同上 |
| request_rand | 混合 control/data random、WSTRB、並行 R/W、readback | 同上 |

Control burst length：2/3/4/7/8/15/16/31/32/63/64/127/128/255/256。
Data burst length：2/3/4/7/8/15/16/31/32/63/64。
皆為 full-width INCR，涵蓋 SAM 起點、4 KB 尾端、SAM 尾端，不跨界。

Random 在 co-sim/direct profile 發送 64 write 與 64 並行 read，完成後 64 readback。
讀寫區域與各 write transaction 的地址互不重疊；memory 與 scoreboard 使用相同 preload。
這次 covergroup 遷移不修改上述 stimulus。

## Functional coverage model

實作：sim/dv/ni_coverage.svh、sim/dv/ni_resource_coverage.sv。
各 covergroup 使用 option.per_instance = 1，避免以某個 instance 命中代替其他 instance。

| Covergroup | Sample 條件／coverpoint | Cross／限制 |
|---|---|---|
| transaction_cg | Source AW/AR handshake：方向、control/data、ID、代表性 length、size、INCR、destination | direction × traffic／length／destination；目前整合 memory profile 只用 INCR |
| write_strobe_cg | W handshake：WSTRB 為 1 的 bit 數，含 zero | 尚未依 AW active byte lanes 分類 full/partial |
| outstanding_cg | Source AXI pending：idle、single、multiple | read pending × write pending；不是 ordering 內部容量 |
| ordering_cg | Ordering ingress 的 B／RLAST arrival，相對仍 pending 的較早 request | direction × same-ID inversion／cross-ID inversion；不是 read-beat interleaving |
| rob_cg | B/R 各一個 instance：bypass/reorder allocation、storage retire、無 tail space、per-ID limit、AXI/output stall | free_cnt 為零不代表所有 ROB entries occupied；output stall 不等於該筆曾發生 inversion |
| reset_cg | Reset 時是否仍有 ordering pending records | 僅 pending-reset 情境，不代表完成 reset recovery |
| fifo_cg | 每個 cc_fifo 與 NSU AW/AR context：full、empty、push+pop、full 後恢復接受 | 不涵蓋全部 CDC FIFO；依 instance 檢查 |
| credit_cg | 每個 credit counter：available、give、take | 三者 cross；排除無 stored credit、無 give 卻 take 的非法組合，仍由 primitive assertion 檢查 |

Sampling 的 pending count、request identity queue、full_seen 只用於辨識情境。
覆蓋次數、bins、cross 與百分比由 simulator 管理，不再維護事件計數字典或 Python coverage parser。
Monitor 無法配對 response 或結束時尚有 records 會報錯，避免把不完整觀察當成有效 coverage。

## Assertions 與 code coverage

保留 AXI stability assertions、FIFO overflow/underflow、credit overflow/underflow、
DAT VC 合法性、ROB allocation/idle checks、NSU context checks、SAM／4 KB legality checks。
不新增重複的 data/order checker。

COVERAGE=1 啟用 coverage，預設關閉。coverage.hier 將 code metrics 限定在
NMU 與四個 NSU hierarchy（含 primitive），排除 coverage monitor。
DUT hierarchy 內的 SAM simulation checker 與 runtime guards 仍在 code metrics 中。
VCS 預設不含 multidimensional-array toggle；FSM 無抽取結果不等於 100%。
舊版 VCS 的 assertion report 仍包含 TB/interface/package，與 DUT code metrics 分開解讀。

Run log 與 .run.json 保留 command、profile、source manifest digest、stimulus digest、VDB 路徑。
.run.json 只記錄重現資訊，不計算 coverage。使用 URG 的原生 group／instance／bin 報告檢查缺口。
舊事件計數報告保留為歷史證據，不能與新的 covergroup 百分比直接比較。

## 尚待規劃／補強

- Capacity full/reuse：依當次參數確認真正限制資源；context full 不等於動態 ID mapping table 用滿。
- HoL isolation、仲裁 fairness、no-avoidable-bubble，以及 reorder × backpressure 的同筆 transaction 關聯。
- 整合 reset recovery、獨立時脈 CDC、代表性 ID／FIFO／context／ROB／REG_TYPE 組態與多 seed。
- Active-lane strobe 分類、完整 supported response-error coverage、其他必要 functional crosses。
- 多 NMU source、Router RTL、multihop、physical CDC/RDC、synthesis/STA 不在目前平台驗收範圍。

未命中的 bin 需區分缺 stimulus、組態不可達、規格不支援或 RTL 問題；不因數值低就直接 waiver。
歷史 baseline 與 stimulus 擴充結果分別見 verification-baseline.md、verification-stimulus-results.md。
