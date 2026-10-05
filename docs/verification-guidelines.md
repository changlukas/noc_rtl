# NI Verification Guidelines

## 文件與 review 範圍

| 文件 | 內容 |
|---|---|
| [Verification Plan](verification-testplan.md) | Generic AXI、NI-specific 功能、驗證目標、coverage 對照、組態與 cases |
| [Verification Report](verification-integration-results.md) | 各 plan item 的證據、未涵蓋項目、原生 coverage 與執行紀錄 |
| 本文件 | 撰寫、取樣、證據維護與驗收規則 |

本目錄其他 verification 文件為歷史紀錄。現行範圍與結果以上述三份文件為準。Logs、VDB、URG reports、manifests 放在 `build/`，逐筆執行與輸入條件放在 `docs/data/`。

Plan 採 Feature → Sub-feature → Item，每項保留 Requirement Location、Feature Description、Verification Goals、Pass/Fail Criteria、Test Type、Coverage Method、Applicable Configurations、Link to Coverage。參考 [OpenHW planning guide](https://github.com/openhwfoundation/core-v-verif/blob/master/docs/VerifPlans/VerificationPlanning101.md) 與 [AXI verification plan](https://github.com/openhwfoundation/cva6/blob/master/verif/docs/VerifPlans/source/dvplan_AXI.md) 的欄位。其他設計的 AXI 限制不沿用。

## Requirement 與觀察介面

- Feature Description 使用規格訊號與條件，例如 `AxBURST = 2'b01`。Verification Goals 列出要觀察的 transfer 與行為。
- Generic AXI 包含 transaction fields、channel handshake、response、outstanding 與 ordering。Input stimulus 清單只能證明產生了哪些交易，仍須觀察 DUT 接受與完成。
- NI-specific 包含 address translation、packet transport、ID restoration、VC／credit、容量限制、CDC 與 reset recovery。
- 功能目標使用 NMU／NSU top-level AXI、REQ、RSP、DAT、credit、clock、reset 訊號。允許 monitor 由已接受的 transactions 建立 pending queue 或 credit balance。
- Internal FIFO、ROB、arbiter 的 covergroup／assertion 列為 implementation evidence。介面 stall 不足以判定某個內部 buffer 已滿，也不能直接量到內部 requester 的 RR 公平性。
- Requirement Location 指向規格定義。若只有 RTL 或 generator 可供核對，註明 implementation reference，正式規格定位標 `[TBD]`。
- 未測的功能不能直接標成 unsupported。FIXED／WRAP、exclusive、unaligned、sideband 等須先確認支援範圍，再訂 coverage 或不適用理由。

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
| Reset recovery | Reset 前 pending、reset 期間 response、reset 後新 request／response，分開 transaction epoch |

Address-derived destination 只代表預期 routing。要證明實際 destination 正確，需配對 NSU AXI 或 NoC top-level packet。Response inversion 與 source retirement order 也要分別觀察。

## 文件與 coverage model 對齊

1. Plan 的 Link to Coverage 填實際檔案、covergroup／coverpoint／cross 或 assertion 名稱。尚未實作填「待補」，不得填預期存在的物件。
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
