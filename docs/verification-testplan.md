# NI Verification Plan

## Scope

驗證對象為 NMU／NSU RTL。整合平台包含一個 NMU、單個 C++ Router、四個 NSU 與 AXI memories。Standalone／direct-link 保留供 debug。

本文件分為功能與驗證目標、測試與 coverage、驗證組態三部分。實際結果見 [Verification Report](verification-integration-results.md)，維護規則見 [Guidelines](verification-guidelines.md)。未確認的支援範圍列於 Scope Requiring Review。

## Interface Notation

| 名稱 | 觀察位置 |
|---|---|
| Source AXI | NMU `axi_wr_i`／`axi_rd_i` |
| Device AXI | 各 NSU `axi_wr_o`／`axi_rd_o` |
| AXI fields | 使用標準名稱，例如 AWID。`Ax` 表示 AW 或 AR |
| NMU NoC | `tx_req_*`、`rx_rsp_*`、`tx_dat_*`、`rx_dat_*` |
| NSU NoC | `rx_req_*`、`tx_rsp_*`、`tx_dat_*`、`rx_dat_*` |
| Clock／reset | `ACLK`／`ARESETn`、`noc_clk`／`noc_rst_n` |

AXI 與 REQ/RSP 在 valid && ready 時傳送。DAT 在 valid 時傳送，使用 VC credit，沒有 ready port。

## Functional Description and Verification Goals

### Generic AXI

| Item | Function | Feature Description | Verification Goals |
|---|---|---|---|
| AXI-01 | Burst Transfers | INCR 的 AxBURST=2'b01，地址依 AxSIZE 遞增。每筆 transaction 有 AxLEN+1 beats | 確認 burst address、beat count 與 WLAST/RLAST 符合 AW/AR |
| AXI-02 | Transfer Size and Address | 2**AxSIZE 表示每 beat bytes，AxADDR 指定起始位址。Burst 不跨 4 KB | 確認 transfer size、byte lanes 與 address boundary 處理正確 |
| AXI-03 | Write Strobes | WSTRB 指定有效 write bytes。NI 傳遞有效 bytes 及其選擇資訊 | 確認有效 bytes 到達 Device，未選取的 bytes 不被寫入 |
| AXI-04 | Channel Handshake | AW/W/B/AR/R 各自使用 VALID/READY。等待期間 VALID/payload 保持穩定，AW/W 可獨立握手 | 確認 transfer 只被接受一次，等待時訊號穩定，AW/W 配對不受握手先後影響 |
| AXI-05 | Response Codes | Device BRESP/RRESP 隨對應 transaction 返回 Source | 確認 response code 與 transaction ID 正確傳遞 |
| AXI-06 | Outstanding Transactions | 前一筆未完成時，可接受後續 requests。Read/write 分別追蹤 | 確認 pending requests 的 ID、資料與 responses 正確配對，完成數等於接受數 |
| AXI-07 | Response Ordering | Same-ID responses 按 request 次序返回。Different-ID responses 允許 out-of-order completion。Read/write 分別保序 | 確認 same-ID responses 保序，different-ID OoO 不造成資料或 ID 配錯 |

### NI-specific

| Item | Function | Feature Description | Verification Goals |
|---|---|---|---|
| NI-01 | Address Decoding and Translation | SAM 將 Source AxADDR 對應到 destination、control/data path 與 Device address | 確認 request 到達目標 NSU，Device address 符合設定 |
| NI-02 | Packetization and Depacketization | AXI channels 依下表轉成 NoC packets，接收端還原 AXI transaction | 確認 channel、header/payload、AW/W 配對與 beat 次序正確 |
| NI-03 | ID Mapping | NSU 將 request ID 映射到 Device AXI ID，response 返回時還原 Source ID | 確認 ID width 不同及多個 Source IDs 共用 Device ID 時，responses 仍屬於原 request |
| NI-04 | Flow Control | REQ/RSP 使用 ready/valid。NI 可接受容量不足時暫停 request，空間釋放後恢復接受 | 確認等待時不遺失已接受的資料，解除限制後恢復傳輸 |
| NI-05 | Credit-Based Flow Control | DAT 每個 VC 獨立計算 credit。送一個 flit 消耗一個 credit，crdvalid[v] 回補一個 credit。初始值為 CREDIT_DEPTH | 確認無可用 credit 時不送出該 VC 的 flit，credit 計帳及回補後傳輸正確 |
| NI-07 | Request Ordering | 同 Source ID、同 destination、同 control/data region 的 requests 保序。不同 region 可超車。Read/write 分別保序 | 確認 Device AW/AR 次序符合規則，Source B/R 同時滿足 AXI-07 |
| NI-08 | Clock Domain Crossing | AXI 與 NoC 使用獨立 clocks，跨域後保持 transaction 內容與次序 | 確認跨域傳輸沒有遺失、重複或資料錯誤 |
| NI-09 | Reset Recovery | Reset 清除 transaction 追蹤狀態，解除後可重新接受 requests | 確認沒有舊 response 殘留，新 transactions 可正確完成 |
| NI-10 | Arbitration | 共用輸出依既定規則選取可傳送的 packets，遵守 packet lock 與 flow control | 確認競爭下的選擇符合規則，不破壞 packet 次序或造成 starvation |

NI-06 原為延遲 destination response 的測試情境，併入 AXI-07 的測試對照，不再列為獨立功能。既有測試證據保留。

## AXI to NoC Mapping

| AXI transaction | Request path | Response path |
|---|---|---|
| Control write | AW、W → REQ | B → RSP |
| Control read | AR → REQ | R → RSP |
| Data write | AW、W → DAT | B → RSP |
| Data read | AR → REQ | R → DAT |

## Scheduling Rules

| 項目 | 設計行為 |
|---|---|
| REQ arbitration | NMU AW/AR 使用 RR。AW 選定後送完該筆 W，再選下一個 AW/AR |
| DAT VC allocation | NMU write packet 的 AW 與所有 W 使用同一 VC。需維持次序的 traffic 使用現行 fixed-VC 規則。Router 每一跳的 VC 編號可不同 |
| TX arbitration | DAT 從有資料且有 credit（含同 cycle 回補）的 VC 做 RR |
| RX arbitration | 接收端依 channel 與下游可接受條件選取 packet。NSU W 按已接受 AW 的次序轉送 |

Shared 模式使用允許的全部 VCs。Read/write split 模式使用各自的 VC pools。

## Test and Coverage Plan

下表列出測試條件與檢查方法，並非新增功能定義。Coverage 欄只列既有物件，缺口與結果由 report 維護。

### Generic AXI Tests

| Item | Stimulus／test conditions | Pass/Fail Criteria | Existing Coverage |
|---|---|---|---|
| AXI-01 | Single 各一筆。Full-width INCR control burst 掃 2～256 beats，data 掃 2～64 beats | 一筆 AW 對應 AWLEN+1 個 W 及一個 B。一筆 AR 對應 ARLEN+1 個 R。LAST 僅在末拍 | transaction_cg.cp_burst、cp_beats、direction_length。完整 length sweep 另有輸入與完成紀錄 |
| AXI-02 | Control AxSIZE=0～3，data AxSIZE=0～6。Aligned addresses、合法 byte lanes、4 KB 邊界 | Device address/size/length 與預期相符，read data 符合 memory preload | transaction_cg.cp_size、boundary_cg.page_boundary |
| AXI-03 | Full/partial/zero/one-hot WSTRB，合法 byte lanes | Device 有效 WDATA/WSTRB 與 Source 相符。Readback 同時檢查更新與保留的 bytes | write_strobe_cg.cp_strobe、cp_lane、cp_size、strobe_size |
| AXI-04 | 各 channel 等待與恢復。AW-first、W-first、同 cycle handshake 為待核對的時序條件 | VALID/payload 等待時穩定，沒有重複接受，AW/W 配對正確 | AXI protocol checks。Device aw_stall_recover、w_stall_recover、ar_stall_recover |
| AXI-05 | Control/data single/burst read/write，各使用 OKAY、SLVERR、DECERR | 每個 B response 與 R beat 的 code/ID 符合 Device 回覆 | response_cg.cp_resp、response_type |
| AXI-06 | Same-ID/multi-ID 多筆 pending，read/write 同時發送 | 每筆 write 一個 B，每筆 read 完整 R beats，全部完成後 pending=0 | outstanding_cg.cp_write、cp_read、read_write，transaction_cg.cp_id |
| AXI-07 | 先接受 A，再接受 B。使 B 的 Device response 先到。分別使用 same/different ID，再加入 Source B/R stall | Same-ID 在 Source 仍為 A→B。Different-ID 的 B→A 是合法 OoO，資料/ID/code 配對正確。必須觀察到次序反轉才算命中 OoO | axi_reorder_compare。ordering_cg 的到達次序取自內部 ordering ingress |

`hol_blocking` 是 AXI-07 的補充情境：north 延遲 response 時，west 的不同 ID response 可完成。它先送 west request，不能單憑此 case 證明 OoO 或 HoL bypass。完整執行條件保留於 report。

### NI-specific Tests

| Item | Stimulus／test conditions | Pass/Fail Criteria | Existing Coverage |
|---|---|---|---|
| NI-01 | 每個 SAM region 的起點、尾端、區間內位址，control/data 各方向 | 實際 Device 與預期 destination 相符，address 符合設定 | 端到端 checker、transaction_cg.cp_destination/direction_destination、boundary_cg.sam_first/sam_last |
| NI-02 | Mapping 表內所有 read/write single/burst，加上混合 requests | 比對 address、ID、length、size、burst、有效 WDATA/WSTRB、RDATA、response code 與 LAST。Device W 必須配對正確 AW | 端到端 checker、transaction_cg.direction_traffic |
| NI-03 | 窄/等寬/寬 Device ID，不同 Source IDs 共用 Device ID 且有多筆 pending | B/R 還原正確 Source ID，不因 Device ID 相同而配錯 transaction | 端到端 checker、transaction_cg.cp_id、組態 records |
| NI-04 | 延遲 responses，持續送 requests。分別針對 per-ID、context、reorder capacity，之後恢復 responses | 已接受資料不遺失，恢復後可接受新 request，所有 transactions 完成 | stress_cg、rob_cg、fifo_cg。精確 full/reuse 證據為內部觀察 |
| NI-05 | 各 VC 的 credit 耗盡、回補、send+return 同 cycle，shared/split 組態 | 無 stored credit 且無同 cycle 回補時不得送出。Credit 在 0～CREDIT_DEPTH，VC 屬於允許的 pool | 內部 credit_cg、credit assertions |
| NI-07 | Same-ID 到相同/不同 destinations、同 destination 的 control/data requests，R_ROB_EN=0/1 | Device AW/AR 各自在同 Source ID、同 destination、同 region 內保序。Source B/R 符合 AXI-07。R_ROB_EN=0 可延遲發出 request 以保序 | axi_reorder_compare、組態 records，ordering_cg 僅補充 response 到達次序 |
| NI-08 | T0/T1/T2 的 random、ordering+stall、reset cases | 兩端 transaction 計數一致，資料與 ordering checks 通過 | Clock records、既有 checkers |
| NI-09 | 有 pending read/write 時同時 reset 全平台，解除後先等待，再送新 requests | 等待期間無舊 response，新 transactions 的 ID/data/count/order 正確 | reset_cg、stress_cg.reset_recovery、reset checks |
| NI-10 | 多 ID/VC read-write 競爭，含 downstream stall | Packet 配對與次序正確。內部 RR/no-bubble assertions 無違規，另檢查 contention 是否發生 | ni_arbiter_checks、ni_credit_forward_checks、cover properties |

功能判定以 top-level interfaces 為主。精確 buffer occupancy 與每 cycle 可參與仲裁的 requests 屬內部證據。Case 完成不代表所有 arbitration 機會均已覆蓋。

## Coverage Source Index

| Source | Objects／用途 |
|---|---|
| [ni_coverage.svh](../sim/dv/ni_coverage.svh) | transaction_cg、write_strobe_cg、boundary_cg、response_cg、outstanding_cg，以及內部／混合的 ordering_cg、rob_cg、stress_cg、reset_cg |
| [ni_resource_coverage.sv](../sim/dv/ni_resource_coverage.sv) | 內部 fifo_cg、credit_cg。FIFO 覆蓋範圍不包含全部 CDC FIFO |
| [tb_top.sv](../sim/tb_top.sv) | Device AXI stall/recovery properties、scoreboard 與 ordering checker 接線 |
| [ni_arbiter_checks.sv](../sim/dv/ni_arbiter_checks.sv) | 內部 RR／no-bubble assertions 與 contention covers |
| [ni_arbiter_checks.sv](../sim/dv/ni_arbiter_checks.sv) 的 ni_credit_forward_checks | 內部 credit forwarding assertions |

Coverage 欄位依目前 source 核對。未實作的物件不納入現有 GROUP 百分比。

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

1. Review Generic AXI／NI 功能與支援範圍，再確認對應測試條件。
2. Review report 的逐項證據與 interface coverage 缺口，決定必要補測。本文不直接授權新增 RTL 或 DV implementation。
3. 各組 code coverage、assertion activation 與未結 bug 均有處置。不得由 GROUP 100% 直接宣告完成。
4. 確认 release configuration、revision、證據交付範圍與核准 exclusions，再判定 issue #7 驗收。

過去 V01～V20 是執行 objective 編號。現行功能使用 AXI-01～AXI-07、NI-01～NI-05、NI-07～NI-10。NI-06 併入 AXI-07 的測試對照，歷史 objective 對照保留於 report。
