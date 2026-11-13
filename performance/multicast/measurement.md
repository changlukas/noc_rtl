# Multicast 量測場景與結果

本批為 single-row、2 KiB 的四個案例。完整 1–32 KiB 與 2D 矩陣尚未完成。

## 1. 量測場景

比較 pipelined sequential forwarding（seq）、binary-tree forwarding（tree）與 hardware multicast（hw），將同一份資料分發到相同收件者。比較方式依據 [collective 論文 §4.2.2、Fig.4／5](https://arxiv.org/html/2603.26438v2#S4.SS2.SSS2)。

| 方法 | 資料流 |
|---|---|
| seq | NI12 → NI0 → NI1 → NI2 → NI3，以 batch 沿鏈路傳遞 |
| tree | NI12 → NI0；NI0 → NI2；最後 NI0 → NI1 與 NI2 → NI3 並行 |
| hw | NI12 以一筆 multicast 將資料送至 NI0、NI1、NI2、NI3 |

每波以先前一波的所有 source B 完成為依賴。中繼 source 從實際 device memory 取得已收到的資料後轉送。各 device memory 起始為空，預期資料僅載入 checker。

## 2. 量測條件

| 項目 | 本次設定 |
|---|---|
| 平台 | 4×4 mesh；每 node 配置 AXI source VIP、NI（NMU＋NSU）、REQ／RSP／DAT router、AXI device VIP |
| AXI、NoC clock frequency | 1 GHz |
| Root／收件者 | NI12 (0,3) → row 0 的 NI0–NI3 |
| Message size | 2 KiB，每個收件者收到相同的 2048 B |
| Seq batch size | 1 KiB、2 KiB，取 runtime 較短者 |
| 交易 | 512-bit AXI writes，ID 0，stimulus outstanding 上限 16 |

本平台使用 VIP push writes、完成事件同步與零延遲本地記憶體存取，未計入 CPU、DMA 或硬體 barrier 指令成本。資料初始位於合法的 root AXI source，未加入 memory fetch。這些條件與原文 memory tile、DMA 及 bare-metal C++ 的成本不同。

設定與來源：[本批紀錄](provenance/preparation.json)、[公開 benchmark](provenance/reference/multicast_benchmark.c)、[原始 batch 範圍](provenance/reference/experiments.py)、[版本與 hash](provenance/reference/evidence.json)。

## 3. 指標與公式

Runtime 從 root 首次 AWVALID assertion 起算，到所有必要 source B handshake 完成。Readback 在量測後執行。

```text
Runtime [cycles] = (t_last_required_B − t_root_AWVALID) / Tclk
Tseq = min(Tseq_batch1KiB, Tseq_batch2KiB)
Tsw = min(Tseq, Ttree)
Speedup = Tsw / Thw
```

所有方法使用相同的事件定義，不加 1 cycle。Seq 的 batch 候選來自保存的公開 benchmark，此 2 KiB message 對應 1 KiB、2 KiB 兩個候選。

## 4. 實驗結果

| 方法 | Batch size | Runtime [cycles] | FSDB |
|---|---:|---:|---|
| seq | 1 KiB | 186 | [波形](results/row-seq-2kib-b1k/runs/row_seq_2kib_b1k/row_seq_2kib_b1k.fsdb) |
| seq | 2 KiB | 208 | [波形](results/row-seq-2kib-b2k/runs/row_seq_2kib_b2k/row_seq_2kib_b2k.fsdb) |
| tree | 2 KiB | 162 | [波形](results/row-tree-2kib/runs/row_tree_2kib/row_tree_2kib.fsdb) |
| hw | 2 KiB | 70 | [波形](results/row-hw-2kib-retry/runs/row_hw_2kib/row_hw_2kib.fsdb) |

本點最佳 software baseline 為 tree，speedup = 162／70 = **2.314286×**。

資料：[四個量測點](tables/points.csv)、[speedup](tables/speedup.csv)、[公式與實際 command](provenance/measurement.json)、[量測程式快照](provenance/performance.py)。各 result 保留 inputs、config、raw AXI events、FSDB、source／seed／hash 與 validation。

```sh
cd /home/mingwei/noc_rtl
make -C sim perf_multicast_report
```
