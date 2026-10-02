# NI coverage strengthening results

2026-10-02。範圍：NMU RTL、四個 NSU RTL，整合 C++ Router 與既有 AXI memories/checkers。
DUT、參數預設值與 C++ source 均未修改。既有 432 份 stimulus 檔案 byte-identical。

## Functional acceptance

- 原本 15 cases 全部 PASS，完成 cycle 與前輪 native baseline 相同；request_rand 為 653 cycles。
- 加入三個 public cases：capacity_reuse、hol_blocking、reset_recovery，整合／direct-link 共 18 個 case 名稱。
- 整合環境共 29 個 case／mode／seed 組合 PASS。包含 control/data capacity targets、ordering backpressure、HoL 與三個 reset seeds。
- Ordering checker 的七個 positive/negative checks 通過；reset 後 R data corruption 同時被 memory scoreboard 與 ordering compare 偵測。
- Direct-link 五組複驗全部 PASS：data context reuse、control/data HoL、data reset recovery、request_rand；request_rand 維持 649 cycles。
- Codegen 與 227 項 Python checks 通過。

Reset seeds 1／17／29 分別等待 15／11／2 cycles，reset 時各有 8／8／2 筆 write 與 read pending。
Reset 丟棄舊 transaction，quiet interval 無 stale response，之後 fresh traffic 正確完成。
C++ Router 使用新 instance 清除狀態；此結果不等於 Router RTL reset 驗證。

## Native functional coverage

| 驗證目標 | URG 證據 |
|---|---|
| per-ID limit 後恢復接受 | direction_limit_reuse：2/2 |
| B/R ROB 真正 full、重新 allocation | storage_full：2/2；storage_reuse：2/2 |
| 四個 NSU AW/AR context | 八個 instances 的 full、recovery bins 均命中 |
| blocked destination 下其他 response 仍前進 | direction_hol_progress：2/2 |
| reset 後 fresh read/write 完成 | reset_recovery：2/2；pending-reset bin 命中 |
| 同一筆 inversion response 遇到 ROB output stall | reorder_backpressure：2/2 |
| 4 KB 尾端、SAM 起點／尾端 | 三組 direction × control/data crosses，各 4/4 |
| active-lane WSTRB 分類 | zero/partial/full × size：20/20 合法組合 |

NSU context 使用 FullBw queue；滿載時可在同 cycle pop/push，full 不必先降成 0。
最初 monitor 漏算此情況；以 VCS UCLI 確認四個 AR context 均曾 full 後，
改以實際接受 push 判定 reuse。Control/data context 均重新通過，cycle 不變。

URG GROUP 91.74%、instance 91.87% 是目前 coverage model 的工具分數。
本輪新增 boundary/stress groups 並修正 strobe 定義，不能直接把它與舊 GROUP 分數當作同一分母，
也不能解讀為規格完成率。沒有為了分數加入 waiver。
Sticky observation 的 bin COUNT 是 sample 次數，不是獨立故障／事件次數。

## Code coverage

相同 DUT hierarchy／參數，包含使用中的 primitives，排除 coverage monitors。

| Metric | 原本 15-case baseline | 本輪 29 組 |
|---|---:|---:|
| Line | 84.60% | 85.22% |
| Condition | 70.03% | 81.07% |
| Branch | 77.53% | 82.44% |
| Toggle | 76.82% | 78.95% |

FSM 未抽取；不代表 100%。未開啟 multidimensional-array toggle。
Assertion report 含 TB/interface/package：588 個 assertions、0 failures、35 uncovered；
其中 2 個 without attempts。它的範圍與上述 DUT code metrics 不完全相同。

## 合併與重現

URG 合併兩批相同 DUT、相容 bins 的資料，沒有 database incompatibility 警告。
第二批只修正 recovery sampling；已通過的原本 cases 不重跑。
Snapshot 僅保留 29 個通過 tests；重複 run 取較新結果，排除失敗、UCLI 除錯與錯誤注入資料。

工作站：/home/mingwei/noc_project/sim/build/coverage-strengthening/acceptance/
- baseline.vdb、stress.vdb：選定的 23 + 6 筆通過 tests。
- merged.vdb：URG 原生合併 database。
- urg/dashboard.html：29-test 報告。
- reports/、runs.json：各 run 的 command、source/stimulus digest、log。
- source-SHA256SUMS：最終同步 source manifest。

本機證據位於 build/coverage-strengthening/，HTML 與 run reports 已下載並以 SHA256 驗證。
C++ DPI cache 沿用，未重建。執行方式見 sim/README.md；stress cycle 含刻意 hold，不作 peak-throughput 比較。

## 剩餘範圍

- WSTRB 起始 lane 命中 20/64；尚缺部分 narrow-transfer 起始位置。
- W context 與部分 destination/VC FIFO 的 full/recovery 尚未命中。
- 本輪 HoL 僅驗證獨立 destination response；未驗證任意 VC、多 source 或共享 FIFO 的所有 HoL 情境。
- 獨立時脈 CDC、代表性 ID／FIFO／context／ROB／REG_TYPE 組態、transaction 多 seed 仍需另行規劃。
- 多 NMU、Router RTL、multihop、physical CDC/RDC、synthesis/STA 不在本輪範圍。
