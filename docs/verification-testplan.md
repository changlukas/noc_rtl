# Module: NI

## Verification Scope

驗證對象為 NMU／NSU RTL。正式平台為一個 NMU、單個 C++ Router、四個 NSU 與 AXI memories。Standalone／direct-link 供 debug，未列入本報告的 accepted coverage。

本 plan 沿用 [OpenHW AXI plan](https://github.com/openhwfoundation/cva6/blob/master/verif/docs/VerifPlans/source/dvplan_AXI.md) 的欄位與訊號式描述。Item 的 Coverage Method 是驗證需求，Link to Coverage 記錄現有實作與缺口。[Report](verification-integration-results.md) 列出逐項證據。[Guidelines](verification-guidelines.md) 定義維護規則。

Generic AXI 使用 [AMBA AXI specification](https://developer.arm.com/documentation/ihi0022/hc) 的 channel、burst、response 與 ordering 定義。NI 介面參考 [NMU top](../rtl/nmu/top/nmu.sv)、[NSU top](../rtl/nsu/top/nsu.sv)、[packet contract](../specgen/generated/json/ni_packet.json)。NI release specification 的版本／章節定位為 `[TBD]`。以下依現行 RTL 記錄行為，尚未將 RTL reference 視為已核准的 release specification。

## Interface Notation

| 名稱 | 觀察位置 |
|---|---|
| Source AXI | NMU `axi_wr_i`／`axi_rd_i` |
| Device AXI | 每個 NSU `axi_wr_o`／`axi_rd_o` |
| AXI fields | 使用標準大寫名稱，例如 `AWID`。實際 interface 成員見 [axi_if.sv](../rtl/common/axi_if.sv) |
| NMU NoC | `tx_req_*`、`rx_rsp_*`、`tx_dat_*`、`rx_dat_*` |
| NSU NoC | `rx_req_*`、`tx_rsp_*`、`tx_dat_*`、`rx_dat_*` |
| Clock／reset | 各 NI 的 `ACLK`／`ARESETn`、`noc_clk`／`noc_rst_n` |

`Ax` 表示 AW 或 AR。所有 transaction counts 以 handshake 計算。DAT 使用 `*_dat_valid_*`、flit VC 與 `*_dat_crdvalid_*`，沒有 ready port。下列 goals 均以這些 top-level interfaces 為觀察邊界。

## NI Verification Functions

| 功能 | 要驗證的行為 | Item |
|---|---|---|
| Address decoding / translation | Request 送到正確 NSU，local address 正確 | NI-01 |
| Packetization / depacketization | AXI 與 NoC 轉換後，欄位、資料與 beat 配對正確 | NI-02 |
| ID mapping / ordering | ID 還原、request 次序與 response 次序符合規則 | NI-03/07、AXI-07 |
| Flow control | Buffer 不足、無 credit 或下游等待時不遺失資料，解除後繼續傳輸 | NI-04/05/06 |
| Arbitration | 競爭時依規則送出，不破壞 packet 與 ordering | NI-10 |
| Clock / reset | 不同 clock 下交易正確，reset 後可恢復運作 | NI-08/09 |

功能分類參考 *On-Chip Networks, Second Edition* 第 5 章 Flow Control、第 6 章 Router Microarchitecture，及本機 ordering 知識整理。實際 channel、VC 與 ordering 規則依本專案 RTL 核對，沒有套用書中的 router 架構。

## Feature: Generic AXI Functional Coverage

### Sub-feature: Burst Transfers

#### Item: AXI-01

- **Requirement Location:** AXI4：Burst type、length、LAST。
- **Feature Description:** INCR 使用 `AxBURST=2'b01`，每筆 transaction 有 `AxLEN+1` beats。
- **Verification Goals:** 測 single、最小／最大 burst 與中間 lengths。Control full-width 為 1～256 beats，data full-width 為 1～64 beats。
- **Pass/Fail Criteria:** 每筆 AW 有 AWLEN+1 個 W handshakes 與一個 B response。每筆 AR 有 ARLEN+1 個 R handshakes。WLAST／RLAST 只出現在最後一拍。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0 完整 length sweep，其他組態為選定 lengths
- **Link to Coverage:** `transaction_cg.cp_burst`、`cp_beats`、`direction_length`。完整 length sweep 另有 transaction／completion records。

### Sub-feature: Transfer Size and Address

#### Item: AXI-02

- **Requirement Location:** AXI4：Transfer size、byte lanes、4 KB boundary。
- **Feature Description:** `2**AxSIZE` 為每 beat bytes。此次測試使用 aligned address，INCR burst 不跨 4 KB。
- **Verification Goals:** Control 掃 AxSIZE=0～3，data 掃 AxSIZE=0～6。測合法起始 byte lanes、4 KB 起點及尾端。
- **Pass/Fail Criteria:** Device AxADDR／AxSIZE／AxLEN 符合預期 request，read data 與預載資料一致。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0 lane sweep，C0～C6 選定 traffic
- **Link to Coverage:** `transaction_cg.cp_size`、`boundary_cg.page_boundary`。Read lane 與完整 size × lane 組合未獨立計量。

### Sub-feature: Write Strobes

#### Item: AXI-03

- **Requirement Location:** AXI4：Write strobes。
- **Feature Description:** `WSTRB[b]=1` 更新 byte b，`WSTRB[b]=0` 保留原值。
- **Verification Goals:** 測 full、partial、zero 與 one-hot WSTRB，涵蓋合法 byte lanes。
- **Pass/Fail Criteria:** Device WDATA／WSTRB 與 Source 相符。Readback 逐 byte 比對，包含 WSTRB=0 的 bytes。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0 strobe sweep，其他組態 random
- **Link to Coverage:** `write_strobe_cg.cp_strobe`、`cp_lane`、`cp_size`、`strobe_size`。1-byte transfer 無 partial strobe。

### Sub-feature: Handshake and Backpressure

#### Item: AXI-04

- **Requirement Location:** AXI4：Channel handshake、VALID stability、AW/W independence。
- **Feature Description:** AW/W/B/AR/R 以 VALID && READY 傳送。VALID=1、READY=0 時，VALID 與 payload 保持不變。AW、W 獨立握手。
- **Verification Goals:** 各 channel 測無 stall、stall、解除 stall。AW/W 測 AW-first、W-first、同 cycle handshake。
- **Pass/Fail Criteria:** 等待期間訊號穩定。解除 stall 後，每筆資料只被接受一次，transaction 能完成。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Assertion Coverage / Functional Coverage。
- **Applicable Configurations:** C0/C1 ordering + BACKPRESSURE=1，其他組態依 records
- **Link to Coverage:** AXI protocol checks。Device AXI 的 `aw_stall_recover`、`w_stall_recover`、`ar_stall_recover` 見 tb_top.sv。AW/W 相對時序尚無 bins。

### Sub-feature: Response Codes

#### Item: AXI-05

- **Requirement Location:** AXI4：Write/read response codes。
- **Feature Description:** Device BRESP／RRESP 必須隨對應 transaction 傳回 Source。
- **Verification Goals:** Read/write 各測 OKAY、SLVERR、DECERR，包含 single 與 burst。每個 R beat 都檢查 RRESP。
- **Pass/Fail Criteria:** Source BRESP／RRESP 等於 Device 回覆，BID／RID 對應正確 request。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0 error variants，C0～C6 OKAY
- **Link to Coverage:** `response_cg.cp_resp`、`response_type`。EXOKAY 尚未納入。

### Sub-feature: Outstanding Transactions

#### Item: AXI-06

- **Requirement Location:** AXI4：Transaction IDs、outstanding requests。
- **Feature Description:** AW 到 B 之間為一筆 pending write。AR 到最後一拍 R 之間為一筆 pending read。Read/write 分別計數。
- **Verification Goals:** 測單筆與多筆 outstanding、same-ID 與 multi-ID，以及 read/write 同時 pending。
- **Pass/Fail Criteria:** 每個已接受的 write 收到一次 B，每個 read 收到完整 R beats。全部完成後 pending count=0。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0～C6 選定 outstanding／random cases
- **Link to Coverage:** `outstanding_cg.cp_write`、`cp_read`、`read_write`，以及 `transaction_cg.cp_id`。

### Sub-feature: Response Ordering

#### Item: AXI-07

- **Requirement Location:** AXI4：Same-ID response ordering、ordering across IDs。
- **Feature Description:** Same-ID write responses 依 AW 次序返回。Same-ID read transactions 依 AR 次序返回。不同 IDs 允許亂序。Read/write 各自保序。
- **Verification Goals:** 讓較晚的 request 先收到 Device response。測 same-ID／different-ID，並加入 Source BREADY／RREADY stall。
- **Pass/Fail Criteria:** Source same-ID responses 與原 request 順序一致，資料與 response code 屬於正確 transaction。不同 ID 不強制全域排序。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0～C6 選定 ordering cases
- **Link to Coverage:** `axi_reorder_compare`。`ordering_cg` 的到達次序取自內部 ordering ingress，外部到達次序的 coverage 尚未建立。

## Feature: NI-Specific Functional Coverage

### Sub-feature: Address Decoding and Translation

#### Item: NI-01

- **Requirement Location:** SAM 設定、NMU／NSU top-level AXI 與 NoC packet fields。
- **Feature Description:** Source AxADDR 經 SAM 決定 destination、control/data path 與 Device local address。
- **Verification Goals:** 測每個 SAM region 的起點、尾端及區間內位址，比對實際收到 request 的 NSU。
- **Pass/Fail Criteria:** 只有目標 NSU 接受 request。Device AxADDR 等於 SAM 定義的 local address。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0 邊界 sweep，C0～C6 選定 traffic
- **Link to Coverage:** `transaction_cg.cp_destination`、`direction_destination`、`boundary_cg.sam_first/sam_last` 與端到端 checker。

### Sub-feature: Packetization and Depacketization

#### Item: NI-02

- **Requirement Location:** Packet format、channel mapping，見下方 AXI to NoC Mapping。
- **Feature Description:** AXI AW/W/AR/B/R 依 control/data path 轉成 NoC packets，接收端還原 AXI transaction。
- **Verification Goals:** 逐項測 mapping 表。比對 address、ID、length、size、burst、WDATA、WSTRB、RDATA、response code 與 LAST。
- **Pass/Fail Criteria:** NoC channel 與 packet type 正確。Device W beats 對應其 AW，read beats 次序及總數符合 ARLEN，沒有跨 transaction 配錯資料。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0～C6
- **Link to Coverage:** 端到端 checker、`transaction_cg.direction_traffic`。Packet-type／REQ-DAT 同時傳輸尚無專用 bins。

### Sub-feature: ID Mapping

#### Item: NI-03

- **Requirement Location:** NSU Device ID mapping、Source response ID，implementation reference：nsu_context_buffer.map_id。
- **Feature Description:** NSU 將 request ID 轉成 Device AXI ID，response 返回時還原 Source ID。
- **Verification Goals:** 測窄、等寬、寬 Device ID。窄 ID 時讓不同 Source IDs 對應同一 Device ID，並同時保留多筆 pending。
- **Pass/Fail Criteria:** 每筆 B/R 回到原 Source ID，資料與 request 一致。Device ID 重複使用不造成 response 配錯。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C1/C0/C2 Device width 1/3/8，C5/C6 Source width 1/8
- **Link to Coverage:** `transaction_cg.cp_id` 與端到端 checker。ID mapping 組合目前由選定組態／transactions 留存。

### Sub-feature: Buffer Backpressure

#### Item: NI-04

- **Requirement Location:** NMU outstanding／reorder capacity、NSU AW/AR context capacity。
- **Feature Description:** 可用儲存空間不足時暫停 request，response 完成並釋放空間後恢復接受。
- **Verification Goals:** 持續送出 request 並延遲 responses，形成 backpressure。分別測 write、read 與需要重排的 transactions，再恢復 responses。
- **Pass/Fail Criteria:** 已接受的 requests 不遺失。恢復 responses 後能接受新 request，所有 transactions 最終完成。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0～C3 capacity_reuse，C4～C6 選定變體
- **Link to Coverage:** `stress_cg`、`rob_cg`、`fifo_cg`。精確 full/reuse 證據來自內部觀察，不能僅由 AXI stall 判定哪個 buffer 滿載。

### Sub-feature: Credit-Based Flow Control

#### Item: NI-05

- **Requirement Location:** DAT link 的 per-VC credit，implementation reference：tx_credit_buffer／rx_credit_buffer。
- **Feature Description:** DAT 每送出一個 flit 消耗該 VC 一個 credit。每個 crdvalid[v] 回補一個 credit。Reset 初始值為 CREDIT_DEPTH。
- **Verification Goals:** 各 VC 測 credit 可用、耗盡、回補及 send/return 同 cycle。另核對 flit 的 VC 在允許的 read/write pool 內。
- **Pass/Fail Criteria:** 無 credit 且當 cycle 無回補時，不得送出該 VC 的 flit。Credit 不超出 0～CREDIT_DEPTH，回補後可繼續傳輸。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0～C6，C1 split，C3/C4 單 VC
- **Link to Coverage:** 內部 `credit_cg` 與 credit assertions。Top-level valid／VC／crdvalid 的獨立 credit 計帳尚未實作。

### Sub-feature: Backpressure

#### Item: NI-06

- **Requirement Location:** 選定的不同 ID／destination 測試情境，case：hol_blocking。
- **Feature Description:** 一個 destination 延遲 response 時，另一個 destination 的不同 ID transaction 仍可完成。
- **Verification Goals:** Device A 暫不送出 B／R。Device B 使用不同 AXI ID 並正常回覆，Source BREADY／RREADY 允許接收。
- **Pass/Fail Criteria:** 在 A 恢復回覆前，Source 收到 B 的 B response 與 R data。A 恢復後，所有 transactions 完成。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0/C1/C4 hol_blocking
- **Link to Coverage:** `stress_cg.direction_hol_progress` 與 stress checks。現有 pattern 先發送 B 的 request，未驗證被阻塞 request 後方的流量能否通過同一 queue。

### Sub-feature: Request Ordering

#### Item: NI-07

- **Requirement Location:** NI 同 Source ID／destination／control-data region 的 request ordering。
- **Feature Description:** Same-ID、同 destination、同 control/data region 的 requests 保持次序。不同 region 可超車。Write 與 read 分別檢查。
- **Verification Goals:** 測 same-ID 到相同／不同 destinations，以及同 destination 的 control/data requests。R_ROB_EN=0/1 都要測。
- **Pass/Fail Criteria:** Device AW 與 AR 各自符合上述 request 次序。Source B/R 仍符合 AXI-07。R_ROB_EN=0 時允許延遲發出 request 以維持 read order。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0/C1/C3/C5/C6 開啟，C2/C4 關閉
- **Link to Coverage:** 端到端 `axi_reorder_compare` 與組態 records。既有 `ordering_cg` 量測 response 到達次序，未獨立量測所有 request-ordering 組合。

### Sub-feature: Clock Domain Crossing

#### Item: NI-08

- **Requirement Location:** NI top-level：ACLK、noc_clk。
- **Feature Description:** AXI 與 NoC 使用獨立 clock。資料跨 clock domain 後，transaction 內容與順序必須保持。
- **Verification Goals:** 測同頻、AXI 較快、NoC 較快與 phase offset，加入 burst、outstanding、response stall。
- **Pass/Fail Criteria:** 兩端接受／完成數相符，WDATA／RDATA 與 ordering checks 通過。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0 T0/T1/T2
- **Link to Coverage:** T0/T1/T2 run records 與既有 checkers。Functional simulation 不涵蓋 metastability／physical CDC。

### Sub-feature: Reset Recovery

#### Item: NI-09

- **Requirement Location:** NI top-level：ARESETn、noc_rst_n。此次測試同時 reset 全平台。
- **Feature Description:** Reset 清除未完成 transactions 的追蹤狀態，解除 reset 後可接受新 requests。
- **Verification Goals:** 在 read/write pending 時 reset。解除後先確認沒有舊 response，再送新 requests。
- **Pass/Fail Criteria:** 沒有 reset 前 transaction 的 B/R 殘留，新 requests 的 ID、資料、response 數與順序正確。
- **Test Type:** Constrained Random
- **Coverage Method:** Functional Coverage。
- **Applicable Configurations:** C0 seeds 1/17/29，C0 T1/T2，其他組態選定 seed
- **Link to Coverage:** `reset_cg`、`stress_cg.reset_recovery` 與 reset checks。Pending 情境目前使用內部 records 取樣。

### Sub-feature: Arbitration

#### Item: NI-10

- **Requirement Location:** 現行 REQ／TX／RX arbitration，見下方 Scheduling Rules。
- **Feature Description:** 多個可傳送的 packets 共用輸出時，依仲裁規則選擇。Packet lock 與 downstream stall 期間保留選擇。
- **Verification Goals:** 形成多 ID／VC read-write 競爭，核對 AW→W packet 順序、VC 使用及各流量的持續進展。
- **Pass/Fail Criteria:** 沒有 packet 資料交錯或被永久餓死的流量。精確 RR grant bound 由補充的內部 assertions 檢查，不從 AXI 總 cycles 推定。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Assertion Coverage / Functional Coverage。
- **Applicable Configurations:** C0～C6 選定 contention traffic
- **Link to Coverage:** `ni_arbiter_checks`、`ni_credit_forward_checks` 與 cover properties。各 instance 的未觸發情境見 report。

## AXI to NoC Mapping

| AXI transaction | Request path | Response path |
|---|---|---|
| Control write | AW、W → REQ | B → RSP |
| Control read | AR → REQ | R → RSP |
| Data write | AW、W → DAT | B → RSP |
| Data read | AR → REQ | R → DAT |

NI-02 檢查 AXI fields 與 packet type。NI-05 檢查 DAT credit。REQ/RSP 使用 ready/valid，等待時 valid/flit 必須保持。這些機制分別驗證。

## Scheduling Rules

以下為現行行為，用來檢查 NI-02/07/10 的測試內容。

| 項目 | 現行規則 | 對外檢查 |
|---|---|---|
| REQ arbitration | NMU AW/AR 使用 RR。AW 選定後送完該筆 W，才選下一個 AW/AR | REQ 上 AW 後的 W 對應正確 transaction，直到最後一拍 |
| DAT VC allocation | NMU write packet 的 AW 與所有 W 使用同一 VC。需要維持順序的 traffic 依現行 fixed-VC 規則選 VC | 同一 packet 的 VC 不變，flits 依序送出。跨 router 不要求 VC 編號相同 |
| TX arbitration | DAT 從有資料且有 credit（含同 cycle 回補）的 VC 做 RR | 送出 flit 的 VC 合法且有 credit，競爭流量可持續前進 |
| RX arbitration | 接收端按可接受的 channel 選取 packet。NSU 的 W 按已接受 AW 的次序轉送 | Device W 配對正確 AW。Source B/R 符合 AXI ordering |

Shared 模式使用允許的全部 VCs。Read/write split 模式將 write 與 read 分配到不同 VC pools。VC 限制以每條 NI link 為單位檢查。

AXI／NoC top-level 可檢查 packet、VC 與完成次序。精確仲裁公平性需要知道當 cycle 可參與仲裁的 requests，因此內部 RR assertions 保留為補充證據。

## Coverage Source Index

| Source | Objects／用途 |
|---|---|
| [ni_coverage.svh](../sim/dv/ni_coverage.svh) | transaction_cg、write_strobe_cg、boundary_cg、response_cg、outstanding_cg，以及內部／混合的 ordering_cg、rob_cg、stress_cg、reset_cg |
| [ni_resource_coverage.sv](../sim/dv/ni_resource_coverage.sv) | 內部 fifo_cg、credit_cg。FIFO 覆蓋範圍不包含全部 CDC FIFO |
| [tb_top.sv](../sim/tb_top.sv) | Device AXI stall/recovery properties、scoreboard 與 ordering checker 接線 |
| [ni_arbiter_checks.sv](../sim/dv/ni_arbiter_checks.sv) | 內部 RR／no-bubble assertions 與 contention covers |
| [ni_arbiter_checks.sv](../sim/dv/ni_arbiter_checks.sv) 的 ni_credit_forward_checks | 內部 credit forwarding assertions |

Link to Coverage 所列名稱依目前 source 核對。標為待補的項目未新增 covergroup，也未納入現有 GROUP 100% 的完成判定。

## Scope Requiring Review

| 項目 | 目前範圍／缺口 |
|---|---|
| FIXED／WRAP | Integration generator 使用 INCR。RTL 支援範圍及必要 tests 待確認 |
| Unaligned first beat | 目前 sweep 使用合法對齊位址。未作完整 unaligned coverage |
| Exclusive／EXOKAY、AxLOCK | 未建立完整 requirement／coverage 對照，待確認支援範圍 |
| AxCACHE／AxPROT／AxQOS／AxREGION／USER | 不以目前固定值判定 unsupported。需確認各欄位的保留、轉換或固定值規則 |
| R beat interleaving、multi-source、multicast | 本輪未完成，後續整合範圍由 issue #6 追蹤 |
| SAM miss／非法跨界 | 現有 SAM／4 KB checks 會檢查輸入是否合法，未驗證這些條件的 DUT error response。處理規則待確認 |
| Negative protocol stimulus | 不以合法 traffic 的 PASS 宣告 malformed packet／非法 AXI testing 完成 |
| Router RTL、multihop、physical CDC/RDC、STA／synthesis | 本階段範圍外 |

## 驗證組態

組態用於功能與容量邊界驗證，不代表面積／性能等級。容量採 2^n，包含 depth=1。未列設定沿用 C0，production defaults 不變。

### C0：基準組態

- Profile：`sim/profile.yml`。執行目錄：`baseline`。
- Source／NoC／Device ID width：3／3／3。
- Transaction capacity：`MAX_OUTSTANDING_PER_ID=32`、`CONTEXT_DEPTH=32`。
- Interface buffering：`IO_FIFO_DEPTH=32`。
- Reorder storage：`B_ROB_DEPTH=128`、`R_ROB_DEPTH=128`。
- 支援 read reordering：`R_ROB_EN=1`。
- Output pipeline bypass：`REG_TYPE=0`。
- DAT transport：`NUM_DAT_VC=2`、SHARED、`CREDIT_DEPTH=8`。
- 目的：驗證基本 read/write、ordering、容量回收與 reset recovery。

### C1：窄 Device ID、受限 transaction capacity、read/write VC 分流

- Profile：`sim/profiles/split.yml`。執行目錄：`split`。
- `DEVICE_ID_WIDTH=1`。
- `MAX_OUTSTANDING_PER_ID=4`、`CONTEXT_DEPTH=4`、`IO_FIFO_DEPTH=4`。
- Spill register：`REG_TYPE=2`。
- `NUM_DAT_VC=4`、READ_WRITE_SPLIT、`CREDIT_DEPTH=2`。
- 目的：驗證多個 request ID 對應同一 Device ID 時，response 仍正確返回。
- 目的：驗證 transaction 達容量上限後的暫停與恢復。
- 目的：驗證 read/write 使用不同 VC 時的傳輸。

### C2：寬 Device ID、無 read reordering

- Profile：`sim/profiles/robless.yml`。執行目錄：`robless`。
- `DEVICE_ID_WIDTH=8`。
- `CONTEXT_DEPTH=1`、`IO_FIFO_DEPTH=4`。
- Simple register：`REG_TYPE=1`。
- 無 read reordering：`R_ROB_EN=0`。AXI read ordering 仍由 admission control 維持。
- 目的：驗證寬 Device ID 下的 response ID 還原。
- 目的：驗證 context 只能保存一筆 transaction 時的接受與回收。
- 目的：驗證無 read reordering 時，same-ID read 仍依序完成。

### C3：受限 reorder capacity、單 VC

- Profile：`sim/profiles/small_rob.yml`。執行目錄：`small_rob`。
- `B_ROB_DEPTH=4`、`R_ROB_DEPTH=8`。
- `NUM_DAT_VC=1`、SHARED、`CREDIT_DEPTH=2`。
- 目的：驗證 reorder buffer 滿載時，暫停接受需要重排的 request，釋放空間後恢復接受。
- 目的：驗證單 VC 的傳輸行為。

### C4：單 VC、無 read reordering

- 基準：C0。
- 差異：`NUM_DAT_VC=1`、`R_ROB_EN=0`。其他設定沿用 C0。
- 目的：驗證這兩項功能選擇同時使用時，read/write 正確完成。
- 此組沒有取消 write response reordering，也沒有面積量測結果。

### C5：1-bit source ID

- 基準：C0。
- 差異：Source／NoC／Device ID width＝1/1/1。
- 目的：驗證較少 ID 時的 outstanding 與 response ID 還原。
- Pattern 與完成條件須依可用兩個 IDs 調整，不得要求超過兩個 unique IDs。

### C6：8-bit source ID

- 基準：C0。
- 差異：Source／NoC／Device ID width＝8/8/3。
- 目的：驗證 source ID 高位元保存，以及多個 source IDs 對應 Device ID 後的正確回覆。
- Stimulus 須包含 ID 0、最高值及只差高位元的 IDs，避免設定 8 bits 卻只測到低位元。

`IO_FIFO_DEPTH`、`CONTEXT_DEPTH`、`REG_TYPE` 為 TB 組態選項。前者設定兩端 AXI CDC FIFOs 與 NMU REQ/RSP FIFOs，NSU REQ/RSP 使用預設。CONTEXT_DEPTH 設定 NSU AW/AR context。REG_TYPE 設定 packetize/depacketize，SAM 使用預設。

- T0：AXI／NoC period＝1000／1000 ps，phase＝0 ps。
- T1：AXI／NoC period＝1000／2000 ps，NoC phase＝250 ps。
- T2：AXI／NoC period＝2000／1000 ps，NoC phase＝250 ps。
- APPL_DELAY＝0，sample delay＝200 ps。C0 使用 T0/T1/T2，其他組態使用 T0。

## Test Cases

| Case | 測試內容 | 主要 checker |
|---|---|---|
| ctrl_write_single | 一筆 control write | ordering compare、AXI protocol |
| ctrl_read_single | 一筆 control read。memory preload | scoreboard、ordering compare |
| ctrl_write_burst | 15 筆基線＋240 筆補測 control write burst | ordering compare、SAM checker |
| ctrl_read_burst | 15 筆基線＋240 筆補測 control read burst。memory preload | scoreboard、ordering compare、SAM checker |
| single_id_outstanding | same-ID 多筆 pending | min_outstanding、ordering compare |
| multi_id_outstanding | multi-ID 多筆 pending | min_unique、min_outstanding、ordering compare |
| multi_id_out_of_order | 不同 ID、跨 destination 的 response 亂序 | ordering compare、scoreboard |
| single_id_reorder | same-ID、跨 destination 的 response 亂序 | ordering compare、scoreboard |
| data_write_single | 一筆 data write | ordering compare、AXI protocol |
| data_write_burst | 11 筆基線＋52 筆補測 data write burst | ordering compare、SAM checker |
| data_read_single | 一筆 data read。memory preload | scoreboard、ordering compare |
| data_read_burst | 11 筆基線＋52 筆補測 data read burst。memory preload | scoreboard、ordering compare、SAM checker |
| ctrl_rand | control random、WSTRB、並行 R/W、readback | scoreboard、ordering compare |
| data_rand | data random、WSTRB、並行 R/W、readback | 同上 |
| request_rand | 混合 control/data random、WSTRB、並行 R/W、readback | 同上 |

Control 基線 length：2/3/4/7/8/15/16/31/32/63/64/127/128/255/256。完整 sweep 包含其餘 lengths，C0 累計2～256 beats。
Data 基線 length：2/3/4/7/8/15/16/31/32/63/64。完整 sweep 包含其餘 lengths，C0 累計2～64 beats。
皆為 full-width INCR，涵蓋 SAM 起點、4 KB 尾端、SAM 尾端，不跨界。

Random 在 co-sim/direct profile 發送 64 write 與 64 並行 read，完成後 64 readback。
讀寫區域與各 write transaction 的地址互不重疊。memory 與 scoreboard 使用相同 preload。
另有 3 個 stress cases，公開 case 合計 18 個。

| Stress case | 內容 |
|---|---|
| capacity_reuse | TARGET=per_id/context/rob。延遲 response 後恢復，read/write 各 320 筆 single |
| hol_blocking | 阻擋 north response，確認 west 先完成，read/write 各 80 筆 single |
| reset_recovery | 8 write／8 read pending 時隨機 reset，reset 後重送 |

Ordering cases 的 `BACKPRESSURE=1` 變體包含 Source B/R stall 與 Device AW/W/AR delay。基本 directed cases 不刻意加入 stall。Random 使用 seeds 1/17/29，reset timing seed 另計。Error tests 沿用 single/burst 名稱並設定 SLVERR／DECERR。

每個 case 的實際條件以 [run records](data/verification-runs.csv) 與 [transaction records](data/verification-transactions.csv) 為準。代表性 burst lengths 與完整 sweep 是同一 case 的不同 stimulus。未執行全部 size × length × lane × stall × configuration 組合。

## Acceptance Review

1. Review 本 plan 的 Generic AXI／NI scope，確認 `[TBD]` requirement 與支援範圍。
2. Review report 的逐項證據與 interface coverage 缺口，決定必要補測。本文不直接授權新增 RTL 或 DV implementation。
3. 各組 code coverage、assertion activation 與未結 bug 均有處置。不得由 GROUP 100% 直接宣告完成。
4. 確认 release configuration、revision、證據交付範圍與核准 exclusions，再判定 issue #7 驗收。

過去 V01～V20 是執行 objective 編號。現行 review 使用 AXI-01～AXI-07、NI-01～NI-10，對照保留於 report。
