# Hacker News 發文素材（本機草稿，未發布）

> 這份只是草稿。發文、選標題、選連結都等使用者決定。
> 建議連結：文章本身（`docs/articles/m4-thermals.en.md` 發布後的網址），不是直接連 repo。HN 對「技術發現」接受度比「我做了一個工具」高。若要用 Show HN，連結就改成 repo，標題用下面的 Show HN 版本。
> HN 標題上限 80 字元，下面每一個都已經控制在 80 字元內。

## 標題候選（5 個）

1. `What the M4 Mac mini's sensors tell you, and what they lie about`
2. `On M4, IOReport CPU frequency is the requested state, not the hardware clock`
3. `Your M4 Mac isn't at 62°C: IOHID "CPU temp" is the power-management IC`
4. `Gating an AI coding agent on thermal pressure instead of temperature`
5. `Show HN: cool42 – M4 fan control that only makes AI agents wait when throttled`

選擇建議：

- 1 和 2 最像 HN 會點進去的「發現」型標題。2 最具體，也最容易引來 macmon/asitop 使用者討論。
- 3 最有話題性，但帶一點「騙你」的語氣，可能被改標題。
- 4 偏 AI agent 圈。
- 5 是 Show HN 格式，要搭配 repo 連結，而且發文當下 repo 要是可安裝的狀態（1.0.3 已發布）。

---

## 首則作者留言（英文，貼在自己的貼文下）

Author here. Some context and the caveats up front.

**Why:** I run long Swift builds, ffmpeg jobs and Python batch work on a Mac mini M4, a lot of it through Claude Code. The stock fan policy is silence-first. Public reports put sustained-load SoC temps at 105–107 °C, with P-cores dropping to 3300–3800 MHz after 10–15 minutes. I wanted to know when that was actually happening on my machine, and then I wanted the agent to stop piling on more heavy jobs *only* when it was. That second part is why the gate is keyed on `powermetrics` thermal pressure rather than on temperature. My first version waited whenever the SoC hit 90 °C, and with a quieter fan curve that meant waiting before nearly every command, for no benefit.

**What surprised me:**

- IOReport's CPU residency (which rootless tools use for frequency) stays pinned at the top P-state under load while `powermetrics` shows 3936 MHz. It looks like the requested DVFS state, not the achieved clock. I filed it with macmon (issue #78) to get data from other chips.
- On M4, IOHID only exposes PMU temperatures. They read 15–20 °C below the SMC per-core keys.
- 94 hours of logs: 31 logged moments at or above 90 °C, and 0 seconds of non-Nominal pressure. Temperature and throttling really are different signals on this chip.

**Limits, plainly:**

- **Tested on one Mac mini M4 only.** No M4 Pro/Max, M1–M3, M5 or MacBooks. The stock-policy numbers in the post are other people's reports, not my own measurements. I have no end-to-end wall-clock comparison, so I'm not claiming anything is faster.
- In the A/B test (25% less fan for +3.8 °C), the `powermetrics` samples were taken just before and just after the 10-minute window, not during it. The post says so.
- The gate hasn't fired in the current logs (0 waits, 0 denies in 94 h). So what I can show is that it stays out of the way, not that it catches throttling in the wild. A controlled repro is on the list.
- **Ad-hoc signed.** No Developer ID or notarization yet. `install.sh` builds from source and signs locally, so read it before running it.
- **It needs a root LaunchDaemon.** Two reasons: writing the SMC fan keys (`F0Md`/`F0Tg`) requires root, and on M4 the only hardware-clock source I found (`powermetrics`) requires root. That daemon is the only root component. The menu-bar panel, CLI, hook and MCP server run as the user and only read 644 JSON snapshots. The README has a threat-model table for the file interfaces, including a `/tmp` symlink issue I fixed in 1.0.2. The long-run cost I measured is 0.49% of one core for the daemon plus its `powermetrics` child.

It's pure Swift plus about 170 lines of C, with no dependencies and an MIT license. Most of it was written with Claude Code over about four days. Happy to be told the IOReport interpretation is wrong. If you have another Apple Silicon machine, a `powermetrics` vs IOReport comparison under load would be the most useful thing anyone could post.

---

## 預期會被問的問題（備答，不要主動貼）

- **「powermetrics 本身不就要 root 嗎？為什麼不讓使用者自己跑？」** → 我們需要常駐、持續的取樣。反正 guard 已經是 root，一個 `-i 5000` 子行程長期約 0.22% 單核（2026-09-23 `ps` 實測）。
- **「3936 不就是降頻了嗎？」** → 3936 是全核滿載的功耗上限頻率（單核 4464），pressure 是 Nominal。外部報告裡原廠的熱降頻是掉到 3300–3800。
- **「90–95°C 時 log 的 ⚡ 中位數才 3.64 GHz？」** → 文章裡已經主動寫了：pressure 是 Nominal、非 Nominal 0 秒；推論是部分負載或功耗上限，尚未證實。
- **「風扇會不會轉壞？」** → 上限是韌體自己的 `F0Mx`（4900）。降速每 5 秒最多 300 rpm，避免劇烈變速；閒置停在韌體最低 1000 rpm，跟原廠 auto 一樣（README）。
- **「為什麼 README 寫 0.3%，這裡寫 0.49%？」** → README 是較早的量測；0.49% 是 2026-09-23 的長期平均，以這個為準。
