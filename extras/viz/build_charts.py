#!/usr/bin/env python3
"""cool42 數據比對圖：只用 python3 標準庫、自己產 SVG。

資料來源（全部是真實數據，不捏造）：
  * docs/ab-test-2026-09-16/        A/B 實測（samples.txt、powermetrics-A/B.txt、config-A/B.json）
  * extras/viz/data/cool42-log-*.txt  /var/log/cool42.log 凍結快照（2026-09-20 01:18:34 → 2026-09-23 23:42:28）
  * extras/viz/data/stats-*.json      /var/db/cool42/stats.json 當日快照
  加 --live 改讀 /var/log/cool42.log 與 /var/db/cool42/stats.json（數字會跟著變）。

輸出：
  * docs/img/charts/<name>-light.svg、<name>-dark.svg   README 用（<picture> 切換亮暗）
  * docs/viz/index.html                                 互動比對頁（單檔、內嵌 SVG＋數據、hover 看值）
  * 另外複製到 ~/Desktop/cool42-數據比對.html（--no-desktop 可略過）

用法：python3 extras/viz/build_charts.py [--live] [--no-desktop]
"""
import argparse
import html
import json
import math
import os
import re
import shutil
import statistics as st
from collections import Counter, defaultdict
from datetime import datetime, timedelta

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
AB = os.path.join(ROOT, "docs", "ab-test-2026-09-16")
DATA = os.path.join(ROOT, "extras", "viz", "data")
OUT_IMG = os.path.join(ROOT, "docs", "img", "charts")
OUT_HTML = os.path.join(ROOT, "docs", "viz", "index.html")
DESKTOP = os.path.expanduser("~/Desktop/cool42-數據比對.html")

FROZEN_LOG = os.path.join(DATA, "cool42-log-20260920_20260923.txt")
FROZEN_STATS = os.path.join(DATA, "stats-2026-09-23.json")

# ---------------------------------------------------------------- 色彩（dataviz 參考色盤，已跑 validate_palette.js）
# 分類三色 all-pairs 亮暗都 PASS；亮色 aqua 對比 2.74 < 3:1 → 以直接標籤＋表格補足（relief rule）。
THEMES = {
    "light": dict(surface="#fcfcfb", ink="#0b0b0b", ink2="#52514e", muted="#898781", grid="#e1e0d9",
                  axis="#c3c2b7", wash="#f0efec", s1="#2a78d6", s2="#eb6834", s3="#1baf7a", crit="#d03b3b",
                  dim="#c3c2b7"),
    "dark": dict(surface="#1a1a19", ink="#ffffff", ink2="#c3c2b7", muted="#898781", grid="#2c2c2a",
                 axis="#383835", wash="#2c2c2a", s1="#3987e5", s2="#d95926", s3="#199e70", crit="#d03b3b",
                 dim="#52514e"),
}
CSS_THEME = {k: f"var(--{k})" for k in THEMES["light"]}
FONT = "system-ui,-apple-system,'PingFang TC','Noto Sans TC','Segoe UI',sans-serif"


def esc(s):
    return html.escape(str(s), quote=True)


def fmt_int(v):
    return f"{int(round(v)):,}"


# ---------------------------------------------------------------- 讀資料
def load_samples():
    rx = re.compile(r"(\S+) (\w) load=([\d.]+) \S+ (\d+)°C 🌀(\d+)rpm")
    starts = {}
    for line in open(os.path.join(AB, "timeline.txt"), encoding="utf-8"):
        t = line.split()[0]
        if "A 開始" in line:
            starts["A"] = t
        elif "切換 B" in line:
            starts["B"] = t
    rows = []
    for line in open(os.path.join(AB, "samples.txt"), encoding="utf-8"):
        m = rx.match(line.strip())
        if not m:
            continue
        t, g, load, temp, rpm = m.groups()
        sec = (datetime.strptime(t, "%H:%M:%S") - datetime.strptime(starts[g], "%H:%M:%S")).seconds
        rows.append(dict(time=t, group=g, sec=sec, load=float(load), temp=int(temp), rpm=int(rpm)))
    return rows


def load_powermetrics(path, group):
    txt = open(path, encoding="utf-8").read()
    blocks = txt.split("*** Sampled system activity")[1:]
    out = []
    for b in blocks:
        t = re.search(r"\((\w{3} \w{3} +\d+ (\d\d:\d\d:\d\d) \d{4})", b).group(2)
        p = int(re.search(r"P-Cluster HW active frequency: (\d+) MHz", b).group(1))
        e = int(re.search(r"E-Cluster HW active frequency: (\d+) MHz", b).group(1))
        w = int(re.search(r"CPU Power: (\d+) mW", b).group(1)) / 1000
        pr = re.search(r"Current pressure level: (\w+)", b).group(1)
        out.append(dict(group=group, time=t, pMHz=p, eMHz=e, cpuW=w, pressure=pr))
    return out


def load_curve(path):
    return [(c["temp"], c["rpm"]) for c in json.load(open(path, encoding="utf-8"))["curve"]]


WRITE_RX = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (\S+) (\d+)°C 🌀(\d+)rpm(?: ⚡([\d.]+)GHz)? → (?:目標 (\d+) rpm|(交還自動))$")


def load_log(path):
    ev = dict(writes=[], handbacks=[], takeovers=[], boosts=[], early=[], levels=[], settle=[], starts=[])
    prev_was_handback = True  # guard 啟動後第一次寫入也算接管
    first = last = None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if len(line) < 19:
            continue
        ts = datetime.strptime(line[:19], "%Y-%m-%d %H:%M:%S")
        first = first or ts
        last = ts
        body = line[20:]
        m = WRITE_RX.match(line)
        if m:
            _, _, temp, rpm, ghz, target, hb = m.groups()
            w = dict(t=ts, temp=int(temp), rpm=int(rpm), ghz=float(ghz) if ghz else None,
                     target=int(target) if target else None)
            ev["writes"].append(w)
            if hb:
                ev["handbacks"].append(w)
                prev_was_handback = True
            else:
                if prev_was_handback:
                    ev["takeovers"].append(w)   # 🌀 值＝接管前一刻 macOS 自動控制下的實際轉速
                prev_was_handback = False
            continue
        if "guard 啟動" in body:
            ev["starts"].append(ts)
            prev_was_handback = True
        elif body.startswith("預熱提早結束"):
            ev["early"].append(ts)
        elif body.startswith("預熱 "):
            ev["boosts"].append((ts, body.split("：", 1)[1]))
        elif body.startswith("等級 "):
            ev["levels"].append((ts, body))
        elif body.startswith("今日統計結算"):
            g = re.search(r"最高 (\d+)°C，hot (\d+)s，critical (\d+)s，hook 等待 (\d+) 次、擋下 (\d+) 次，預熱 (\d+) 次，降頻 (\d+)s", body)
            day = (ts - timedelta(days=1)).strftime("%Y-%m-%d")  # 00:00:01 結算的是前一天
            ev["settle"].append(dict(date=day, max=int(g.group(1)), hot=int(g.group(2)), critical=int(g.group(3)),
                                     waits=int(g.group(4)), denies=int(g.group(5)), boosts=int(g.group(6)),
                                     throttle=int(g.group(7))))
    ev["first"], ev["last"] = first, last
    return ev


# ---------------------------------------------------------------- SVG 繪圖基礎
class Plot:
    def __init__(self, th, W, H, x0, x1, y0, y1, ml=58, mr=150, mt=104, mb=56, interactive=False, title=None,
                 subtitle=None, xlabel=None, ylabel=None, show_title=True):
        self.th, self.W, self.H = th, W, H
        self.ml, self.mr, self.mt, self.mb = ml, mr, (mt if show_title else mt - 44), mb
        self.x0, self.x1, self.y0, self.y1 = x0, x1, y0, y1
        self.interactive = interactive
        self.parts, self.hits = [], []
        self.title, self.subtitle, self.xlabel, self.ylabel = title, subtitle, xlabel, ylabel
        self.show_title = show_title
        self.legend_items = []

    # 座標
    def sx(self, v):
        return self.ml + (v - self.x0) / (self.x1 - self.x0) * (self.W - self.ml - self.mr)

    def sy(self, v):
        return self.H - self.mb - (v - self.y0) / (self.y1 - self.y0) * (self.H - self.mt - self.mb)

    @property
    def pl(self):
        return self.ml

    @property
    def pr(self):
        return self.W - self.mr

    @property
    def pt(self):
        return self.mt

    @property
    def pb(self):
        return self.H - self.mb

    def text(self, x, y, s, color="ink2", size=12, anchor="start", weight=400, extra=""):
        self.parts.append(f'<text x="{x:.1f}" y="{y:.1f}" fill="{self.th[color]}" font-size="{size}" '
                          f'text-anchor="{anchor}" font-weight="{weight}" {extra}>{esc(s)}</text>')

    def tip_attr(self, title, rows):
        if not self.interactive:
            return ""
        return f' data-tt="{esc(title)}" data-tip="{esc(json.dumps(rows, ensure_ascii=False))}" tabindex="0"'

    def ygrid(self, ticks, fmt=lambda v: fmt_int(v)):
        for v in ticks:
            y = self.sy(v)
            self.parts.append(f'<line x1="{self.pl}" x2="{self.pr}" y1="{y:.1f}" y2="{y:.1f}" stroke="{self.th["grid"]}" stroke-width="1"/>')
            self.text(self.pl - 8, y + 4, fmt(v), "muted", 11, "end", extra='font-variant-numeric="tabular-nums"')
        if self.ylabel:
            self.text(self.pl - 8, self.pt - 12, self.ylabel, "muted", 11, "end")

    def xaxis(self, ticks, fmt=str, grid=False):
        self.parts.append(f'<line x1="{self.pl}" x2="{self.pr}" y1="{self.pb:.1f}" y2="{self.pb:.1f}" stroke="{self.th["axis"]}" stroke-width="1"/>')
        for v in ticks:
            x = self.sx(v)
            if grid:
                self.parts.append(f'<line x1="{x:.1f}" x2="{x:.1f}" y1="{self.pt}" y2="{self.pb}" stroke="{self.th["grid"]}" stroke-width="1"/>')
            self.text(x, self.pb + 18, fmt(v), "muted", 11, "middle")
        if self.xlabel:
            self.text(self.pr, self.pb + 38, self.xlabel, "muted", 11, "end")

    def hline(self, v, label, color="ink2", dash="4 3", label_color="ink2", side="right"):
        y = self.sy(v)
        self.parts.append(f'<line x1="{self.pl}" x2="{self.pr}" y1="{y:.1f}" y2="{y:.1f}" stroke="{self.th[color]}" stroke-width="1" stroke-dasharray="{dash}"/>')
        if side == "right":
            self.text(self.pr + 6, y + 4, label, label_color, 11)
        else:
            self.text(self.pl + 6, y - 6, label, label_color, 11)

    def band(self, xa, xb, label=None, ya=None, yb=None):
        ya = self.y0 if ya is None else ya
        yb = self.y1 if yb is None else yb
        x, y = self.sx(xa), self.sy(yb)
        self.parts.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{self.sx(xb) - x:.1f}" height="{self.sy(ya) - y:.1f}" fill="{self.th["wash"]}"/>')
        if label:
            self.text(x + 6, self.sy(ya) - 8, label, "muted", 11)

    def line(self, pts, color, width=2, opacity=1):
        d = " ".join(f"{'M' if i == 0 else 'L'}{self.sx(x):.1f},{self.sy(y):.1f}" for i, (x, y) in enumerate(pts))
        self.parts.append(f'<path d="{d}" fill="none" stroke="{self.th[color]}" stroke-width="{width}" '
                          f'stroke-linejoin="round" stroke-linecap="round" opacity="{opacity}"/>')

    def dot(self, x, y, color, r=4, ring=True, hollow=False, tip=None, opacity=1):
        cx, cy = self.sx(x), self.sy(y)
        ring_s = f' stroke="{self.th["surface"]}" stroke-width="2"' if ring and not hollow else ""
        fill = "none" if hollow else self.th[color]
        stroke = f' stroke="{self.th[color]}" stroke-width="2"' if hollow else ring_s
        attr = self.tip_attr(*tip) if tip else ""
        cls = ' class="mk"' if attr else ""
        self.parts.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r}" fill="{fill}"{stroke} opacity="{opacity}"{cls}{attr}/>')

    def col(self, xc, v, w, color, tip=None, label=None):
        """柱：4px 圓角資料端、基線方角。"""
        x = xc - w / 2
        y, yb = self.sy(v), self.sy(self.y0)
        h = yb - y
        r = min(4, h)
        d = (f"M{x:.1f},{yb:.1f} L{x:.1f},{y + r:.1f} Q{x:.1f},{y:.1f} {x + r:.1f},{y:.1f} "
             f"L{x + w - r:.1f},{y:.1f} Q{x + w:.1f},{y:.1f} {x + w:.1f},{y + r:.1f} L{x + w:.1f},{yb:.1f} Z")
        attr = self.tip_attr(*tip) if tip else ""
        cls = ' class="mk"' if attr else ""
        self.parts.append(f'<path d="{d}" fill="{self.th[color]}"{cls}{attr}/>')
        if label is not None:
            self.text(xc, y - 6, label, "ink", 11, "middle", 600)

    def legend(self, items):
        """items: [(kind, color, label)] kind ∈ line/dot/rect/dash"""
        self.legend_items = items

    def crosshair_hits(self, xs, rows_fn, title_fn):
        """線圖 hover：每個 X 一條直向命中帶，tooltip 列出該 X 所有序列。"""
        if not self.interactive:
            return
        xs = sorted(xs)
        for i, x in enumerate(xs):
            left = self.pl if i == 0 else (self.sx(xs[i - 1]) + self.sx(x)) / 2
            right = self.pr if i == len(xs) - 1 else (self.sx(x) + self.sx(xs[i + 1])) / 2
            self.hits.append(f'<rect x="{left:.1f}" y="{self.pt}" width="{max(right - left, 1):.1f}" height="{self.pb - self.pt}" '
                             f'fill="transparent" class="hit" data-cx="{self.sx(x):.1f}"{self.tip_attr(title_fn(x), rows_fn(x))}/>')

    def render(self, desc=""):
        th = self.th
        head = []
        if self.show_title:
            head.append(f'<text x="20" y="30" fill="{th["ink"]}" font-size="17" font-weight="650">{esc(self.title)}</text>')
            if self.subtitle:
                head.append(f'<text x="20" y="52" fill="{th["ink2"]}" font-size="12.5">{esc(self.subtitle)}</text>')
        ly = (self.mt - 22) if self.show_title else 18
        lx = self.pl
        for kind, color, label in self.legend_items:
            c = th[color]
            if kind == "line":
                head.append(f'<line x1="{lx}" x2="{lx + 16}" y1="{ly - 4}" y2="{ly - 4}" stroke="{c}" stroke-width="2" stroke-linecap="round"/>')
            elif kind == "dash":
                head.append(f'<line x1="{lx}" x2="{lx + 16}" y1="{ly - 4}" y2="{ly - 4}" stroke="{c}" stroke-width="1" stroke-dasharray="4 3"/>')
            elif kind == "dot":
                head.append(f'<circle cx="{lx + 8}" cy="{ly - 4}" r="4" fill="{c}"/>')
            elif kind == "ring":
                head.append(f'<circle cx="{lx + 8}" cy="{ly - 4}" r="4" fill="none" stroke="{c}" stroke-width="2"/>')
            else:
                head.append(f'<rect x="{lx + 2}" y="{ly - 10}" width="12" height="12" rx="3" fill="{c}"/>')
            head.append(f'<text x="{lx + 22}" y="{ly}" fill="{th["ink2"]}" font-size="12">{esc(label)}</text>')
            lx += 22 + 12.5 * visual_len(label) + 18
        xh = ""
        if self.interactive and self.hits:
            xh = f'<line class="xhair" x1="0" x2="0" y1="{self.pt}" y2="{self.pb}" stroke="{th["ink2"]}" stroke-width="1" visibility="hidden"/>'
        bg = f'<rect width="{self.W}" height="{self.H}" fill="{th["surface"]}" rx="{0 if self.interactive else 10}"/>'
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.W} {self.H}" width="{self.W}" height="{self.H}" '
                f'font-family="{FONT}" role="img" aria-label="{esc(self.title)}">'
                f'<title>{esc(self.title)}</title><desc>{esc(desc or self.subtitle or "")}</desc>'
                f'{bg}{"".join(head)}{"".join(self.parts)}{xh}{"".join(self.hits)}</svg>')


def visual_len(s):
    """粗估字寬（中日韓字 1、其他 0.55）。"""
    return sum(1 if ord(ch) > 0x2e80 else 0.55 for ch in s)


def nice_ticks(lo, hi, n=5):
    span = hi - lo
    step = 10 ** math.floor(math.log10(span / n))
    for m in (1, 2, 2.5, 5, 10):
        if span / (step * m) <= n:
            step *= m
            break
    v = math.ceil(lo / step) * step
    out = []
    while v <= hi + 1e-9:
        out.append(round(v, 6))
        v += step
    return out


# ---------------------------------------------------------------- 各圖
def chart_ab_series(D, th, inter, metric, show_title=True):
    s = D["samples"]
    A = [r for r in s if r["group"] == "A"]
    B = [r for r in s if r["group"] == "B"]
    stA, stB = D["abA"], D["abB"]
    if metric == "temp":
        y0, y1, unit, key = 70, 96, "°C", "temp"
        title = "A/B：控制溫度，B 只多 3.8°C"
        sub = f"同一個 Python 重負載（load 22–42），各 5 分鐘、每 10 秒一筆；丟前 60 秒後 A 均 {stA['temp']:.1f}°C、B 均 {stB['temp']:.1f}°C"
        ticks = [70, 75, 80, 85, 90, 95]
        fmt = lambda v: f"{v:.0f}°"
    else:
        y0, y1, unit, key = 2000, 5000, " rpm", "rpm"
        title = "A/B：風扇轉速，B 少轉 25%"
        sub = f"丟前 60 秒後 A 均 {stA['rpm']:,.0f} rpm、B 均 {stB['rpm']:,.0f} rpm（−{stA['rpm'] - stB['rpm']:,.0f}，推估約 −6.3 dB）"
        ticks = [2000, 3000, 4000, 5000]
        fmt = fmt_int
    p = Plot(th, 760, 380, 0, 300, y0, y1, interactive=inter, title=title, subtitle=sub,
             xlabel="段內秒數（A 05:06:01 起、B 05:11:08 起）", ylabel=unit.strip(), show_title=show_title)
    p.band(0, 60, "過渡 60 秒，不計入平均")
    p.ygrid(ticks, fmt)
    p.xaxis([0, 60, 120, 180, 240, 300], lambda v: f"{v}s")
    for grp, rows, color, stt, name in (("A", A, "s1", stA, "A 強力"), ("B", B, "s2", stB, "B 均衡（現行預設）")):
        p.line([(r["sec"], r[key]) for r in rows], color)
        mean = stt[key]
        p.parts.append(f'<line x1="{p.sx(60):.1f}" x2="{p.pr}" y1="{p.sy(mean):.1f}" y2="{p.sy(mean):.1f}" stroke="{th[color]}" stroke-width="1" opacity=".55"/>')
        p.dot(rows[-1]["sec"], rows[-1][key], color, 4)
        lab = f"{grp} 均 {mean:.1f}°C" if metric == "temp" else f"{grp} 均 {mean:,.0f} rpm"
        p.text(p.pr + 8, p.sy(mean) + 4, lab, "ink", 12, weight=600)
    p.legend([("line", "s1", "A 強力（舊預設）"), ("line", "s2", "B 均衡（現行預設）")])
    byA = {r["sec"] // 10: r for r in A}
    byB = {r["sec"] // 10: r for r in B}
    xs = sorted(set(list(byA) + list(byB)))
    def rows(k):
        out = []
        for g, d in (("A", byA), ("B", byB)):
            if k in d:
                r = d[k]
                out.append([f"{r[key]}{unit}" if metric == "temp" else f"{r[key]:,} rpm", f"{g}（{r['time']}，load {r['load']}）"])
        return out
    # 用 10 秒格子當 X
    p.crosshair_hits([k * 10 for k in xs], lambda x: rows(x // 10), lambda x: f"段內 {x}s")
    return p.render()


def chart_ab_pcore(D, th, inter, show_title=True):
    pm = D["pm"]
    title = "A/B：P-core 硬體時脈都停在 3936 MHz，9/9 Nominal"
    sub = "powermetrics P-Cluster HW active frequency；3936 是 M4 全核功耗上限頻率，不是熱降頻"
    p = Plot(th, 760, 380, -0.6, len(pm) - 0.4, 3200, 4600, interactive=inter, title=title, subtitle=sub,
             ylabel="MHz", show_title=show_title, mr=200)
    p.band(-0.6, len(pm) - 0.4, None, 3300, 3800)
    p.text(p.pl + 8, p.sy(3800) + 16, "原廠 M4 mini 重載 10–15 分鐘後 3300–3800 MHz（外部資料，非同機實測）", "muted", 11)
    p.ygrid([3200, 3600, 4000, 4400], fmt_int)
    p.hline(4464, "單核最高 4464", side="right")
    p.xaxis([], str)
    for i, r in enumerate(pm):
        color = "s1" if r["group"] == "A" else "s2"
        p.dot(i, r["pMHz"], color, 5, tip=(f"{r['group']} 段 {r['time']}",
              [[f"{r['pMHz']:,} MHz", "P-Cluster HW"], [f"{r['cpuW']:.1f} W", "CPU Power"], [r["pressure"], "thermal pressure"]]))
        p.text(p.sx(i), p.pb + 18, r["time"][:5] if i in (0, 3) else "", "muted", 11, "middle")
    nA = sum(1 for r in pm if r["group"] == "A")
    p.text((p.sx(0) + p.sx(nA - 1)) / 2, p.pb + 36, "A 段前（05:00:41–47，3 秒間隔）", "muted", 11, "middle")
    p.text((p.sx(nA) + p.sx(len(pm) - 1)) / 2, p.pb + 36, "B 段後（05:19–05:20，20 秒間隔）", "muted", 11, "middle")
    p.text(p.sx(len(pm) - 1) + 12, p.sy(3943) - 10, "8 筆 3936、1 筆 3950", "ink", 12, weight=600)
    p.legend([("dot", "s1", "A 強力"), ("dot", "s2", "B 均衡")])
    return p.render()


def chart_timeline(D, th, inter, show_title=True):
    ev = D["ev"]
    w = ev["writes"]
    t0 = datetime(2026, 9, 20)
    hrs = lambda t: (t - t0).total_seconds() / 3600
    x1 = math.ceil(hrs(ev["last"]) / 24) * 24
    hot = [x for x in w if x["temp"] >= 90]
    s = D["summary"]
    title = f"近 {s['hours']:.0f} 小時：{len(hot)} 個時刻 ≥90°C，AI 一次都沒被卡"
    sub = f"每一點是 guard 寫 SMC 的時刻（共 {len(w):,} 筆，只在轉速改變時記錄，非等間隔）；hook 等待 0 次、擋下 0 次、降頻 0 秒"
    p = Plot(th, 760, 380, 0, x1, 30, 105, interactive=inter, title=title, subtitle=sub, ylabel="°C",
             show_title=show_title, mr=176)
    p.ygrid([30, 40, 50, 60, 70, 80, 90, 100], lambda v: f"{v:.0f}°")
    p.xaxis(list(range(0, x1 + 1, 24)), lambda h: (t0 + timedelta(hours=h)).strftime("%-m/%-d"), grid=False)
    for h in range(12, x1, 24):
        p.text(p.sx(h), p.pb + 18, "12:00", "muted", 10, "middle")
    for x in w:
        if x["temp"] < 90:
            p.dot(hrs(x["t"]), x["temp"], "dim", 2.2, ring=False, opacity=0.8)
    p.hline(90, "第一版門檻 90°C", "ink2")
    p.hline(100, "擋下 100°C", "crit")
    for x in hot:
        p.dot(hrs(x["t"]), x["temp"], "s2", 3.5, tip=(x["t"].strftime("%m-%d %H:%M:%S"),
              [[f"{x['temp']}°C", "控制溫度"], [f"{x['rpm']:,} rpm", "當下轉速"],
               [f"{x['ghz']:.2f} GHz" if x["ghz"] else "—", "IOReport P-core"], ["放行", "hook 結果（當日等待 0 次）"]]))
    p.legend([("dot", "s2", f"≥90°C 的寫入（{len(hot)} 次）"), ("dot", "dim", f"<90°C（{len(w) - len(hot):,} 次）")])
    return p.render()


def chart_hist(D, th, inter, show_title=True):
    w = D["ev"]["writes"]
    bins = Counter((x["temp"] // 5) * 5 for x in w)
    lo, hi = 35, 100
    mx = max(bins.values())
    med = st.median(x["temp"] for x in w)
    title = f"寫入時溫度多半在 60–75°C，中位 {med:.0f}°C"
    sub = f"{len(w):,} 筆 SMC 寫入的控制溫度，每 5°C 一格；是「寫入時刻」分布，不是時間佔比"
    p = Plot(th, 760, 380, lo, hi, 0, math.ceil(mx / 100) * 100, interactive=inter, title=title, subtitle=sub,
             ylabel="次數", show_title=show_title, mr=40)
    p.ygrid(nice_ticks(0, math.ceil(mx / 100) * 100, 4))
    p.xaxis(list(range(lo, hi + 1, 5)), lambda v: f"{v}°")
    bw = (p.sx(5) - p.sx(0)) - 2
    bw = min(bw, 24 * 1.6)
    for b in range(lo, hi, 5):
        n = bins.get(b, 0)
        if n == 0:
            continue
        p.col(p.sx(b + 2.5), n, bw, "s1" if b < 90 else "s2",
              tip=(f"{b}–{b + 4}°C", [[f"{n:,} 次", "寫入"], [f"{n / len(w) * 100:.1f}%", "佔全部寫入"]]),
              label=fmt_int(n) if (n == mx or b >= 90) else None)
    p.legend([("rect", "s1", "<90°C"), ("rect", "s2", "≥90°C")])
    return p.render()


def chart_scatter(D, th, inter, show_title=True):
    w = [x for x in D["ev"]["writes"] if x["target"] is not None]
    curve = D["curveB"]
    title = "目標轉速沿著曲線 B 走，降溫時慢慢收"
    sub = f"{len(w):,} 次目標轉速（EMA 平滑：升 0.7 / 降 0.2、每輪最多降 300 rpm）；中位 {st.median(x['target'] for x in w):,.0f} rpm，從未到 4900"
    p = Plot(th, 760, 380, 40, 100, 0, 5000, interactive=inter, title=title, subtitle=sub, ylabel="rpm",
             xlabel="控制溫度 °C", show_title=show_title, mr=150)
    p.ygrid([0, 1000, 2000, 3000, 4000, 5000])
    p.xaxis(list(range(40, 101, 10)), lambda v: f"{v}°")
    for x in w:
        p.dot(x["temp"], x["target"], "s1", 2.6, ring=False, opacity=0.45,
              tip=(x["t"].strftime("%m-%d %H:%M:%S"), [[f"{x['target']:,} rpm", "目標"], [f"{x['temp']}°C", "控制溫度"], [f"{x['rpm']:,} rpm", "當下轉速"]]))
    pts = [(40, curve[0][1])] + curve + [(100, curve[-1][1])]
    p.line(pts, "s2", 2)
    for tt, rr in curve:
        p.dot(tt, rr, "s2", 4)
    p.text(p.pr + 8, p.sy(curve[-1][1]) + 4, "曲線 B 97°→4900", "ink", 12, weight=600)
    p.text(p.pr + 8, p.sy(3000) + 4, "預熱 3000 rpm", "muted", 11)
    p.parts.append(f'<line x1="{p.pl}" x2="{p.pr}" y1="{p.sy(3000):.1f}" y2="{p.sy(3000):.1f}" stroke="{th["ink2"]}" stroke-width="1" stroke-dasharray="4 3"/>')
    p.legend([("dot", "s1", "目標轉速（每次寫入）"), ("line", "s2", "設定曲線 B（本機現行）")])
    return p.render()


def chart_daily_max(D, th, inter, show_title=True):
    days = D["daily"]
    title = "每日最高溫 93–94°C，降頻 0 秒、hook 等待 0 次"
    sub = "guard 每日結算（09-23 取 stats.json，至 23:42）；結算用 Int 截斷、log 行四捨五入，所以 log 看得到 95°C"
    p = Plot(th, 760, 380, -0.5, len(days) - 0.5, 0, 110, interactive=inter, title=title, subtitle=sub,
             ylabel="°C", show_title=show_title, mr=150, mb=64)
    p.ygrid([0, 20, 40, 60, 80, 100], lambda v: f"{v:.0f}°")
    p.xaxis([], str)
    p.hline(90, "第一版門檻 90°C")
    p.hline(100, "擋下 100°C", "crit")
    for i, d in enumerate(days):
        p.col(p.sx(i), d["max"], 24, "s1", tip=(d["date"] + ("（至 23:42）" if d.get("partial") else ""),
              [[f"{d['max']:.0f}°C" if isinstance(d['max'], int) else f"{d['max']:.1f}°C", "結算最高"],
               [f"{d['logmax']}°C", "log 行最高"], [f"{d['throttle']} s", "降頻"], [f"{d['waits']} / {d['denies']}", "hook 等待 / 擋下"]]),
              label=None)
        p.text(p.sx(i), p.pb + 18, d["date"][5:].replace("-", "/") + ("（部分）" if d.get("partial") else "") + f" · {d['max']:.0f}°C", "ink", 12, "middle", 600)
        p.text(p.sx(i), p.pb + 36, f"降頻 {d['throttle']}s · 等待 {d['waits']}", "muted", 11, "middle")
    return p.render()


def chart_daily_ctrl(D, th, inter, show_title=True):
    days = D["daily"]
    mx = max(max(d["takeovers"], d["handbacks"], d["boosts"]) for d in days)
    ymax = math.ceil(mx / 50) * 50
    title = "每天交還 macOS 自動 59–137 次：閒下來就放手"
    sub = f"接管＝交還後又寫 SMC；預熱＝偵測到重指令先拉 3000 rpm；09-20 自 01:18 起、09-23 至 23:42；推論接管時間約 {D['summary']['ctrl_pct']:.0f}%"
    p = Plot(th, 760, 380, -0.5, len(days) - 0.5, 0, ymax, interactive=inter, title=title, subtitle=sub,
             ylabel="次數", show_title=show_title, mr=40)
    p.ygrid(nice_ticks(0, ymax, 4))
    p.xaxis([], str)
    keys = (("takeovers", "s1", "接管"), ("handbacks", "s2", "交還自動"), ("boosts", "s3", "重指令預熱"))
    bw = 22
    for i, d in enumerate(days):
        for j, (k, c, name) in enumerate(keys):
            xc = p.sx(i) + (j - 1) * (bw + 2)
            p.col(xc, max(d[k], 0.0001), bw, c, tip=(d["date"], [[f"{d[k]} 次", name]]), label=str(d[k]))
        p.text(p.sx(i), p.pb + 18, d["date"][5:].replace("-", "/"), "ink2", 12, "middle")
    p.legend([("rect", c, n) for _, c, n in keys])
    return p.render()


def chart_curves(D, th, inter, show_title=True):
    A, B = D["curveA"], D["curveB"]
    tk = D["ev"]["takeovers"]
    title = "macOS 自動 vs cool42 曲線：缺同負載穩態對照"
    sub = "線＝cool42 設定曲線；點＝guard 接管前一刻 macOS 自動控制下的實際轉速（非穩態、非同負載）"
    p = Plot(th, 760, 400, 40, 110, 0, 5000, interactive=inter, title=title, subtitle=sub, ylabel="rpm",
             xlabel="控制溫度 °C", show_title=show_title, mr=170, mb=62)
    p.band(100, 110, None)
    p.ygrid([0, 1000, 2000, 3000, 4000, 5000])
    p.xaxis(list(range(40, 111, 10)), lambda v: f"{v}°")
    for x in tk:
        p.dot(x["temp"], x["rpm"], "s3", 3, ring=False, opacity=0.5,
              tip=(x["t"].strftime("%m-%d %H:%M:%S"), [[f"{x['rpm']:,} rpm", "macOS 自動（接管前）"], [f"{x['temp']}°C", "控制溫度"]]))
    for c, color, name in ((A, "s1", "A 強力"), (B, "s2", "B 均衡")):
        p.line(c, color)
        for tt, rr in c:
            p.dot(tt, rr, color, 4)
    p.text(p.sx(A[-1][0]) - 10, p.sy(A[-1][1]) + 4, "A 90°→4900", "ink", 12, "end", 600)
    p.text(p.sx(B[-1][0]) + 8, p.sy(B[-1][1]) + 4, "B 97°→4900", "ink", 12, "start", 600)
    # README 記載：第一次接管前 macOS 自動 105°C / 1774 rpm（原始 log 已不在）
    p.dot(105, 1774, "s3", 6, hollow=True, tip=("README「實測」段", [["1,774 rpm", "macOS 自動"], ["105°C", "第一次接管前"], ["20 秒後 82°C", "cool42 接管後（舊曲線 4618 rpm）"]]))
    p.text(p.sx(105), p.sy(1774) + 22, "105° / 1,774", "ink", 11, "middle", 600)
    p.dot(106, 2100, "muted", 6, hollow=True, tip=("外部資料（MacRumors 等）", [["~2,100 rpm", "原廠重載"], ["105–107°C", "溫度"]]))
    p.text(p.sx(106) - 11, p.sy(2100) + 4, "外部 ~2,100", "muted", 11, "end")
    p.text(p.sx(100) + 6, p.sy(4300), "≥100°C", "muted", 11)
    p.text(p.sx(100) + 6, p.sy(4300) + 15, "擋下區", "muted", 11)
    p.text(p.sx(100) + 6, p.sy(4300) + 30, "近 4 天 0 次", "muted", 11)
    by = p.pt + 90
    p.parts.append(f'<rect x="{p.pr + 12}" y="{by - 10}" width="10" height="10" rx="2" fill="{th["crit"]}"/>')
    p.text(p.pr + 28, by, "待補", "ink", 12, weight=650)
    p.text(p.pr + 12, by + 18, "perf_vs_temp.py", "ink2", 11.5)
    p.text(p.pr + 12, by + 35, "同負載、固定轉速", "muted", 11)
    p.text(p.pr + 12, by + 51, "的穩態對照", "muted", 11)
    p.text(p.pr + 12, by + 67, "（需 sudo＋空機）", "muted", 11)
    med = st.median(x["rpm"] for x in tk)
    p.text(p.sx(56), p.sy(med) + 22, f"macOS 自動中位 {med:,.0f} rpm（n={len(tk)}）", "ink", 11, "start", 600)
    p.legend([("line", "s1", "A 強力"), ("line", "s2", "B 均衡"), ("dot", "s3", "macOS 自動（接管前一刻）"), ("ring", "muted", "外部資料")])
    return p.render()


CHARTS = [
    # id, 函式, 標題（HTML 用）, 群組
    ("hook-timeline", chart_timeline, "AI 從沒被卡：≥90°C 31 次、hook 等待 0", "主打"),
    ("ab-temp", lambda D, th, i, st_=True: chart_ab_series(D, th, i, "temp", st_), "A/B 溫度", "A/B 實測"),
    ("ab-rpm", lambda D, th, i, st_=True: chart_ab_series(D, th, i, "rpm", st_), "A/B 轉速", "A/B 實測"),
    ("ab-pcore", chart_ab_pcore, "A/B P-core 時脈", "A/B 實測"),
    ("daily-max", chart_daily_max, "每日最高溫與降頻", "近 4 天 log"),
    ("daily-control", chart_daily_ctrl, "每日接管 / 交還 / 預熱", "近 4 天 log"),
    ("temp-hist", chart_hist, "寫入時溫度分布", "近 4 天 log"),
    ("rpm-vs-temp", chart_scatter, "目標轉速 vs 溫度", "近 4 天 log"),
    ("curve-vs-macos", chart_curves, "macOS 自動 vs cool42 曲線", "對照（待補）"),
]


# ---------------------------------------------------------------- 匯總
def summarize(D):
    s = D["samples"]
    for g in "AB":
        rows = [r for r in s if r["group"] == g][6:]
        D["ab" + g] = dict(temp=st.mean(r["temp"] for r in rows), rpm=st.mean(r["rpm"] for r in rows),
                           tmin=min(r["temp"] for r in rows), tmax=max(r["temp"] for r in rows),
                           rmin=min(r["rpm"] for r in rows), rmax=max(r["rpm"] for r in rows),
                           lmin=min(r["load"] for r in s if r["group"] == g), lmax=max(r["load"] for r in s if r["group"] == g), n=len(rows))
    ev = D["ev"]
    w = ev["writes"]
    hours = (ev["last"] - ev["first"]).total_seconds() / 3600
    # 接管時間估算：接管寫入 → 下一次交還
    ctrl = 0.0
    on = None
    for x in w:
        if x["target"] is not None and on is None:
            on = x["t"]
        elif x["target"] is None and on is not None:
            ctrl += (x["t"] - on).total_seconds()
            on = None
    if on is not None:
        ctrl += (ev["last"] - on).total_seconds()
    settle = {d["date"]: d for d in ev["settle"]}
    days = []
    for day in sorted({x["t"].strftime("%Y-%m-%d") for x in w}):
        dw = [x for x in w if x["t"].strftime("%Y-%m-%d") == day]
        row = dict(date=day, logmax=max(x["temp"] for x in dw),
                   takeovers=sum(1 for x in ev["takeovers"] if x["t"].strftime("%Y-%m-%d") == day),
                   handbacks=sum(1 for x in ev["handbacks"] if x["t"].strftime("%Y-%m-%d") == day),
                   boosts=sum(1 for t, _ in ev["boosts"] if t.strftime("%Y-%m-%d") == day))
        if day in settle:
            sd = settle[day]
            row.update(max=sd["max"], throttle=sd["throttle"], waits=sd["waits"], denies=sd["denies"], hot=sd["hot"], critical=sd["critical"])
        elif D["stats"].get("date") == day:
            sj = D["stats"]
            row.update(max=round(sj["maxTemp"], 1), throttle=int(sj["throttleSeconds"]), waits=sj["hookWaits"],
                       denies=sj["hookDenies"], hot=int(sj["hotSeconds"]), critical=int(sj["criticalSeconds"]), partial=True)
        else:
            row.update(max=row["logmax"], throttle=None, waits=None, denies=None, partial=True)
        days.append(row)
    D["daily"] = days
    tg = [x["target"] for x in w if x["target"] is not None]
    D["summary"] = dict(
        log_first=ev["first"].strftime("%Y-%m-%d %H:%M:%S"), log_last=ev["last"].strftime("%Y-%m-%d %H:%M:%S"),
        hours=hours, writes=len(w), targets=len(tg), handbacks=len(ev["handbacks"]), takeovers=len(ev["takeovers"]),
        boosts=len(ev["boosts"]), boost_cmds=Counter(c for _, c in ev["boosts"]).most_common(), early=len(ev["early"]),
        ge90=sum(1 for x in w if x["temp"] >= 90), ge100=sum(1 for x in w if x["temp"] >= 100),
        max_log=max(x["temp"] for x in w), temp_med=st.median(x["temp"] for x in w), temp_mean=st.mean(x["temp"] for x in w),
        target_med=st.median(tg), target_mean=st.mean(tg), target_max=max(tg), target_ge3000=sum(1 for v in tg if v >= 3000),
        level_changes=len(ev["levels"]), ctrl_hours=ctrl / 3600, ctrl_pct=ctrl / 3600 / hours * 100,
        macos_rpm_med=st.median(x["rpm"] for x in ev["takeovers"]), macos_rpm_max=max(x["rpm"] for x in ev["takeovers"]),
        waits=sum(d["waits"] or 0 for d in days), denies=sum(d["denies"] or 0 for d in days), throttle=sum(d["throttle"] or 0 for d in days),
        pm_p=[r["pMHz"] for r in D["pm"]], pm_pressure=Counter(r["pressure"] for r in D["pm"]),
        A=D["abA"], B=D["abB"],
    )


# ---------------------------------------------------------------- 表格（HTML 表格檢視）
def tables(D):
    s = D["summary"]
    T = {}
    T["hook-timeline"] = (["時間", "控制溫度", "當下轉速", "IOReport GHz"],
                          [[x["t"].strftime("%m-%d %H:%M:%S"), f"{x['temp']}°C", f"{x['rpm']:,}", f"{x['ghz']:.2f}" if x["ghz"] else "—"]
                           for x in D["ev"]["writes"] if x["temp"] >= 90])
    for m, k in (("ab-temp", "temp"), ("ab-rpm", "rpm")):
        T[m] = (["組", "時間", "段內秒", "load", "溫度 °C", "轉速 rpm"],
                [[r["group"], r["time"], r["sec"], r["load"], r["temp"], f"{r['rpm']:,}"] for r in D["samples"]])
    T["ab-pcore"] = (["組", "時間", "P-Cluster MHz", "E-Cluster MHz", "CPU W", "pressure"],
                     [[r["group"], r["time"], f"{r['pMHz']:,}", f"{r['eMHz']:,}", f"{r['cpuW']:.1f}", r["pressure"]] for r in D["pm"]])
    T["daily-max"] = (["日期", "結算最高", "log 行最高", "降頻 s", "hook 等待", "擋下", "critical s"],
                      [[d["date"] + ("（部分）" if d.get("partial") else ""), d["max"], d["logmax"], d["throttle"], d["waits"], d["denies"], d.get("critical")] for d in D["daily"]])
    T["daily-control"] = (["日期", "接管", "交還自動", "預熱"], [[d["date"], d["takeovers"], d["handbacks"], d["boosts"]] for d in D["daily"]])
    bins = Counter((x["temp"] // 5) * 5 for x in D["ev"]["writes"])
    T["temp-hist"] = (["溫度區間", "寫入次數", "佔比"], [[f"{b}–{b + 4}°C", bins[b], f"{bins[b] / s['writes'] * 100:.1f}%"] for b in sorted(bins)])
    tg = defaultdict(list)
    for x in D["ev"]["writes"]:
        if x["target"] is not None:
            tg[(x["temp"] // 5) * 5].append(x["target"])
    T["rpm-vs-temp"] = (["溫度區間", "次數", "目標中位 rpm", "目標最高 rpm", "曲線 B 對應 rpm"],
                        [[f"{b}–{b + 4}°C", len(v), f"{st.median(v):,.0f}", f"{max(v):,}", f"{interp(D['curveB'], b + 2.5):,.0f}"] for b, v in sorted(tg.items())])
    T["curve-vs-macos"] = (["來源", "溫度", "轉速", "說明"],
                           [["曲線 A", "→".join(str(t) for t, _ in D["curveA"]), "→".join(str(r) for _, r in D["curveA"]), "config-A.json"],
                            ["曲線 B", "→".join(str(t) for t, _ in D["curveB"]), "→".join(str(r) for _, r in D["curveB"]), "config-B.json（現行預設）"],
                            ["macOS 自動（接管前一刻）", f"n={s['takeovers']}", f"中位 {s['macos_rpm_med']:,.0f}、最高 {s['macos_rpm_max']:,}", "cool42.log 接管那一行的 🌀 值"],
                            ["README 第一次接管", "105°C", "1,774", "原始 log 已不在，照文件引用"],
                            ["外部資料", "105–107°C", "~2,100", "MacRumors / theenterprisemac"],
                            ["待補", "—", "—", "perf_vs_temp.py：同負載、固定轉速的穩態溫度／時脈／ops/J"]])
    return T


def interp(curve, t):
    if t <= curve[0][0]:
        return curve[0][1]
    for (t0, r0), (t1, r1) in zip(curve, curve[1:]):
        if t <= t1:
            return r0 + (r1 - r0) * (t - t0) / (t1 - t0)
    return curve[-1][1]


def conclusions(D):
    s = D["summary"]
    A, B = s["A"], s["B"]
    return {
        "hook-timeline": f"{s['hours']:.1f} 小時內控制溫度 ≥90°C 的寫入 {s['ge90']} 次（最高 {s['max_log']}°C、≥100°C {s['ge100']} 次），hook 等待 {s['waits']} 次、擋下 {s['denies']} 次、降頻 {s['throttle']} 秒。推論：若用第一版「90°C 就等」，這 {s['ge90']} 個時刻都會卡住 AI。",
        "ab-temp": f"丟前 60 秒後 A 均 {A['temp']:.1f}°C（{A['tmin']}–{A['tmax']}）→ B 均 {B['temp']:.1f}°C（{B['tmin']}–{B['tmax']}），只多 {B['temp'] - A['temp']:.1f}°C。",
        "ab-rpm": f"A 均 {A['rpm']:,.0f} rpm → B 均 {B['rpm']:,.0f} rpm，少轉 {A['rpm'] - B['rpm']:,.0f}（−{(1 - B['rpm'] / A['rpm']) * 100:.0f}%），風扇定律推估約 −{50 * math.log10(A['rpm'] / B['rpm']):.1f} dB（推論值，非實測）。",
        "ab-pcore": f"9 筆 powermetrics 中 8 筆 3936 MHz、1 筆 3950，pressure {s['pm_pressure'].get('Nominal', 0)}/9 Nominal；但取樣時間在 A/B 視窗前後（05:00、05:19–05:20），是鄰近時段證據，不是同一時刻。",
        "daily-max": "每日結算最高 " + "、".join(f"{d['date'][5:]} {d['max']:.0f}°C" for d in D["daily"]) + f"；4 天降頻合計 {s['throttle']} 秒，hook 等待 {s['waits']} 次。",
        "daily-control": "交還 macOS 自動 " + "、".join(f"{d['date'][5:]} {d['handbacks']}" for d in D["daily"]) + f" 次（共 {s['handbacks']}）；接管 {s['takeovers']} 次、預熱 {s['boosts']} 次（{s['early']} 次提早結束）。推論接管時間約 {s['ctrl_hours']:.1f}/{s['hours']:.1f} 小時（{s['ctrl_pct']:.0f}%，未扣睡眠）。",
        "temp-hist": f"{s['writes']:,} 筆寫入的溫度中位 {s['temp_med']:.0f}°C、平均 {s['temp_mean']:.1f}°C；≥90°C 只有 {s['ge90']} 筆（{s['ge90'] / s['writes'] * 100:.1f}%）。這是寫入時刻分布，不是時間佔比。",
        "rpm-vs-temp": f"{s['targets']:,} 次目標轉速中位 {s['target_med']:,.0f} rpm、平均 {s['target_mean']:,.0f}、最高 {s['target_max']:,}（≥3000 共 {s['target_ge3000']} 次），從未到 4900。推論：曲線下方的點是升溫時 EMA 還在追、上方的點是降溫時每輪最多降 300 rpm 與預熱 3000 rpm。",
        "curve-vs-macos": f"macOS 自動在接管前一刻的轉速中位 {s['macos_rpm_med']:,.0f} rpm（n={s['takeovers']}），README 記載 105°C 時只有 1,774 rpm；cool42 曲線 B 在 85°C 就給 2,600。缺同負載穩態對照，待 perf_vs_temp.py 補。",
    }


# ---------------------------------------------------------------- HTML
HTML_CSS = """
:root{color-scheme:light;--surface:#fcfcfb;--page:#f9f9f7;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;--wash:#f0efec;--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--crit:#d03b3b;--dim:#c3c2b7;--border:rgba(11,11,11,.10);--good:#006300}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;--surface:#1a1a19;--page:#0d0d0d;--ink:#fff;--ink2:#c3c2b7;--muted:#898781;--grid:#2c2c2a;--axis:#383835;--wash:#2c2c2a;--s1:#3987e5;--s2:#d95926;--s3:#199e70;--dim:#52514e;--border:rgba(255,255,255,.10);--good:#0ca30c}}
:root[data-theme="dark"]{color-scheme:dark;--surface:#1a1a19;--page:#0d0d0d;--ink:#fff;--ink2:#c3c2b7;--muted:#898781;--grid:#2c2c2a;--axis:#383835;--wash:#2c2c2a;--s1:#3987e5;--s2:#d95926;--s3:#199e70;--dim:#52514e;--border:rgba(255,255,255,.10);--good:#0ca30c}
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--ink);font:15px/1.6 system-ui,-apple-system,"PingFang TC","Noto Sans TC","Segoe UI",sans-serif}
main{max-width:1000px;margin:0 auto;padding:28px 16px 64px}
header h1{font-size:26px;margin:0 0 4px;letter-spacing:-.01em}
header p{margin:0;color:var(--ink2)}
.brand{font-size:12px;color:var(--muted);letter-spacing:.04em;margin-bottom:6px}
.tiles{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:12px;margin:22px 0 8px}
@media (max-width:860px){.tiles{grid-template-columns:repeat(2,minmax(0,1fr))}}
.tile{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:14px 16px}
.tile .lab{font-size:12.5px;color:var(--ink2)}
.tile .val{font-size:26px;font-weight:650;margin-top:2px;white-space:nowrap}
.tile .sub{font-size:12px;color:var(--muted)}
.tile.hero{grid-column:span 2}
.tile.hero .val{font-size:48px;line-height:1.1}
@media (max-width:860px){.tile.hero .val{font-size:40px}}
.bar select{font:inherit;font-size:13px;border:1px solid var(--border);background:var(--surface);color:var(--ink2);border-radius:999px;padding:5px 10px;max-width:100%}
.bar{position:sticky;top:0;z-index:5;background:var(--page);padding:10px 0;display:flex;flex-wrap:wrap;gap:6px;align-items:center;border-bottom:1px solid var(--border);margin:18px 0 8px}
.bar button{font:inherit;font-size:13px;border:1px solid var(--border);background:var(--surface);color:var(--ink2);border-radius:999px;padding:5px 12px;cursor:pointer}
.bar button[aria-pressed="true"]{background:var(--ink);color:var(--page);border-color:var(--ink)}
.bar .sp{flex:1}
.fig{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:18px 18px 12px;margin:16px 0}
.fig[hidden]{display:none}
.fig .grp{font-size:12px;color:var(--muted)}
.fig h2{font-size:18px;margin:2px 0 4px}
.fig .con{margin:0 0 10px;color:var(--ink)}
.fig .svgw{width:100%;overflow-x:auto;-webkit-overflow-scrolling:touch}
@media (max-width:600px){.fig svg{min-width:600px}.bar{position:static}.fig{padding:14px 12px 10px}}
.fig svg{width:100%;height:auto;display:block}
.fig .src{font-size:12px;color:var(--muted);margin:8px 0 0}
.fig details{margin-top:8px;font-size:13px}
.fig summary{cursor:pointer;color:var(--ink2)}
.tw{max-height:320px;overflow:auto;margin-top:6px;border:1px solid var(--border);border-radius:8px}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
th,td{padding:5px 10px;text-align:left;border-bottom:1px solid var(--grid);white-space:nowrap}
th{position:sticky;top:0;background:var(--surface);color:var(--ink2);font-weight:600}
.todo{display:inline-block;font-size:12px;font-weight:650;color:var(--crit);border:1px solid var(--crit);border-radius:6px;padding:1px 7px;margin-left:6px;vertical-align:2px}
.gap{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:16px 20px;margin:24px 0}
.gap h2{font-size:17px;margin:0 0 6px}
.gap li{margin:4px 0;color:var(--ink2)}
.mk{cursor:pointer}.mk:hover,.mk:focus{opacity:1!important;filter:brightness(1.15);outline:none}
.hit{cursor:crosshair}.hit:focus{outline:none}
#tt{position:fixed;pointer-events:none;z-index:20;background:var(--surface);color:var(--ink);border:1px solid var(--border);border-radius:10px;padding:8px 11px;font-size:12.5px;box-shadow:0 6px 24px rgba(0,0,0,.18);min-width:140px;display:none}
#tt .t{color:var(--muted);font-size:11.5px;margin-bottom:3px}
#tt .r{display:flex;gap:8px;align-items:baseline}
#tt .r b{font-weight:650}
#tt .r span{color:var(--ink2)}
footer{color:var(--muted);font-size:12.5px;margin-top:28px}
code{font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--wash);padding:1px 5px;border-radius:5px}
"""

HTML_JS = r"""
(function(){
  var tt=document.getElementById('tt');
  function show(el,ev){
    var rows; try{rows=JSON.parse(el.getAttribute('data-tip'))}catch(e){return}
    tt.textContent='';
    var t=document.createElement('div');t.className='t';t.textContent=el.getAttribute('data-tt')||'';tt.appendChild(t);
    rows.forEach(function(r){var d=document.createElement('div');d.className='r';var b=document.createElement('b');b.textContent=r[0];var s=document.createElement('span');s.textContent=r[1];d.appendChild(b);d.appendChild(s);tt.appendChild(d)});
    tt.style.display='block';
    var x,y;
    if(ev&&ev.clientX!=null){x=ev.clientX;y=ev.clientY}else{var bb=el.getBoundingClientRect();x=bb.left+bb.width/2;y=bb.top}
    var w=tt.offsetWidth,h=tt.offsetHeight;
    var L=x+14; if(L+w>innerWidth-8) L=x-w-14; if(L<8)L=8;
    var T=y-h-12; if(T<8) T=y+16;
    tt.style.left=L+'px';tt.style.top=T+'px';
    var svg=el.ownerSVGElement, xh=svg&&svg.querySelector('.xhair');
    if(xh){ if(el.hasAttribute('data-cx')){xh.setAttribute('x1',el.getAttribute('data-cx'));xh.setAttribute('x2',el.getAttribute('data-cx'));xh.setAttribute('visibility','visible')} else xh.setAttribute('visibility','hidden')}
  }
  function hide(el){tt.style.display='none';var svg=el&&el.ownerSVGElement,xh=svg&&svg.querySelector('.xhair');if(xh)xh.setAttribute('visibility','hidden')}
  document.addEventListener('pointermove',function(e){var el=e.target.closest&&e.target.closest('[data-tip]');if(el)show(el,e);else if(tt.style.display==='block')hide(document.querySelector('.xhair'))});
  document.addEventListener('focusin',function(e){if(e.target.hasAttribute&&e.target.hasAttribute('data-tip'))show(e.target)});
  document.addEventListener('focusout',function(e){hide(e.target)});
  // 切換圖
  var btns=[].slice.call(document.querySelectorAll('.bar button[data-f]'));
  var one=document.getElementById('one');
  function pick(f){btns.forEach(function(b){b.setAttribute('aria-pressed',b.dataset.f===f)});
    one.value=btns.some(function(b){return b.dataset.f===f})?'':f;
    document.querySelectorAll('.fig').forEach(function(s){s.hidden=!(f==='all'||s.dataset.id===f||s.dataset.g===f)});
    try{localStorage.setItem('cool42viz',f)}catch(e){}}
  btns.forEach(function(b){b.addEventListener('click',function(){pick(b.dataset.f)})});
  var saved='all';try{saved=localStorage.getItem('cool42viz')||'all'}catch(e){}
  one.addEventListener('change',function(){pick(one.value||'all')});
  if(!btns.some(function(b){return b.dataset.f===saved})&&![].some.call(document.querySelectorAll('.fig'),function(x){return x.dataset.id===saved}))saved='all';
  pick(saved);
  // 亮暗
  var tb=document.getElementById('theme');
  tb.addEventListener('click',function(){var r=document.documentElement;var dark=r.dataset.theme?r.dataset.theme==='dark':matchMedia('(prefers-color-scheme: dark)').matches;r.dataset.theme=dark?'light':'dark';tb.textContent=dark?'暗色':'亮色'});
})();
"""

SOURCES = {
    "hook-timeline": "extras/viz/data/cool42-log-20260920_20260923.txt（/var/log/cool42.log 快照）＋每日結算＋stats.json",
    "ab-temp": "docs/ab-test-2026-09-16/samples.txt、timeline.txt",
    "ab-rpm": "docs/ab-test-2026-09-16/samples.txt、timeline.txt",
    "ab-pcore": "docs/ab-test-2026-09-16/powermetrics-A.txt、powermetrics-B.txt；原廠區間引自同目錄 README（外部資料）",
    "daily-max": "cool42.log「今日統計結算」3 行＋extras/viz/data/stats-2026-09-23.json",
    "daily-control": "cool42.log「交還自動」「目標」「預熱」行",
    "temp-hist": "cool42.log 寫入行",
    "rpm-vs-temp": "cool42.log 寫入行＋docs/ab-test-2026-09-16/config-B.json",
    "curve-vs-macos": "config-A/B.json、cool42.log 接管行、README「實測」段、外部資料",
}


def build_html(D):
    s = D["summary"]
    T = tables(D)
    C = conclusions(D)
    groups = []
    for _, _, _, g in CHARTS:
        if g not in groups:
            groups.append(g)
    figs = []
    for cid, fn, name, g in CHARTS:
        svg = fn(D, CSS_THEME, True, False)
        head, rows = T[cid]
        tbl = "<table><thead><tr>" + "".join(f"<th>{esc(h)}</th>" for h in head) + "</tr></thead><tbody>" + \
              "".join("<tr>" + "".join(f"<td>{esc('—' if c is None else c)}</td>" for c in r) + "</tr>" for r in rows) + "</tbody></table>"
        todo = '<span class="todo">待補：perf_vs_temp.py</span>' if cid == "curve-vs-macos" else ""
        figs.append(f'<section class="fig" data-id="{cid}" data-g="{esc(g)}"><div class="grp">{esc(g)}</div>'
                    f'<h2>{esc(name)}{todo}</h2><p class="con">{esc(C[cid])}</p><div class="svgw">{svg}</div>'
                    f'<p class="src">來源：{esc(SOURCES[cid])} · 靜態圖：docs/img/charts/{cid}-light.svg / -dark.svg</p>'
                    f'<details><summary>表格檢視（{len(rows):,} 列）</summary><div class="tw">{tbl}</div></details></section>')
    A, B = s["A"], s["B"]
    tiles = f"""
<div class="tiles">
  <div class="tile hero"><div class="lab">≥90°C 的時刻 → hook 等待</div><div class="val">{s['ge90']} → {s['waits']}</div><div class="sub">近 {s['hours']:.1f} 小時；擋下 {s['denies']} 次、降頻 {s['throttle']} 秒（只看 thermal pressure，不看溫度）</div></div>
  <div class="tile"><div class="lab">A/B 風扇轉速</div><div class="val">−{(1 - B['rpm'] / A['rpm']) * 100:.0f}%</div><div class="sub">{A['rpm']:,.0f} → {B['rpm']:,.0f} rpm</div></div>
  <div class="tile"><div class="lab">A/B 控制溫度</div><div class="val">+{B['temp'] - A['temp']:.1f}°C</div><div class="sub">{A['temp']:.1f} → {B['temp']:.1f}°C</div></div>
  <div class="tile"><div class="lab">P-core 硬體時脈</div><div class="val">3936</div><div class="sub">MHz · 9/9 Nominal（鄰近時段）</div></div>
  <div class="tile"><div class="lab">交還 macOS 自動</div><div class="val">{s['handbacks']} 次</div><div class="sub">推論接管約 {s['ctrl_pct']:.0f}% 時間</div></div>
</div>"""
    btns = ['<button data-f="all" aria-pressed="true">全部</button>'] + \
           [f'<button data-f="{esc(g)}">{esc(g)}</button>' for g in groups] + \
           ['<select id="one" aria-label="只看一張圖"><option value="">只看一張…</option>' +
            "".join(f'<option value="{cid}">{esc(name)}</option>' for cid, _, name, _ in CHARTS) + '</select>']
    gaps = """
<section class="gap"><h2>缺的數據（不補就不能宣稱）</h2><ul>
<li><b>macOS 預設 vs cool42 同負載穩態</b>：A/B 只有兩條 cool42 曲線，沒有「原廠自動」組。原廠 105–107°C / ~2,100 rpm / P-core 3300–3800 MHz 是外部網路資料。<span class="todo">待補：perf_vs_temp.py</span>（需 sudo＋空機）。</li>
<li><b>同一時段的時脈</b>：powermetrics 9 筆都在 A/B 5 分鐘視窗外（A 在 05:00:41–47、B 在 05:19–05:20）。</li>
<li><b>同一工作總耗時</b>：沒量過，不能宣稱「快 X%」。</li>
<li><b>真的降頻 → hook 等待 → 恢復放行</b>：近 4 天 0 次，沒有實例可展示主打功能的「等」那一段；需受控重現。</li>
<li><b>A/B 期間的降頻秒數</b>：當時 guard 尚未記錄 throttleSeconds，以 pressure 9/9 Nominal 代替。</li>
<li><b>等間隔溫度時間序列</b>：log 只在寫 SMC 時記錄；history.json 只留 5 分鐘。分布圖不能當時間佔比。</li>
<li>n=1 台 Mac mini M4；09-20 之前的 log 已不在，README／CHANGELOG 的歷史數字只能照文件引用。</li>
</ul></section>"""
    return f"""<!doctype html>
<html lang="zh-Hant-TW"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>cool42 數據比對</title><meta name="description" content="okle42 cool42：A/B 實測與近 4 天 guard log 的真實數據圖">
<style>{HTML_CSS}</style></head>
<body><main>
<header><div class="brand">okle42 · cool42</div><h1>cool42 數據比對</h1>
<p>AI 寫程式時自己看溫度排隊，只在真的降頻才等。以下全部是本機真實數據：A/B 實測（2026-09-16）＋ guard log {esc(s['log_first'])} → {esc(s['log_last'])}。</p></header>
{tiles}
<nav class="bar" aria-label="切換圖">{''.join(btns)}<span class="sp"></span><button id="theme" type="button">切換亮暗</button></nav>
{''.join(figs)}
{gaps}
<footer>產生器：<code>python3 extras/viz/build_charts.py</code>（標準庫、自產 SVG）。色盤經 dataviz validate_palette.js 驗證（亮／暗 all-pairs PASS）；亮色 aqua 對比不足 3:1，已以直接標籤與表格補足。推論值皆有標明。</footer>
</main><div id="tt" role="tooltip"></div>
<script>{HTML_JS}</script></body></html>"""


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", action="store_true", help="改讀 /var/log/cool42.log 與 /var/db/cool42/stats.json")
    ap.add_argument("--no-desktop", action="store_true")
    a = ap.parse_args()
    log_path = "/var/log/cool42.log" if a.live else FROZEN_LOG
    stats_path = "/var/db/cool42/stats.json" if a.live else FROZEN_STATS
    D = dict(samples=load_samples(),
             pm=load_powermetrics(os.path.join(AB, "powermetrics-A.txt"), "A") + load_powermetrics(os.path.join(AB, "powermetrics-B.txt"), "B"),
             curveA=load_curve(os.path.join(AB, "config-A.json")), curveB=load_curve(os.path.join(AB, "config-B.json")),
             ev=load_log(log_path), stats=json.load(open(stats_path, encoding="utf-8")))
    summarize(D)
    os.makedirs(OUT_IMG, exist_ok=True)
    os.makedirs(os.path.dirname(OUT_HTML), exist_ok=True)
    for cid, fn, _, _ in CHARTS:
        for mode in ("light", "dark"):
            with open(os.path.join(OUT_IMG, f"{cid}-{mode}.svg"), "w", encoding="utf-8") as f:
                f.write(fn(D, THEMES[mode], False, True))
    page = build_html(D)
    with open(OUT_HTML, "w", encoding="utf-8") as f:
        f.write(page)
    if not a.no_desktop:
        shutil.copyfile(OUT_HTML, DESKTOP)
    s = dict(D["summary"])
    s["pm_pressure"] = dict(s["pm_pressure"])
    print(json.dumps(s, ensure_ascii=False, indent=1, default=str))
    for cid, text in conclusions(D).items():
        print(f"- {cid}: {text}")


if __name__ == "__main__":
    main()
