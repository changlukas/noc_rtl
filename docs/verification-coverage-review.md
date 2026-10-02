# NI coverage review and follow-up test plan

## 本輪結果

2026-10-02，source commit a4b1f23。既有 15 cases 全部 PASS，既有 data/order/protocol checks 通過。
沿用 VCS M-2017.03-SP1 binary；DUT、stimulus、參數與 C++ DPI cache 未修改。
本輪僅建立完整 baseline 與提出後續計畫，未新增 stimulus、coverage bins 或 waiver。

平台：NMU RTL → 單個 C++ Router → 四個 NSU RTL → AXI memories。
MODE=auto、seed=1、WAVE=0、COVERAGE=1；共用 1 GHz clock。
Source/NoC/device ID width=3/3/3，MAX_OUTSTANDING_PER_ID=32，
CONTEXT_DEPTH=32，IO_FIFO_DEPTH=32，CREDIT_DEPTH=8；
B/R ROB depth=128/128，R_ROB_EN=1，OUTPUT_REG_TYPE=0，兩個 shared DAT VC。
此結果不涵蓋其他 seed、獨立 clock、其他 elaboration 或 Router RTL。

| Metric | URG result |
|---|---:|
| Line | 84.60% |
| Condition | 70.03% |
| Branch | 77.53% |
| Toggle | 76.82% |
| FSM | 未抽取 |
| Functional group / instance score | 64.63% / 64.10% |

Code metrics 使用 DUT hierarchy，仍包含其 SAM checker/runtime guards；預設未啟用 MDA toggle。
Functional score 依目前 bins 與工具權重計算，不代表規格完成比例。

| Case | Cycles | Result |
|---|---:|---|
| ctrl_write_single | 27 | PASS |
| ctrl_read_single | 26 | PASS |
| ctrl_write_burst | 1051 | PASS |
| ctrl_read_burst | 1036 | PASS |
| single_id_outstanding | 98 | PASS |
| multi_id_outstanding | 98 | PASS |
| multi_id_out_of_order | 99 | PASS |
| single_id_reorder | 102 | PASS |
| data_write_single | 29 | PASS |
| data_write_burst | 283 | PASS |
| data_read_single | 28 | PASS |
| data_read_burst | 272 | PASS |
| ctrl_rand | 732 | PASS |
| data_rand | 659 | PASS |
| request_rand | 653 | PASS |

## 已觀察到的情境與缺口

原生 grpinfo.txt：
- Read/write pending cross：9/9 bins 命中，包含同時多筆 read/write pending。
- Same-ID response inversion：write 3、read 93 次；cross-ID：write 14、read 225 次。
- WSTRB zero：240 次；目前只量測 bit count，不能取代依 active byte lanes 判定 full/partial。
- B/R ROB 均有 bypass/reorder allocation 與 storage retirement。
- R ROB no-tail-space：164 次；B 為 0。Tail space 為零不等於 ROB 全部 occupied。
- B/R per-ID limit、AXI stall、ROB output stall 均為 0。
- 四個 NSU 的 AW/AR context full/recovery bins 均未命中。
- Pending reset bin 未命中；現有 coverage 尚未量測完整 reset recovery。
- HoL isolation、仲裁 fairness 與 no-avoidable-bubble 尚無對應 coverage，不能由上述百分比判定。

## Code coverage 缺口分類

| 類別 | 原生報告／source 證據 | 處理 |
|---|---|---|
| 缺 stimulus | ordering.sv:219–221、247–249、324–329 的 B/R hold paths 未執行；對應 output-stall bins 為零 | 補 response backpressure，須傳到內部 ordering output |
| 缺 stimulus／平台支援待確認 | ordering.sv:269 的 WRAP address path 未執行；generator 目前只產生 INCR | 先確認 supported burst 範圍；TB read address 計算目前採 INCR，不能只換 stimulus |
| 當次組態未啟用 | ordering.sv:338/352 collective state、NSU request_depacketize.sv:74–79 coordinate replacement 未執行；目前 SAM 未啟用 collective | 另行確認 collective 驗收範圍，不能當作永久不可達 |
| 錯誤防護分支 | ROB bounds、context mismatch、credit overflow、非法 SAM 等 $fatal paths | 與正常 PASS regression 分開；不為提高 line score 故意觸發 |
| 有邏輯限制的 condition | NMU rx_vc_arbiter.sv:35：上游 invalid 時 payload 清零，NarrowR encoding 非零，因此 valid=0/is_r=1 不可達 | 保留 instance 與接線證據；本輪未加 waiver |
| 固定拓撲／參數 | 單 source、固定 coordinates、ID width、REG_TYPE、ROB mode | 以代表性合法組態補驗證；不任意更改預設值 |

以上為具體抽查與功能對照，尚非所有 uncovered line/toggle 的逐項 signoff。

## 建議執行順序（待 review）

| 順序 | 項目／原因 | 測試方式 | 驗收 |
|---|---|---|---|
| 0 | 修正 coverage 定義 | 以標準 covergroup 補 active-lane full/partial/zero WSTRB、4 KB/SAM boundary；現有 stimulus 已含這些情境 | Bin 與 handshake/transaction 對應；不改 data/order checker、不追求所有 WSTRB popcount |
| 1 | Reorder + response backpressure | 沿用現有 AXI driver/receive hooks，分別 hold BREADY/RREADY，讓 backpressure 穿過 response FIFO；再搭配既有亂序流量 | B/R hold path 與 output-stall bins 命中；payload 穩定；同一測試有實際 inversion，並確認被 stall transaction 的關聯；解除後 checker drain |
| 2 | Capacity / reuse | 依當次深度產生足夠 requests，分開壓到 per-ID limit、NSU AW/AR context、B/R ROB 的限制，再釋放 responses | 各目標 instance 呈現 limit/full → admission block → release → accept；data/order 正確且無殘留，不以 source outstanding 或 no-tail-space 代替 occupancy |
| 3 | HoL blocking / arbitration | 阻塞指定 destination／VC，另送使用獨立可用資源的流量；沿用 driver/backpressure 機制 | 被阻塞流量尚未釋放時其他 eligible flow 已前進；解除後全部完成。共享 FIFO 的固有 HoL 另行記錄，不誤判為 arbiter bug |
| 4 | Random reset recovery | 先固定整合平台的共同 reset 契約；於有 pending transaction 時 reset，reset 後發送新 transactions | 證明 reset 時 occupied、舊 transaction 不洩漏、reset 後重新完成；checker 同步清除 epoch，不能只以 pending-reset bin 判 PASS |

先做 0–2，確認結果後再做 3–4。保持正常 single/burst cases 無人工 stall；
壓力情境以明確的測試設定執行，不默默改變原有性能 baseline。暫不增加 public case 名稱或 Make target。
既有 private backpressure/capacity recipes 可優先沿用，但須確認它們真正命中上表資源。

現有 concurrent random 使用 master.run，未走 receive_b/receive_r 的 hold hooks；
因此不能只在 random schedule 填入 stall 值就宣稱有 backpressure。
優先使用現有 sequential receive 路徑或既有 driver 能力，不另寫 AXI master。

## 後續組態與範圍確認

- 獨立 AXI/NoC clocks、ROB mode、REG_TYPE、ID width：另選少量代表性合法組態，不改預設值。
- 當前單 source、NoC/device ID 同寬，不能涵蓋不同 source key 壓縮到同一 device ID 的競爭；需較窄 device ID 或多 source。
- FIXED/WRAP、response errors：先確認規格與 TB 支援。TB 目前要求 OKAY，不能直接用 non-OKAY 當正向測試；SAM miss 也不能擅自改成產生 DECERR。
- Collective、multisource、Router RTL/multihop：獨立範圍，不將此 baseline 延伸宣稱為全 NoC signoff。
- Fairness/progress 與 no-avoidable-bubble 應對照實際 eligible/grant/credit；
  latency bound 與吞吐門檻 [TBD]，不凭空設定數字。

## 證據與重現

工作站：/home/mingwei/noc_project/sim/build/native-coverage-baseline/
- baseline.vdb：本輪獨立 15-test snapshot；URG tests.txt 確認沒有混入前輪六個 tests。
- urg/dashboard.html、grpinfo.txt、modinfo.txt：原生工具報告。
- results.json、reports/、各 case log：PASS、cycles、command、source/stimulus digests。
- prior-six-cases.vdb：前輪完整 VDB 備份，原有報告保留。

本機：build/native-coverage-baseline/；下載的 167 個 URG 檔案與 55 個 log/provenance 檔案均 SHA256 驗證。
既有指令：make sim COVERAGE=1 MODE=auto CASE=<case> REPORT=<report-directory>；
先完成相同 source/config 的 compile。本輪 cached binary 直接重用。
報告：urg -full64 -dir <baseline.vdb> -report <urg-directory> -format both。


## Follow-up

The approved stress extension and native coverage merge are recorded in [Stress acceptance](verification-stress-results.md). The baseline above remains historical.
