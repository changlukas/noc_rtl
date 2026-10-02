# 驗證規劃與 Coverage 指引

有。成熟 DV 流程常見的做法是：**定義要驗到的情境、量測 DUT 是否真的遇到，再確認對應行為正確。** case PASS、functional coverage、code coverage 是不同的證據。[OpenTitan DV methodology](https://opentitan.org/book/doc/contributing/dv/methodology/index.html)

以目前 NI／Router 平台，我認為以下最有價值。

**1. Functional coverage：確認情境真的發生**

建議沿用現有 15 個 case，增加這些觀察點：

| 項目 | 值得涵蓋的條件 |
|---|---|
| AXI transaction | control／data、read／write、single／burst、支援的 size／burst type |
| Burst／address | 最小、最大、非 2 次方 length；接近 4 KB 與 SAM region 邊界的合法存取 |
| Write strobe | full、partial、zero strobe，以及不同 byte lane |
| Outstanding | 1 筆、多筆、達容量上限、完成後重新接受 |
| Ordering | same／different ID、same／different destination、實際發生亂序、ROB bypass／reorder |
| Buffer／credit | empty、full、同 cycle enqueue/dequeue；credit 耗盡、回補、送出與回補同 cycle |
| Arbitration／HoL | 多個 eligible request 同時競爭、一股流量阻塞而另一股仍可前進 |
| Reset recovery | 有 pending transaction／buffer 非空時 reset，之後 fresh traffic 正常完成 |

涵蓋範圍以目前規格支援的功能為準。例如 unsupported AXI burst type 不應為了 coverage 而硬加進正向測試。

**重點是從 monitor 觀察實際 handshake 與內部事件。** pattern 檔案產生了 64 筆 request，只能證明「有準備 stimulus」，不能證明 64 筆都被接受、完成，也不能證明 ROB 或 credit full 曾經發生。

**2. Cross coverage：確認功能組合有一起發生**

單獨驗過兩個功能，不代表它們同時發生時也正確。例如：

| 組合 | 要回答的問題 |
|---|---|
| Reorder × backpressure | response 亂序且 AXI 暫停接收時，順序是否仍正確？ |
| ID remap × capacity full | mapping 用滿後，釋放與重用是否正確？ |
| Read × write 並行 | 兩個方向同時繁忙時，是否互相造成非預期阻塞？ |
| VC contention × credit return | 多個 VC 競爭，且當 cycle 回補 credit 時，仲裁是否正確？ |
| Reset × pending traffic | 有未完成 transaction 時 reset，是否殘留舊 response？ |

先挑有硬體交互作用的組合即可，避免把所有參數做完整 Cartesian product。

**3. Code coverage：找出 RTL 沒有被走到的部分**

常見會看：

- **Branch／condition coverage：**控制判斷的不同結果是否發生。
- **FSM state／transition coverage：**狀態與轉移是否被走到。
- **Toggle coverage：**訊號是否發生切換。
- **Line coverage：**程式碼是否執行過。

漏掉的項目要分類：缺少 stimulus、目前組態不可達、規格不支援，或 RTL 有多餘邏輯。排除項目需留下理由；高 coverage 百分比本身不等於功能正確。[Coverage collection 與 exclusions](https://opentitan.org/book/doc/contributing/dv/methodology/index.html#coverage-collection)

**4. Assertions：檢查每個 cycle 的規則**

端到端 scoreboard 適合檢查結果，assertions 適合抓第一個違反規則的位置。例如：

- `valid && !ready` 時，valid／payload 保持穩定。
- FIFO 不 overflow／underflow。
- credit 不超出容量、不在無 credit 時送出。
- 同一筆 transaction 不重複 allocate／retire。
- packet lock、AXI ordering 遵守規格。

目前已有部分 assertions，可以先盤點缺口。另加對應的 `cover property`，確認 assertion 的觸發條件真的發生，避免整場沒有遇到該情境卻看起來全部通過。

**5. Random regression 與參數組態**

常見方式是讓同一個 case 跑不同 seed、時序停頓與硬體組態。公開 AXI 測試也會掃 address offset、transfer length、idle／backpressure，以及不同 port／data width。[AXI crossbar tests](https://github.com/alexforencich/verilog-axi/blob/master/tb/axi_crossbar/test_axi_crossbar.py)

我們可以挑代表性組態：

- ID width：壓縮、相同、擴展。
- FIFO／context／ROB：合法最小值、一般值、容易觸發 full 的組態。
- 支援的 ROB mode、REG_TYPE。
- AXI／NoC：同頻、不同頻率與 phase。

每次失敗保留 **commit、參數、seed、實際 pattern、log**，才能重現；coverage 則彙整各次執行結果。

**我建議目前先做三件事：**

1. 建立「規格功能 → case → checker → coverage point」對照表。
2. 補上 **實際乱序、容量 full/recovery、並行 read/write、HoL** 的事件覆蓋。
3. 開啟一次目前 15-case regression 的 RTL code coverage，先看真正的缺口，再決定增加哪些 seed／組態。

這樣可以向主管具體回答：「哪些功能已驗到、哪些條件未觸發、哪些範圍尚未驗證」，也能保留目前簡單的 TB 與操作方式。
