# What the M4 Mac mini's sensors actually tell you (and what they lie about)

*One Mac mini M4 (Mac16,10), macOS 26 (build 25G83), September 2026. n = 1. Every number below links back to a raw file in the cool42 repo; where something is an inference rather than a measurement, it says so.*

I wanted one thing from my Mac mini: to know, while a long build or render was running, whether the CPU was being thermally throttled. That turned out to be harder than it sounds. Most of the obvious ways to read "CPU frequency" and "CPU temperature" on Apple Silicon give numbers that are real, but answer a different question from the one you're asking.

This post covers what I found on the M4, a fan-curve A/B test, and why I gate an AI coding agent on *throttling* rather than *temperature*. The tool is at the end; the findings stand on their own.

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
- A resident `powermetrics -i 5000` child costs about 0.18% CPU, plus about 0.8 s of CPU once at startup (findings §1). My longer-run figure is further down.

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

The stock fan policy on the M4 mini is silence-first. The figures below come from **other people's machines, not mine** ([theenterprisemac](https://theenterprisemac.com/post/768543525732237312/m4mini-thermal-throttle), [MacRumors](https://forums.macrumors.com/threads/mac-mini-m4-thermals.2442671/), [MacRumors](https://forums.macrumors.com/threads/is-100-105-cpu-celsius-on-the-new-m4-mini-thermal-throttling.2442865/)). They report that after 10–15 minutes of sustained load the SoC sits at 105–107 °C with the fan around 2100 rpm, and the P-cores drop from 4464 to 3300–3800 MHz, which is −15 to −25%.

On my machine, under an all-core load, `powermetrics` reported **3936 MHz with thermal pressure `Nominal`**. I read 3936 as the all-core power-limited frequency. The single-core peak is 4464. That's a power limit, not thermal throttling, and the `Nominal` pressure level backs that up.

That's the main point of this post. **Temperature and throttling are different signals.** The first time my guard took over from the stock policy, the log showed 105 °C at 1774 rpm, and 82 °C at 4618 rpm 20 seconds later (README "Measurements"; that raw log is also gone). The four days of current log (94.4 h) show:

- a daily maximum of 93, 94, 94 and 78 °C (the last day runs to 23:42), with the highest logged value 95 °C (three lines) and nothing at or above 100 °C;
- 31 logged moments at or above 90 °C;
- **0 seconds** with thermal pressure other than `Nominal` on every day (`/var/log/cool42.log` daily summaries, `/var/db/cool42/stats.json`).

One thing I can't fully explain yet, and I'd rather mention it than have someone find it. In the log lines at 90–95 °C, the median P-core clock (the ⚡ field) is 3.64 GHz, which is below the 3.936 GHz all-core figure. Pressure was `Nominal` throughout. My guess is partial load or the power limit, but it's a guess. "Nominal" doesn't mean "every core at 3936".

## 6. Fan curve A/B test: 25% less fan for 3.8 °C

With "throttled or not" as the target, the question becomes: what's the lowest fan speed that keeps pressure at `Nominal`?

Setup: the same Python geometry workload for both runs (two processes at 400–800% CPU, load average 22–42 on 10 cores), 5 minutes per curve, one `cool42 status --short` sample every 10 s, with the first 60 s of each run dropped (`docs/ab-test-2026-09-16/`).

| | A (old default, aggressive) | B (current default) | Δ |
|---|---|---|---|
| curve (°C→rpm) | 55→1000 65→1800 75→3000 85→4200 90→4900 | 60→1000 75→1800 85→2600 92→3600 97→4900 | |
| control temp, mean (range) | 83.0 °C (75–88) | 86.8 °C (77–93) | +3.8 °C |
| fan, mean (range) | 4216 rpm (3952–4542) | 3150 rpm (2344–3805) | −1066 rpm (−25%) |
| load average | 23.1–37.1 | 21.9–41.6 | |
| P-core HW frequency | 3936 MHz ×3, Nominal | 3936 ×5, 3950 ×1, Nominal 6/6 | ≈0 |
| CPU power | 21.5–22.1 W | 16.8–21.2 W | |
| noise (estimate) | | | −6.3 dB |

*Sources: `samples.txt` (recomputed), `powermetrics-A.txt`, `powermetrics-B.txt`, `README.md` in that directory.*

Caveats, since this is the part people will quote:

- **The powermetrics samples bracket the window. They weren't taken inside it.** The A samples are from 05:00:41–47, just before A started at 05:06:01. The B samples are from 05:19:04–05:20:44, after the B run ended at 05:16:14. So the honest claim is: "powermetrics read 3936 MHz and `Nominal` immediately before and after, under the same load." It isn't "measured at the same instant". The repo's own README describes the B samples as "steady-state", which is looser than it should be.
- −6.3 dB is the fan law, `50·log10(4216/3150)`. I didn't measure it with a meter.
- I have **no wall-clock comparison** (same job, stock vs cool42) and no same-machine stock baseline under the same load. So I'm not claiming anything is "X% faster".
- n = 1 machine, in one room, for one 10-minute session.

Even so, it was enough to make B the default. It costs 4 °C more for a quarter less fan, with no sign of pressure leaving `Nominal`.

## 7. Gating an AI agent on throttling, not temperature

I spend a lot of time with Claude Code running `swift build`, `ffmpeg` and Python jobs on this machine, often several at once. Claude Code has a `PreToolUse` hook that runs a program before each Bash command, and that program can allow, delay or deny the command. That makes it a natural place for "don't start another heavy job if the machine is struggling".

**The first version was a temperature gate: wait if the SoC is at 90 °C or above.** Once curve B was the default, sustained-load temperatures sat in the high 80s and low 90s, and the agent waited before nearly every Bash call. That traded real progress for a temperature number that didn't mean anything.

The current gate uses the thermal pressure level from `powermetrics`, read by the root daemon:

| thermal pressure | hook | `cool42 check` exit |
|---|---|---|
| `Nominal` | allow, **whatever the temperature** | 0 |
| `Moderate` / `Heavy`, or GPU capped by CLTM > 5% | wait for recovery (≤ 90 s), then allow | 1 |
| `Trapping` / `Sleeping` | deny (configurable) | 2 |
| temperature ≥ 100 °C | deny, regardless of pressure (safety floor) | 2 |

The fan's job is to keep throttling from happening, and the gate's job is to step in only when it actually happens. The hook doesn't touch SMC or spawn `powermetrics`. It reads the JSON snapshot the daemon writes every 5 s, which takes about 9 ms per call (README; I didn't re-measure it for this post).

There's also a **pre-warm** step. If the command looks heavy (`swift build`, `xcodebuild`, `ffmpeg`, `python -m`, `make`…), the hook drops an event and the daemon runs the fan at 3000 rpm for two minutes *before* the heat arrives. In the 94.4 h log this fired 32 times (ffmpeg 25, `python3 -m` 3, `swift build` 2, `xcodebuild` 1, `make` 1). Three of those were cut short after 30–45 s, because the temperature never rose above the bottom of the curve and the job clearly wasn't heavy.

Results over the same four days: 31 logged moments at or above 90 °C, and **0 hook waits, 0 denies, 0 s non-Nominal pressure**. *Inference:* under the first version's 90 °C rule, each of those 31 moments would have stalled the agent.

To be clear about what this shows: it shows the gate **doesn't get in the way** when it has no reason to. The current log doesn't contain a single real "throttled → waited → resumed" episode. That's a good outcome for a fan controller, but it means I can't show you the gate firing in the wild. A controlled reproduction (the stock curve plus a stress load) is on the to-do list.

## 8. What it costs, and why it needs root

Only one part runs as root: a LaunchDaemon that writes the SMC fan keys and keeps one `powermetrics -i 5000` child alive. You need root to write `F0Md`/`F0Tg`, and on the M4 you also need it to see hardware clocks at all (section 1). Everything else (the menu-bar panel, the hook, the CLI, an MCP server for the agent) runs as the user and only reads 644 JSON files. The README has a threat-model table covering the file interfaces, including a `/tmp` symlink issue that I fixed in 1.0.2.

Measured with `ps` on 2026-09-23, long-run averages: the guard plus its `powermetrics` child use **0.49% of one core** (0.27% + 0.22%), and the guard's RSS is 11.3 MB. That's higher than the README's figure (0.3% total, guard 3.5 MB), which was measured earlier and is out of date. At the time of measurement the guard had been running for 3 days 21 hours without a restart.

Two lessons that might save someone a day:

- **Don't run a fan daemon at Background QoS.** At load 35, my first LaunchDaemon (`ProcessType Background`, `Nice 10`) took three minutes to finish its first round, with 1375 SMC calls queued in `mach_msg2_trap`. A fan guard is needed most when the machine is busiest, and that's exactly when Background QoS gets no CPU. I switched it to `Standard` + `Nice -5`.
- **`cp` over a running signed binary gets new processes killed** with `OS_REASON_CODESIGNING`. Copy to `.new`, then `mv`.

## Limits

- Tested on **one Mac mini M4** only. I haven't tested M4 Pro/Max, M1–M3, M5 or MacBooks. I also don't know whether IOReport is decoupled from hardware clocks on M1/M2 too.
- The stock-policy numbers are external reports, not my own measurements.
- No end-to-end wall-clock comparison.
- The builds are ad-hoc signed (no Developer ID or notarization yet). `install.sh` builds from source and signs locally.

---

## The tool

All of the above came out of building **cool42**, a fan guard for Apple Silicon: a root daemon that runs the fan curve, a menu-bar panel with a per-sensor heat grid (all 73 SMC sensors, one cell each) plus real P-core clock and pressure, a CLI, and a Claude Code hook + MCP server that implement the gate in section 7. It's pure Swift plus about 170 lines of C for SMC and libproc, with no external dependencies, 40 unit tests, and an MIT license.

It was also an experiment in building with an AI agent. Most of the code was written with Claude Code, over 42 commits in about four days (0.1 → 1.0.3). The four fixes in 1.0.1 came from having the agent read 2.5 days of its own guard log.

- Repo: <https://github.com/Okle42/cool42>
- Raw sensor notes (EN/ZH): `docs/findings-m4-sensors.md`
- A/B raw data: `docs/ab-test-2026-09-16/`

If you have a different Apple Silicon machine, the most useful thing you can send is the output of `cool42 chip`, `cool42 sensors` and `cool42 doctor`, or just a `powermetrics` vs IOReport comparison under load. That's how we find out whether any of this holds beyond one M4.

*— okle42*
