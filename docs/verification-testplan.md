# Module: NI

## Verification Scope

驗證對象為 NMU／NSU RTL。正式平台為一個 NMU、單個 C++ Router、四個 NSU 與 AXI memories。Standalone／direct-link 供 debug，未列入本報告的 accepted coverage。

本 plan 供 review，沿用 [OpenHW AXI plan](https://github.com/openhwfoundation/cva6/blob/master/verif/docs/VerifPlans/source/dvplan_AXI.md) 的欄位與訊號式描述。Item 的 Coverage Method 是驗證需求，Link to Coverage 記錄現有實作與缺口。[Report](verification-integration-results.md) 列出逐項證據。[Guidelines](verification-guidelines.md) 定義維護規則。

Generic AXI 使用 [AMBA AXI specification](https://developer.arm.com/documentation/ihi0022/hc) 的 channel、burst、response 與 ordering 定義。NI 介面參考 [NMU top](../rtl/nmu/top/nmu.sv)、[NSU top](../rtl/nsu/top/nsu.sv)、[packet contract](../specgen/generated/json/ni_packet.json) 與 [handshake contract](../specgen/source/interface_handshake.json)。NI release specification 的固定版本／章節定位為 `[TBD]`，RTL reference 不代替正式 requirement。

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

## Feature: Generic AXI Functional Coverage

### Sub-feature: Burst

#### Item: AXI-01

- **Requirement Location:** AXI specification 的對應 channel／transaction 規則，支援的 stimulus 範圍見本 plan。
- **Feature Description:** 本階段 stimulus 使用 `AxBURST=2'b01`。Single 為 `AxLEN=0`。
- **Verification Goals:** 於 AW／AR handshake 覆蓋 single 與 INCR burst。Control full-width 掃 `AxLEN=1..255`，data full-width 掃 `AxLEN=1..63`。
- **Pass/Fail Criteria:** 每筆 AW 對應 `AWLEN+1` 個 W transfers 與一個 B。每筆 AR 對應 `ARLEN+1` 個 R transfers。僅末 beat 的 LAST 為 1。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0 完整 length sweep，其他組態為選定 lengths
- **Link to Coverage:** `transaction_cg.cp_burst/cp_beats`、`direction_length`。只含代表性 length bins，完整 length 清單見 run／transaction records。

### Sub-feature: Size and Address

#### Item: AXI-02

- **Requirement Location:** AXI specification 的對應 channel／transaction 規則，支援的 stimulus 範圍見本 plan。
- **Feature Description:** `2**AxSIZE` 為每 beat bytes，不得超過 AXI data bus。Burst 不跨 4 KB。
- **Verification Goals:** 覆蓋 control `AxSIZE=0..3`、data `AxSIZE=0..6` 的合法對齊 `AxADDR`。覆蓋各 byte lane 與 4 KB 尾端。
- **Pass/Fail Criteria:** Device AXI address／size／length 符合轉換後 request，RDATA 符合 preload／write data。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0 lane sweep，C0～C6 選定 traffic
- **Link to Coverage:** `transaction_cg.cp_size`、`boundary_cg.page_boundary`。Read lane 與 size × lane 專用 cross 待補。

### Sub-feature: Write Strobe

#### Item: AXI-03

- **Requirement Location:** AXI specification 的對應 channel／transaction 規則，支援的 stimulus 範圍見本 plan。
- **Feature Description:** `WSTRB[b]=1` 的 byte 寫入，`WSTRB[b]=0` 的 byte 保留。
- **Verification Goals:** 於 W handshake 覆蓋 zero／partial／full WSTRB 與 one-hot byte selection，依接受的 AW 取得 active lanes。
- **Pass/Fail Criteria:** Device WDATA／WSTRB 與 request 相符，readback 包含更新與保留的 bytes。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0 strobe sweep，其他組態 random
- **Link to Coverage:** `write_strobe_cg.cp_strobe/cp_lane/cp_size`、`strobe_size`。1-byte partial 被排除，該組合不存在。One-hot sweep 無獨立 bin。

### Sub-feature: Channel Handshake

#### Item: AXI-04

- **Requirement Location:** AXI specification 的對應 channel／transaction 規則，支援的 stimulus 範圍見本 plan。
- **Feature Description:** AW、W、B、AR、R 以 `VALID && READY` transfer。等待期間 VALID 與 payload 保持穩定。
- **Verification Goals:** 兩端各 channel 覆蓋立即接受、stall、恢復。AW／W 覆蓋 AW-first、W-first、同 cycle 接受。
- **Pass/Fail Criteria:** Protocol assertions 無違規，解除 stall 後無重複或遺失 transfer。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0/C1 ordering + BACKPRESSURE=1，其他組態依 records
- **Link to Coverage:** 既有 AXI protocol checks。`tb_top.sv` 的 `aw_stall_recover/w_stall_recover/ar_stall_recover` 觀察 Device AXI。AW/W relative timing bins 與完整五 channel coverage 待補。

### Sub-feature: Responses

#### Item: AXI-05

- **Requirement Location:** AXI specification 的對應 channel／transaction 規則，支援的 stimulus 範圍見本 plan。
- **Feature Description:** BID／RID 對應已接受的 AWID／ARID，BRESP／RRESP 傳遞 Device response。
- **Verification Goals:** B handshake 與每個 R handshake 覆蓋 OKAY、SLVERR、DECERR。Error read 的每 beat response 分別檢查。
- **Pass/Fail Criteria:** Source BID／RID 及 BRESP／RRESP 符合 pending transaction。正常存取另比對 RDATA。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0 error variants，C0～C6 OKAY
- **Link to Coverage:** `response_cg.cp_resp`、`response_type`。沒有 EXOKAY bin。

### Sub-feature: Outstanding

#### Item: AXI-06

- **Requirement Location:** AXI specification 的對應 channel／transaction 規則，支援的 stimulus 範圍見本 plan。
- **Feature Description:** Write pending 由 AW handshake 增加、B handshake 減少。Read pending 由 AR 增加、RLAST handshake 減少。
- **Verification Goals:** 覆蓋單筆、多筆、read/write 同時 pending、same-ID 與 multi-ID。
- **Pass/Fail Criteria:** 完成數與接受數相符，drain 後無 pending。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0～C6 選定 outstanding／random cases
- **Link to Coverage:** `outstanding_cg.cp_write/cp_read`、`read_write` 與 `transaction_cg.cp_id`。ID count × per-ID depth cross 待補。

### Sub-feature: Response Ordering

#### Item: AXI-07

- **Requirement Location:** AXI specification 的對應 channel／transaction 規則，支援的 stimulus 範圍見本 plan。
- **Feature Description:** Source same-ID B 與 same-ID read transactions 依 request 接受次序完成。不同 IDs 可亂序完成。
- **Verification Goals:** 在 Device responses 亂序及 Source BREADY／RREADY stall 下，檢查 Source BID／RID、response data 與先後次序。
- **Pass/Fail Criteria:** `axi_reorder_compare` 比對通過，所有 pending transactions drain。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0～C6 選定 ordering cases
- **Link to Coverage:** 端到端 ordering checker 已有。`ordering_cg` 使用內部 arrival，不符合本項 top-level sampling 邊界，interface inversion coverage 待補。

## Feature: NI-Specific Functional Coverage

### Sub-feature: Address Translation

#### Item: NI-01

- **Requirement Location:** NI top-level／packet／handshake contracts，見 Interface Notation。正式規格章節 `[TBD]`。
- **Feature Description:** Source AxADDR 依 SAM 選 destination、control/data region 與 Device local address。
- **Verification Goals:** 配對 Source AW／AR、NoC packet 與實際 Device AW／AR。覆蓋四個 destinations、SAM 起點／尾端。
- **Pass/Fail Criteria:** 只有預期 Device 接受 request，local address 與 transaction fields 符合 SAM。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0 邊界 sweep，C0～C6 選定 traffic
- **Link to Coverage:** `transaction_cg.cp_destination/direction_destination`、`boundary_cg.sam_first/sam_last` 與端到端 checker。Destination bins 從 Source address 推導，實際 route cross 待補。

### Sub-feature: Packet Transport

#### Item: NI-02

- **Requirement Location:** NI top-level／packet／handshake contracts，見 Interface Notation。正式規格章節 `[TBD]`。
- **Feature Description:** AXI requests 經 REQ／DAT 傳出，responses 經 RSP／DAT 返回。
- **Verification Goals:** 配對 AXI transfers 與 top-level flits，覆蓋 control/data read/write、single/burst、REQ 與 DAT 同時傳送。REQ／RSP 在 valid=1、ready=0 時保持 flit，恢復 ready 後 transfer。
- **Pass/Fail Criteria:** 欄位、WDATA／WSTRB、RDATA、ID、LAST 及 transaction 數符合輸入，無遺失或重複。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0～C6
- **Link to Coverage:** `transaction_cg.direction_traffic` 與端到端 checker。NoC packet-type／REQ × DAT concurrency covergroup 待補。

### Sub-feature: ID Restoration

#### Item: NI-03

- **Requirement Location:** NI top-level／packet／handshake contracts，見 Interface Notation。正式規格章節 `[TBD]`。
- **Feature Description:** NSU Device AWID／ARID 可與 Source ID 寬度不同。Source BID／RID 必須還原原 request ID。
- **Verification Goals:** 配對 Source／Device requests 與 responses，覆蓋窄、等寬、寬 Device ID，以及只差高位元的 Source IDs。
- **Pass/Fail Criteria:** 回覆歸屬正確，same-ID response ordering 保持。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C1/C0/C2 Device width 1/3/8，C5/C6 Source width 1/8
- **Link to Coverage:** `transaction_cg.cp_id` 與端到端 checker。Source ID × Device ID 專用 cross 待補。

### Sub-feature: Capacity and Recovery

#### Item: NI-04

- **Requirement Location:** NI top-level／packet／handshake contracts，見 Interface Notation。正式規格章節 `[TBD]`。
- **Feature Description:** Pending requests 超過可接受容量時，以 interface backpressure 暫停，responses 完成後恢復接受。
- **Verification Goals:** 保持 AWVALID／ARVALID，延遲 Device B/R，觀察 request stall。恢復 responses 後觀察新 request handshake。
- **Pass/Fail Criteria:** 已接受 transactions 全部正確完成，解除阻塞後恢復前進。不得以 Source pending 數直接推定內部 occupancy。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0～C3 capacity_reuse，C4～C6 選定變體
- **Link to Coverage:** `stress_cg`、`rob_cg`、`fifo_cg` 是內部或混合證據。按介面統計的 limit／stall／recovery cross 待補。

### Sub-feature: VC and Credit

#### Item: NI-05

- **Requirement Location:** NI top-level／packet／handshake contracts，見 Interface Notation。正式規格章節 `[TBD]`。
- **Feature Description:** 每個 DAT VC 的 send 受 credit 限制。Tx 可使用當 cycle 回補的 credit。
- **Verification Goals:** 以 top-level valid、flit VC 與 crdvalid 重建每 VC balance。覆蓋 available、exhausted、return、send+return，並核對 read/write VC pool。
- **Pass/Fail Criteria:** 每次 send 有 stored 或同 cycle returned credit。Balance 不超出合法範圍，回補後 traffic 恢復。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0～C6，C1 split，C3/C4 單 VC
- **Link to Coverage:** `credit_cg` 與 primitive assertions 使用內部 counter。Top-level credit balance／VC × direction coverage 待補。

### Sub-feature: Destination Blocking

#### Item: NI-06

- **Requirement Location:** NI top-level／packet／handshake contracts，見 Interface Notation。正式規格章節 `[TBD]`。
- **Feature Description:** 指定 Device 暫停 response 時，獨立 destination 可返回 response。
- **Verification Goals:** 阻擋 north Device B/R，觀察解除阻塞前 west 的 Source B/R completion。
- **Pass/Fail Criteria:** west 有完成，恢復 north 後全部 transactions drain。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0/C1/C4 hol_blocking
- **Link to Coverage:** `stress_cg.direction_hol_progress` 含內部 full 前提。既有完成檢查保留，純 interface blocked-destination cross 待補。

### Sub-feature: Read Ordering Configuration

#### Item: NI-07

- **Requirement Location:** NI top-level／packet／handshake contracts，見 Interface Notation。正式規格章節 `[TBD]`。
- **Feature Description:** `R_ROB_EN=0` 與 `R_ROB_EN=1` 均須維持 Source same-ID read ordering。
- **Verification Goals:** 對同 RID 對應的 AR requests 發送到不同 destinations，延遲較早 response，觀察 Source R 次序。
- **Pass/Fail Criteria:** 兩種組態皆正確完成。無 read reordering 組態允許 request 等待，不要求 Device same-ID response inversion。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0/C1/C3/C5/C6 開啟，C2/C4 關閉
- **Link to Coverage:** 端到端 checker 與組態 records。獨立 interface ordering-mode cross 待補，內部 `ordering_cg` 僅補充。

### Sub-feature: CDC

#### Item: NI-08

- **Requirement Location:** NI top-level／packet／handshake contracts，見 Interface Notation。正式規格章節 `[TBD]`。
- **Feature Description:** AXI transfer 使用 ACLK，NoC transfer 使用 noc_clk。兩者可不同頻率與 phase。
- **Verification Goals:** T0/T1/T2 下執行 random、ordering + backpressure、reset recovery，於各自 clock 取樣。
- **Pass/Fail Criteria:** 資料、計數與 ordering 正確，完成後無殘留 transaction。
- **Test Type:** Directed SelfChk / Constrained Random
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0 T0/T1/T2
- **Link to Coverage:** Run clock 記錄與既有 checkers。無 clock-ratio covergroup，結果不代表 physical CDC/RDC signoff。

### Sub-feature: Reset Recovery

#### Item: NI-09

- **Requirement Location:** NI top-level／packet／handshake contracts，見 Interface Notation。正式規格章節 `[TBD]`。
- **Feature Description:** ARESETn／noc_rst_n 有效時中止本 epoch，解除 reset 後接受新 transactions。
- **Verification Goals:** 有已接受且未完成的 AW／AR 時 reset。觀察 reset 後無舊 response，fresh B/R 正確完成。
- **Pass/Fail Criteria:** Reset quiet interval 與 fresh-traffic data/order checks 通過。
- **Test Type:** Constrained Random
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0 seeds 1/17/29，C0 T1/T2，其他組態選定 seed
- **Link to Coverage:** `reset_cg` 使用內部 pending，`stress_cg.reset_recovery` 使用完成事件。Source pending × reset timing coverage 待補。範圍為全平台 reset，非單一 domain reset。

### Sub-feature: Scheduling and Throughput

#### Item: NI-10

- **Requirement Location:** NI top-level／packet／handshake contracts，見 Interface Notation。正式規格章節 `[TBD]`。
- **Feature Description:** REQ／RSP 依 ready/valid，DAT 依 credit 傳送。下游可接受且有待送 traffic 時應持續前進。
- **Verification Goals:** 以 top-level transfer sequence 檢查競爭流量的進展與可避免的 bubbles。需先固定 traffic、pipeline 及 buffer 條件。
- **Pass/Fail Criteria:** 既定排程規則通過。介面 latency／throughput 數值門檻 `[TBD]`，不由總 cycles 推定 RR 公平性。
- **Test Type:** Directed SelfChk
- **Coverage Method:** Functional Coverage / checker，實作狀態如下。
- **Applicable Configurations:** C0～C6 選定 contention traffic
- **Link to Coverage:** `ni_arbiter_checks.sv`、`ni_credit_forward_checks` 是內部 assertions。端口級 throughput invariant coverage 待補。

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
