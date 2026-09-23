# M4 Mac mini 的感測器，哪些數字能信、哪些在騙你

*測試環境：Mac mini M4（Mac16,10）、macOS 26（25G83），2026 年 9 月。只有一台機器（n = 1）。文中每個數字都附原始檔出處；是推論的地方會直接標「推論」。*

事情的起點很單純：我想知道 Mac mini 跑長時間 build 或轉檔的時候，CPU 到底有沒有被熱降頻。

結果這件事在 Apple Silicon 上沒那麼好回答。常見工具讀到的「CPU 頻率」和「CPU 溫度」都是真的數字，只是它們回答的問題，跟你以為的不是同一個。這篇整理我在 M4 上實際對照出來的結果，包括一場風扇曲線 A/B 測試，以及後來我為什麼讓 AI coding agent 看「有沒有降頻」決定要不要等，而不是看溫度。工具放在文末，前面的發現就算不用這個工具也成立。

---

## 一、IOReport 算出來的頻率是「請求檔位」，不是硬體頻率

macmon、asitop 這類不需要 root 的工具，頻率來自私有框架 `libIOReport`：拿 `CPU Stats / CPU Core Performance States` 通道每個 P-state 的 residency 加權，再乘上 `pmgr` 裡 `voltage-states5-sram` 的頻率表。

我在同一秒拿它跟 `powermetrics --samplers cpu_power` 對照。後者讀的是硬體計數器，要 root：

| 時刻 | IOReport `PCPU` residency | powermetrics `P-Cluster HW active frequency` |
|---|---|---|
| 重載（load 23） | `V19P0` 100%（表值 4464 MHz） | **3936 MHz**，100% 停在 3936 |
| 重載 | `V19P0` 100% | 4187 MHz（3936 16% / 3984 19% / 4044 20% / 4416 32% / 4464 13%） |
| 重載 | `V19P0` 100% | 4130 MHz |

*出處：`docs/findings-m4-sensors.md` §1*

IOReport 的四組 CPU 通道我全都試過：`CPU Core Performance States`、`CPU Complex Performance States`、`CPU Complex Voltage States`、`Core Performance Level`。結果都一樣，重載時停在最高檔，動都不動。E-core 也有同樣的狀況：IOReport 顯示 100% 在 `V7P0`（2892 MHz），硬體實際跑 2808。

我的解讀是，IOReport 反映的是軟體向 DVFS 請求的檔位。硬體在功耗和溫度限制下實際跑出來的頻率在更下面一層，而降頻偏偏就發生在這一層。**所以在 M4 上，用 IOReport 算頻率的工具，在你最需要看到降頻的時候看不到。** 目前我找到唯一能讀硬體頻率的是 `powermetrics`，而且要 root。

兩個踩過的小坑：

- `powermetrics -n 0` 不是「無限取樣」，取完第一筆就結束。要無限取樣就不要帶 `-n`。
- 常駐一個 `powermetrics -i 5000` 子行程，每筆大約 0.18% CPU，另外啟動時一次性花掉約 0.8 秒 CPU（findings §1）。長期實測的數字在後面。

這一條我對 macmon 開了 [issue #78](https://github.com/vladkens/macmon/issues/78)，請手上有其他晶片的人幫忙驗證。我自己只在一台 M4 上確認過。

## 二、M4 上 IOHID 的「CPU 溫度」，其實是 PMU 溫度

另一條不用 root 的路是 `IOHIDEventSystemClient`（usage page `0xff00`、usage 5）。M4 上讀得到 40 個溫度感測器，名字是 `PMU tdie1…14`、`PMU tdev1…8`、`PMU tcal`、`PMU2 …`、`NAND CH0 temp`。M1 那一代這條路還有 `pACC MTR Temp Sensor`，那才是真正的核心感測器，但 M4 已經沒有了。

PMU 是 Power Management Unit，主機板上另一顆 IC（有 `PMU`、`PMU2` 兩顆），負責把電源轉成 SoC 各區的電壓。`tdie` 是它自己的晶片溫度。它負責供電給 CPU，所以溫度趨勢會跟著 CPU 走，但物理位置不在核心熱點上：

| 時刻 | IOHID `PMU tdie` 最高 | SMC `Tp*` 最高 | SMC `TCMz` |
|---|---|---|---|
| 1 | 62.7°C | 84.7°C | — |
| 2 | 62.2°C | 77.9°C（`Tp3X`） | **77.9°C** |

*出處：findings §2*

SMC（`AppleSMC` IOKit service、`IOConnectCallStructMethod` selector 2，讀取不需要 root）有每顆核心旁邊的 key：P-core 是 `Tp*`，E-core 是 `Te*`。另外還有一個 `TCMz`，我判斷是 Apple 自己的「SoC 最高溫」聚合值，實測每一筆都剛好等於 `max(Tp*)`。

所以如果某個工具顯示的 M4 溫度比另一個低 15–20°C，那不是 SMC 讀太高，而是兩邊量的根本是不同的晶片。另一種正常的差異是「平均 vs 最高」：macmon 在 macOS 14 以後也改讀 SMC，但顯示的是各 key 的平均（這台重載時約 60–68°C），我取的是最高值（同一時刻 78–85°C），因為降頻看的是最熱的那個點。兩個數字都對，只是回答不同的問題。

## 三、M4 有 1375 個 SMC key，不要寫死

啟動時把所有 key 列出來：`#KEY` 取總數，selector 8 依索引取名字。篩出 `T` 開頭、型別 `flt` 或 `sp78`、值落在 10–120 的，再依前綴分組：`Tp` P-core、`Te` E-core、`Tg` GPU、`TH0` SSD。這台 M4 分出來是 **CPU 55 個、GPU 18 個，共 73 個**（`/var/run/cool42/state.json` 的 `cpuKeys`/`gpuKeys`）。

風扇相關的 key：`FNum`、`F0Ac`（實際轉速）、`F0Tg`（目標轉速）、`F0Mn`/`F0Mx`（韌體回報的範圍，M4 mini 是 1000–4900 rpm）、`F0Md`（手動模式）。讀取不需要權限，寫 `F0Md=1` 和 `F0Tg` 要 root。換晶片的時候改設定檔裡的前綴就好，不用改程式。

## 四、「正常」長什麼樣：閒置 40 幾度，負載一來就大跳

開始讀每核最高溫之後，第一個反應通常是「怎麼跳這麼兇」。其實多半是 M4 的正常特性：

- **閒置和輕負載大概落在 40 幾度。** 近四天 guard log 的 2184 筆 SMC 寫入中，最低溫是 44°C，其中 40–49°C 這一段有 313 筆（`/var/log/cool42.log`，2026-09-20 01:18 到 09-23 23:42，共 94.4 小時）。
- **短工作會讓 P-core 在一個 5 秒取樣內從 50 幾度跳到 80 度，再跳回來。** 這是我自己踩出來的：第一版的 warm 門檻只有 3°C 遲滯，兩天半寫了 1742 條 `ok ↔ warm`（CHANGELOG 1.0.1。那段原始 log 已經不在了，無法重算）。後來改成要連續 6 輪（30 秒）都低於門檻才降級，之後 94.4 小時只剩 32 條。兩段時間的工作量不一樣，所以這個比較只能當參考。
- **寫入時的溫度分布：** 中位數 65°C、平均 64.6°C；40 幾度 313 筆、50 幾度 331、60 幾度 752、70 幾度 631、80 幾度 126、90 幾度 31。要注意，guard 只在轉速目標或狀態改變時才寫 log，不是固定間隔取樣，所以這**不是**「各溫度區間佔多少時間」的分布。

每核最高溫 5 秒內跳 30 度不是故障。如果控制迴圈每一筆都照單全收，風扇只會一直在追雜訊。

## 五、降頻到底什麼時候才會發生

M4 mini 原廠的風扇策略是安靜優先。下面這組數字是**別人機器上的外部資料，不是我自己量的**（[theenterprisemac](https://theenterprisemac.com/post/768543525732237312/m4mini-thermal-throttle)、[MacRumors](https://forums.macrumors.com/threads/mac-mini-m4-thermals.2442671/)、[MacRumors](https://forums.macrumors.com/threads/is-100-105-cpu-celsius-on-the-new-m4-mini-thermal-throttling.2442865/)）：重載 10–15 分鐘後，SoC 停在 105–107°C、風扇約 2100 rpm，P-core 從 4464 掉到 3300–3800 MHz，也就是少了 15–25%。

在我這台機器上，全核重載時 `powermetrics` 讀到的是 **3936 MHz、thermal pressure `Nominal`**。3936 是 M4 全核滿載時的功耗上限頻率（單核最高是 4464）。這是功耗上限，不是熱降頻，pressure 顯示 `Nominal` 就是證據。

這篇最想講的就是這件事：**溫度和降頻是兩個不同的訊號。** 我的 guard 第一次從原廠手上接管時，log 是 105°C / 1774 rpm，20 秒後變成 82°C / 4618 rpm（README「實測」段，那段原始 log 也不在了）。至於現在這份 94.4 小時的 log：

- 每日最高溫依序是 93、94、94、78°C（最後一天只算到 23:42），log 裡最高是 95°C（出現 3 次），100°C 以上 0 次
- ≥ 90°C 的寫入有 31 次
- 每一天 thermal pressure 不是 `Nominal` 的秒數都是 **0 秒**（`/var/log/cool42.log` 每日結算、`/var/db/cool42/stats.json`）

有一個我還沒完全解釋清楚的地方，先講出來，免得被別人挖出來：90–95°C 那幾行 log 裡，P-core 頻率（⚡ 欄位）的中位數是 3.64 GHz，比全核的 3.936 GHz 低，但這段時間 pressure 一直是 `Nominal`。我的推論是部分負載或功耗上限造成的，但這只是推論。換句話說，「Nominal」不等於「每一顆核心都在 3936」。

## 六、風扇曲線 A/B：少轉 25%，只換來多 3.8°C

既然目標從「溫度越低越好」改成「不要降頻」，問題就變成：要讓 pressure 保持在 `Nominal`，風扇最低可以轉多慢？

測試條件：兩段都跑同一個 Python 幾何運算 workflow（兩個行程各吃 400–800% CPU，10 核 load average 22–42），每條曲線跑 5 分鐘，每 10 秒記一筆 `cool42 status --short`，每段丟掉前 60 秒的過渡期（`docs/ab-test-2026-09-16/`）。

| | A（舊預設，激進） | B（現行預設） | 差 |
|---|---|---|---|
| 曲線（°C→rpm） | 55→1000 65→1800 75→3000 85→4200 90→4900 | 60→1000 75→1800 85→2600 92→3600 97→4900 | |
| 控制溫度平均（範圍） | 83.0°C（75–88） | 86.8°C（77–93） | +3.8°C |
| 風扇平均（範圍） | 4216 rpm（3952–4542） | 3150 rpm（2344–3805） | −1066 rpm（−25%） |
| load average | 23.1–37.1 | 21.9–41.6 | |
| P-core 硬體頻率 | 3936 MHz ×3，Nominal | 3936 ×5、3950 ×1，Nominal 6/6 | ≈0 |
| CPU 功耗 | 21.5–22.1 W | 16.8–21.2 W | |
| 噪音（估算） | | | −6.3 dB |

*出處：`samples.txt`（重新計算過）、`powermetrics-A.txt`、`powermetrics-B.txt`、同目錄 `README.md`*

以下幾點要先講清楚，因為這段最容易被引用：

- **powermetrics 的取樣是在 A/B 時段的前後，不在時段內。** A 的 3 筆是 05:00:41–47，在 A 段 05:06:01 開始之前；B 的 6 筆是 05:19:04–05:20:44，B 段已經在 05:16:14 結束。所以嚴格的說法是「同一個負載下，測試前後的 powermetrics 都是 3936 MHz、Nominal」，不是「同一時刻實測頻率不變」。repo 裡 README 把 B 那 6 筆寫成「穩態」，說得太寬了。
- −6.3 dB 是用風扇定律 `50·log10(4216/3150)` 推算的，沒有拿分貝計量。
- **沒有「同一個工作總共跑多久」的比較**，也沒有同一台機器、同樣負載下的原廠對照。所以我不會說快了幾 %。
- 一台機器、一個房間、一次 10 分鐘的測試。

即使有這些限制，這個結果已經足夠讓 B 成為預設：多 4°C，風扇少轉四分之一，pressure 也沒有離開過 `Nominal`。

## 七、讓 AI agent 只在真的降頻時才等

我很常讓 Claude Code 在這台機器上跑 `swift build`、`ffmpeg`、Python 批次，而且常常好幾個同時跑。Claude Code 有 `PreToolUse` hook，每次執行 Bash 前可以先跑一支程式，決定放行、等待或擋下。「機器已經很吃力了，先別再開一個重工作」這件事，放在這裡剛好。

**第一版是看溫度：SoC ≥ 90°C 就等。** 換成 B 曲線之後，重載穩態落在 80 幾到 90 出頭，結果幾乎每次 Bash 前都在等。等於拿實際的工作進度，去換一個沒有意義的溫度數字。

現在改成看 root daemon 從 `powermetrics` 讀到的 thermal pressure：

| thermal pressure | hook | `cool42 check` exit |
|---|---|---|
| `Nominal` | 放行，**不管幾度** | 0 |
| `Moderate` / `Heavy`，或 GPU 被 CLTM 壓超過 5% | 等它恢復（最多 90 秒）再放行 | 1 |
| `Trapping` / `Sleeping` | 擋下（可關閉） | 2 |
| 溫度 ≥ 100°C | 不管 pressure 一律擋（安全底線） | 2 |

**風扇的工作是讓降頻不要發生，hook 的工作是降頻真的發生時才介入。** hook 本身不碰 SMC、也不開 `powermetrics`，只讀 daemon 每 5 秒寫一次的 JSON 快照，每次約 9 ms（README 的數字，這次沒有重測）。

另外還有**預熱**：指令看起來是重工作（`swift build`、`xcodebuild`、`ffmpeg`、`python -m`、`make`…）時，hook 丟一個事件，daemon 在熱度上來**之前**先把風扇拉到 3000 rpm 兩分鐘。94.4 小時內觸發了 32 次（ffmpeg 25、`python3 -m` 3、`swift build` 2、`xcodebuild` 1、`make` 1）。其中 3 次在 30–45 秒後自己提早收掉，因為溫度一直在曲線起點以下，判斷不像重工作。

同樣這四天：≥ 90°C 的時刻 31 次，**hook 等待 0 次、擋下 0 次、非 Nominal 0 秒**。*推論：如果還是第一版的 90°C 規則，這 31 個時刻 agent 都會被卡住。*

這份資料能證明的是，沒必要的時候 gate **不會擋路**。但現在這份 log 裡沒有任何一次真實的「降頻 → 等待 → 恢復放行」。對風扇控制來說這是好事，只是我也因此沒辦法拿真實案例示範 gate 觸發。接下來打算用原廠曲線加壓力測試做一次受控重現。

## 八、成本，以及為什麼一定要 root

整套系統只有一個部分是 root：一個 LaunchDaemon，負責寫 SMC 風扇 key，並常駐一個 `powermetrics -i 5000` 子行程。寫 `F0Md`/`F0Tg` 本來就要 root，而且第一節提到，M4 上要看到硬體頻率也只有這條路。其他部分（選單列面板、hook、CLI、給 agent 用的 MCP server）都以使用者身分執行，只讀權限 644 的 JSON 檔。README 有一張威脅模型表，逐一列出這些檔案介面，包括 1.0.2 修掉的 `/tmp` symlink 問題。

2026-09-23 用 `ps` 量的長期平均：guard 加 `powermetrics` 子行程合計**單核 0.49%**（0.27% + 0.22%），guard RSS 11.3 MB。這比 README 寫的數字高（合計 0.3%、guard 3.5 MB），README 那份是較早量的，已經過時。量測當下，guard 已經連續跑了 3 天 21 小時，中間沒有重啟過。

兩個可能幫你省一天的教訓：

- **風扇 daemon 不要設成 Background QoS。** 第一版 LaunchDaemon 用 `ProcessType Background` + `Nice 10`，load 35 時啟動後卡了三分鐘才跑完第一輪，1375 次 SMC 呼叫全部塞在 `mach_msg2_trap` 排隊。風扇守門員最需要工作的時候，正是系統最忙的時候，偏偏這時 Background QoS 分不到 CPU。後來改成 `Standard` + `Nice -5`。
- **直接 `cp` 蓋掉已簽章、還在跑的執行檔，之後新開的行程都會被 kernel 以 `OS_REASON_CODESIGNING` 殺掉。** 要先 cp 成 `.new`，再 `mv` 過去。

## 限制

- 只在**一台 Mac mini M4** 上測過。M4 Pro/Max、M1–M3、M5、MacBook 都沒測過；IOReport 在 M1/M2 上是否也跟硬體頻率脫節，也不知道。
- 原廠策略的數字是外部資料，不是我自己量的。
- 沒有端到端的總耗時比較。
- 目前是 ad-hoc 簽章（還沒有 Developer ID，也沒做 notarization），`install.sh` 會在本機從原始碼編譯並自簽。

---

## 工具：cool42

上面這些都是做 **cool42** 的過程中挖出來的。cool42 是 Apple Silicon 的風扇守門員，包含：跑風扇曲線的 root daemon；選單列面板，有每顆感測器一格的熱度格（73 個 SMC 感測器全部攤開），也有真實的 P-core 頻率與 pressure；一個 CLI；以及實作第七節 gate 的 Claude Code hook + MCP server。純 Swift 加上約 170 行 C（SMC 與 libproc），沒有外部依賴，40 個單元測試，MIT 授權。

它同時也是一次「讓 AI 把工具做出來」的實驗：大部分程式是和 Claude Code 一起寫的，約 4 天、42 個 commit，從 0.1 走到 1.0.3。1.0.1 的四個修正，是讓 agent 自己讀 2.5 天份的 guard log 找出來的。

- Repo：<https://github.com/Okle42/cool42>
- 感測器原始筆記（中英）：`docs/findings-m4-sensors.md`
- A/B 原始資料：`docs/ab-test-2026-09-16/`

如果你手上是其他 Apple Silicon 機器，最有幫助的是 `cool42 chip`、`cool42 sensors`、`cool42 doctor` 的輸出。不裝也沒關係，只要在重載下對照一次 `powermetrics` 和 IOReport 就很有價值。這樣才知道這些發現是不是只有這台 M4 才成立。

*— okle42*
