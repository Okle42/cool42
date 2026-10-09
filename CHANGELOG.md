# Changelog

## 1.1.0 — 2026-10-10

### 專案名稱統一為 cool42

2026-09-27 起各處名稱統一為 **cool42**，功能不變。

- 全部統一：CLI 執行檔 `cool42`（daemon 用 `cool42-guard` 啟動）、SwiftPM 產品與 target（`cool42`、`cool42-panel`、`Cool42Core`）、面板「cool42 Panel.app」（bundle id `com.cool42.panel`，LaunchAgent 同名）、LaunchDaemon `com.cool42.guard`、`/etc/cool42/config.json`、`~/.config/cool42/`、`/var/db/cool42/`、`/var/run/cool42/`、`/var/log/cool42.log`、newsyslog `/etc/newsyslog.d/cool42.conf`、MCP server `cool42`（`mcp/cool42_mcp.py`，工具 `cool42_check`／`cool42_wait`／`cool42_top`／`cool42_status`／`cool42_doctor`／`cool42_get_config`／`cool42_set_fan`）、Claude Code hook `/usr/local/bin/cool42 hook`、`hookAllowCommands` 預設值、log 與介面字串、Homebrew `cool42`／`cool42-setup`、release 檔名 `cool42-<版本>-arm64.zip`
- 面板「今天」時間軸與 `extras/ux_metrics.py` 比對 guard 起訖行時不再寫死產品名

2026-09-25 同機實測「macOS 原廠自動 vs cool42 曲線」，發現 thermal pressure 會在已經降頻時仍回報 Nominal：CPU＋GPU 滿載交給原廠，P-core 硬體頻率 3936 → 平均 3644 MHz（−7.4%），pressure 輪詢 79/79、powermetrics 90/90 全是 Nominal。資料、已知 bug 與限制在 [`docs/perf-2026-09-25/`](docs/perf-2026-09-25/)（原廠穩態只有 1 輪、熱機起跑）。

- **時脈降頻判斷（無聲降頻）**：控制溫度 ≥ `clockThrottleTemp`（預設 100°C）且 P-core 硬體頻率 < 全核滿載頻率 × `clockThrottleRatio`（預設 0.95）就算降頻，不管 pressure；頻率回到 × 0.97 以上，或溫度低於 `clockThrottleTemp` − `levelHysteresis` 才解除。快照新增 `clockThrottled`
- 「降頻」的定義改成三選一：pressure 非 Nominal、GPU CLTM > 5%、時脈降頻。hook / `cool42 check` / `wait`、每日「降頻秒數」、log（「熱降頻開始：時脈（pressure 仍 Nominal）」）、面板、`status --short`（「降頻(時脈)」）一起生效
- **全核滿載頻率用實測表**，目前只有 Apple M4 = 3936 MHz（09-25 所有曲線檔 powermetrics 450/450 筆）；**表外晶片預設不判斷**，可用新設定鍵 `clockFullLoadMHz` 自訂。不讓 guard 自己學峰值：高溫下單核衝到 4464 會被當成峰值，之後全核 3936 就被誤判。`clockThrottleRatio` 必須在 0.5–1 之間
- 預設 `criticalTemp` 100 → 108°C：09-25 CPU＋GPU 滿載時 cool42 曲線穩態 104.4°C 且全速，100 會讓全速運作也擋下 AI；108 高於 cool42 滿載穩態、低於原廠冷機起跑的峰值（35–40 秒過 112°C）。105–108°C 的無聲降頻由時脈判斷處理。設定檔寫死 100 的要自己改
- 3 條新測試（共 43 項）；10-06～10-07 實機重負載已記到「pressure 仍 Nominal」的時脈降頻（最低 P-core 2,949 MHz）；同負載的原廠對照還沒重跑
- **perf 對照腳本**：`extras/perf_vs_temp.py`（每檔切 cool42 設定、等穩態、取樣 powermetrics，記溫度 / 轉速 / P-core 硬體頻率 / 功率 / sha256 工作量 / pressure）、`extras/run_perf_overnight.sh`（空閒檢查、防睡、備份還原設定、完成通知）、`extras/gpu_burn.swift`（`--gpu` 的 Metal 滿載）。四次實跑修掉的坑：換檔前要停負載並降溫（至少 120 秒、維持 30 秒 ≤ 55°C，只看晶片溫度會熱機起跑）；原廠自動檔與曲線檔共用 112°C 安全上限；報表加 P-core 硬體頻率與「比全速 3936」百分比。用法見 [`docs/perf-vs-temp.md`](docs/perf-vs-temp.md)
- 數據圖新增兩張（CPU＋GPU 時間軸、CPU-only 原廠接手前 60 秒），共 11 張；README 的「數據」改以同機對照為主

### 面板只做監控、設定移到設定視窗、玻璃改成和 Dock 同一種

使用者回饋（2026-09-25 截圖）：桌面左下角行事曆 widget 與 Dock 是深色、通透；面板是霧灰色，卡片像實心灰板。原因四個：卡片 `Neon.cardBG` 不透明度 0.88 疊在玻璃上、NSPanel 用 `.titled`＋`.utilityWindow` 多一層外框與背景、`NSGlassEffectView` `.regular` 會依背景自己抬亮度、截圖時底下剛好是白網頁。

- **設定視窗**（⌘,、選單列右鍵「設定⋯」、面板頁尾「設定⋯」；從 Finder 再打開一次 app 也會開）：`NSTabViewController` `.toolbar` 分頁＋SwiftUI grouped `Form`，分頁「風扇控制／情境與噪音上限／提示音／通知與顯示／關於與檢查」；標題跟著分頁、記住上次分頁、不可縮放與最小化、大小跟著分頁。寫設定檔的欄位沿用 draft →「套用」（刻意不做即時生效：拖滑桿每格寫檔會讓風扇抖、曲線要整組驗證），面板本機偏好即時生效。加了看不到的主選單（⌘, ⌘Q ⌘W、文字欄位的拷貝／貼上）
- **面板只留監控**：狀態句、溫度、熱度格（可折疊）、風扇、P-core 頻率、今日統計、今天時間軸（預設收合）、健康紅燈（「查看⋯」開設定視窗）、**一鍵模式切換**（曲線／固定／自動，直接寫設定檔，切到自動會記下原模式讓右鍵選單能「恢復」）、頁尾。熱度格展開約 890pt，1920×1080 不用捲動；放不下時才包 ScrollView
- **無邊框玻璃**：`.borderless`＋`.nonactivatingPanel`（可變 key 的子類別），圓角與陰影自己來；深淺都用 `.clear`＋tint（深黑 0.70、淺白 0.80）＋1pt 邊緣光。四輪實機並排（星空／白網頁 × 深／淺，對照 Dock 與 widget）：`.regular` 在星空上 ≈ 38/255（Dock ≈ 12）、白網頁上洗成 ≈ 150、淺色壓在深色桌布上 ≈ 90，霓虹數字對比 1.1–2:1；`.regular` 的白 tint 不會提亮。定案版星空底 ≈ 10、白網頁底 ≈ 50（深色）／225–255（淺色），大數字 ≥ 3.7:1、內文 ≥ 7:1。對照圖 `docs/img/screens/glass-compare.png`
- **拿掉實心卡片**：區段之間一條系統分隔線，圖表只留極淡的底；說明字一律系統 label 色，霓虹色只給大數字、圖表線、狀態點。發光暈只在深色外觀（淺色底上彩色暈只讓線變粗）
- 回退：「減少透明度」＝實色底（色值改成取樣自實機深色玻璃）＋髮絲線；「增加對比」＝窗緣改成明顯的 label 色邊、發光關掉；macOS 14–25 用 `NSVisualEffectView .popover`（`maskImage` 裁圓角）
- 修：直接把 `NSGlassEffectView` 設成無邊框視窗的 contentView 時，視窗縮高後 contentView 留著 −76pt 的上緣位移（標題列被裁掉、底下空一截）；改成普通容器 view 用約束釘在視窗框上，hosting view 的 `sizingOptions` 清空
- 截圖工具：`capture-glass.sh` 新增星空／白網頁背景、`--full`（整個螢幕，拼 Dock／widget 並排）、`--settings`（設定視窗各分頁）、`--looks`、`--backdrops`、`-glass.*` 參數比對；README 的實機截圖、離屏截圖、hero、demo GIF 重產
- **還沒安裝到 /Applications 實測**；「減少透明度」「增加對比」是用強制回退截的，系統開關本身沒切

#### 審查後修正（同日第二輪）

- **未套用的變更不再被悄悄丟掉或蓋掉別人的設定**：關設定視窗時有未套用的變更會先問「套用／捨棄變更／取消」；面板頁尾多一行「設定有未套用的變更」（按了打開那一頁）。「套用」改成三方合併（`Config.applyingPanelEdits`，Cool42Core）：記下開始編輯時的設定，只把使用者改過的欄位疊到磁碟上最新的設定檔再寫，編輯期間手動、`cool42` CLI、MCP `cool42_set_fan` 改的鍵（例如 `takeoverHoldSeconds`、`boostLearn`）保留；設定檔被外部改了時，未套用的編輯也疊到新檔上。設定檔解析失敗時不寫。4 條新測試（`ConfigEditsTests`，共 89 項）
- 設定視窗的「模式」和面板上一樣按了就寫（原本要按「套用」，同一個控制項兩處行為不同）
- 設定視窗高度跟著分頁內容（讀 grouped Form 的捲動內容高度，macOS 15+），最高到螢幕可用高度 − 96；原本各頁寫死 620–760pt，沒有規則的「情境」頁底下空 300pt
- **窗緣光改成跟 Dock 同一種**：同一張整螢幕截圖逐像素量，Dock 只有上下緣亮（83 → 28 → 21 → 18 → 16）、側邊 0，widget 也一樣；原本一圈均勻 1pt 白 0.26 四邊都 ≈ 88、往內直接掉到 13，像 HUD 外框。改成垂直漸層的 1pt 邊（上下 0.26、側邊 0）＋上下緣內側 6pt 柔光，實測上緣 84 → 30 → 23 → 19 → 17；「增加對比」才用均勻加粗的邊
- 圓角 16 → 26（量 widget 與 Dock 的輪廓）；圖表井、紅燈框跟著同心（26 − 16 = 10）
- **淺色不再是實心白板**：tint 0.80 → 0.62（0.80 壓在白網頁上是 255，完全看不到底），淺色霓虹色壓暗一階；星空底 ≈ 193 時大數字仍 ≥ 3.2:1。代價是淺色壓在深色桌布上時系統次要字約 3.5:1（系統次要字在純白上也只有約 4:1）
- 熱度格「最熱XX°」、「今天」摘要這類小字不再用霓虹色（淺色玻璃壓在深色桌布上只有 3.8–4.3:1）：字用系統色，狀態色改給前面的點／烏龜圖示
- **「增加對比」分支截得到了**：`NSAppearance(named: .accessibilityHighContrast*)` 實測會退回一般外觀，舊的 `--hc` 截圖其實跟一般版一樣；新增 `A11y.forceHC`（`-glass.forceHC YES`／截圖工具內設），高對比時 tint 加到深 0.85／淺 0.90、窗緣改均勻加粗、發光關掉。另修：「減少透明度」「增加對比」的變更通知原本掛在 `NotificationCenter.default`（收不到），改掛 `NSWorkspace.shared.notificationCenter`，切系統設定不用重開面板
- macOS 14–25 回退（`NSVisualEffectView .popover`）加一層色：深色黑 0.55（白網頁上原本 ≈ 110、霓虹數字 1.7–3:1，現在 ≥ 4.8:1）、淺色白 0.60（深色桌布上原本 ≈ 144、1.8:1，現在 ≥ 3.7:1）
- 1080p 高度：熱度格和「今天」一次只展開一個；「今天」事件清單超過 200pt 在自己那一塊裡捲（紅燈時 120pt）；健康檢查紅燈時熱度格先收起來（不改偏好，自己展開就照你的）。離屏量：熱度格展開 891、收合 719、「今天」展開 927、紅燈＋「今天」915（英文 927）；可用約 944
- 截圖工具：`--dirty-close`（截關閉確認單，截完捨棄、不寫設定檔）、`--variant sensors-off`；並排圖 `glass-compare.png` 重做：只裁 widget 左半（日期與國定假日，不含行事曆事件）與 Dock 左段，其他視窗與通知都不入鏡，加 4× 圓角與窗緣亮度剖面

### 安靜優先（風扇「呼吸」與預熱過度）

09-20～25 的 log（`extras/ux_metrics.py` 量）：一天交還自動 59～212 次、每小時風扇目標變更 14～48 次，典型是單輪尖峰 73°C 接管 → 1340 rpm → 36 秒後 49°C 交還；預熱 111 波裡 91 波（82%，按波次算；事件行 206 行）30 秒後仍只有 44–52°C，但那 30 秒一律轟 3000 rpm。

- **接管去抖** `takeoverHoldSeconds`（預設 10 秒 = 2 輪）：從交還自動重新接管，要原始控制溫度連續在曲線起點 −5°C 以上；用「連續」不用「30 秒平均」，因為單輪 90°C 就能把平均拉過門檻，而 EMA 降溫慢、一輪尖峰後平滑值會在門檻上停 15～20 秒，所以看原始值。≥ `hotTemp` 或降頻中立刻接管，預熱與設定重載不等
- **預熱漸進** `boostStartRPM`（2000）、`boostEscalateTemp`（70°C）、`boostEscalateRise`（10 秒內 +10°C）：先用 2000，溫度真的起來才加碼到 `boostRPM`，log「預熱加碼」；30 秒不像重工作就提早結束照舊
- **預熱學習** `boostLearn`（預設開）：同一關鍵字連續 3 次預熱都不像重工作，暫停替它預熱 24 小時（log「學到：X 不再預熱」「略過預熱」「恢復預熱」），狀態在 `/var/db/cool42/boost-learn.json`，和 `stats.json` 同樣 O_EXCL|O_NOFOLLOW 原子寫入。只學 `boostCommands` 裡的關鍵字、最多 64 個（事件備註是本機任何程式都能寫的）
- `extras/ux_metrics.py`：按日列接管、交還、預熱、提早結束比例、每小時目標變更，`--since` 比較改版前後、`--json`
- 16 條新測試（`QuietTests`，共 59 項）；**還沒實機跑過**，裝上後跑 `ux_metrics.py --since` 對照

### 情境自動切換與噪音上限

- **`maxRPM` 噪音上限**（預設不設＝不限）：guard 所有目標轉速（曲線、固定、預熱）夾在上限以下；**critical 或降頻中忽略上限**（安全例外），log「噪音上限 … 暫停／恢復」。上限生效時高於上限的目標不等「連續 N 輪偏冷」就往下降（仍受 `maxRampDown` 限制）；比風扇最低轉速還低時以最低轉速為準
- **`profiles` 情境規則**（預設 `[]`）：依序第一條符合的生效，都不符合用基本設定；`when` 有寫的條件全部成立才算。條件：時段 `{from, to}`（HH:mm、跨午夜）、App 在跑 `{apps: [...]}`（guard 以 root 列舉程序名稱，沒有 apps 規則就不列舉）、專注模式 `{focus: true}`。動作：內建預設曲線 `curve`（quiet／balanced／performance，也收「安靜／均衡／強力」）和／或 `maxRPM`。最多 16 條，名稱不能換行（會進 log）。情境不改 `mode`，緊急交還原廠不受影響。log「情境「X」生效：…」「情境「X」結束，回到基本設定」；快照新增 `profile`、`maxRPM`、`maxRPMSuspended`，`cool42 status` 也會顯示
- **專注模式**：guard（root 常駐程式）拿不到 —— 唯一公開 API `INFocusStatusCenter` 要在使用者 session 的 app 裡經授權，`~/Library/DoNotDisturb/DB` 格式沒公開、排程開啟的也不一定記在裡面。改由面板讀、寫 `~/.config/cool42/focus.json`（每 60 秒或狀態改變），guard 讀主控台使用者那份（不 follow symlink、要是該使用者的檔、180 秒沒更新當作不知道；不知道＝規則不成立）。授權只在使用者按規則下方的「繼續⋯」時才請求；`make-app.sh` 的 Info.plist 加 `NSFocusStatusUsageDescription`（中英 `InfoPlist.strings`）。**沒在正式 .app 上驗證過**：ad-hoc 簽名的 app 能不能拿到專注模式狀態還不確定（Apple 文件另要求 Communication Notifications capability，這裡沒加 entitlement），拿不到時面板會說這條規則不會生效
- **面板「情境與噪音上限」卡**：目前生效的情境（例如「「夜間安靜」生效中 · 23:00–07:00 · 安靜 · 上限 2200 rpm」）、上限因降頻暫停的提示、平常上限的開關與滑桿（附取捨說明：只引用 09-25 原廠 ~2,950 rpm 時 P-core −7.4% 這一個實測，不給換算）、規則清單（新增時段／App／專注模式規則、展開編輯名稱／時段／App／曲線／上限、上移、刪除），走同一個「套用」；面板先擋掉 guard 會拒絕的規則，寫檔前再跑一次 `validate()`。預設曲線搬到 `Cool42Core`（`Config.presetCurves`），面板與規則共用
- 20 條新測試（`ProfileTests`，共 79 項）：跨午夜與同日時段、App 名稱比對（大小寫、`.app`、截斷）、專注條件、條件 AND、規則順序、套用後的有效設定、上限夾限與兩個安全例外、舊設定相容、驗證、README 範例 JSON 可解析、專注旗標讀寫／過期／擁有者／symlink。**guard 的整合行為還沒實機跑過**

### 升級注意（安靜優先、情境與噪音上限、面板改版）

- **升級會改變行為**：舊設定檔沒有新鍵時，預設就啟用接管去抖（`takeoverHoldSeconds` 10）、預熱漸進（`boostStartRPM` 2000）與預熱學習（`boostLearn` true）。要回到舊行為：`"takeoverHoldSeconds": 0, "boostStartRPM": 0, "boostLearn": false`。`maxRPM`／`profiles` 沒設就和以前一樣不限轉速
- **guard 與面板要一起更新**：舊版面板不認得 `maxRPM`、`profiles`，在它上面按「套用」會把兩段整個刪掉、沒有提示。guard 重載時發現它們不見了會記「⚠️ 設定檔裡的 … 不見了」；`./install.sh` 會同時重建 guard 與面板
- 通知與專注模式的授權都在第一次用到時才請求（通知：第一次真的要發；專注模式：按規則下方的「繼續⋯」）

### 審查修正

- **噪音上限的安全例外加上 hot**（blocker）：原本只有 critical（108°C）與降頻會解除上限，95–107°C 之間風扇仍被夾在上限以下；降頻偵測在晶片不在表內或 powermetrics 過期時也看不到。現在 `hotTemp` 或等級仍在 hot 以上就解除
- **上限暫停改成閂鎖**：hot／critical／降頻任一成立就暫停；要降到 `hotTemp` − `levelHysteresis` 以下、連續 `rampDownHoldRounds` 輪沒再觸發才恢復，恢復後照一般降速節奏降回上限（「直接往上限降」只留給剛進情境、剛改設定）。避免重載下「上限 → 降頻 → 全速 → 45 秒降回上限 → 再降頻」的一分鐘循環。純邏輯在 `CapLatch`
- **預熱學習防下毒**：只記每一波開頭那個事件的關鍵字（延長事件不算）、只學主控台使用者自己丟的事件（`Event` 新增 `ownerUID`，由 drain 的 lstat 填），每個關鍵字每小時最多記 6 次；「不像重工作」的門檻改用**基本設定**曲線起點，不隨情境漂移
- **學習狀態檔安全讀取**：`O_NOFOLLOW`、只收 root 擁有、≤ 64 KB 的普通檔；暫停時間超過 24 小時（時鐘跳過或檔案被改）就清掉並記 log
- **接管去抖的 hot 例外看等級遲滯**，頻率資料過期時當作可能在降頻、立刻接管
- **apps 規則只看主控台使用者的程序**（`cp_uid`＋`ProcList.runningNames(owner:)`），別的本機帳號跑同名程序不會觸發；規則名稱不能重複
- `ux_metrics.py` **按波次**算預熱：新欄位 `boost_waves`、`early_end_ratio_per_wave`，事件行改名 `boost_events`。09-20～25 是 111 波裡 91 波提早結束（**82%**）；先前回報的 43%（81/190）是拿事件行當分母、低估
- 面板：首次導覽不再保證「不必降頻」、檔案清單分成「安裝時放的」與「執行時會寫的」並補齊 `boost-learn.json`、`focus.json` 等；健康檢查在風扇卡手動時不再說「由macOS控制」、紅燈依處理順序排、「查看」會捲到健康卡、提示移到標題列下；選單列降頻角標改成烏龜（和面板一致，⚡ 只表示全速）、hot 多一個點、溫度字固定三位數寬；通知以「一段過熱」為單位（穩定正常 2.5 分鐘才算恢復、30 分鐘內接續不重發、恢復時收掉先前的警告）、文案拆成「原因／目前溫度」、沒裝 hook 不提 hook；時間軸接上預熱加碼、學到／略過／恢復預熱、情境生效／結束、噪音上限暫停／恢復，預熱併行不看轉速、顯示時間區間、次數從完整清單算；情境卡在交還原廠／固定模式時說明不作用、預設收合、時間跟系統 12／24 小時制、App 欄可從執行中的 App 挑選、每列只剩一個刪除鈕；提示音與面板偏好併成可收合的「偏好」卡；右鍵選單加「交還原廠控制⋯」；英文統一彎引號、critical、Clock
- `scripts/check-l10n.py` 改成遞迴掃子目錄，檔頭 `// l10n:ignore-file` 才豁免中文字串檢查（`GuardLogPatterns.swift` 搬回面板目錄並加標記）；`uninstall.sh` 移除 `~/.config/cool42/focus.json`
- 測試共 85 項（新增 hot 例外、閂鎖遲滯、學習速率上限、遠未來暫停夾限、symlink／擁有者、重名規則）；面板自我檢查 26 項。**guard 的整合行為仍未實機跑過**

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
