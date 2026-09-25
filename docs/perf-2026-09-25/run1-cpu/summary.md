# macOS 原廠自動 vs cool42 曲線：同機同負載穩態對照

- 機器：Apple M4（Mac16,10），macOS 27.0，10 核
- 時間：2026-09-25 10:32:05 → 2026-09-25 10:36:38
- 負載：10 個 sha256 worker；每檔取樣 90 秒；穩態判準 60 秒內 ΔT < 1.5°C（非固定檔位另要 Δrpm < 200），最短 120 秒、最長 480 秒
- 順序：cool42 曲線#1 → macOS 原廠自動#1 → cool42 曲線#2 → macOS 原廠自動#2
- 起始：控制溫度 72.4°C，load avg 2.65 2.62 2.80
- cool42 曲線（量測時的設定）：60°C→1000、75°C→1800、85°C→2600、92°C→3600、97°C→4900

## 各檔位穩態（有量到的平均；重複 ≥2 次附最小–最大）

| 檔位 | n | 控制溫度 °C | 風扇 rpm | P-core MHz | CPU W | ops/s | ops/J | worst pressure | 到穩態 s |
|---|---|---|---|---|---|---|---|---|---|
| cool42 曲線 | 1/2 | 93.1 | 3879 | 3936 | 23.51 | 17905.7 | 761.65 | Nominal | 123 |
| macOS 原廠自動 | 0/2 | 未量到：溫度 103.4°C ≥ 103，中止；溫度 105.2°C ≥ 103，中止 |||||||||

## 原廠 vs cool42

curve 與 auto 沒有都量到，無法對照。

## 讀法與限制

- ops = 每 worker 每 2000 次 sha256 記 1 次；ops/J 用 powermetrics 的 CPU Power（不含 DRAM、風扇、整機）。
- 頻率與功率來自 powermetrics 硬體計數器（`P-Cluster HW active frequency`、`CPU Power`）；溫度與轉速來自 cool42 status。
- 「macOS 原廠自動」= cool42 設定 mode=auto：guard 仍在跑但把風扇交還 SMC，不寫任何轉速。
- 同一台機器、同一負載、同一天；室溫沒控制，順序效應用 A/B/A/B 重複緩解。
- 原始資料：results.json（含每檔穩態過程）、results.csv、pm/*.txt（powermetrics 原始輸出）、perf.log。
