#!/usr/bin/env python3
"""從本資料夾的原始數據重算 README 的結論 1–3，並輸出圖表用的數據檔。

只讀 run*/results.json（各檔 trace＝perf.log 每 5 秒一行）與 run*/pm/*.txt（powermetrics 每秒一筆）。
只用 python3 標準庫。

用法：
  python3 docs/perf-2026-09-25/recompute.py            # 印出重算表（Markdown）
  python3 docs/perf-2026-09-25/recompute.py --viz      # 另外寫 extras/viz/data/perf-2026-09-25.json
"""
import json
import math
import os
import re
import statistics as st
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
VIZ_OUT = os.path.join(ROOT, "extras", "viz", "data", "perf-2026-09-25.json")
RUNS = ["run1-cpu", "run2-cpu", "run3-cpugpu", "run4-cpugpu"]
FULL_MHZ = 3936   # M4 全核滿載 P-core 硬體頻率（本資料夾所有 curve 檔 pm 取樣 450/450 筆都是 3936）


def load(run):
    return json.load(open(os.path.join(HERE, run, "results.json"), encoding="utf-8"))


def pm(run, name):
    txt = open(os.path.join(HERE, run, "pm", name), encoding="utf-8").read()
    out = []
    for b in txt.split("*** Sampled system activity")[1:]:
        ts = re.search(r"\(\w{3} (\w{3} +\d+ \d\d:\d\d:\d\d) \d{4}", b).group(1)
        out.append(dict(
            ts=datetime.strptime("2026 " + ts, "%Y %b %d %H:%M:%S"),
            p=int(re.search(r"P-Cluster HW active frequency: (\d+) MHz", b).group(1)),
            cpuW=int(re.search(r"CPU Power: (\d+) mW", b).group(1)) / 1000,
            gpuW=int(re.search(r"GPU Power: (\d+) mW", b).group(1)) / 1000,
            pressure=re.search(r"Current pressure level: (\w+)", b).group(1)))
    return out


def pct(xs, q):
    xs = sorted(xs)
    k = (len(xs) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def fmt(x, n=1):
    return f"{x:,.{n}f}"


def main():
    R = {r: load(r) for r in RUNS}
    rows = []   # (結論, 項目, 重算值, 算法／出處)

    # ---------------- 結論 1：CPU-only，原廠自動接手後
    for run, idx in (("run2-cpu", 1), ("run2-cpu", 3), ("run1-cpu", 1)):
        x = R[run]["results"][idx]
        tr = x["trace"]
        after = tr[1:]                                   # t=0 那筆是換檔前一刻（降溫檔或前一檔留下的轉速）
        at1000 = [p for p in after if p["rpm"] <= 1010]
        ramp = [p for p in after if p["rpm"] > 1010]
        tag = f"{run} 第 {idx + 1} 檔（原廠自動 #{x['rep']}）"
        rows.append(("1", f"{tag}：接手後轉速", f"{min(p['rpm'] for p in after):.0f}–{max(p['rpm'] for p in at1000):.0f} rpm 共 {len(at1000)} 筆（t+{at1000[0]['t']:.0f}–{at1000[-1]['t']:.0f}s）",
                     f"results.json results[{idx}].trace[1:]，rpm ≤ 1010 視為 1000"))
        rows.append(("1", f"{tag}：停在 1000 時溫度", f"{at1000[0]['temp']:.1f} → {at1000[-1]['temp']:.1f}°C（+{at1000[-1]['temp'] - at1000[0]['temp']:.1f}°C / {at1000[-1]['t'] - at1000[0]['t']:.0f}s）", "同上"))
        if ramp:
            inc = [b["rpm"] - a["rpm"] for a, b in zip([at1000[-1]] + ramp, ramp)]
            rows.append(("1", f"{tag}：開始拉轉速", f"最後一筆 1000 rpm 在 {at1000[-1]['temp']:.1f}°C，第一筆 >1000 在 {ramp[0]['temp']:.1f}°C；每 5 秒 +" + "/".join(f"{v:.0f}" for v in inc) + " rpm",
                         "trace 相鄰兩筆 rpm 差"))
        rows.append(("1", f"{tag}：中止時", f"{tr[-1]['temp']:.1f}°C、{tr[-1]['rpm']:.0f} rpm；P-core 輪詢 {sorted({p['pcore'] for p in after})} MHz；pressure {sorted({p['pressure'] for p in tr})}",
                     f"results.json results[{idx}] reason：{x['reason']}"))

    # ---------------- 結論 2：CPU＋GPU，原廠自動（run3 第 4 檔）
    x = R["run3-cpugpu"]["results"][3]
    tr = x["trace"]
    plateau = [p for p in tr if p["t"] >= 45]            # 風扇 t+45s 起停在 ~2950
    P = pm("run3-cpugpu", "04-auto-r2.txt")
    pp = [s["p"] for s in P]
    rows += [
        ("2", "run3 第 4 檔：起跑狀態", f"t+0 {tr[0]['temp']:.1f}°C、{tr[0]['rpm']:.0f} rpm（熱機起跑：降溫判定 {x['cooldown_end_c']:.1f}°C、{x['cooldown_s']:.0f}s 就算完成）",
         "results.json results[3].trace[0]、cooldown_end_c／cooldown_s"),
        ("2", "run3 第 4 檔：風扇（t≥45s 輪詢）", f"平均 {st.mean(p['rpm'] for p in plateau):,.0f}、{min(p['rpm'] for p in plateau):.0f}–{max(p['rpm'] for p in plateau):.0f} rpm（n={len(plateau)}）",
         "results.json results[3].trace，t ≥ 45"),
        ("2", "run3 第 4 檔：溫度（t≥45s 輪詢）", f"平均 {st.mean(p['temp'] for p in plateau):.1f}°C、P10–P90 {pct([p['temp'] for p in plateau], .1):.1f}–{pct([p['temp'] for p in plateau], .9):.1f}、全距 {min(p['temp'] for p in plateau):.1f}–{max(p['temp'] for p in plateau):.1f}",
         "同上"),
        ("2", "run3 第 4 檔：取樣窗溫度（90s）", f"平均 {x['temp_c']:.1f}°C、最高 {x['temp_max_c']:.1f}°C；風扇 {x['rpm_actual']:,.0f}（{x['rpm_min']:.0f}–{x['rpm_max']:.0f}）", "results.json results[3] temp_c／temp_max_c／rpm_*；results.csv 第 5 行"),
        ("2", "run3 第 4 檔：P-core（pm 取樣窗 90 筆）", f"平均 {st.mean(pp):,.1f} MHz（{st.mean(pp) / FULL_MHZ * 100 - 100:+.1f}%）、P5–P95 {pct(pp, .05):.0f}–{pct(pp, .95):.0f}、全距 {min(pp)}–{max(pp)}",
         "pm/04-auto-r2.txt「P-Cluster HW active frequency」"),
        ("2", "run3 第 4 檔：P-core（t≥45s 輪詢）", f"平均 {st.mean(p['pcore'] for p in plateau):,.0f} MHz、{min(p['pcore'] for p in plateau)}–{max(p['pcore'] for p in plateau)}", "results.json results[3].trace pcore"),
        ("2", "run3 第 4 檔：pressure", f"trace {sum(p['pressure'] == 'Nominal' for p in tr)}/{len(tr)} Nominal；pm {sum(s['pressure'] == 'Nominal' for s in P)}/{len(P)} Nominal",
         "trace pressure、pm「Current pressure level」"),
        ("2", "run3 第 4 檔：功率（pm）", f"CPU {st.mean(s['cpuW'] for s in P):.2f} W、GPU {st.mean(s['gpuW'] for s in P):.2f} W", "pm「CPU Power」「GPU Power」"),
        ("2", "run3 第 4 檔：ops/s", f"{x['ops_per_s']:,.1f}（ops/J {x['ops_per_j']:.1f}）", "results.json results[3].ops_per_s／ops_per_j"),
    ]
    for run, idx in (("run4-cpugpu", 1), ("run4-cpugpu", 3), ("run3-cpugpu", 1)):
        y = R[run]["results"][idx]
        t = y["trace"]
        rows.append(("2", f"{run} 第 {idx + 1} 檔（原廠自動 #{y['rep']}）", f"起跑 {t[0]['temp']:.1f}°C → t+{t[-1]['t']:.0f}s {t[-1]['temp']:.1f}°C 被切；接手後風扇最高 {max(p['rpm'] for p in t[1:]):.0f} rpm；pressure {sorted({p['pressure'] for p in t})}",
                     f"results.json results[{idx}].trace；reason：{y['reason']}"))

    # ---------------- 結論 3：cool42 曲線（run4 第 1、3 檔）vs 原廠（run3 第 4 檔）
    c = [R["run4-cpugpu"]["results"][i] for i in (0, 2)]
    cpm = pm("run4-cpugpu", "01-curve-r1.txt") + pm("run4-cpugpu", "03-curve-r2.txt")
    ct = st.mean(v["temp_c"] for v in c)
    cr = st.mean(v["rpm_actual"] for v in c)
    co = st.mean(v["ops_per_s"] for v in c)
    cj = st.mean(v["ops_per_j"] for v in c)
    rows += [
        ("3", "run4 曲線 2 輪：溫度", f"{c[0]['temp_c']:.2f} / {c[1]['temp_c']:.2f} → 平均 {ct:.2f}°C", "run4 results.json results[0]／[2].temp_c"),
        ("3", "run4 曲線 2 輪：風扇", f"{c[0]['rpm_actual']:,.0f} / {c[1]['rpm_actual']:,.0f} → 平均 {cr:,.0f} rpm", "rpm_actual"),
        ("3", "run4 曲線 2 輪：P-core（pm 180 筆）", f"平均 {st.mean(s['p'] for s in cpm):.1f} MHz、{min(s['p'] for s in cpm)}–{max(s['p'] for s in cpm)}；pressure {sum(s['pressure'] == 'Nominal' for s in cpm)}/{len(cpm)} Nominal",
         "pm/01-curve-r1.txt＋03-curve-r2.txt"),
        ("3", "run4 曲線 2 輪：ops/s", f"{c[0]['ops_per_s']:,.1f} / {c[1]['ops_per_s']:,.1f} → 平均 {co:,.1f}", "ops_per_s"),
        ("3", "曲線 vs 原廠 ops/s", f"{co:,.1f} / {x['ops_per_s']:,.1f} = {co / x['ops_per_s'] * 100 - 100:+.2f}%（逐輪 {c[0]['ops_per_s'] / x['ops_per_s'] * 100 - 100:+.2f}% / {c[1]['ops_per_s'] / x['ops_per_s'] * 100 - 100:+.2f}%）",
         "run4 平均 ÷ run3 第 4 檔"),
        ("3", "曲線 vs 原廠 溫度", f"{ct:.1f} vs {x['temp_c']:.1f}°C（{ct - x['temp_c']:+.1f}°C）", "取樣窗平均"),
        ("3", "曲線 vs 原廠 CPU 功率", f"{st.mean(v['cpu_w'] for v in c):.2f} vs {x['cpu_w']:.2f} W（{st.mean(v['cpu_w'] for v in c) / x['cpu_w'] * 100 - 100:+.1f}%）", "cpu_w（pm CPU Power 平均）"),
        ("3", "曲線 vs 原廠 ops/J", f"{cj:.1f} vs {x['ops_per_j']:.1f}（{cj / x['ops_per_j'] * 100 - 100:+.1f}%，原廠每焦耳較省）", "ops_per_j"),
        ("4", "噪音推估（推論，非量測）", f"50·log10({cr:,.0f}/{x['rpm_actual']:,.0f}) = +{50 * math.log10(cr / x['rpm_actual']):.1f} dB", "風扇定律：聲功率 ∝ 轉速⁵；未量 dB"),
    ]
    # 曲線全部 pm：run1/run2/run4 的 curve 檔
    allc = []
    for run, names in (("run1-cpu", ["01-curve-r1.txt"]), ("run2-cpu", ["01-curve-r1.txt", "03-curve-r2.txt"]), ("run4-cpugpu", ["01-curve-r1.txt", "03-curve-r2.txt"])):
        for n in names:
            allc += pm(run, n)
    rows.append(("5", "全核滿載頻率 3936 的依據", f"所有 curve 檔 pm {sum(s['p'] == FULL_MHZ for s in allc)}/{len(allc)} 筆 = {FULL_MHZ} MHz", "run1/run2/run4 pm/*curve*.txt"))

    print("| # | 項目 | 重算值 | 算法／出處 |\n|---|---|---|---|")
    for r in rows:
        print("| " + " | ".join(r) + " |")

    if "--viz" in sys.argv:
        def tr_of(v):
            return [dict(t=round(p["t"], 1), temp=round(p["temp"], 2), rpm=round(p["rpm"]), pcore=p["pcore"], pressure=p["pressure"]) for p in v["trace"]]

        def pm_of(samples, settle):
            t0 = samples[0]["ts"]
            # pm 取樣窗緊接在 trace 之後開始（run3 第 4 檔：trace 起點約 11:09:28＋399s ≈ 11:16:07＝pm 第一筆）；位置約略對齊（±5 秒）
            return [dict(t=round(settle + (s["ts"] - t0).total_seconds(), 1), p=s["p"], pressure=s["pressure"]) for s in samples]

        c1 = R["run4-cpugpu"]["results"][0]
        out = dict(
            source="docs/perf-2026-09-25（recompute.py --viz 產生）",
            full_mhz=FULL_MHZ,
            auto_cpugpu=dict(run="run3-cpugpu", step=4, trace=tr_of(x), pm=pm_of(P, x["settle_s"]),
                             sample=dict(temp=x["temp_c"], rpm=x["rpm_actual"], pcore=x["pcore_mhz"], ops=x["ops_per_s"], cpu_w=x["cpu_w"], ops_j=x["ops_per_j"]),
                             settle_s=x["settle_s"], state=x["state"]),
            curve_cpugpu=dict(run="run4-cpugpu", step=1, trace=tr_of(c1), pm=pm_of(pm("run4-cpugpu", "01-curve-r1.txt"), c1["settle_s"]),
                              sample=dict(temp=c1["temp_c"], rpm=c1["rpm_actual"], pcore=c1["pcore_mhz"], ops=c1["ops_per_s"], cpu_w=c1["cpu_w"], ops_j=c1["ops_per_j"]),
                              settle_s=c1["settle_s"], state=c1["state"],
                              both=dict(temp=ct, rpm=cr, ops=co, ops_j=cj)),
            auto_cold=[dict(run="run4-cpugpu", step=i + 1, trace=tr_of(R["run4-cpugpu"]["results"][i])) for i in (1, 3)],
            auto_cpu=[dict(run="run2-cpu", step=i + 1, trace=tr_of(R["run2-cpu"]["results"][i])) for i in (1, 3)],
            guard_log=[l.rstrip("\n") for l in open(os.path.join(HERE, "guard-log-2026-09-25-1110.txt"), encoding="utf-8")],
        )
        with open(VIZ_OUT, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
        print(f"\n寫出 {os.path.relpath(VIZ_OUT, ROOT)}")


if __name__ == "__main__":
    main()
