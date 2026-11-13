# Interference 量測場景與結果

## 1. 量測場景

四條 row 從最左側向最右側傳送 bulk writes，走 DAT；中間兩條 column 從上向下傳送固定 8 B small writes，走 REQ／RSP。目的地不交換，四個角落節點只參與 bulk traffic。

![Interference data flow](figures/data-flow.png)

| 流量 | 來源 → 目的 |
|---|---|
| DAT req | NI0 → NI3、NI4 → NI7、NI8 → NI11、NI12 → NI15 |
| Narrow req | NI1 → NI13、NI2 → NI14 |

本場景量測不同 DAT burst size 下兩類 write 的完成延遲。這是本專案採用的交叉流量，參考 FlooNoC narrow／wide 的量測主題，未重現其 Fig.5 的 wide-only 硬體比較。

## 2. 工作量與條件

| 項目 | DAT req | Narrow req |
|---|---|---|
| 每筆有效資料 | 64／128／256／512／1024 B | 固定 8 B |
| AXI burst | 1／2／4／8／16 beats × 64 B | 1 beat × 8 B |
| AW／W 路徑 | DAT | REQ |
| B 回應 | RSP | RSP |
| 參與來源數 | 4 | 2 |

原生 4×4 mesh／VIP，AXI 與 NoC clock 均為 1 ns、phase 0。設定與實際交易筆數見 [逐來源資料](tables/sources.csv) 及 [案例設定快照](results/cross/split-uni-64/provenance/source/dv/config/cases.json)。

## 3. 指標與公式

ROI 為共同 ENABLE 起算的第 64 至 576 cycles，採半開區間。將來源端在 ROI 內 accepted AW 的交易納入 cohort，追蹤其 B handshake 至完成，包含 ROI 結束後才回覆的 B。

```text
ROI = [t_ENABLE + 64 ns, t_ENABLE + 576 ns)
Latency_j [ns] = t_B,j − t_AW,j
Avg. latency [ns] = sum_j(Latency_j) / N_cohort
```

AW 與 B 均取 VALID、READY 同時成立的握手時刻。兩條曲線分別對該類流量全部 cohort 交易取平均，沒有 +1 cycle。此取樣窗口是本平台定義。

## 4. 實驗結果

![Interference latency](figures/latency.png)

| DAT burst size [B] | Narrow req [ns] | DAT req [ns] |
|---:|---:|---:|
| 64 | 31 | 31 |
| 128 | 31 | 47 |
| 256 | 31 | 79 |
| 512 | 31 | 143 |
| 1024 | 31 | 271 |

本批 Narrow req 的平均延遲在五種 DAT burst size 下均為 31 ns。

資料：[圖上數值](tables/points.csv)、[逐來源資料](tables/sources.csv)、[逐筆 cohort](tables/cohort.csv)、[公式與繪圖紀錄](provenance/plot.json)、[程式快照](provenance/performance.py)。每案的設定、log、FSDB、seed／hash 與校準保存在 [results/cross](results/cross/)。

```sh
cd /home/mingwei/noc_rtl
make -C sim perf_cross_plot
```
