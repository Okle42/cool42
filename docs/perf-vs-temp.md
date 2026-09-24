# macOS 原廠自動 vs cool42 曲線：同機同負載量測

`extras/perf_vs_temp.py` 在同一台 Mac、同一個固定 CPU 負載下，依序把風扇交給不同控制方式，每一檔都等到穩態再取樣，回答「cool42 曲線比 macOS 原廠自動好在哪、代價是多少」。

## 一行跑完（過夜）

```sh
extras/run_perf_overnight.sh            # 問一次 sudo 密碼，之後可以離開；跑完跳 macOS 通知
```

先看計畫、不動任何東西：

```sh
extras/run_perf_overnight.sh --dry-run  # 不問密碼、不寫設定、不跑負載
```

預設 `--modes curve auto --repeat 2 --sample 90`，也就是 cool42 曲線 → 原廠自動 → cool42 曲線 → 原廠自動（A/B/A/B，才看得出重複量測的散佈）。時間由參數推出：每檔 3 分 30 秒（最快收斂）到 10 分（上限），4 檔共 14–40 分鐘，另加等空閒的時間。

## 檔位

| 寫法 | 設定檔改成 | 意思 |
|---|---|---|
| `curve` | `mode: "curve"`（曲線原封不動） | 使用者現行的 cool42 曲線 |
| `auto` | `mode: "auto"` | guard 仍在跑、仍讀溫度，但把風扇交還 SMC，由 macOS 原廠控制 |
| `3000`（或 `fixed:3000`） | `mode: "fixed"`, `fixedRPM: 3000` | 固定轉速；超出韌體 F0Mn–F0Mx 會被 guard 夾回範圍內 |

切檔位走的是和面板、MCP `cool42_set_fan` 同一條路：改 `/etc/cool42/config.json`，guard 下一輪（5 秒內）熱重載。腳本寫完會讀 `cool42 status` 確認 `guardMode` 真的切過去（`auto` 要看到目標轉速變成「交還」），25 秒內沒切到就中止並還原。launchd 的 guard 只讀 `/etc/cool42/config.json`，這份檔不存在時 guard 不會熱重載，腳本會直接拒跑。

## 每一檔量什麼

1. 切檔位並確認 guard 已套用。
2. 等穩態：至少 120 秒，之後 60 秒視窗內控制溫度變化 < 1.5°C；`curve`/`auto` 另外要轉速變化 < 200 rpm（原廠自動的風扇爬得慢）。480 秒還沒收斂就以現況取樣並標記「未收斂」。
3. 取樣 `--sample` 秒：`powermetrics` 給 P/E-cluster 硬體頻率、CPU/GPU 功率、thermal pressure；同時每 5 秒讀 `cool42 status` 取溫度與轉速平均；sha256 worker 的計數給工作量，算出 ops/s 與 ops/J。

## 安全

- 控制溫度 ≥ `--abort-temp`（預設 103°C）就放棄該檔，所有檔位都一樣。
- 固定轉速檔位在 thermal pressure 進 Heavy 時也放棄。`curve`/`auto` 本身就會自己保護晶片，Heavy 正是要量的結果，照樣取樣並記錄。
- 結束時一律把設定檔的**原位元組**寫回（正常結束、Ctrl-C、SIGTERM/SIGHUP、例外都一樣），並確認 guard 回到原模式。直接覆寫不換 inode，檔案擁有者不變，面板照樣能寫。
- 收尾時先寫回設定、再停負載，而且收尾期間 Ctrl-C、SIGTERM、SIGHUP 都先忽略，還原不會被第二個訊號打斷。
- 啟動腳本在空閒檢查通過後、量測前一刻另外備份一份 `config.backup.json`，結束時再比對一次；量測程式若被 `kill -9`，由啟動腳本寫回。備份沒拍成功就不量；備份不存在或是空檔時，啟動腳本絕不寫回。

## 啟動腳本做的事

1. 檢查 cool42、guard 在跑、設定檔存在。
2. 先問一次 sudo 密碼，背景每 50 秒續期，等空閒的期間不會過期。
3. 空閒檢查：1 分鐘 load avg ≤ `LOAD_MAX`（預設 3.0）才開跑；不空閒就每分鐘列出最吃 CPU 的程式、等最多 `WAIT_IDLE_MIN` 分鐘（預設 30），逾時不量並跳通知。量之前請關掉 Xcode、瀏覽器、Docker、影片轉檔、其他 build，也不要在量測中開面板改設定。
4. `caffeinate -ims` 防止系統睡眠（螢幕可以關）。
5. 備份設定檔（先寫暫存檔、比對一致才改名），失敗就不量。
6. 用 sudo 跑量測，全部輸出存 `~/cool42-perf-<時間>/run.log`。
7. 跑完用 macOS 通知告知結果位置或失敗原因。

**sudo 的範圍要知道**：輸入一次密碼後，sudo 憑證會被背景迴圈續期到整支腳本結束（一整夜都有效）；以 root 執行的是 Python 直譯器和 repo 裡的 `extras/perf_vs_temp.py`。直譯器預設用系統的 `/usr/bin/python3`（root 擁有），不用 PATH 上使用者可寫的 Homebrew python；系統那份不能用時才退回 PATH 上的 `python3`，也可以用 `PYTHON=/path/to/python3` 指定。量測期間這個 repo 目錄的寫入權限等於 root 權限，不要讓別的程式改它。

```sh
LOAD_MAX=2 WAIT_IDLE_MIN=60 extras/run_perf_overnight.sh --modes curve auto 4900 3000 --repeat 2
```

`--modes`、`--repeat`、`--sample` 以外的參數原樣交給 `perf_vs_temp.py`（`--help` 看全部）。

## 輸出（`~/cool42-perf-<時間>/`）

| 檔案 | 內容 |
|---|---|
| `summary.md` | 各檔位穩態表；原廠 vs cool42 對照（溫度、頻率、功率、ops/s、ops/J、pressure）；重複量測散佈與「差距是否大於散佈」；噪音推估 |
| `results.json` | 環境、參數、每檔結果，以及每檔等穩態的過程（每 5 秒一筆） |
| `results.csv` | 每檔一列 |
| `pm/*.txt` | 每檔 powermetrics 原始輸出 |
| `perf.log`、`run.log` | 量測程式 log、啟動腳本的完整終端輸出 |

## 讀法與限制

- **噪音是推論，不是量測。** 沒有用麥克風；`summary.md` 依風扇相似律（同一顆風扇聲功率約與轉速 5 次方成正比，ΔL ≈ 50·log10(rpm₂/rpm₁)）從平均轉速推估 dB 差，只能當量級參考。
- ops/J 只算 powermetrics 的 CPU Power，不含 DRAM、風扇與整機功耗。
- 自訂負載（`--load-cmd`）沒有工作量計數，只能看 MHz/W。
- 室溫沒控制；A/B/A/B 能緩解順序效應，但如果兩者差距落在同檔位重複量測的散佈內，`summary.md` 會直接寫「不足以下結論」。
- 取樣期間如果有 Claude Code hook 觸發預熱（guard boost），該列會標記 `boost_seen`，這種情況不該拿來比較。
