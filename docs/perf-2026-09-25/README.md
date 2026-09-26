# 原廠自動 vs cool42 曲線：四次同機實跑（2026-09-25）

> **當時名稱為 cool42**（cool42 原名 cool42，2026-09-27 改名）。這個資料夾的原始數據（`run*/perf.log`、`run*/pm/*`、`run*/results.*`、`run*/summary.md`、`guard-log-2026-09-25-1110.txt`）是量測當時的輸出，保留原樣，裡面的指令、路徑與標題都還是 `cool42`（例如 `/usr/local/bin/cool42`、`/etc/cool42/config.json`、`/var/log/cool42.log`）；本文與 `recompute.py` 已改用新名稱。

目的：同一台 Mac、同一個負載下，把風扇交給 macOS 原廠自動與 cool42 曲線，比較溫度、轉速、P-core 頻率與工作量；順便抓「pressure 還是 Nominal、但頻率已經掉了」的無聲降頻。

**一句話（照資料能說到的程度）**：CPU＋GPU 滿載時，原廠自動讓風扇停在約 2,950 rpm、溫度 106.8°C（取樣窗平均），P-core 從 3936 掉到 3644 MHz（−7.4%），thermal pressure 全程 Nominal；cool42 曲線同負載 4,877 rpm、104.4°C、P-core 3936 全速，工作量多 4.7%。**原廠穩態只有 1 輪、而且是熱機起跑**（腳本降溫判定 bug），冷機起跑的兩輪 35–40 秒就超過 112°C 被切掉，所以這是 n=1 的對照，不是定論。

所有數字都能用 `python3 docs/perf-2026-09-25/recompute.py` 從本資料夾的原始檔重算（下面「重算表」就是它的輸出）。

## 環境（四次都一樣）

- Mac mini M4（Mac16,10），macOS 27.0，10 核；來源：各 `runN/summary.md` 第 3 行、`perf.log` 第 2 行
- 負載：10 個 sha256 worker（run3、run4 另加 Metal GPU 滿載 `extras/gpu_burn.swift`）；每檔取樣 90 秒
- 順序：cool42 曲線#1 → 原廠自動#1 → cool42 曲線#2 → 原廠自動#2（`perf.log` 第 3 行）
- cool42 曲線：60°C→1000、75°C→1800、85°C→2600、92°C→3600、97°C→4900（`summary.md` 第 8 行）
- 「原廠自動」＝ cool42 設定 `mode=auto`：guard 照跑但把風扇交還 SMC，不寫轉速
- 室溫沒控制；guard 當時是安裝中的舊版（沒有時脈降頻判斷）

## 四次實跑

| 資料夾 | 時間 | 負載 | 腳本版本（推論） | 中止門檻 | 換檔前降溫 | 有效的檔 |
|---|---|---|---|---|---|---|
| `run1-cpu/` | 10:32–10:36 | CPU | `dd5c71a`（第一版） | 所有檔 103°C | **沒有** | 第 1 檔（曲線#1）；原廠 2 檔都在 103°C 被切 |
| `run2-cpu/` | 10:43–10:55 | CPU | `b02c114` | 曲線 103°C／原廠 108°C | 停負載＋風扇 4900，降到 75°C | 曲線#1、#2（穩態）；原廠 2 檔在 108°C 被切，只看得到前 46–56 秒 |
| `run3-cpugpu/` | 11:06–11:17 | CPU＋GPU | `3414881` | 曲線 103°C／原廠 112°C | 同上（降溫檔用 curve） | **只有第 4 檔（原廠#2）**：6.5 分鐘未收斂、以現況取樣；曲線 2 檔都在 103°C 被切 |
| `run4-cpugpu/` | 11:46–12:04 | CPU＋GPU | `a21d480` | 曲線與原廠共用 112°C（`meta.args.abort_temp` 103 只管固定轉速檔） | 停負載 ≥120 秒、降到 55°C 並維持 30 秒 | 曲線#1、#2（穩態）；原廠 2 檔冷機起跑 35–40 秒衝過 112°C 被切 |

腳本版本是推論：`results.json` 沒記 commit，是用 `meta.args` 有哪些參數（`auto_abort_temp`、`gpu`、`cooldown_min`…）和各 commit 的預設值、commit 時間對出來的（`dd5c71a` 沒有 `--auto-abort-temp`；`b02c114` 預設 108、`--cooldown-to 75`；`3414881` 加 `--gpu`、改 112；`a21d480` 加 `--cooldown-min 120`／`--cooldown-hold 30`、`--cooldown-to 55`，並讓曲線檔也改用 112°C 上限）。

### 已知 bug

- **run1 沒有換檔前降溫**：第一版腳本換檔不停負載。曲線#2 一開始就 105.9°C（`run1-cpu/perf.log` 第 50 行）、原廠#2 起跑 101.7°C（第 55 行），都立刻被 103°C 切掉。只有第 1 檔能用。
- **run3（以及 run2）降溫判定太早**：`--cooldown-to 75` 看的是控制溫度，停負載後晶片幾秒內就掉到 75°C 以下，但散熱片還是熱的。`run3-cpugpu/perf.log` 第 35、57 行「降溫完成：69.8°C（0s）」「69.3°C（0s）」，接著原廠#2 **t+0 就 100.8°C、2627 rpm**（第 59 行）＝熱機起跑。run2 同樣 0–5 秒就算降完（第 52、70、118 行），原廠兩輪 t+0 是 89.8／90.5°C（第 54、120 行）。`a21d480` 改成至少停 120 秒＋維持 30 秒，run4 的降溫就都是 121 秒（`run4-cpugpu/perf.log` 第 9、47、61、98 行）。
- run3 原廠#2 是在這個 bug 下量到的：它是唯一的原廠穩態數據，但起跑條件和 run4 的曲線不同。

## 結論（附出處）

### 1. CPU-only：原廠先把風扇降到 1000 rpm，104–106.6°C 才開始拉

<picture><source media="(prefers-color-scheme: dark)" srcset="../img/charts/perf-cpu-auto60-dark.svg"><img src="../img/charts/perf-cpu-auto60-light.svg" alt="CPU-only 原廠接手後 60 秒：風扇停在 1000 rpm、溫度從 91.5 爬到 105.2°C，106.6°C 才開始拉轉速"></picture>

- run2 原廠#1：接手後 5 秒轉速就從 4817（降溫檔留下）掉到 1005，t+5–35s 都是 1000–1005 rpm，溫度 91.5 → 105.2°C；t+40s 106.6°C 才第一次 >1000（1152），之後每 5 秒 +204／+202／+222 rpm；t+56s 108.5°C、1780 rpm 被腳本切（`run2-cpu/perf.log` 第 54–66 行）。
- run2 原廠#2：1000–1001 rpm 到 t+30s（104.0°C），t+35s 106.4°C 開始拉，+67／+178／+194；t+46s 108.0°C、1439 rpm 被切（第 120–130 行）。
- run1 原廠#1：t+5–25s 都 999–1001 rpm，95.0 → 103.4°C 被 103°C 切（`run1-cpu/perf.log` 第 40–46 行）。
- 被切之前 P-core 輪詢全是 3936 MHz、pressure 全是 Nominal（同上各行）。**CPU-only 沒看到降頻就被切了**，不能說原廠 CPU-only 會或不會降頻。

### 2. CPU＋GPU：原廠風扇停在 ~2950 rpm，P-core 掉 7.4%，pressure 全程 Nominal

<picture><source media="(prefers-color-scheme: dark)" srcset="../img/charts/perf-cpugpu-dark.svg"><img src="../img/charts/perf-cpugpu-light.svg" alt="CPU＋GPU 滿載：原廠自動風扇停在 2,951 rpm、P-core 3,644 MHz、pressure 全程 Nominal；cool42 曲線 4,854 rpm、3936 MHz"></picture>

來源：run3 第 4 檔（原廠#2）＝ `run3-cpugpu/perf.log` 第 55–140 行、`results.json` `results[3]`、`results.csv` 第 5 行、`pm/04-auto-r2.txt`（90 筆）。

- 風扇：t+45s 起停在 2946–2954 rpm（70 筆輪詢平均 2,950；`perf.log` 第 68–137 行），取樣窗 2,951 rpm（2947–2955）。同一台風扇在 cool42 曲線下會跑到平均 4,901、4,895–4,910（`run4-cpugpu/results.csv` 第 4 行），所以原廠沒用到上面那一段。
- 溫度：t≥45s 輪詢平均 107.9°C（P10–P90 106.4–109.4，全距 105.0–111.5）；90 秒取樣窗平均 106.8°C、最高 108.9°C（`results.csv` 第 5 行）。
- P-core：取樣窗 powermetrics 平均 3,643.8 MHz，比全核滿載 3936 **−7.4%**；P5–P95 3603–3686、全距 3562–3706（`pm/04-auto-r2.txt` 的 `P-Cluster HW active frequency`）。輪詢值 t+30s 起從 3918 一路往下，t≥150s 都在 3599–3700（`perf.log` 第 65–137 行）。
- pressure：輪詢 79/79、powermetrics 90/90 都是 Nominal ⇒ **時脈掉了、系統沒說（無聲降頻）**。P-core 掉 7.4% 是實測；歸因於熱（同時有 GPU CLTM 13–18%）是推論，功耗上限造成的可能沒有直接排除。
- 當時的舊版 guard 有記到降頻，但是靠 GPU CLTM：`/var/log/cool42.log` 11:10:08、11:10:24、11:11:16 三次「熱降頻開始：pressure Nominal … GPU CLTM 16%／18%／13%」（摘錄在 `guard-log-2026-09-25-1110.txt` 第 3、5、7 行）。只有 CPU 重載、GPU 沒被限時，舊版只看 pressure 就會漏掉。
- 冷機起跑衝過 112°C：run4 原廠#1 從 84.7°C 起跑、t+20s 106.1°C 仍 1000 rpm、t+35s 112.6°C 被切，接手後風扇最高 1437（`run4-cpugpu/perf.log` 第 49–57 行）；原廠#2 85.9°C 起跑、t+40s 112.6°C 被切、最高 1714 rpm（第 100–109 行）。112.6°C 是被切那一刻的讀值，**真正峰值沒量到**。run3 原廠#1（熱機起跑）t+20s 就 112.2°C（`run3-cpugpu/perf.log` 第 37–42 行）。

### 3. cool42 曲線同負載：104.4°C、4,877 rpm、3936 MHz 全速，工作量多 4.7%

來源：run4 第 1、3 檔＝ `run4-cpugpu/results.csv` 第 2、4 行、`perf.log` 第 43、94 行、`pm/01-curve-r1.txt`＋`pm/03-curve-r2.txt`（180 筆）。

- 溫度 104.15／104.68 → 平均 104.4°C；風扇 4,854／4,901 → 平均 4,877 rpm；P-core 180/180 筆 3936 MHz、pressure 180/180 Nominal。
- ops/s 17,912.9／17,836.3 → 平均 17,874.6；比 run3 原廠 17,066.2 多 **+4.74%**（逐輪 +4.96%／+4.51%）。
- 代價（同一組數據）：CPU 功率 23.89 vs 20.34 W（+17.5%），**每焦耳工作量原廠多 12%**（ops/J 839.2 vs 748.1）。降頻省電，只是做得比較慢。
- 限制：原廠只有 1 輪（n=1）、熱機起跑；曲線與原廠來自兩次實跑（相隔約 40 分鐘），腳本版本不同（`3414881` vs `a21d480`；兩版 diff 只動降溫、上限與報表，worker／gpu_burn／ops 計數沒改）；室溫沒控制。

### 4. 噪音只能推估

轉速比 4,877 / 2,951 → 50·log10 ≈ **+10.9 dB**（風扇定律：聲功率 ∝ 轉速⁵）。**這是推論，沒有量 dB**；實際聽感還跟風扇頻譜、機殼有關。

### 5. 新版 guard 的「降頻」定義（`6f35a19`，尚未安裝）

guard 記錄與累計的「降頻」＝以下任一成立：

1. thermal pressure 非 Nominal（原本就有）
2. **時脈降頻**：控制溫度 ≥ `clockThrottleTemp`（100°C）且 P-core 硬體頻率 < 全核滿載 × `clockThrottleRatio`（3936 × 0.95 ≈ 3739 MHz）；頻率回到 ×0.97 以上或溫度低於門檻 − `levelHysteresis` 才解除
3. GPU CLTM 限頻（原本就有）

全核滿載頻率用實測表，目前只有 Apple M4 = 3936（依據：本資料夾所有 curve 檔 powermetrics 450/450 筆都是 3936 MHz；見重算表第 5 項）；表外晶片不判斷時脈降頻，可用 `clockFullLoadMHz` 自訂。拿本資料夾的數據套：run3 原廠#2 取樣窗 3644 MHz、106.8°C ⇒ 會判定降頻；run4 曲線 3936 MHz ⇒ 不會。這是用規則回推，**新版 guard 還沒實機跑過**。

## 重算表

`python3 docs/perf-2026-09-25/recompute.py` 的輸出（trace＝`results.json` 的 `results[i].trace`，就是 `perf.log` 每 5 秒一行；pm＝`pm/*.txt`）：

| # | 項目 | 重算值 | 算法／出處 |
|---|---|---|---|
| 1 | run2 原廠#1：接手後轉速 | 1000–1005 rpm 共 7 筆（t+5–35s） | `run2-cpu/results.json` `results[1].trace[1:]`，rpm ≤ 1010 視為 1000 |
| 1 | run2 原廠#1：停在 1000 時溫度 | 91.5 → 105.2°C（+13.8°C / 30s） | 同上 |
| 1 | run2 原廠#1：開始拉轉速 | 最後一筆 1000 在 105.2°C，第一筆 >1000 在 106.6°C；每 5 秒 +152/204/202/222 | 相鄰兩筆 rpm 差 |
| 1 | run2 原廠#1：中止時 | 108.5°C、1780 rpm；P-core 全 3936；pressure 全 Nominal | `results[1].reason` |
| 1 | run2 原廠#2：接手後轉速 | 1000–1001 rpm 共 6 筆（t+5–30s） | `results[3].trace[1:]` |
| 1 | run2 原廠#2：停在 1000 時溫度 | 93.1 → 104.0°C（+10.9°C / 25s） | 同上 |
| 1 | run2 原廠#2：開始拉轉速 | 最後一筆 1000 在 104.0°C，第一筆 >1000 在 106.4°C；+67/178/194 | 相鄰兩筆 rpm 差 |
| 1 | run2 原廠#2：中止時 | 108.0°C、1439 rpm；P-core 全 3936；pressure 全 Nominal | `results[3].reason` |
| 1 | run1 原廠#1 | 999–1001 rpm 共 5 筆；95.0 → 103.4°C；P-core 全 3936；Nominal | `run1-cpu/results.json` `results[1]` |
| 2 | run3 原廠#2：起跑 | t+0 100.8°C、2627 rpm；降溫判定 69.3°C、0 秒就算完成 | `run3-cpugpu/results.json` `results[3].trace[0]`、`cooldown_end_c`／`cooldown_s` |
| 2 | run3 原廠#2：風扇（t≥45s 輪詢） | 平均 2,950、2946–2954 rpm（n=70） | `results[3].trace`，t ≥ 45 |
| 2 | run3 原廠#2：溫度（t≥45s 輪詢） | 平均 107.9°C、P10–P90 106.4–109.4、全距 105.0–111.5 | 同上 |
| 2 | run3 原廠#2：取樣窗 | 106.8°C（最高 108.9）、2,951 rpm（2947–2955） | `results[3]`；`results.csv` 第 5 行 |
| 2 | run3 原廠#2：P-core（pm 90 筆） | 平均 3,643.8 MHz（−7.4%）、P5–P95 3603–3686、全距 3562–3706 | `pm/04-auto-r2.txt` |
| 2 | run3 原廠#2：P-core（t≥45s 輪詢） | 平均 3,680、3599–3800 MHz | `results[3].trace` |
| 2 | run3 原廠#2：pressure | 輪詢 79/79、pm 90/90 Nominal | trace、pm「Current pressure level」 |
| 2 | run3 原廠#2：功率 | CPU 20.34 W、GPU 12.65 W | pm「CPU Power」「GPU Power」 |
| 2 | run3 原廠#2：工作量 | 17,066.2 ops/s（839.2 ops/J） | `results[3]` |
| 2 | run4 原廠#1 | 84.7°C 起跑 → t+35s 112.6°C 被切；接手後風扇最高 1437；Nominal | `run4-cpugpu/results.json` `results[1]` |
| 2 | run4 原廠#2 | 85.9°C 起跑 → t+40s 112.6°C 被切；最高 1714；Nominal | `results[3]` |
| 2 | run3 原廠#1 | 100.1°C 起跑（熱機）→ t+20s 112.2°C 被切；接手後最高 1374；Nominal | `run3-cpugpu/results.json` `results[1]` |
| 3 | run4 曲線 2 輪：溫度 | 104.15 / 104.68 → 104.41°C | `run4-cpugpu/results.json` `results[0]`／`[2]` |
| 3 | run4 曲線 2 輪：風扇 | 4,854 / 4,901 → 4,877 rpm | 同上 |
| 3 | run4 曲線 2 輪：P-core（pm 180 筆） | 全部 3936 MHz；pressure 180/180 Nominal | `pm/01-curve-r1.txt`＋`03-curve-r2.txt` |
| 3 | run4 曲線 2 輪：ops/s | 17,912.9 / 17,836.3 → 17,874.6 | 同上 |
| 3 | 曲線 vs 原廠 ops/s | +4.74%（逐輪 +4.96% / +4.51%） | run4 平均 ÷ run3 第 4 檔 |
| 3 | 曲線 vs 原廠 溫度 | 104.4 vs 106.8°C（−2.4°C） | 取樣窗平均 |
| 3 | 曲線 vs 原廠 CPU 功率 | 23.89 vs 20.34 W（+17.5%） | pm CPU Power 平均 |
| 3 | 曲線 vs 原廠 ops/J | 748.1 vs 839.2（−10.9%；原廠每焦耳多 12%） | `ops_per_j` |
| 4 | 噪音推估（推論，非量測） | 50·log10(4,877/2,951) = +10.9 dB | 風扇定律 |
| 5 | 全核滿載 3936 的依據 | run1／run2／run4 所有 curve 檔 pm 450/450 筆 = 3936 MHz | `pm/*curve*.txt` |

### 和先前口頭結論的出入

- 「原廠 P-core 3624–3689 MHz」：重算後取樣窗是**平均 3,644、P5–P95 3603–3686、全距 3562–3706**；3624–3689 大約是中間八成，不是全距。
- 「原廠穩態約 107–109°C」：輪詢（t≥45s）平均 107.9、P10–P90 106.4–109.4；但**90 秒取樣窗平均是 106.8°C**。對照表一律用取樣窗平均（106.8 vs 104.4）。
- 「冷機起跑峰值 > 112.6°C」：正確說法是「被切時讀值 112.6°C，真正峰值沒量到」。
- 「105–106°C 才開始拉、每 5 秒約 +200」：最後一筆 1000 rpm 在 104.0／105.2°C，第一筆拉升在 106.4／106.6°C；每步 +67–222（7 步裡 5 步在 +178–222）。
- 「約 −7.5%」：重算 −7.4%（3643.8 / 3936）。
- 另外補一項原本沒提的代價：原廠每焦耳工作量多 12%。

## 還不能宣稱的

- 原廠穩態 n=1、熱機起跑；冷機起跑兩輪都在 112°C 被切。要拿到原廠冷機穩態只能放寬上限或接受熱機起跑，需要再跑幾輪。
- 同一工作的總耗時沒量；+4.7% 是穩態 ops/s，不是「快 4.7%」。
- 噪音沒量。室溫沒控制。只有 1 台 Mac mini M4。
- 新版 guard（`6f35a19`）的時脈降頻判斷還沒實機驗證。

## 檔案

| 檔案 | 內容 |
|---|---|
| `runN-*/summary.md` | 腳本自動產的摘要 |
| `runN-*/results.json` | 每檔結果＋`trace`（每 5 秒：溫度、轉速、P-core、pressure）；`meta.args` 是當時參數 |
| `runN-*/results.csv` | 每檔一行（第 1 行是欄名，第 N+1 行是第 N 檔） |
| `runN-*/perf.log` | 執行過程逐行紀錄 |
| `runN-*/pm/*.txt` | powermetrics 原始輸出（每秒一筆，只在有取樣的檔） |
| `guard-log-2026-09-25-1110.txt` | `/var/log/cool42.log` 第 4020–4030 行摘錄（run3 原廠#2 期間） |
| `recompute.py` | 重算上面所有數字；`--viz` 另外寫 `extras/viz/data/perf-2026-09-25.json` 給圖表用 |

原始資料夾的 `/Users/<名字>` 路徑已改成 `~`（只出現在 `results.json` 的 `meta.args.out_dir`）；其他內容照原樣。圖表：`python3 extras/viz/build_charts.py` 產 `docs/img/charts/perf-cpugpu-*.svg`、`perf-cpu-auto60-*.svg` 與 `docs/viz/index.html`。
