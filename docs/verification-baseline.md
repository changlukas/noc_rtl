# NI coverage baseline — 2026-10-02

## 執行範圍

一個 NMU RTL、單個 C++ Router、四個 NSU RTL、AXI memories；既有 15 個 case，
MODE=auto、既有生成 seed=1、AXI/NoC 同頻 1 GHz、source/NoC/device ID width=3/3/3。
功能與參數未修改；404 份既有 pattern 檔案內容與前次同步一致。
共用 direct-link TB 已同步相同 coverage 支援，本輪只執行整合環境的完整 15-case baseline。

Base RTL revision：834fdb253ff662d605f01a6e7e1d5734704e3053。
本輪新增的 coverage observer 只讀取 DUT／interface，沿用原有 data/order checker。

## Case 結果

15/15 Functional PASS，15/15 Scenario HIT；HIT 只代表 testplan 為該 case 定義的必要事件，
不表示完整規格或所有 cross coverage 已完成。既有 burst length sweep 各點均已命中。

| Case | Completion cycles | Functional | Scenario |
|---|---:|---|---|
| ctrl_write_single | 27 | PASS | HIT |
| ctrl_read_single | 26 | PASS | HIT |
| ctrl_write_burst | 1078 | PASS | HIT |
| ctrl_read_burst | 1078 | PASS | HIT |
| single_id_outstanding | 98 | PASS | HIT |
| multi_id_outstanding | 98 | PASS | HIT |
| multi_id_out_of_order | 99 | PASS | HIT |
| single_id_reorder | 102 | PASS | HIT |
| data_write_single | 29 | PASS | HIT |
| data_write_burst | 312 | PASS | HIT |
| data_read_single | 28 | PASS | HIT |
| data_read_burst | 312 | PASS | HIT |
| ctrl_rand | 653 | PASS | HIT |
| data_rand | 679 | PASS | HIT |
| request_rand | 626 | PASS | HIT |

Cycles 為第一筆 master AXI AW/AR handshake 到最後一筆 B/RLAST handshake，包含首尾 cycle。
request_rand 為 626 cycles，與前次整合結果相同；本輪未重建 C++ DPI。

## 實際覆蓋與缺口

下列事件為 15 次執行的加總；跨多 instance 的 cycle count 不等於全局 elapsed cycles。

| 觀察 | 本輪結果 | 解讀／後續 |
|---|---:|---|
| FIFO full | 378 instance-cycles | 只有 9 個受觀察 queue instance 發生，不代表所有 FIFO |
| FIFO full 後再次接受 push | 112 次 | 部分 FIFO 已有 recovery；不等於全系統容量回復測試完成 |
| Credit zero | 686 instance-cycles | 確實耗盡過 budget；單獨 zero 不等於有 pending flit 被阻塞 |
| Credit zero 時回補 | 127 次 | 有實際 refill-from-zero |
| Credit zero 時 give+take | 108 次 | 同 cycle 回補與送出有命中 |
| R ROB 無尾端可配置空間 | 237 cycles | ctrl_rand 184、request_rand 53；不能稱所有 ROB entries 都 occupied |
| B ROB 無尾端可配置空間 | 0 | 未命中 |
| Per-ID limit admission 壓力 | W/R 均 0 | 下一批需依容量規劃流量 |
| NSU AW/AR context full | 四個 NSU 均 0 | 下一批補 shared context 容量與 collision/reuse |
| Read/write pending 重疊 | 0 | 現有 co-sim write/read phases 沒有涵蓋並行 |
| ROB output stall | B/R 均 0 | reorder × backpressure 尚未命中 |
| 非 2 次方 burst length | AW/AR 均 0 | 下一批擴充既有 burst/random stimulus |
| Zero write strobe | 0 | 下一批補 strobe 類型；本輪只量測 strobe population，不宣稱完整 partial-lane coverage |
| Reset 時有 pending request | 0 | 本輪無 reset recovery stimulus |
| HoL isolation、independent-clock CDC | 尚未量測 | 不能由一般 stall 或同步 clock 執行推定通過 |

Ordering case 的確產生亂序：

| Case | B inversion | R completion inversion | ROB retirement |
|---|---:|---:|---|
| multi_id_out_of_order | 1 次 cross-ID | 12 次 cross-ID | 不要求使用 ROB |
| single_id_reorder | 1 次 same-ID | 12 次 same-ID | B 2 次、R 12 beats |

Inversion 定義：response 進入 NMU ordering 並握手時，仍有較早接受、尚未返回的 request。
R 以 RLAST completion 計算；不是相鄰 flit 次序下降次數，也不是 read-beat interleaving。
資料與 AXI 順序是否正確仍由既有 checkers 判定。

## VCS coverage

15 個 test 的合併 hierarchy 結果（含實際使用的 primitive 與 DUT 內 simulation guards/checker）：

| Metric | Coverage |
|---|---:|
| Line | 84.42% |
| Condition | 69.07% |
| Toggle | 76.14% |
| Branch | 77.16% |
| FSM | 工具未提供 extracted FSM coverage（--），不能解讀為 100% |

未啟用 multidimensional-array toggle，因此不宣稱 payload memory 每個 bit 都已覆蓋。
VCS 2017 assertion 報告另外包含 TB/interface/package：588 個 assertion，0 failure，
88 個 uncovered、2 個 without attempts。這些分類有重疊，不相加；也不以 mixed SCORE 判定完成度。

已確認需要分類的例子：

- SAM 的 collective mask 分支未走到；目前 topology 的 collective_en=0。這是目前組態缺口，
  不能直接宣稱整個設計不支援 collective 或將其無條件 waive。
- FIFO full antecedent、部分 arbitration lock antecedent 未觸發，需增加對應壓力情境。
- spill-register flush 分支在本組態 tie-off，應逐項確認是否屬合法 exclusion。
- runtime fatal/error 分支未執行，需依規格與既有 negative-test 證據分類，不能為衝高百分比任意注入非法流量。

本輪未新增 coverage waiver 或 signoff 百分比門檻。

## 驗證與重現

- VCS M-2017.03-SP1 編譯、15 個 case 與 URG report generation 完成。
- Codegen 與 215 項 Python checks 通過；包括 coverage 缺事件與觀察不完整的報告分類測試。
- 既有 C++ DPI cache 的 size/mtime 未變。
- 原有 ordering checker address-decode port-width warning 保留；本輪未修改 upstream checker。
- Coverage hierarchy 已加入 SV cache key；case requirements/report metadata 的更新以既有 log 重新分析，未改 stimulus 或重跑模擬。

詳細原始資料保留於本機 ignored 目錄：
`build/coverage-baseline/reports/build/report_coverage_wave0/`、
`build/coverage-baseline/reports/build/coverage-baseline/urg/`。
每個 case JSON 含 source manifest digest、stimulus digest、binary 與執行 command；下載檔案以 SHA256 核對。
工作站 VDB：
`/home/mingwei/noc_project/sim/build/vcs_wave0_f6fffbcb1052/simv.vdb`。

## 下一批優先項目

1. 整理 read/write burst 的重複 stimulus，補非 2 次方 length 與合法 address boundary。
2. 沿用既有能力補 partial/zero strobe、read/write concurrency。
3. 對 per-ID／NSU context／B ROB 的未命中容量條件規劃 directed stress；R ROB 已觀察到尾端空間不足，需分辨原因。
4. 後續再加入 HoL、reorder+backpressure、reset recovery，以及參數／clock regression。

測試規劃依據：[verification-testplan.md](verification-testplan.md)。
