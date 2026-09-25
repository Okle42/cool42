# Changelog

## Unreleased

2026-09-25 同機實測「macOS 原廠自動 vs cool42 曲線」，發現 thermal pressure 會在已經降頻時仍回報 Nominal：CPU＋GPU 滿載交給原廠，P-core 硬體頻率 3936 → 平均 3644 MHz（−7.4%），pressure 輪詢 79/79、powermetrics 90/90 全是 Nominal。資料、已知 bug 與限制在 [`docs/perf-2026-09-25/`](docs/perf-2026-09-25/)（原廠穩態只有 1 輪、熱機起跑）。

- **時脈降頻判斷（無聲降頻）**：控制溫度 ≥ `clockThrottleTemp`（預設 100°C）且 P-core 硬體頻率 < 全核滿載頻率 × `clockThrottleRatio`（預設 0.95）就算降頻，不管 pressure；頻率回到 × 0.97 以上，或溫度低於 `clockThrottleTemp` − `levelHysteresis` 才解除。快照新增 `clockThrottled`
- 「降頻」的定義改成三選一：pressure 非 Nominal、GPU CLTM > 5%、時脈降頻。hook / `cool42 check` / `wait`、每日「降頻秒數」、log（「熱降頻開始：時脈（pressure 仍 Nominal）」）、面板、`status --short`（「降頻(時脈)」）一起生效
- **全核滿載頻率用實測表**，目前只有 Apple M4 = 3936 MHz（09-25 所有曲線檔 powermetrics 450/450 筆）；**表外晶片預設不判斷**，可用新設定鍵 `clockFullLoadMHz` 自訂。不讓 guard 自己學峰值：高溫下單核衝到 4464 會被當成峰值，之後全核 3936 就被誤判。`clockThrottleRatio` 必須在 0.5–1 之間
- 預設 `criticalTemp` 100 → 108°C：09-25 CPU＋GPU 滿載時 cool42 曲線穩態 104.4°C 且全速，100 會讓全速運作也擋下 AI；108 高於 cool42 滿載穩態、低於原廠冷機起跑的峰值（35–40 秒過 112°C）。105–108°C 的無聲降頻由時脈判斷處理。設定檔寫死 100 的要自己改
- 3 條新測試（共 43 項）；**還沒實機跑過**，裝上後要再跑一次原廠對照確認不誤判、不漏判
- **perf 對照腳本**：`extras/perf_vs_temp.py`（每檔切 cool42 設定、等穩態、取樣 powermetrics，記溫度 / 轉速 / P-core 硬體頻率 / 功率 / sha256 工作量 / pressure）、`extras/run_perf_overnight.sh`（空閒檢查、防睡、備份還原設定、完成通知）、`extras/gpu_burn.swift`（`--gpu` 的 Metal 滿載）。四次實跑修掉的坑：換檔前要停負載並降溫（至少 120 秒、維持 30 秒 ≤ 55°C，只看晶片溫度會熱機起跑）；原廠自動檔與曲線檔共用 112°C 安全上限；報表加 P-core 硬體頻率與「比全速 3936」百分比。用法見 [`docs/perf-vs-temp.md`](docs/perf-vs-temp.md)
- 數據圖新增兩張（CPU＋GPU 時間軸、CPU-only 原廠接手前 60 秒），共 11 張；README 的「數據」改以同機對照為主

## 1.0.3 — 2026-09-20

一個安靜的把關漏洞：`includeGPU` 開著，但 GPU 溫度從來沒被算進去。

- **GPU 感測器清單會被空快取毒化**：`Snapshot.take` 判斷「要不要重掃 SMC」只看 `cachedCPUKeys.isEmpty`，採用舊快照時也只驗 `cpuPrefixes`，GPU 則是 `cachedGPUKeys = saved.gpuKeys ?? []` 照單全收。`gpuKeys` 為 `nil`（這份快照沒掃過 GPU）和空陣列（掃過、這台真的沒有）被混為一談，於是空清單自我延續 —— guard 吃到空的再原樣寫回快照，之後永遠不重掃。M4 上 SMC 明明有 18 個 `Tg0*`、config 也寫著 `gpuPrefixes: ["Tg"]`，`doctor` 卻一直報「GPU 感測器：0 個」
- **後果**：`gpuMax` 恆為 0，`control = includeGPU ? max(cpuMax, gpuMax) : cpuMax` 等於永遠只看 CPU。GPU 才是熱源的工作（算圖、影片轉檔）不會把風扇拉上去；面板的 GPU 熱度格也是空的
- **修法**：採納條件抽成 `Snapshot.canReuse(cpuKeys:gpuKeys:config:)`，CPU 與 GPU 前綴都要驗，`gpuKeys` 為 `nil` 不再當成空陣列；並加一條自癒出口 —— `includeGPU` 開著卻拿到空 GPU 清單就不信這份快取，重掃一次確認。真的沒有 GPU 感測器的機器掃完仍是空，程式生命週期內不會重複掃
- 6 條回歸測試（`SnapshotTests`），涵蓋空 GPU 清單、`includeGPU` 關閉時空清單仍合法、CPU/GPU 前綴不符、舊快照 `gpuKeys` 為 `nil`
- **升級後**：guard 重啟會重掃並把正確的 18 個 key 寫回快照，不必手動清 `/var/run/cool42/state.json`

## 1.0.2 — 2026-09-18

安全審視（「一個 root daemon 會被怎麼看」）修出來的，行為不變。README 新增威脅模型表。

- **執行期檔案搬離 `/tmp`**：快照、歷史、事件目錄改到 root 擁有的 `/var/run/cool42/`。之前在 world-writable 的 `/tmp` 用固定檔名讓 root 寫檔，本機任何程式先放一個 symlink（`/tmp/cool42.json.tmp` → 任意檔）就能讓 root 覆寫；`chmod 1777` 事件目錄同理能把任意目錄變成人人可寫（CWE-59）。guard 啟動改用 `mkdir(2)`＋`lstat` 確認是自己的真目錄，不是就拒絕啟動；寫檔 `O_CREAT|O_EXCL|O_NOFOLLOW`
- **事件目錄是信任邊界**：1777 → 1733（能丟、不能列）；guard 只收 ≤ 4 KB 普通檔、一輪最多 64 個，不合規的丟棄並記警告；預熱轉速與秒數不信事件值、一律用 config（之前丟 `rpm: 99999` 會照登進 log）；備註在 guard 端去控制字元與換行、限 60 字（之前只在 hook 端處理，直接丟事件檔的人仍能假造 log 行）
- **log 不再記指令原文**：hook 的預熱備註改成命中的關鍵字（`swift build`），`/var/log/cool42.log` 是 644 全機可讀，指令前 60 字可能帶 token
- statusline 片段、README、`uninstall.sh` 路徑跟著改；`install-root.sh` 清掉舊的 `/tmp/cool42*`
- **升級注意**：自己的 statusline 若讀 `/tmp/cool42.json`，改讀 `/var/run/cool42/state.json`

## 1.0.1 — 2026-09-18

從 2.5 天、8300 行 `/var/log/cool42.log` 讀出來的四個毛病，都修在 guard / hook，面板不動。

- **預熱誤判**：343 次預熱裡一大半不是重工作 —— heredoc（`python3 - <<'PY'`）的每一行、`sed 's|a|swift build|'`、`grep -E "pytest|make "` 引號裡的 `|` 都被當成獨立指令去比對。切段改成先剝掉 heredoc 主體、只在引號外的 `; | &` 切（`Policy.segments`），加了 8 條回歸測試
- **預熱提早收**：預熱 30 秒後控制溫度還在曲線起點以下（不像重工作，例如 5 秒跑完的 pytest）就結束，不再 46°C 轟滿 120 秒
- **等級抖動**：P-core 做短工作 5 秒內 50 ↔ 80°C 來回，3°C 遲滯擋不住，兩天半寫了 1,742 條 `ok ↔ warm`。降級改成要連續 `rampDownHoldRounds`（6 輪 / 30 秒）都低於門檻；升級照舊立即。交還自動同樣要等 6 輪，不再 5 秒接管、5 秒交還
- **log 被 heredoc 撐成多行**：hook 送的預熱備註含換行，125 行沒時間戳。換行改成 `⏎`
- **今日統計重開機歸零**：快照在 `/tmp`，關機重開就沒了。統計另外每分鐘落地到 `/var/db/cool42/stats.json`，guard 重啟／重開機都接得上；`uninstall.sh` 一併清

## 1.0.0 — 2026-09-18

第一個正式公開版。2026-09-16 起三天內從 0.1 走到這裡（0.1 → 0.2.x → 0.3.0 的過程合併記在這一條；細節在 git log 與 README「克服的問題」）。

**監控**
- 選單列 `🟡 82°`；面板是**可拖的浮動視窗**：點圖示開 / 關、右上 ✕ 收起、切 app 不消失、跨 Space、位置記住、高度跟內容走（自己拖過就停止自動，右鍵可恢復）、內容超過螢幕就捲
- 溫度 / 風扇 / P-core 頻率三張卡，各帶目前值與 5 分鐘曲線；頂端一句結論（全速運作 / 降頻中 / 溫度危險）；「現在誰在算」（libproc 差分，Mach tick 換算）
- **各感測器熱度格**：P-core / E-core / GPU 三組，一格一個 SMC 感測器（M4 共 73 個），顏色 40° 藍 → 60° 綠 → 80° 琥珀 → 95° 紅，滑過看 key 與度數；只有展開才讀
- **CPU 硬體頻率與 thermal pressure**（guard 常駐 `powermetrics` 子行程，root）：IOReport 給的是軟體檔位、看不到降頻，只有這條路是真的
- **GPU** 使用率、頻率、`GPU_CLTM` 熱降頻（IOReport，不需 root）
- 今日統計：降頻 / warm / hot / critical 秒數、最高溫、hook 等待與擋下、預熱次數
- 提示音：過熱 / 降頻、降溫回穩各一段，內建合成 chime（`Sounds/*.m4a`，`extras/make_sounds.py` 產），config `sounds.overheat / cooldown` 可換；觸發溫度面板可調（`overheatAbove` / `cooldownBelow`，互相夾住）；一趟過熱只響兩聲，門檻抖動不連叫

**風扇**
- 曲線 / 固定 / 自動；面板即改即生效（寫 config → guard 熱重載）；內建「安靜 / 均衡 / 強力」
- 預設曲線 `60→1000 75→1800 85→2600 92→3600 97→4900` 來自 A/B 實測：同負載比舊曲線少轉 25%（M4 mini 重載平均 86.8°C / 3150 rpm）；B 段內沒有 powermetrics 取樣，不降頻與否由日常統計的降頻秒數持續驗證
- 控制溫度 = max(CPU, GPU)；EMA 升 0.7 / 降 0.2；每輪最多降 300 / 升 800 rpm，≥ hot 時升速不限；降級 3°C 遲滯；deadband 150
- 轉速夾在韌體回報的 `F0Mn`–`F0Mx`，寫不出更高的值；SIGTERM 保持轉速等 launchd 接管，Ctrl-C / uninstall 才交還自動
- 容錯：設定檔解析失敗保留上一份；感測器讀不完整不動風扇，連續 30 秒交還自動；SMC 假值過濾（只收 10–125°C）

**AI agent 把關**
- Claude Code PreToolUse hook：**真的降頻才等**（Moderate / Heavy 等最多 90 秒），Trapping 或 ≥ critical 才擋；白名單指令任何等級放行
- 重指令預熱：`swift build` / `blender` / `ffmpeg` / `python -m`… 開頭就先把風扇拉到 3000 rpm 撐 2 分鐘
- MCP server（`mcp/cool42_mcp.py`，PEP 723 單檔）：7 個 tool 查狀態、判斷可否開工、等降溫、看誰在吃 CPU、讀設定、切風扇模式
- `cool42 check` exit 0 / 1 / 2；statusline 片段

**可靠性**
- guard LaunchDaemon `Standard` + `Nice -5`（`Background` 在高負載時被餓死三分鐘，最需要它時動不了）；watchdog 6 週期沒心跳自殺讓 launchd 重啟
- 感測器 key 清單寫進快照，不再每次列舉 1375 個 key
- 權限切分：只有 guard 要 root；面板 / hook / MCP 只讀 644 JSON，改動走設定檔與 `/tmp/cool42.events/`
- 安裝 binary 寫暫存檔再 mv（避免 `OS_REASON_CODESIGNING`）；無 TTY 也能裝（系統密碼視窗）
- 28 個單元測試

**已知盲區**
- 記憶體壓力：swap 卡死時 CPU 涼、風扇低，結論會顯示「閒置 · 未降頻」但工作實際卡住。計畫把 free % / swap / `memory_pressure` 接進快照
- 只在 Mac mini M4 上實測過；其他 M 系列需要照 README「移植新晶片」確認感測器前綴與風扇 key
