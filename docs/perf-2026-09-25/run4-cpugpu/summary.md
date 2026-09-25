# macOS 原廠自動 vs cool42 曲線：同機同負載穩態對照

- 機器：Apple M4（Mac16,10），macOS 27.0，10 核
- 時間：2026-09-25 11:46:35 → 2026-09-25 12:04:23
- 負載：10 個 sha256 worker ＋ Metal GPU 滿載（gpu_burn）；每檔取樣 90 秒；穩態判準 60 秒內 ΔT < 1.5°C（非固定檔位另要 Δrpm < 200），最短 120 秒、最長 480 秒
- 順序：cool42 曲線#1 → macOS 原廠自動#1 → cool42 曲線#2 → macOS 原廠自動#2
- 起始：控制溫度 46.1°C，load avg 2.47 2.42 3.94
- cool42 曲線（量測時的設定）：60°C→1000、75°C→1800、85°C→2600、92°C→3600、97°C→4900

## 各檔位穩態（有量到的平均；重複 ≥2 次附最小–最大）

| 檔位 | n | 控制溫度 °C | 風扇 rpm | P-core MHz | CPU W | ops/s | ops/J | worst pressure | 到穩態 s |
|---|---|---|---|---|---|---|---|---|---|
| cool42 曲線 | 2/2 | 104.4（104.2–104.7） | 4877（4854–4901） | 3936（3936–3936） | 23.89（23.89–23.90） | 17874.6（17836.3–17912.9） | 748.05（746.57–749.53） | Nominal | 146（143–148） |
| macOS 原廠自動 | 0/2 | 未量到：溫度 112.6°C ≥ 112，中止（t+35s，期間風扇最高 1437 rpm）；溫度 112.6°C ≥ 112，中止（t+40s，期間風扇最高 1714 rpm） |||||||||

## 原廠 vs cool42

curve 與 auto 沒有都量到，無法對照。

## 降頻觀察

| 檔位 | 輪 | 結果 | 平均溫度 | 風扇 | P-core 硬體頻率 | 比全速 3936 | worst pressure |
|---|---|---|---|---|---|---|---|
| cool42 曲線 | 1 | converged | 104.2 °C | 4854 rpm | 3936 MHz | +0.0 % | Nominal |
| macOS 原廠自動 | 1 | aborted | 112.6 °C | 1437 rpm | — MHz | — % | Nominal |
| cool42 曲線 | 2 | converged | 104.7 °C | 4901 rpm | 3936 MHz | +0.0 % | Nominal |
| macOS 原廠自動 | 2 | aborted | 112.6 °C | 1714 rpm | — MHz | — % | Nominal |

- 第 1 輪：沒抓到降頻（溫度 112.6°C ≥ 112，中止（t+35s，期間風扇最高 1437 rpm））；期間最高 112.6°C、風扇最高 1437 rpm
- 第 2 輪：沒抓到降頻（溫度 112.6°C ≥ 112，中止（t+40s，期間風扇最高 1714 rpm））；期間最高 112.6°C、風扇最高 1714 rpm

## 讀法與限制

- ops = 每 worker 每 2000 次 sha256 記 1 次；ops/J 用 powermetrics 的 CPU Power（不含 DRAM、風扇、整機）。
- 「pressure 降頻」= thermal pressure 離開 Nominal（cool42 hook 目前的判斷）。另看 powermetrics 的 P-core 硬體頻率：2026-09-25 實測原廠自動在 pressure 全程 Nominal 下 P-core 從 3936 掉到約 3640 MHz（無聲降頻），所以兩個都要看。
- 頻率與功率來自 powermetrics 硬體計數器（`P-Cluster HW active frequency`、`CPU Power`）；溫度與轉速來自 cool42 status。
- 「macOS 原廠自動」= cool42 設定 mode=auto：guard 仍在跑但把風扇交還 SMC，不寫任何轉速。
- 同一台機器、同一負載、同一天；室溫沒控制，順序效應用 A/B/A/B 重複緩解。
- 原始資料：results.json（含每檔穩態過程）、results.csv、pm/*.txt（powermetrics 原始輸出）、perf.log。
