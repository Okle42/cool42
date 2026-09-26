# A/B 實測：激進曲線 vs 中間路線（2026-09-16）

> **當時名稱為 cool42**（cool42 原名 cool42，2026-09-27 改名）。這個資料夾的原始檔（`ab.sh`、`config-A.json`、`config-B.json`、`history-*.json`、`powermetrics-*.txt`、`samples.txt`、`timeline.txt`）保留量測當時的原樣，裡面的指令與路徑還是 `cool42`（例如 `cool42 status --short`、`/etc/cool42/config.json`、`/tmp/cool42.history.json`）；要重跑請把 `ab.sh` 裡的名稱與路徑換成 cool42 的（`/var/run/cool42/history.json`、`/etc/cool42/config.json`）。

目的：確認「風扇少轉 25%」會不會讓 M4 降頻。

結論（照資料能說到的程度）：同一負載下 B 曲線比 A 少轉 25%、控制溫度只多 3.8°C，B 段最高 93°C。**B 段 5 分鐘內沒有 powermetrics 取樣**，所以「B 段內有沒有降頻」這份資料回答不了；下面的 powermetrics 都是在 A 曲線生效時量的（見「powermetrics 取樣時間」）。

## 環境

- Mac mini M4（Mac16,10），macOS 26（25G83），cool42 guard v2（EMA 升 0.7 / 降 0.2，每輪最多降 300 rpm）
- 負載：一個 Python 幾何運算 workflow，兩個行程各 400–800% CPU，load average 22–42（10 核）
- 每段 5 分鐘、每 10 秒一筆 `cool42 status --short`，統計時丟掉前 60 秒過渡（每段剩 24 筆）；powermetrics 另外以 root 手動取樣，**不在 A、B 兩段時段內**

## 曲線

| | A：舊預設（激進） | B：新預設（中間路線） |
|---|---|---|
| curve | 55→1000 65→1800 75→3000 85→4200 90→4900 | 60→1000 75→1800 85→2600 92→3600 97→4900 |

## 結果

| | A | B | 差 |
|---|---|---|---|
| 控制溫度平均（max(CPU,GPU)） | 83.0°C（75–88） | 86.8°C（77–93） | +3.8°C |
| 風扇平均 | 4216 rpm（3952–4542） | 3150 rpm（2344–3805） | −1066 rpm（−25%） |
| P-core HW active frequency | B 段內未量 | B 段內未量 | — |
| thermal pressure | B 段內未量 | B 段內未量 | — |
| 噪音估算（風扇定律 50·log₁₀(N₁/N₂)） | — | −6.3 dB | 人耳約少 1/3 |

## powermetrics 取樣時間（兩批都是 A 曲線生效時）

| 檔案 | 時間（+0800） | 當時的曲線 | 結果 |
|---|---|---|---|
| `powermetrics-A.txt` | 05:00:41–05:00:47，3 筆 | A（測試開始前，A 是當時的設定） | 3 筆都是 P-core 3936 MHz（100% residency 在 3936）、Nominal；CPU 21.5–22.1 W |
| `powermetrics-B.txt` | 05:19:04–05:20:44，6 筆 | **A**（`ab.sh` 在 05:16:14 B 結束時已把設定還原成 A，這批是還原後約 3–4.5 分鐘） | 5/6 筆 100% 在 3936 MHz，最後一筆 3950 MHz（3936 佔 74%、3984 佔 25%）；6 筆都是 Nominal；CPU 16.8–21.2 W |

檔名 `powermetrics-B.txt` 是當時的命名，內容不是 B 曲線時段的數據。B 段峰值 93°C（05:12:50、05:14:01）當下的 pressure 也沒有量。要主張「B 曲線不降頻」，需要重做一次 A/B、讓 powermetrics 在兩段時段內同步記錄。

推論（未證實）：3936 MHz 像是 M4 全核滿載時的功耗上限頻率（單核最高 4464）。Nominal 只說明量的那一刻沒有熱壓力，證明不了 3936 是功耗上限；而且 2026-09-20～23 的 guard log 裡 ≥ 90°C 的 29 筆頻率值落在 3.04–3.96 GHz、中位數 3.64 GHz，同期 pressure 非 Nominal 0 秒 —— 「Nominal」不等於「停在 3936」。

## 對照：原廠設定（外部資料）

以下是別人機器上的外部資料，不是本機同負載的對照：M4 mini（非 Pro）原廠曲線重載 10–15 分鐘後 P-core 從 4464 掉到 3300–3800 MHz，溫度 105–107°C，風扇約 2100 rpm。
來源：[theenterprisemac](https://theenterprisemac.com/post/768543525732237312/m4mini-thermal-throttle)、[MacRumors – Mac mini M4 thermals](https://forums.macrumors.com/threads/mac-mini-m4-thermals.2442671/)、[MacRumors – 100–105°C throttling](https://forums.macrumors.com/threads/is-100-105-cpu-celsius-on-the-new-m4-mini-thermal-throttling.2442865/)

## 決定

B 成為預設（`config.example.json`、`Config.swift`、面板「均衡」），理由是風扇少 25%、溫度只多 3.8°C；是否降頻用日常運作的每日統計（降頻秒數）持續驗證。舊 A 曲線保留為面板「強力」。

## 檔案

- `samples.txt`：每 10 秒的 load / 溫度 / 風扇（A、B 各 30 筆）
- `timeline.txt`：切換時間點
- `history-A.json` / `history-B.json`：guard 每 5 秒寫的 5 分鐘歷史（含 target）
- `powermetrics-A.txt`：A 段開始前約 5 分鐘的 3 筆（A 曲線）；`powermetrics-B.txt`：B 結束、設定已還原成 A 之後約 3 分鐘起的 6 筆（見上表）
- `config-A.json` / `config-B.json`：兩段完整設定
- `ab.sh`：測試腳本（powermetrics 另外以 root 手動取樣；腳本最後一步把設定還原成 A）

## 參考資料（壽命與風扇）

- [Electronics Cooling – 每升 10°C 壽命減半是否成立](https://www.electronics-cooling.com/2017/08/10c-increase-temperature-really-reduce-life-electronics-half/)：只對電遷移、腐蝕成立；熱循環比穩態高溫更傷（Collins Radio：8×）
- [Electronics Cooling – 風扇壽命評估](https://www.electronics-cooling.com/1996/05/how-to-evaluate-fan-life/)、[Longwell – L10 計算](https://www.longwellfans.com/resources/bearing-life-calculator/)：L10 70,000 h @ 40°C，壽命 ∝ (額定/實際轉速)^1.5
- [Apple Support 101576 – 風扇與風扇噪音](https://support.apple.com/en-us/101576)：未提及目標溫度或壽命
- [Tom's Hardware – M3 Air 114°C 壓測](https://www.tomshardware.com/laptops/macbooks/m3-macbook-air-hits-eye-popping-114-degrees-celsius-in-stress-test-and-didnt-melt)
