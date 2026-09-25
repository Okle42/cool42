# What the M4 Mac mini's sensors actually tell you (and what they lie about)

*One Mac mini M4 (Mac16,10), September 2026: sensor comparisons and the A/B run on macOS 26 (25G83), the 94-hour runtime log and the 2026-09-25 stock comparison on macOS 27.0 (26A428, upgraded 2026-09-20 01:18). n = 1. Every number below links back to a raw file in the cool42 repo; where something is an inference rather than a measurement, it says so.*

I wanted one thing from my Mac mini: to know, while a long build or render was running, whether the CPU was being thermally throttled. That turned out to be harder than it sounds. Most of the obvious ways to read "CPU frequency" and "CPU temperature" on Apple Silicon give numbers that are real, but answer a different question from the one you're asking.

This post covers what I found on the M4, a fan-curve A/B test, a same-machine comparison of macOS auto vs a custom curve (which shows macOS thermal pressure reading `Nominal` while the chip is already throttling), and why I gate an AI coding agent on *throttling* rather than *temperature* — and why "is it throttling?" can't just be asked of macOS. The tool is at the end; the findings stand on their own.

---

## 1. IOReport frequency is the requested state, not the hardware clock

Tools that don't need root (macmon, asitop and friends) get CPU frequency from the private `libIOReport` framework. They take the `CPU Stats / CPU Core Performance States` channel, weight each P-state's residency, and multiply by the frequency table in `pmgr` (`voltage-states5-sram`).

I compared that with `powermetrics --samplers cpu_power`, which reads hardware counters and needs root, on the same second:

| Moment | IOReport `PCPU` residency | powermetrics `P-Cluster HW active frequency` |
|---|---|---|
| sustained load (load avg 23) | `V19P0` 100% (table value 4464 MHz) | **3936 MHz**, 100% residency at 3936 |
| sustained load | `V19P0` 100% | 4187 MHz (3936 16% / 3984 19% / 4044 20% / 4416 32% / 4464 13%) |
| sustained load | `V19P0` 100% | 4130 MHz |

*Source: `docs/findings-m4-sensors.md` §1.*

I tried all four IOReport CPU channel groups: `CPU Core Performance States`, `CPU Complex Performance States`, `CPU Complex Voltage States` and `Core Performance Level`. Under load, every one of them sits at the top state and stays there. The E-cores show the same thing: IOReport reports 100% `V7P0` (2892 MHz), while the hardware runs at 2808.

My reading is that IOReport shows the DVFS state software *asked for*. The frequency the hardware actually runs after power and thermal limits is one layer below that, and this is exactly the layer where throttling happens. **So a frequency derived from IOReport can't show throttling on the M4, which is the moment you most want to see it.** The only source of real hardware clocks I found is `powermetrics`, and it needs root.

Two small things that cost me time:

- `powermetrics -n 0` doesn't mean "sample forever". It exits after the first sample. For an unlimited run, leave `-n` off.
- A resident `powermetrics -i 5000` child cost about 0.18% CPU in an early measurement (0.22% long-run), plus about 0.8 s of CPU once at startup (findings §1). My longer-run figure is further down.

I filed this with macmon as [issue #78](https://github.com/vladkens/macmon/issues/78) so people on other chips can check whether it holds for them. I've only verified it on one M4.

## 2. On the M4, IOHID "CPU temperature" is a PMU temperature

The other rootless route is `IOHIDEventSystemClient` (usage page `0xff00`, usage 5). On the M4 it exposes 40 temperature sensors named `PMU tdie1…14`, `PMU tdev1…8`, `PMU tcal`, `PMU2 …` and `NAND CH0 temp`. M1-era machines also exposed `pACC MTR Temp Sensor`, which really was a core sensor. The M4 doesn't expose it anymore.

PMU is the Power Management Unit, a separate IC on the board (there are two, `PMU` and `PMU2`) that generates the SoC's supply rails. `tdie` is the PMU's own die temperature. It follows the CPU's trend because it powers the CPU, but it isn't physically at the hot spot:

| Moment | IOHID `PMU tdie` max | SMC `Tp*` max | SMC `TCMz` |
|---|---|---|---|
| 1 | 62.7 °C | 84.7 °C | — |
| 2 | 62.2 °C | 77.9 °C (`Tp3X`) | **77.9 °C** |

*Source: findings §2.*

SMC (the `AppleSMC` IOKit service, `IOConnectCallStructMethod` selector 2, no root needed to read) has per-core keys: `Tp*` next to the P-cores and `Te*` for the E-cores. It also has `TCMz`, which I take to be Apple's own "SoC max" aggregate. In every sample I checked, `TCMz == max(Tp*)`.

So if a tool shows your M4 running 15–20 °C cooler than another tool, the SMC isn't reading high. The two tools are measuring different chips. A second, legitimate source of disagreement is **average vs max**. macmon on macOS 14+ uses SMC but averages the keys (roughly 60–68 °C under heavy load on this machine), while I take the max (78–85 °C at the same moment), because throttling follows the hottest spot. Both numbers are right. They just answer different questions.

## 3. The M4 exposes 1375 SMC keys, so don't hard-code the names

Enumerate every key at startup: `#KEY` gives the count, and selector 8 returns the name at each index. Keep keys that start with `T`, have type `flt` or `sp78`, and read between 10 and 120. Then group them by prefix: `Tp` P-core, `Te` E-core, `Tg` GPU, `TH0` SSD. On this M4 that gives **55 CPU sensors and 18 GPU sensors, 73 in all** (`/var/run/cool42/state.json`, `cpuKeys`/`gpuKeys`). The fan keys are `FNum`, `F0Ac` (actual), `F0Tg` (target), `F0Mn`/`F0Mx` (firmware range, 1000–4900 rpm on the M4 mini) and `F0Md` (manual mode). Reading needs no special privileges. Writing `F0Md=1` and `F0Tg` needs root.

## 4. What "normal" looks like: 40s at idle, and big swings

Once you're reading per-core maxima, the numbers look alarming at first. That's mostly the M4's normal behaviour:

- **Idle and light load sit in the 40s.** The lowest temperature among the 2184 SMC-write lines in four days of guard log is 44 °C, and 313 of those lines fall in the 40–49 °C band (`/var/log/cool42.log`, 2026-09-20 01:18 to 2026-09-23 23:42, 94.4 h).
- **Short bursts swing a P-core between about 50 and 80 °C within one 5-second sample.** I found this the hard way. My first "warm" threshold had 3 °C of hysteresis, and in 2.5 days it logged 1742 `ok ↔ warm` transitions (CHANGELOG 1.0.1; that older log is no longer on disk, so I can't recompute it). The fix was to require 6 consecutive rounds (30 s) below the threshold before stepping down. Over the 94.4 h since, there were 32 transitions. The workload was different, so treat that comparison as indicative.
- **Distribution of logged temperatures.** Median 65 °C, mean 64.6. By band: 40s 313, 50s 331, 60s 752, 70s 631, 80s 126, 90s 31. Caveat: these lines are written only when the fan target or state changes, not on a fixed clock, so this is **not** a time-share histogram.

A max-of-cores reading that jumps 30 °C in five seconds isn't a fault; a control loop that reacts to every sample is chasing noise.

## 5. When throttling actually happens

The stock fan policy on the M4 mini is silence-first. External reports first; the figures below come from **other people's machines, not mine** ([theenterprisemac](https://theenterprisemac.com/post/768543525732237312/m4mini-thermal-throttle), [MacRumors](https://forums.macrumors.com/threads/mac-mini-m4-thermals.2442671/), [MacRumors](https://forums.macrumors.com/threads/is-100-105-cpu-celsius-on-the-new-m4-mini-thermal-throttling.2442865/)). They report that after 10–15 minutes of sustained load the SoC sits at 105–107 °C with the fan around 2100 rpm, and the P-cores drop from 4464 to 3300–3800 MHz, which is about −15 to −26%.

Later I ran a same-machine, same-load comparison on my own Mac (2026-09-25, details in section 7). With CPU + GPU fully loaded and macOS auto in charge, the fan sat at 2,951 rpm, the temperature at 106.8 °C, and the P-cores fell from 3936 to an average of 3644 MHz (**−7.4%**), with thermal pressure `Nominal` throughout. On a CPU-only load, macOS first dropped the fan to 1000 rpm and only began ramping at 104–106.6 °C; until my script cut it off at 108 °C the P-cores were still at 3936, so it was cut before any throttling showed. The external −15 to −26% or so is measured against the 4464 single-core peak and my −7.4% against the all-core 3936, so they can't be compared directly.

On my machine, under an all-core load at moderate temperature, `powermetrics` reported **3936 MHz with thermal pressure `Nominal`** (the single-core peak is 4464). *Inference:* 3936 looks like the all-core power limit. All 450/450 `powermetrics` samples in the 09-25 cool42 curve runs read 3936, which supports that, but it still doesn't prove it's a power limit. The P-cores also ran anywhere from 3.04 to 3.96 GHz while `Nominal`, and I've seen 4187 and 4130 MHz under heavy load (section 1), so the clock has to be read together with temperature and load; its level alone doesn't tell you about throttling.

That's the main point of this post. **Temperature and throttling are different signals.** The first time my guard took over from the stock policy, the log showed 105 °C at 1774 rpm, and 82 °C at 4618 rpm 20 seconds later (README "Measurements"; that raw log is also gone). The four days of current log (94.4 h) show:

- a daily maximum of 93, 95, 95 and 78 °C (log values; the last day runs to 23:42; the daily summary truncates them to 93, 94, 94, 78), with the highest logged value 95 °C (three lines) and nothing at or above 100 °C;
- 31 fan-guard writes at or above 90 °C, which group into 5 hot periods (a gap of more than 5 minutes starts a new one; two of the writes are the residual heat guard inherited from macOS auto at startup, 09-20 01:18:45);
- **0 seconds** "throttled" on every day (`/var/log/cool42.log` daily summaries, `/var/db/cool42/stats.json`). The definition then was thermal pressure above `Nominal` or GPU CLTM, with no clock check, so this zero doesn't rule out silent throttling (section 7).

One thing I can't fully explain yet, and I'd rather mention it than have someone find it. In the log lines at 90–95 °C, the P-core hardware clock (the ⚡ field, from `powermetrics`) has 29 values between 3.04 and 3.96 GHz, median 3.64 GHz, which is below the 3.936 GHz all-core figure. Pressure was `Nominal` throughout. My guess is partial load or the power limit, but it's a guess. The 09-25 comparison adds another possibility: under macOS auto at 106–109 °C the P-cores were also around 3.6 GHz with pressure `Nominal`, while the cool42 curve on the same load held 3936 at 2.4 °C cooler and 17.5% more CPU power — the 7.4% drop is measured; *attributing it to heat (the GPU was CLTM-capped 13–18% at the same time) is an inference*, and a power limit hasn't been ruled out directly (same sentence as in section 7). But the cool42 curve kept 3936 even at 104 °C under full all-core load, so the 3.64 GHz at 90–95 °C looks less like thermal throttling — also an inference. "Nominal" doesn't mean "every core at 3936", and it doesn't mean "not throttled" either.

## 6. Fan curve A/B test: 25% less fan for 3.8 °C

With "throttled or not" as the target, the question becomes: what's the lowest fan speed that doesn't throttle? (At the time I used `Nominal` pressure as "not throttled"; section 7 explains why that isn't enough.)

Setup: the same Python geometry workload for both runs (two processes at 400–800% CPU, load average 22–42 on 10 cores), 5 minutes per curve, one `cool42 status --short` sample every 10 s, with the first 60 s of each run dropped (`docs/ab-test-2026-09-16/`).

| | A (old default, aggressive) | B (current default) | Δ |
|---|---|---|---|
| curve (°C→rpm) | 55→1000 65→1800 75→3000 85→4200 90→4900 | 60→1000 75→1800 85→2600 92→3600 97→4900 | |
| control temp, mean (range) | 83.0 °C (75–88) | 86.8 °C (77–93) | +3.8 °C |
| fan, mean (range) | 4216 rpm (3952–4542) | 3150 rpm (2344–3805) | −1066 rpm (−25%) |
| load average | 23.1–37.1 | 21.9–41.6 | |
| P-core HW frequency | not sampled in the window | not sampled in the window | — |
| noise (estimate) | | | −6.3 dB |

*Sources: `samples.txt` (recomputed), `README.md` in that directory.*

There are two batches of `powermetrics` outside the windows, and **both were taken with the old curve A active**: 3 samples before the A run (3936 MHz ×3, Nominal, 21.5–22.1 W), and 6 samples starting ~3 minutes after the B run ended and `ab.sh` restored the config to A (`powermetrics-B.txt`: 3936 ×5, 3950 ×1, Nominal 6/6, 16.8–21.2 W). The "B" in that filename is historical; the content isn't curve-B data.

Caveats, since this is the part people will quote:

- **There is no `powermetrics` sample inside the 5-minute B window.** The A samples are from 05:00:41–47, before A started at 05:06:01. The "B" samples are from 05:19:04–05:20:44, but `ab.sh` restored the config to curve A at 05:16:14 when B ended. The pressure at B's 93 °C peak wasn't measured either. So this A/B supports "25% less fan for 3.8 °C" and **not** "B doesn't throttle"; the 94 hours of daily stats afterwards show 0 s of non-Nominal pressure, but pressure can miss silent throttling (section 7), so that isn't evidence either. The closest support is 09-25: the same curve B held all 180/180 P-core samples at 3936 MHz under a heavier CPU + GPU load — a different load, though. Proving it directly needs a re-run with `powermetrics` recording inside both windows.
- −6.3 dB is the fan law, `50·log10(4216/3150)`. I didn't measure it with a meter.
- I have **no wall-clock comparison** (same job, stock vs cool42), and no stock baseline under this A/B load (the 09-25 stock comparison used a different load). So I'm not claiming anything is "X% faster".
- n = 1 machine, in one room, for one 10-minute session.

Even so, I made B the default: 3.8 °C more for a quarter less fan, and on 09-25 it also held the full 3936 MHz under a CPU + GPU load.

## 7. Gating an AI agent on throttling, not temperature — and why pressure isn't enough

I spend a lot of time with Claude Code running `swift build`, `ffmpeg` and Python jobs on this machine, often several at once. Claude Code has a `PreToolUse` hook that runs a program before each Bash command, and that program can allow, delay or deny the command. That makes it a natural place for "don't start another heavy job if the machine is struggling".

**The first version was a temperature gate: wait if the SoC is at 90 °C or above.** Once curve B was the default, heavy-load temperatures sat at 77–93 °C (the A/B's B run, mean 86.8 °C), and above 90 °C the agent waited before every Bash call (from the first version's log, which is no longer on disk). That traded real progress for a temperature number that didn't mean anything.

**The second version used the thermal pressure level from `powermetrics`**, read by the root daemon, plus GPU CLTM capping:

| state | hook | `cool42 check` exit |
|---|---|---|
| `Nominal`, GPU not capped | allow, **whatever the temperature** | 0 |
| `Moderate` / `Heavy`, or GPU capped by CLTM > 5% | wait for recovery (≤ 90 s), then allow | 1 |
| `Trapping` / `Sleeping` | deny (configurable) | 2 |
| temperature ≥ 100 °C | deny, regardless of pressure (safety floor) | 2 |

My assumption was that `Nominal` means not throttled — let macOS be the judge. On 2026-09-25 my own measurement proved that wrong.

**The measurement.** Same machine, same load (10 sha256 workers plus a full Metal GPU load), with the fan handed alternately to macOS auto and to cool42's default curve; each mode waits for steady state and then samples `powermetrics` for 90 s (`docs/perf-2026-09-25/`, recomputable with `recompute.py`):

| | macOS auto | cool42 default curve |
|---|---|---|
| control temp (sample-window mean) | 106.8 °C | 104.4 °C |
| fan | 2,951 rpm (max 4,900) | 4,877 rpm |
| P-core hardware clock | mean 3,644 MHz (**−7.4%** vs the all-core 3936) | 3936 MHz (180/180 samples) |
| thermal pressure | **`Nominal`** (polls 79/79, `powermetrics` 90/90) | `Nominal` (180/180) |
| sha256 ops/s | 17,066 | 17,875 (+4.7%) |

In the stock run the P-core clock slid down from t+30 s and stayed at 3599–3700 MHz after 150 s, while macOS reported `Nominal` from start to finish. **The clock dropped and the system didn't say so.** The 7.4% P-core drop is measured; attributing it to heat (the GPU was CLTM-capped 13–18% at the same time) is an inference, and a power limit hasn't been ruled out directly — that is what "silent throttling" means throughout this article.

The second-version guard installed at the time did log "throttling started", but reading the log closely, what triggered it was GPU CLTM (13–18%), not pressure; and twice it declared throttling over while the P-cores were still at 3761 and 3729 MHz (`guard-log-2026-09-25-1110.txt`). This time the GPU load caught it; with a CPU-only load and no GPU capping, the second version would have recorded the whole stretch as "not throttled".

To be precise about what the hook would have done, so as not to overstate the problem: the temperature was 105–111 °C, and the hook checks a safety floor before it looks at throttling — at a control temperature ≥ 100 °C (`criticalTemp`) it denies. So even the second version would have denied new Bash calls then, because it was *too hot*, not because it saw throttling. What the pressure blind spot really fooled was the throttling *record*: daily seconds throttled would read 0, the log wouldn't mention it, the panel and `status` wouldn't flag it. For a tool whose advice is "seconds throttled should be 0", that zero was false.

**The third version (in the repo source, not in any release yet) adds a clock check.** A control temperature ≥ `clockThrottleTemp` (default 100 °C) with the P-core hardware clock < the all-core full-load clock × `clockThrottleRatio` (default 0.95) counts as throttling; it clears once the clock is back above × 0.97 or the temperature falls 3 °C below the threshold. So "throttling" is now any of three: pressure above `Nominal`, GPU CLTM, or a clock drop — one definition shared by guard's log, the daily seconds throttled, the panel and the hook.

The hard part is the "all-core full-load clock". Letting guard learn its own peak doesn't work: when hot, a single core boosts to 4464, and once that's taken as the peak, the all-core 3936 looks throttled and the hook waits for nothing. So it's a table of measured values with one entry so far: **Apple M4 = 3936 MHz** (all 450/450 `powermetrics` samples in the 09-25 curve runs read 3936). **Other chips get no clock check by default**; set `clockFullLoadMHz` in the config to opt in.

Applying the rule to the 09-25 data: the stock run at 106.8 °C and 3644 MHz would count as throttling; the cool42 curve at 104.4 °C and 3936 MHz would not. That's the rule applied after the fact — **the third version hasn't run on real hardware yet**.

The default `clockThrottleTemp` and `criticalTemp` are both 100 °C, so with default settings the clock check mainly makes the throttling record honest; it changes hook behaviour directly only for people who raise `criticalTemp`. And one unflattering thing I should say: under the same CPU + GPU load the default cool42 curve also sits at 104.4 °C, above the 100 °C floor, so by the rules the hook denies new Bash calls there too. The default curve can't hold that extreme load under 100 °C.

The cost, too: the cool42 curve spins the fan 65% faster (≈ +10.9 dB estimated from rpm, not measured), draws 17.5% more CPU power (23.89 vs 20.34 W), and the stock run actually gets 12% more work per joule. Throttling isn't bad in itself — it saves power and it's quiet. The problem is that it doesn't tell you, and the one thing a tool that claims to "see throttling" can't do is report "not throttled" while it's happening.

Limits of this comparison: the stock steady state is **one run**, and a warm start at that (a bug in that run's cool-down check meant it began at 100.8 °C); both cold-start stock runs reached 112.6 °C within 35–40 s and were cut off by the script's safety limit, so the true peak and a cold-start steady state weren't measured. The stock run and the two curve runs come from two sessions about 40 minutes apart. One machine, room temperature not controlled.

**The fan's job is to keep throttling from happening, and the gate's job is to step in only when it actually happens** — that hasn't changed; what changed is how throttling is recognised. The hook doesn't touch SMC or spawn `powermetrics`. It reads the JSON snapshot the daemon writes every 5 s, which takes about 9 ms per call (README; I didn't re-measure it for this post).

There's also a **pre-warm** step. If the command looks heavy (`swift build`, `xcodebuild`, `ffmpeg`, `python -m`, `make`…), the hook drops an event and the daemon runs the fan at 3000 rpm for two minutes *before* the heat arrives. In the 94.4 h log this fired 32 times (ffmpeg 25, `python3 -m` 3, `swift build` 2, `xcodebuild` 1, `make` 1). Three of those were cut short after 30–45 s, because the temperature never rose above the bottom of the curve and the job clearly wasn't heavy.

Looking back at the 94.4 h of daily log: 5 hot periods (31 writes at or above 90 °C), 0 hook waits, 0 denies, and 0 s of non-`Nominal` pressure or GPU CLTM. Those zeros use the second version's definition and **don't rule out silent throttling**; *inference from the rule:* that log peaks at 95 °C, below the third version's 100 °C threshold, so the clock check wouldn't have fired either. The log records hook waits and denials, not every allowed call, so I don't know how many Bash calls actually went through the hook during those periods. *Inference:* if heavy commands ran then, the first version's 90 °C rule would have made them wait.

What the daily data shows is that the gate **doesn't get in the way** when it has no reason to; the daily log still contains no real "throttled → waited → resumed" episode. The 09-25 run deliberately handed the fan to macOS; guard flagged throttling (via GPU CLTM), but the log has no hook wait or deny in that window, so it doesn't count as a real case either. Next step: install the third version and rerun the same comparison, to see whether the clock check misfires or misses on real hardware.

## 8. What it costs, and why it needs root

Only one part runs as root: a LaunchDaemon that writes the SMC fan keys and keeps one `powermetrics -i 5000` child alive. You need root to write `F0Md`/`F0Tg`, and on the M4 you also need it to see hardware clocks at all (section 1). Everything else (the menu-bar panel, the hook, the CLI, an MCP server for the agent) runs as the user and only reads 644 JSON files. The README has a threat-model table covering the file interfaces, including a `/tmp` symlink issue that I fixed in 1.0.2.

Measured with `ps` on 2026-09-23, long-run averages: the guard plus its `powermetrics` child use **0.49% of one core** (0.27% + 0.22%), and the guard's RSS is 11.3 MB. That's higher than the README's figure (0.3% total, guard 3.5 MB), which was measured earlier and is out of date. At the time of measurement the guard had been running for 3 days 21 hours without a restart.

Two lessons that might save someone a day:

- **Don't run a fan daemon at Background QoS.** At load 35, my first LaunchDaemon (`ProcessType Background`, `Nice 10`) took three minutes to finish its first round, with 1375 SMC calls queued in `mach_msg2_trap`. A fan guard is needed most when the machine is busiest, and that's exactly when Background QoS gets no CPU. I switched it to `Standard` + `Nice -5`.
- **`cp` over a running signed binary gets new processes killed** with `OS_REASON_CODESIGNING`. Copy to `.new`, then `mv`.

## Limits

- Tested on **one Mac mini M4** only. I haven't tested M4 Pro/Max, M1–M3, M5 or MacBooks. I also don't know whether IOReport is decoupled from hardware clocks on M1/M2 too.
- I have only one stock steady-state run of my own (09-25, warm start); both cold-start stock runs were cut off at 112 °C. The other stock numbers are external reports.
- The clock-throttling check (section 7) isn't released and hasn't run on real hardware; the all-core full-load clock has one measured entry, the M4.
- All noise figures are estimated from rpm, not measured with a meter.
- No end-to-end wall-clock comparison.
- The builds are ad-hoc signed (no Developer ID or notarization yet). `install.sh` builds from source and signs locally.

---

## The tool

All of the above came out of building **cool42**, a fan guard for Apple Silicon: a root daemon that runs the fan curve, a menu-bar panel with a per-sensor heat grid (all 73 CPU/GPU temperature sensors, one cell each) plus the P-core hardware clock from `powermetrics` and pressure, a CLI, and a Claude Code hook + MCP server that implement the gate in section 7. It's pure Swift plus about 170 lines of C for SMC and libproc, with no external dependencies, 43 unit tests (including the unreleased clock check), and an MIT license.

It was also an experiment in building with an AI agent. Most of the code was written with Claude Code, over 42 commits in about four days (0.1 → 1.0.3). The four fixes in 1.0.1 came from having the agent read 2.5 days of its own guard log.

- Repo: <https://github.com/Okle42/cool42>
- Raw sensor notes (EN/ZH): `docs/findings-m4-sensors.md`
- A/B raw data: `docs/ab-test-2026-09-16/`
- Stock vs curve on the same machine (four sessions, known bugs, recomputation script; notes in Chinese): `docs/perf-2026-09-25/`

If you have a different Apple Silicon machine, the most useful thing you can send is the output of `cool42 chip`, `cool42 sensors` and `cool42 doctor`, or just a `powermetrics` vs IOReport comparison under load. That's how we find out whether any of this holds beyond one M4.

*— okle42*
