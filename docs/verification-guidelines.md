# NI Verification Guidelines

## 文件與 review 範圍

| 文件 | 內容 |
|---|---|
| [Verification Plan](verification-testplan.md) | Generic AXI、NI-specific 功能、驗證目標、coverage 對照、組態與 cases |
| [Verification Report](verification-integration-results.md) | 各 plan item 的證據、未涵蓋項目、原生 coverage 與執行紀錄 |
| 本文件 | 撰寫、取樣、證據維護與驗收規則 |

本目錄其他 verification 文件為歷史紀錄。現行範圍與結果以上述三份文件為準。Logs、VDB、URG reports、manifests 放在 `build/`，逐筆執行與輸入條件放在 `docs/data/`。

Plan 採 Feature → Sub-feature → Item，每項保留 Requirement Location、Feature Description、Verification Goals、Pass/Fail Criteria、Test Type、Coverage Method、Applicable Configurations、Link to Coverage。參考 [OpenHW planning guide](https://github.com/openhwfoundation/core-v-verif/blob/master/docs/VerifPlans/VerificationPlanning101.md) 與 [AXI verification plan](https://github.com/openhwfoundation/cva6/blob/master/verif/docs/VerifPlans/source/dvplan_AXI.md) 的欄位。其他設計的 AXI 限制不沿用。

## 功能分類與用語

NI 的功能依 address decoding/translation、packetization/depacketization、ID mapping/ordering、flow control、arbitration、clock/reset 整理。每類先列應有行為，再對照已測內容，避免由現有 cases 反推所有 requirements。

| 用語 | 定義／撰寫重點 |
|---|---|
| Backpressure | 接收端暫停接受，或 credit 不足導致傳送端等待。寫出哪個 channel、哪一端、如何恢復 |
| Head-of-line (HoL) blocking | Queue 最前面的 packet 無法前進，連帶擋住後面原本可以前進的 packet。只延遲某個 destination 不足以證明這個情境 |
| Request ordering | 比較 requests 在接收端出現的次序。列出 source、ID、destination、control/data region 與 read/write 的範圍 |
| Response ordering | 比較 responses 回到 Source 的次序。Same-ID 要保序，不同 IDs 可亂序，read/write 分別判定 |
| Arbitration | 多個 requests 共用輸出時選誰。區分 packet lock、backpressure 與實際可仲裁的 cycle |
| Throughput / latency | 列出量測起訖、clock、traffic 與 stall 條件。總執行 cycles 不等於單筆 latency 或仲裁公平性 |

Flow control 與 arbitration 的分類參考 *On-Chip Networks, Second Edition* 第 5、6 章。Ordering 分析使用本機 `noc-ordering` 知識整理。這些資料提供概念，專案行為仍以核准規格與現行 RTL 逐項核對。

## 每個 Item 必須說清楚的內容

- **Feature Description**：功能與適用條件，例如「same-ID read responses 按 AR 接受次序返回」。不放 script、monitor 作法或歷次修改紀錄。
- **Verification Goals**：如何觸發情境，以及要看哪些 top-level signals。必要條件如 different IDs、哪端 stall、是否存在較早 pending request，必須列出。
- **Pass/Fail Criteria**：具體比較什麼。使用 ID、address、data、beat count、response code、先後次序，避免只寫「正確完成」或「checker PASS」。
- **Link to Coverage**：實際物件與觀察位置。沒有專用 bin 時記錄目前證據，另由 report 說明不足，不自動將每個可能 cross 列為必做。
- **Requirement Location**：規格或 implementation reference。兩者不一致時列為待確認事項，不能自行選一份當規格。

Generic AXI 包含輸入與輸出的 transaction fields、handshake、responses、outstanding、ordering。NI-specific 補上 AXI 與 NoC 之間的轉換和 flow control。先檢查功能是否列全，再檢查 coverage model 是否量到。

功能目標使用 NMU／NSU top-level interfaces。Internal FIFO、ROB、arbiter coverage 保留為補充證據。外部 stall 只能證明發生等待，不能直接判定哪個 buffer 已滿。內部公平性也不能只由端口輸出次序推定。

未測功能不得直接標為 unsupported。FIXED/WRAP、exclusive、unaligned、sideband、SAM miss 等需先確認支援範圍。每個建議新增的 cross 必須指出它要檢查的功能交互作用，不要求所有欄位做 Cartesian product。

## 五項驗證原則

| 項目 | 要求 |
|---|---|
| Functional coverage | 定義訊號、sample event、bins、適用組態。每項情境須有正確性檢查 |
| Cross coverage | 選擇有功能交互作用的組合。列出已實作與待補的 cross，不以單項皆命中推定交叉已測 |
| Code coverage | 分組態檢查 line、condition、branch、toggle、FSM。缺口分類後再決定 stimulus、修正或 exclusion |
| Assertions | 檢查 handshake、stability、ordering、flow control。以 activation／cover property 確認前提曾發生 |
| Random／parameter regression | 每組設定說明驗證目的。保存 seed、clock、profile、source／stimulus digest、log、VDB |

## Sampling

| 觀察項目 | Sample condition |
|---|---|
| AXI AW／AR | 所屬 `ACLK` 的 `AxVALID && AxREADY` |
| AXI W | `WVALID && WREADY`，依 AW 接受順序配對。W 可以先於 AW 到達 |
| AXI B | `BVALID && BREADY`，一筆 write completion |
| AXI R | `RVALID && RREADY`，每個 beat 取樣。只有 `RLAST=1` 才計一筆 read completion |
| AXI stability | `VALID && !READY` 後至 handshake 的 VALID 與 payload，reset 期間依規格停用 |
| REQ／RSP | 所屬 `noc_clk` 的 `valid && ready` |
| DAT | `noc_clk` 的 `valid` 與 packet VC。DAT 沒有 ready port |
| Credit | 每個 VC 的 credit-return pulse 與實際 DAT send，按核准初始容量重建 balance |
| Reset recovery | Reset 前 pending、reset 期間 response、reset 後新 request／response，分開記錄 reset 前後的 transactions |

Address-derived destination 只代表預期 routing。要證明實際 destination 正確，需配對 NSU AXI 或 NoC top-level packet。Response 到達 NI 的次序與返回 Source AXI 的次序分別觀察。

## 文件與 coverage model 對齊

1. Plan 的 Link to Coverage 填實際檔案、covergroup／coverpoint／cross 或 assertion 名稱。尚未實作填「未實作」，不得填預期存在的物件。是否需要新增，由功能目標與現有證據決定。
2. 對照 sample code，確認訊號來源、clock、reset、bin 範圍、ignore bins 與 cross。列出外部與內部觀察的差異。
3. Report 使用相同 Item ID，記錄已驗證條件與剩餘範圍。區分 case PASS、coverage hit、checker self-test 與 input records。
4. 每次 coverage model 修改後，重新核對 model version 與 VDB 來源。不同模型分母不得直接比較。URG merge 無 warning 仍須人工確認語意一致。
5. Git 保存 plan、model、checker 版本。每筆 run 另保留 build manifest 與 stimulus digest，不能把歷史 runs 全部標成目前 HEAD。

以上是 review 流程。目前沒有自動證明 requirement 完整性或文件語意一致的工具。本輪核對紀錄見 report，尚未實作的 interface coverage 保留為缺口。

## Coverage closure 與驗收

- 已驗證：明列條件有 checker 與執行證據。部分驗證：仍缺情境、觀察點或 cross。待驗證：尚無有效證據。不適用：有規格依據並經 review。
- 同組態合併相容資料。跨組態 functional union 保留各 instance 結果。不同 elaboration 的 code coverage 各自報告，不平均百分比。
- 忽略合法但未測的 bins 不能作為 closure。Illegal／ignore bins 需有規格依據。不可達與 exclusion 需 review，未核准前保留缺口。
- 驗收需完成 plan review、checker 檢查、必要 regression、coverage gap 處置與未結 bug review。Functional 100% 僅代表該模型定義的 bins 全部命中。
- Release 組態、revision、未驗證範圍與豁免需明列。Functional simulation 不替代 physical CDC/RDC、STA 或 synthesis。
