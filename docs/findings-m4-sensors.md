# Apple Silicon (M4) 上四條讀「CPU 頻率 / 溫度」的路徑，哪些是真的

*Findings from building cool42, 2026-09-16. Mac mini M4 (Mac16,10), macOS 26 (25G83). English summary at the bottom.*

*環境註記：本文的感測器對照與 A/B（2026-09-16）在 macOS 26 上量；2026-09-20 起的 94 小時運作 log 與 2026-09-25 的原廠對照（§4、§5）是在 macOS 27.0（26A428）上跑的。*

寫風扇守門員的過程中，我需要知道「CPU 現在有沒有被熱降頻」。這件事在 Apple Silicon 上比想像中難，因為常見工具讀的數字和硬體實際狀態不一樣。以下是四條路徑的同秒對照。

## 1. 頻率：IOReport 給的是軟體請求檔位，不是硬體頻率

macmon、asitop 這類不需 root 的工具，用私有框架 `libIOReport` 的 `CPU Stats / CPU Core Performance States` 通道算頻率：每個 P-state 的 residency 加權，乘上 `pmgr` 的 `voltage-states5-sram` 頻率表。

同一秒對照 `powermetrics --samplers cpu_power`（硬體計數器，需 root）：

| 時刻 | IOReport `PCPU` residency | powermetrics `P-Cluster HW active frequency` |
|---|---|---|
| 重載（load 23） | `V19P0` = 100%（最高檔，表值 4464 MHz） | **3936 MHz**，residency 100% 在 3936 |
| 重載 | `V19P0` = 100% | 4187 MHz（3936 16% / 3984 19% / 4044 20% / 4416 32% / 4464 13%） |
| 重載 | `V19P0` = 100% | 4130 MHz |

IOReport 的四組 CPU 通道都試過：`CPU Core Performance States`（每核）、`CPU Complex Performance States`（cluster）、`CPU Complex Voltage States`、`Core Performance Level`。全部一樣：重載時停在最高檔不動。

**結論**：IOReport 反映的是軟體向 DVFS 請求的檔位；M4 硬體在功率 / 熱限制下實際跑的頻率比請求低，而這一層 IOReport 看不到。**用 IOReport 算頻率的工具，在最需要看降頻的時候看不到降頻。** 要硬體頻率只能 `powermetrics`，要 root。

E-core 也有同樣現象：IOReport `ECPU` 100% 在 `V7P0`（表值 2892），硬體 2808。

附帶：`powermetrics -n 0` 不是「無限取樣」，會在第一筆後退出；要無限就不帶 `-n`。常駐一個 `-i 5000` 子行程的持續成本早期實測 0.18% CPU（初始化一次 0.8 秒 CPU）；2026-09-23 用 `ps` 量的長期平均是 0.22% 單核。

## 2. 溫度：IOHID 的「CPU 溫度」是 PMU 溫度

不需 root 的第二條路是 `IOHIDEventSystemClient`（usage page 0xff00 / usage 5），在 M4 上讀到 40 個溫度感測器，名稱是 `PMU tdie1…14`、`PMU tdev1…8`、`PMU tcal`、`PMU2 …`、`NAND CH0 temp`。M1 世代這條路還有 `pACC MTR Temp Sensor`（真正的核心感測器），M4 上已經沒有，只剩 PMU 系列 —— 所以在 M4 上靠 IOHID 拿 CPU 溫度，拿到的只能是 PMU 溫度。（macmon 在 macOS 14+ 已改走 SMC `Tp/Te/Ts` 取平均，只有舊系統才退回 IOHID；其他只走 IOHID 的小工具則會落到 PMU 值。）

同時刻對照 SMC（`AppleSMC` IOKit service，`IOConnectCallStructMethod` selector 2，不需 root）：

| 時刻 | IOHID `PMU tdie` 最高 | SMC `Tp*` 最高 | SMC `TCMz` |
|---|---|---|---|
| 1 | 62.7°C | 84.7°C | — |
| 2 | 62.2°C | 77.9°C（`Tp3X`） | **77.9°C** |

**PMU = Power Management Unit**，是主機板上另一顆 IC（M 系列有兩顆，`PMU` / `PMU2`），負責把電源轉成 SoC 各區域的電壓。`tdie` 是它自己的 die 溫度、`tdev` 是它量的周邊、`tcal` 是校正參考。它供電給 CPU 所以趨勢跟著走，但物理上不在核心熱點，絕對值低 15–20°C。

SMC 的 `Tp*` 是 SoC 內每顆 P-core 旁的感測器（M4 有 55 個 `Tp*`/`Te*` key），`TCMz` 是 Apple 自己的「SoC 最高溫」聚合 key，實測 `TCMz == max(Tp*)`。熱管理與降頻看的是這個。

**結論**：IOHID 溫度趨勢對、絕對值不對。看到別的工具 CPU 溫度比 SMC 讀的低 15–20°C，不是 SMC 虛高。另一個常見差異是「平均 vs 最高」：macmon 顯示 SMC 各 key 的平均（M4 重載時約 60–68°C），cool42 用最高值（同時刻 78–85°C），因為熱管理與降頻看的是熱點。兩者都對，只是問的問題不同。

## 3. M4 上 SMC 共 1375 個 key（溫度 key 另外篩），不用寫死

啟動時列舉所有 key（`#KEY` 取數量、selector 8 依索引取名），篩 `T` 開頭、型別 `flt`/`sp78`、值在 10–120 之間，再依前綴分組：`Tp*` P-core、`Te*` E-core、`Tg*` GPU、`TH0*` SSD、`TCMz` SoC max。這台 M4 分出 CPU 55 個、GPU 18 個，共 73 個 CPU/GPU 溫度 key（SSD 等其他 `T*` 另計）。前綴放設定檔，換晶片改設定就好。風扇 key：`FNum`、`F0Ac`（實際）、`F0Tg`（目標）、`F0Mn`/`F0Mx`（韌體回報的範圍，M4 mini = 1000–4900）、`F0Md`（手動模式）。寫 `F0Md=1` + `F0Tg` 要 root。

## 4. Mac mini M4 原廠風扇策略的數字

| 情境 | 溫度 | 風扇 | 來源 |
|---|---|---|---|
| 原廠，重載，cool42 接管前一刻（本機） | 105°C | 1774 rpm | 早期 guard log（原始檔已輪替） |
| 原廠，重載 10–15 分後 | 105–107°C | ~2100 rpm，P-core 4464 → 3300–3800 MHz | **外部資料**，非本機同負載 |
| cool42 接管後 20 秒（本機） | 105 → 82°C | 目標 4900、20 秒後實際 4618 rpm | 早期 guard log（原始檔已輪替） |
| cool42 A/B 曲線 B，重載 5 分鐘（本機） | 平均 86.8°C（77–93） | 平均 3150 rpm | `ab-test-2026-09-16/samples.txt`；B 段內**沒有** powermetrics |
| A 曲線（B 前後，本機） | — | — | powermetrics P-core 3936 MHz、pressure Nominal（B 結束、還原 A 後約 3 分鐘起 6 筆，及 A 段前 3 筆） |
| **原廠自動，CPU＋GPU 滿載穩態（本機，2026-09-25）** | 106.8°C（取樣窗平均） | 2,951 rpm（上限 4,900 沒用到） | P-core 平均 3,644 MHz（比全核 3936 −7.4%），pressure 輪詢 79/79、powermetrics 90/90 **Nominal**；n=1、熱機起跑；`perf-2026-09-25/run3-cpugpu/` |
| cool42 預設曲線，同負載（本機，2026-09-25） | 104.4°C | 4,877 rpm | P-core 3936 MHz（180/180）、Nominal；ops/s 比原廠多 4.7%、CPU 功率多 17.5%；`perf-2026-09-25/run4-cpugpu/` |
| 原廠自動，CPU＋GPU 冷機起跑（本機，2026-09-25） | 84.7／85.9 → 35–40 秒到 112.6°C 被腳本切 | 最高 1,437／1,714 rpm | 真正峰值沒量到；同次實跑 cool42 曲線全程最高 105.2／105.7°C |
| 原廠自動，CPU-only（本機，2026-09-25） | 91.5 → 105.2°C 期間停在 1000 rpm，104–106.6°C 才開始拉 | 1000 → 每 5 秒 +67～+222 | 108°C 被腳本切之前 P-core 3936、Nominal，沒看到降頻；`perf-2026-09-25/run2-cpu/` |

原本表內「原廠重載 96–105°C / 1000–1774 rpm」一列沒有留下原始檔，已拿掉。2026-09-25 之前本機唯一的原廠數據點是接管前一刻的 105°C / 1774 rpm；之後有了同機同負載的對照（上表後四列），但原廠穩態只有 1 輪、熱機起跑，且和曲線那兩輪來自相隔約 40 分鐘的兩次實跑，限制與已知 bug 見 [`perf-2026-09-25/README.md`](perf-2026-09-25/README.md)。外部報告的約 −15～−26% 是以單核峰值 4464 為基準，本機 −7.4% 以全核 3936 為基準，不能直接比。噪音差（約 +10.9 dB）是用轉速比推估，沒量。

原始資料：[`ab-test-2026-09-16/`](ab-test-2026-09-16/)、[`perf-2026-09-25/`](perf-2026-09-25/)。

## 5. 讓 AI agent 自己節流：判斷依據是降頻，不是溫度 —— 而降頻不能只問 thermal pressure

Claude Code 的 PreToolUse hook 可以在每次執行 Bash 前跑一支程式決定放行 / 等待 / 擋下。第一版用溫度門檻（≥ 90°C 等）。換成省風扇的 B 曲線後，重載溫度落在 77–93°C（A/B 的 B 段，平均 86.8°C），90°C 以上的時候每個 Bash 前都要等，拿工作進度換一個沒意義的溫度數字（「每個 Bash 都在等」出自第一版當時的 log，原始檔已不在）。

第二版改看 `powermetrics` 的 thermal pressure（加上 GPU CLTM）：Nominal 放行（不看溫度）、Moderate / Heavy 等它回 Nominal、Trapping 擋。溫度只當備援（拿不到 pressure 時）和安全底線（≥ 100°C）。

**2026-09-25 的對照證明只看 pressure 不夠**（§4 表）：原廠自動在 CPU＋GPU 滿載下 P-core 掉了 7.4%，pressure 從頭到尾都是 Nominal。當時的 guard 會記到「降頻」，只是因為 GPU 剛好被 CLTM 限了 13–18%，而且兩度在 P-core 仍只有 3761 / 3729 MHz 時判「降頻結束」（[`perf-2026-09-25/guard-log-2026-09-25-1110.txt`](perf-2026-09-25/guard-log-2026-09-25-1110.txt)）。

所以「降頻」改成以下任一成立：

1. thermal pressure 非 Nominal
2. GPU CLTM 限頻 > 5% 時間
3. **時脈降頻**（尚未發布）：控制溫度 ≥ `clockThrottleTemp`（100°C）且 P-core 硬體頻率 < 全核滿載 × `clockThrottleRatio`（0.95）；頻率回到 × 0.97 以上或溫度低於門檻 − `levelHysteresis` 才解除。全核滿載頻率用實測表，目前只有 Apple M4 = 3936 MHz（09-25 所有曲線檔 powermetrics 450/450 筆）；表外晶片不判斷，可用 `clockFullLoadMHz` 自訂。不讓 guard 自己學峰值，因為高溫下單核會衝到 4464，學到之後全核 3936 會被誤判

套到 09-25 的數據（照規則回推，新版還沒實機跑過）：原廠 106.8°C、3644 MHz ⇒ 判降頻；cool42 曲線 104.4°C、3936 MHz ⇒ 不判。要注意預設 `criticalTemp` 也是 100°C、hook 先看 critical：在預設設定下，這種 ≥ 100°C 的無聲降頻 hook 本來就會因溫度擋下，時脈判斷主要修正的是「降頻」紀錄（每日降頻秒數、log、面板）；`criticalTemp` 調高時才會直接改變 hook 行為。同負載下 cool42 預設曲線也在 104.4°C，照規則 hook 一樣會擋。

**風扇的工作是讓降頻不發生，hook 的工作是在降頻真的發生時才介入** —— 但「降頻」要看時脈，不能只信 macOS 自己回報的 pressure。

hook 本身不開 SMC、不跑 powermetrics，只讀 guard 每 5 秒寫的 JSON 快照，每次 9 ms。

## 對外

- 2026-09-16 對 macmon 開了 issue [#78](https://github.com/vladkens/macmon/issues/78)（頻率那條），等社群在其他晶片上驗證。

## 沒驗證的

- 只有一台 M4 mini（n = 1）。M4 Pro / Max、M3、M5 是否相同未測。
- IOReport 在 M1 / M2 上是否也和硬體頻率脫節，未測（M1 / M2 mini 重載不降頻，可能剛好看不出差別）。
- 「原廠 vs cool42 同一 workflow 總耗時」還沒做（09-25 的 +4.7% 是穩態每秒工作量）。同機同負載的原廠對照只有 1 輪穩態、熱機起跑；冷機起跑兩輪在 112°C 被切。
- A/B 的 B 段內沒有 powermetrics 取樣，「B 曲線在那組負載下不降頻」尚未直接量到（09-25 同一條曲線在 CPU＋GPU 滿載下是 3936 MHz，負載不同）。
- 時脈降頻判斷還沒實機跑過；全核滿載頻率只有 M4 一筆。
- 3936 MHz 是否就是全核功耗上限，是推論。

---

## English summary

**Setup**: Mac mini M4 (Mac16,10), macOS 26 for the sensor comparisons and the A/B run; the 94-hour runtime log (from 2026-09-20) and the 2026-09-25 stock comparison are on macOS 27.0. Sensor comparisons in 1–2 are same-second.

1. **IOReport CPU frequency is the software-requested DVFS state, not the hardware frequency.** Under sustained load, IOReport `CPU Core Performance States` sits at 100% `V19P0` (table value 4464 MHz) while `powermetrics` `P-Cluster HW active frequency` reads 3936–4187 MHz. All four IOReport CPU channel groups behave the same. Tools that derive frequency from IOReport (macmon, asitop, …) cannot see power/thermal throttling on M4. Hardware frequency requires `powermetrics` (root). Note: `powermetrics -n 0` exits after one sample; omit `-n` for unlimited. A resident `-i 5000` process cost 0.18% CPU in an early measurement, 0.22% of one core as a long-run `ps` average.
2. **On M4, IOHID only exposes PMU temperatures.** The `pACC MTR Temp Sensor` entries that existed on M1 are gone; what's left is `PMU tdie/tdev/tcal`. `PMU tdie` max 62°C vs SMC `Tp*` max 78–85°C at the same instant. PMU = Power Management Unit, a separate IC. SMC `TCMz` (Apple's own SoC-max key) equals `max(Tp*)` exactly. IOHID tracks the trend but reads 15–20°C low. (macmon uses SMC on macOS 14+, averaged; cool42 uses the max because throttling follows the hotspot.)
3. **M4 exposes 1375 SMC keys in total**; the temperature keys (55 CPU + 18 GPU = 73 on this machine, plus SSD and others) can be discovered at runtime (`T*`, type `flt`/`sp78`, 10–120 range) and grouped by prefix (`Tp` P-core, `Te` E-core, `Tg` GPU, `TH0` SSD). Fan: `F0Ac/F0Tg/F0Mn/F0Mx/F0Md`.
4. **Stock M4 mini fan policy**: on this machine, 105°C at 1774 rpm the moment before cool42 took over; external reports (other machines) put P-cores at 3300–3800 MHz after 10–15 min, down from 4464. In our A/B, a curve averaging 3150 rpm held the SoC at 86.8°C on average (77–93°C). No powermetrics sample was taken during that 5-minute window; samples taken with the old curve active (just before, and ~3 min after the config was restored) read 3936 MHz and pressure Nominal. Whether 3936 MHz is the all-core power limit is an inference. **Same machine, same load (2026-09-25, CPU + GPU)**: macOS auto parked the fan at 2,951 rpm (max 4,900) at 106.8 °C and the P-cores averaged 3,644 MHz (−7.4% vs the all-core 3936) with thermal pressure `Nominal` in 79/79 polls and 90/90 `powermetrics` samples; the cool42 default curve ran 4,877 rpm, 104.4 °C, 3936 MHz, +4.7% ops/s, at 17.5% more CPU power (stock gets 12% more work per joule). From a cold start, stock reached 112.6 °C within 35–40 s and was cut off (true peak not measured); the curve peaked at 105.7 °C. Stock steady state is n = 1 and a warm start; noise (+10.9 dB) is a fan-law estimate. Raw data: `perf-2026-09-25/`.
5. **Agent self-throttling**: gate a coding agent's tool calls on throttling (go when not throttled; wait when throttled; deny on Trapping), not on temperature. But **thermal pressure alone is not enough**: on 09-25 the P-cores lost 7.4% while pressure stayed `Nominal`. "Throttling" in cool42 is now any of: pressure above Nominal, GPU CLTM > 5%, or (unreleased) a clock check — control temp ≥ `clockThrottleTemp` (100 °C) and P-core clock < full-load × `clockThrottleRatio` (0.95), with the full-load clock from a measured table (M4 = 3936 MHz only; other chips off unless `clockFullLoadMHz` is set). With default settings the hook's 100 °C critical floor already denies at those temperatures, so the check mainly makes the throttling record honest. The fan's job is to prevent throttling; the gate's job is to act only when it actually happens.

Not verified: other chips (n = 1), IOReport behaviour on M1/M2, end-to-end wall-clock gain, a cold-start stock steady state (only one warm-start stock run), pressure / clocks during the B window, the clock check on real hardware.
