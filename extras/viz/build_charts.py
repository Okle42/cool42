#!/usr/bin/env python3
"""cool42 數據比對圖：只用 python3 標準庫、自己產 SVG。

資料來源（全部是真實數據，不捏造）：
  * docs/ab-test-2026-09-16/        A/B 實測（samples.txt、powermetrics-A/B.txt、config-A/B.json）
  * extras/viz/data/cool42-log-*.txt  /var/log/cool42.log 凍結快照（2026-09-20 01:18:34 → 2026-09-23 23:42:28）
  * extras/viz/data/stats-*.json      /var/db/cool42/stats.json 當日快照
  加 --live 改讀 /var/log/cool42.log 與 /var/db/cool42/stats.json（數字會跟著變）。

輸出：
  * docs/img/charts/<name>-light.svg、<name>-dark.svg   README 用（<picture> 切換亮暗）
  * docs/img/charts/<name>-en-light.svg、<name>-en-dark.svg   英文版（README.en.md 用），9 張都有
  * docs/viz/index.html                                 互動比對頁（單檔、內嵌 SVG＋數據、hover 看值）
  * 另外複製到 ~/Desktop/cool42-數據比對.html（--no-desktop 可略過）

用法：python3 extras/viz/build_charts.py [--live] [--lang zh|en|both] [--no-desktop]
  --lang 預設 both：中文 <name>-light/-dark.svg 與英文 <name>-en-light/-dark.svg 各 9 張（同一份數據）；
  互動頁一律內含中英兩版，右上「中文 / English」切換，也可用 index.html?lang=en 直接開英文。
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
LANG = "zh"   # main() 產英文版（*-en-*.svg）時切成 "en"


def L(zh, en):
    return en if LANG == "en" else zh


def hot_segments(writes, gap=300):
    """≥90°C 的寫入依時間分段：間隔超過 gap 秒算新的一段（高溫「事件」數，不是寫入筆數）"""
    hot = sorted((x for x in writes if x["temp"] >= 90), key=lambda x: x["t"])
    segs = []
    for x in hot:
        if segs and (x["t"] - segs[-1][-1]["t"]).total_seconds() <= gap:
            segs[-1].append(x)
        else:
            segs.append([x])
    return segs


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
        # 副標太長（英文版常見）就折成兩行（左起 x=20、右留 ≥2px），上邊界與總高各加 16px，繪圖區高度不變
        self.sub_lines = wrap_line(subtitle, W - 22, 12.5) if (show_title and subtitle) else []
        if len(self.sub_lines) > 1:
            self.mt += 16
            self.H += 16

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
            for k, line in enumerate(self.sub_lines):
                head.append(f'<text x="20" y="{52 + 16 * k}" fill="{th["ink2"]}" font-size="12.5">{esc(line)}</text>')
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
            # 中文版沿用原本估法（圖不變）；英文字較窄，用 12px × 0.5em 估，免得圖例間距過大
            lx += 22 + (12.5 * visual_len(label) if LANG == "zh" else 12 * text_em(label)) + 18
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


def text_em(s):
    """折行用的字寬估計（em）：中日韓字 0.97、其他 0.5（system-ui 12.5px 實測：中文約 0.96、英文 0.46–0.49，寧可高估）。"""
    return sum(0.97 if ord(ch) > 0x2e80 else 0.5 for ch in s)


def wrap_line(s, max_px, size):
    """放得下就一行；放不下就切成兩行。切點優先「; 」「；」「. 」「。」，其次「, 」「，」「、」，最後空白；
    同一級裡取兩行都放得下、第一行佔全長 40–75% 的切點（標點取最後一個、空白取最平均的），避免一行只剩幾個字。"""
    fits = lambda a: text_em(a) * size <= max_px
    if fits(s):
        return [s]
    total = text_em(s)
    for seps in (("; ", "；", ". ", "。"), (", ", "，", "、"), (" ",)):
        cut = sorted(i + len(sp) for sp in seps for i in range(len(s)) if s.startswith(sp, i))
        ok = [i for i in cut if fits(s[:i].rstrip()) and fits(s[i:]) and 0.4 * total <= text_em(s[:i]) <= 0.75 * total]
        if ok:
            i = max(ok) if seps != (" ",) else min(ok, key=lambda k: abs(text_em(s[:k]) - total / 2))
            return [s[:i].rstrip(), s[i:].lstrip()]
    return [s]


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
        title = L("A/B：控制溫度，B 只多 3.8°C", "A/B: control temperature, B only 3.8 °C warmer")
        sub = L(f"同一個 Python 重負載（load 22–42），各 5 分鐘、每 10 秒一筆；丟前 60 秒後 A 均 {stA['temp']:.1f}°C、B 均 {stB['temp']:.1f}°C",
                f"Same Python load (load 22–42), 5 min each, one sample per 10 s; after dropping the first 60 s A {stA['temp']:.1f} °C, B {stB['temp']:.1f} °C")
        ticks = [70, 75, 80, 85, 90, 95]
        fmt = lambda v: f"{v:.0f}°"
    else:
        y0, y1, unit, key = 2000, 5000, " rpm", "rpm"
        title = L("A/B：風扇轉速，B 少轉 25%", "A/B: fan speed, B spins 25% slower")
        sub = L(f"丟前 60 秒後 A 均 {stA['rpm']:,.0f} rpm、B 均 {stB['rpm']:,.0f} rpm（−{stA['rpm'] - stB['rpm']:,.0f}，推估約 −6.3 dB）；Y 軸從 2,000 起，不從 0",
                f"After dropping the first 60 s: A {stA['rpm']:,.0f} rpm, B {stB['rpm']:,.0f} rpm (−{stA['rpm'] - stB['rpm']:,.0f}, ≈ −6.3 dB by fan law); Y axis starts at 2,000, not 0")
        ticks = [2000, 3000, 4000, 5000]
        fmt = fmt_int
    p = Plot(th, 760, 380, 0, 300, y0, y1, interactive=inter, title=title, subtitle=sub,
             xlabel=L("段內秒數（A 05:06:01 起、B 05:11:08 起）", "seconds into run (A from 05:06:01, B from 05:11:08)"), ylabel=unit.strip(), show_title=show_title)
    p.band(0, 60, L("過渡 60 秒，不計入平均", "first 60 s dropped"))
    p.ygrid(ticks, fmt)
    p.xaxis([0, 60, 120, 180, 240, 300], lambda v: f"{v}s")
    for grp, rows, color, stt, name in (("A", A, "s1", stA, L("A 強力", "A strong")), ("B", B, "s2", stB, L("B 均衡（現行預設）", "B balanced (default)"))):
        p.line([(r["sec"], r[key]) for r in rows], color)
        mean = stt[key]
        p.parts.append(f'<line x1="{p.sx(60):.1f}" x2="{p.pr}" y1="{p.sy(mean):.1f}" y2="{p.sy(mean):.1f}" stroke="{th[color]}" stroke-width="1" opacity=".55"/>')
        p.dot(rows[-1]["sec"], rows[-1][key], color, 4)
        lab = (f"{grp} {L('均', 'mean')} {mean:.1f}°C" if metric == "temp" else f"{grp} {L('均', 'mean')} {mean:,.0f} rpm")
        p.text(p.pr + 8, p.sy(mean) + 4, lab, "ink", 12, weight=600)
    p.legend([("line", "s1", L("A 強力（舊預設）", "A strong (old default)")), ("line", "s2", L("B 均衡（現行預設）", "B balanced (current default)"))])
    byA = {r["sec"] // 10: r for r in A}
    byB = {r["sec"] // 10: r for r in B}
    xs = sorted(set(list(byA) + list(byB)))
    def rows(k):
        out = []
        for g, d in (("A", byA), ("B", byB)):
            if k in d:
                r = d[k]
                out.append([f"{r[key]}{unit}" if metric == "temp" else f"{r[key]:,} rpm", L(f"{g}（{r['time']}，load {r['load']}）", f"{g} ({r['time']}, load {r['load']})")])
        return out
    # 用 10 秒格子當 X
    p.crosshair_hits([k * 10 for k in xs], lambda x: rows(x // 10), lambda x: L(f"段內 {x}s", f"{x}s into run"))
    return p.render()


def chart_ab_pcore(D, th, inter, show_title=True):
    pm = D["pm"]
    title = L("A/B 前後（A 曲線生效時）：8/9 筆 3936 MHz、1 筆 3950，9/9 Nominal",
              "Around the A/B run (curve A active): 8/9 samples 3936 MHz, 1 at 3950, 9/9 Nominal")
    sub = L("powermetrics P-Cluster HW active frequency；B 段 5 分鐘內沒有取樣。推論：3936 像是 M4 全核功耗上限",
            "powermetrics P-Cluster HW active frequency; no samples inside the 5-min B run. Inference: 3936 looks like the M4 all-core power limit")
    p = Plot(th, 760, 380, -0.6, len(pm) - 0.4, 3200, 4600, interactive=inter, title=title, subtitle=sub,
             ylabel="MHz", show_title=show_title, mr=200)
    p.band(-0.6, len(pm) - 0.4, None, 3300, 3800)
    p.text(p.pl + 8, p.sy(3800) + 16, L("原廠 M4 mini 重載 10–15 分鐘後 3300–3800 MHz（外部資料，非同機實測）", "Stock M4 mini after 10–15 min of heavy load: 3300–3800 MHz (external data, not measured here)"), "muted", 11)
    p.ygrid([3200, 3600, 4000, 4400], fmt_int)
    p.hline(4464, L("單核最高 4464", "1-core max 4464"), side="right")
    p.xaxis([], str)
    for i, r in enumerate(pm):
        color = "s1" if r["group"] == "A" else "s2"
        p.dot(i, r["pMHz"], color, 5, tip=((L("A 段前", "before A") if r["group"] == "A" else L("B 後（已還原 A 曲線）", "after B (curve A restored)")) + f" {r['time']}",
              [[f"{r['pMHz']:,} MHz", "P-Cluster HW"], [f"{r['cpuW']:.1f} W", "CPU Power"], [r["pressure"], "thermal pressure"]]))
        p.text(p.sx(i), p.pb + 18, r["time"][:5] if i in (0, 3) else "", "muted", 11, "middle")
    nA = sum(1 for r in pm if r["group"] == "A")
    p.text((p.sx(0) + p.sx(nA - 1)) / 2, p.pb + 36, L("A 段前（05:00:41–47，3 秒間隔）", "before A (05:00:41–47, 3 s apart)"), "muted", 11, "middle")
    p.text((p.sx(nA) + p.sx(len(pm) - 1)) / 2, p.pb + 36, L("B 後（已還原 A 曲線；05:19–05:20，20 秒間隔）", "after B (curve A restored; 05:19–05:20, 20 s apart)"), "muted", 11, "middle")
    p.text(p.sx(len(pm) - 1) + 12, p.sy(3943) - 10, L("8 筆 3936、1 筆 3950", "8 × 3936, 1 × 3950"), "ink", 12, weight=600)
    p.legend([("dot", "s1", L("A 段前（A 曲線）", "before A (curve A)")), ("dot", "s2", L("B 後（已還原 A 曲線）", "after B (curve A restored)"))])
    return p.render()


def chart_timeline(D, th, inter, show_title=True):
    ev = D["ev"]
    w = ev["writes"]
    t0 = datetime(2026, 9, 20)
    hrs = lambda t: (t - t0).total_seconds() / 3600
    x1 = math.ceil(hrs(ev["last"]) / 24) * 24
    hot = [x for x in w if x["temp"] >= 90]
    segs = hot_segments(w)
    s = D["summary"]
    title = L(f"近 {s['hours']:.0f} 小時：{len(segs)} 段高溫（{len(hot)} 筆 ≥90°C），hook 等待 0 次",
              f"Last {s['hours']:.0f} h: {len(segs)} hot periods ({len(hot)} writes ≥ 90 °C), 0 hook waits")
    sub = L(f"每一點是 guard 寫 SMC 的時刻（共 {len(w):,} 筆，只在轉速改變時記錄，非等間隔）；hook 等待 0、擋下 0、pressure 非 Nominal 0 秒",
            f"Each dot is a fan-guard SMC write ({len(w):,} total, logged only when the target changes); 0 hook waits, 0 denials, 0 s non-Nominal pressure")
    p = Plot(th, 760, 380, 0, x1, 30, 105, interactive=inter, title=title, subtitle=sub, ylabel="°C",
             show_title=show_title, mr=176)
    p.ygrid([30, 40, 50, 60, 70, 80, 90, 100], lambda v: f"{v:.0f}°")
    p.xaxis(list(range(0, x1 + 1, 24)), lambda h: (t0 + timedelta(hours=h)).strftime("%-m/%-d"), grid=False)
    for h in range(12, x1, 24):
        p.text(p.sx(h), p.pb + 18, "12:00", "muted", 10, "middle")
    for x in w:
        if x["temp"] < 90:
            p.dot(hrs(x["t"]), x["temp"], "dim", 2.2, ring=False, opacity=0.8)
    p.hline(90, L("第一版門檻 90°C", "v1 threshold 90 °C"), "ink2")
    p.hline(100, L("擋下 100°C", "deny 100 °C"), "crit")
    for x in hot:
        p.dot(hrs(x["t"]), x["temp"], "s2", 3.5, tip=(x["t"].strftime("%m-%d %H:%M:%S"),
              [[f"{x['temp']}°C", L("控制溫度", "control temp")], [f"{x['rpm']:,} rpm", L("當下轉速", "fan rpm")],
               [f"{x['ghz']:.2f} GHz" if x["ghz"] else "—", L("powermetrics P-core（硬體）", "powermetrics P-core (hardware)")]]))
    p.legend([("dot", "s2", L(f"≥90°C 的寫入（{len(hot)} 筆，{len(segs)} 段）", f"writes ≥ 90 °C ({len(hot)}, {len(segs)} periods)")),
              ("dot", "dim", L(f"<90°C（{len(w) - len(hot):,} 筆）", f"< 90 °C ({len(w) - len(hot):,})"))])
    return p.render()


def chart_hist(D, th, inter, show_title=True):
    w = D["ev"]["writes"]
    bins = Counter((x["temp"] // 5) * 5 for x in w)
    lo, hi = 35, 100
    mx = max(bins.values())
    med = st.median(x["temp"] for x in w)
    n6080 = sum(1 for x in w if 60 <= x["temp"] < 80)
    title = L(f"寫入時溫度六成多落在 60–80°C（{n6080 / len(w) * 100:.0f}%），中位 {med:.0f}°C",
              f"Most writes happen at 60–80 °C ({n6080 / len(w) * 100:.0f}%), median {med:.0f} °C")
    sub = L(f"{len(w):,} 筆 SMC 寫入的控制溫度，每 5°C 一格；是「寫入時刻」分布，不是時間佔比",
            f"Control temperature of {len(w):,} SMC writes in 5 °C bins; a distribution of write moments, not of time")
    p = Plot(th, 760, 380, lo, hi, 0, math.ceil(mx / 100) * 100, interactive=inter, title=title, subtitle=sub,
             ylabel=L("次數", "writes"), show_title=show_title, mr=40)
    p.ygrid(nice_ticks(0, math.ceil(mx / 100) * 100, 4))
    p.xaxis(list(range(lo, hi + 1, 5)), lambda v: f"{v}°")
    bw = (p.sx(5) - p.sx(0)) - 2
    bw = min(bw, 24 * 1.6)
    for b in range(lo, hi, 5):
        n = bins.get(b, 0)
        if n == 0:
            continue
        p.col(p.sx(b + 2.5), n, bw, "s1" if b < 90 else "s2",
              tip=(f"{b}–{b + 4}°C", [[L(f"{n:,} 次", f"{n:,}"), L("寫入", "writes")], [f"{n / len(w) * 100:.1f}%", L("佔全部寫入", "of all writes")]]),
              label=fmt_int(n) if (n == mx or b >= 90) else None)
    p.legend([("rect", "s1", "<90°C"), ("rect", "s2", "≥90°C")])
    return p.render()


def chart_scatter(D, th, inter, show_title=True):
    w = [x for x in D["ev"]["writes"] if x["target"] is not None]
    curve = D["curveB"]
    title = L("目標轉速沿著曲線 B 走，降溫時慢慢收", "Target rpm follows curve B and eases off slowly while cooling")
    sub = L(f"{len(w):,} 次目標轉速（EMA 平滑：升 0.7 / 降 0.2、每輪最多降 300 rpm）；中位 {st.median(x['target'] for x in w):,.0f} rpm，從未到 4900",
            f"{len(w):,} target-rpm writes (EMA smoothing: up 0.7 / down 0.2, at most −300 rpm per round); median {st.median(x['target'] for x in w):,.0f} rpm, never reached 4900")
    p = Plot(th, 760, 380, 40, 100, 0, 5000, interactive=inter, title=title, subtitle=sub, ylabel="rpm",
             xlabel=L("控制溫度 °C", "control temp °C"), show_title=show_title, mr=150)
    p.ygrid([0, 1000, 2000, 3000, 4000, 5000])
    p.xaxis(list(range(40, 101, 10)), lambda v: f"{v}°")
    for x in w:
        p.dot(x["temp"], x["target"], "s1", 2.6, ring=False, opacity=0.45,
              tip=(x["t"].strftime("%m-%d %H:%M:%S"), [[f"{x['target']:,} rpm", L("目標", "target")], [f"{x['temp']}°C", L("控制溫度", "control temp")], [f"{x['rpm']:,} rpm", L("當下轉速", "fan rpm")]]))
    pts = [(40, curve[0][1])] + curve + [(100, curve[-1][1])]
    p.line(pts, "s2", 2)
    for tt, rr in curve:
        p.dot(tt, rr, "s2", 4)
    p.text(p.pr + 8, p.sy(curve[-1][1]) + 4, L("曲線 B 97°→4900", "curve B 97°→4900"), "ink", 12, weight=600)
    p.text(p.pr + 8, p.sy(3000) + 4, L("預熱 3000 rpm", "pre-warm 3000 rpm"), "muted", 11)
    p.parts.append(f'<line x1="{p.pl}" x2="{p.pr}" y1="{p.sy(3000):.1f}" y2="{p.sy(3000):.1f}" stroke="{th["ink2"]}" stroke-width="1" stroke-dasharray="4 3"/>')
    p.legend([("dot", "s1", L("目標轉速（每次寫入）", "target rpm (each write)")), ("line", "s2", L("設定曲線 B（本機現行）", "curve B (current on this Mac)"))])
    return p.render()


def chart_daily_max(D, th, inter, show_title=True):
    days = D["daily"]
    full = [d["logmax"] for d in days if not d.get("partial")]
    last = days[-1]
    title = L(f"每日最高 {min(full)}–{max(full)}°C（log 值；{last['date'][5:]} 至 23:42 為 {last['logmax']}°C），降頻 0 秒",
              f"Daily peak {min(full)}–{max(full)} °C (log values; {last['date'][5:]} to 23:42: {last['logmax']} °C), 0 s throttled")
    sub = L("柱＝每日結算（Int 截斷，可能比 log 值低 1°C）；09-23 取 stats.json 快照，約 23:48–23:50 抓取，log 只到 23:42",
            "Bars = daily summary (truncated to int, may be 1 °C below the log value); 09-23 from a stats.json snapshot taken ~23:48–23:50, log ends 23:42")
    p = Plot(th, 760, 380, -0.5, len(days) - 0.5, 0, 110, interactive=inter, title=title, subtitle=sub,
             ylabel="°C", show_title=show_title, mr=150, mb=64)
    p.ygrid([0, 20, 40, 60, 80, 100], lambda v: f"{v:.0f}°")
    p.xaxis([], str)
    p.hline(90, L("第一版門檻 90°C", "v1 threshold 90 °C"))
    p.hline(100, L("擋下 100°C", "deny 100 °C"), "crit")
    for i, d in enumerate(days):
        p.col(p.sx(i), d["max"], 24, "s1", tip=(d["date"] + (L("（至 23:42）", " (to 23:42)") if d.get("partial") else ""),
              [[f"{d['max']:.0f}°C" if isinstance(d['max'], int) else f"{d['max']:.1f}°C", L("結算最高", "daily summary")],
               [f"{d['logmax']}°C", L("log 行最高", "log max")], [f"{d['throttle']} s", L("降頻（pressure 非 Nominal）", "throttled (non-Nominal)")],
               [f"{d['waits']} / {d['denies']}", L("hook 等待 / 擋下", "hook waits / denials")]]),
              label=None)
        p.text(p.sx(i), p.pb + 18, d["date"][5:].replace("-", "/") + (L("（部分）", " (partial)") if d.get("partial") else "") + f" · log {d['logmax']}°C", "ink", 12, "middle", 600)
        p.text(p.sx(i), p.pb + 36, L(f"降頻 {d['throttle']}s · 等待 {d['waits']}", f"throttled {d['throttle']}s · waits {d['waits']}"), "muted", 11, "middle")
    return p.render()


def chart_daily_ctrl(D, th, inter, show_title=True):
    days = D["daily"]
    mx = max(max(d["takeovers"], d["handbacks"], d["boosts"]) for d in days)
    ymax = math.ceil(mx / 50) * 50
    title = L("每天交還 macOS 自動 59–137 次：閒下來就放手", "Hands the fan back to macOS auto 59–137 times a day: lets go when idle")
    sub = L(f"接管＝交還後又寫 SMC；預熱＝偵測到重指令先拉 3000 rpm；09-20 自 01:18 起、09-23 至 23:42；推論接管時間約 {D['summary']['ctrl_pct']:.0f}%",
            f"Takeover = writing SMC again after a hand-back; pre-warm = 3000 rpm when a heavy command is detected; 09-20 from 01:18, 09-23 to 23:42; inferred in control ≈ {D['summary']['ctrl_pct']:.0f}% of the time")
    p = Plot(th, 760, 380, -0.5, len(days) - 0.5, 0, ymax, interactive=inter, title=title, subtitle=sub,
             ylabel=L("次數", "count"), show_title=show_title, mr=40)
    p.ygrid(nice_ticks(0, ymax, 4))
    p.xaxis([], str)
    keys = (("takeovers", "s1", L("接管", "takeover")), ("handbacks", "s2", L("交還自動", "hand back to auto")), ("boosts", "s3", L("重指令預熱", "heavy-command pre-warm")))
    bw = 22
    for i, d in enumerate(days):
        for j, (k, c, name) in enumerate(keys):
            xc = p.sx(i) + (j - 1) * (bw + 2)
            p.col(xc, max(d[k], 0.0001), bw, c, tip=(d["date"], [[L(f"{d[k]} 次", f"{d[k]}"), name]]), label=str(d[k]))
        p.text(p.sx(i), p.pb + 18, d["date"][5:].replace("-", "/"), "ink2", 12, "middle")
    p.legend([("rect", c, n) for _, c, n in keys])
    return p.render()


def chart_curves(D, th, inter, show_title=True):
    A, B = D["curveA"], D["curveB"]
    tk = D["ev"]["takeovers"]
    title = L("macOS 自動 vs cool42 曲線：缺同負載穩態對照", "macOS auto vs cool42 curves: no same-load steady-state comparison yet")
    sub = L("線＝cool42 設定曲線；點＝guard 接管前一刻 macOS 自動控制下的實際轉速（非穩態、非同負載）",
            "Lines = cool42 curves; dots = actual rpm under macOS auto control right before guard took over (not steady state, not same load)")
    p = Plot(th, 760, 400, 40, 110, 0, 5000, interactive=inter, title=title, subtitle=sub, ylabel="rpm",
             xlabel=L("控制溫度 °C", "control temp °C"), show_title=show_title, mr=170, mb=62)
    p.band(100, 110, None)
    p.ygrid([0, 1000, 2000, 3000, 4000, 5000])
    p.xaxis(list(range(40, 111, 10)), lambda v: f"{v}°")
    for x in tk:
        p.dot(x["temp"], x["rpm"], "s3", 3, ring=False, opacity=0.5,
              tip=(x["t"].strftime("%m-%d %H:%M:%S"), [[f"{x['rpm']:,} rpm", L("macOS 自動（接管前）", "macOS auto (before takeover)")], [f"{x['temp']}°C", L("控制溫度", "control temp")]]))
    for c, color, name in ((A, "s1", L("A 強力", "A strong")), (B, "s2", L("B 均衡", "B balanced"))):
        p.line(c, color)
        for tt, rr in c:
            p.dot(tt, rr, color, 4)
    p.text(p.sx(A[-1][0]) - 10, p.sy(A[-1][1]) + 4, "A 90°→4900", "ink", 12, "end", 600)
    p.text(p.sx(B[-1][0]) + 8, p.sy(B[-1][1]) + 4, "B 97°→4900", "ink", 12, "start", 600)
    # README 記載：第一次接管前 macOS 自動 105°C / 1774 rpm（原始 log 已不在）
    p.dot(105, 1774, "s3", 6, hollow=True, tip=(L("README「實測」段", "README “measured” section"), [["1,774 rpm", L("macOS 自動", "macOS auto")], ["105°C", L("第一次接管前", "before first takeover")],
          [L("20 秒後 82°C", "82°C 20 s later"), L("cool42 接管後（舊曲線 4618 rpm）", "after cool42 took over (old curve 4618 rpm)")]]))
    p.text(p.sx(105), p.sy(1774) + 22, "105° / 1,774", "ink", 11, "middle", 600)
    p.dot(106, 2100, "muted", 6, hollow=True, tip=(L("外部資料（MacRumors 等）", "external data (MacRumors etc.)"), [["~2,100 rpm", L("原廠重載", "stock, heavy load")], ["105–107°C", L("溫度", "temperature")]]))
    p.text(p.sx(106) - 11, p.sy(2100) + 4, L("外部 ~2,100", "external ~2,100"), "muted", 11, "end")
    p.text(p.sx(100) + 6, p.sy(4300), "≥100°C", "muted", 11)
    p.text(p.sx(100) + 6, p.sy(4300) + 15, L("擋下區", "deny zone"), "muted", 11)
    p.text(p.sx(100) + 6, p.sy(4300) + 30, L("近 4 天 0 次", "0 in 4 days"), "muted", 11)
    by = p.pt + 90
    p.parts.append(f'<rect x="{p.pr + 12}" y="{by - 10}" width="10" height="10" rx="2" fill="{th["crit"]}"/>')
    p.text(p.pr + 28, by, L("待補", "TODO"), "ink", 12, weight=650)
    p.text(p.pr + 12, by + 18, "perf_vs_temp.py", "ink2", 11.5)
    p.text(p.pr + 12, by + 35, L("同負載、固定轉速", "same load, fixed rpm"), "muted", 11)
    p.text(p.pr + 12, by + 51, L("的穩態對照", "steady-state test"), "muted", 11)
    p.text(p.pr + 12, by + 67, L("（需 sudo＋空機）", "(needs sudo + idle Mac)"), "muted", 11)
    med = st.median(x["rpm"] for x in tk)
    p.text(p.sx(56), p.sy(med) + 22, L(f"macOS 自動中位 {med:,.0f} rpm（n={len(tk)}）", f"macOS auto median {med:,.0f} rpm (n={len(tk)})"), "ink", 11, "start", 600)
    p.legend([("line", "s1", L("A 強力", "A strong")), ("line", "s2", L("B 均衡", "B balanced")), ("dot", "s3", L("macOS 自動（接管前一刻）", "macOS auto (right before takeover)")), ("ring", "muted", L("外部資料", "external data"))])
    return p.render()


CHARTS = [
    # id, 函式, 標題 zh / en（HTML 用）, 群組 id
    ("hook-timeline", chart_timeline, "高溫期間 hook 等待 0 次：5 段高溫、31 筆 ≥90°C",
     "0 hook waits during hot periods: 5 hot periods, 31 writes ≥ 90 °C", "main"),
    ("ab-temp", lambda D, th, i, st_=True: chart_ab_series(D, th, i, "temp", st_), "A/B 溫度", "A/B temperature", "ab"),
    ("ab-rpm", lambda D, th, i, st_=True: chart_ab_series(D, th, i, "rpm", st_), "A/B 轉速", "A/B fan speed", "ab"),
    ("ab-pcore", chart_ab_pcore, "A/B P-core 時脈", "A/B P-core clock", "ab"),
    ("daily-max", chart_daily_max, "每日最高溫與降頻", "Daily peak temperature and throttling", "log"),
    ("daily-control", chart_daily_ctrl, "每日接管 / 交還 / 預熱", "Daily takeovers / hand-backs / pre-warms", "log"),
    ("temp-hist", chart_hist, "寫入時溫度分布", "Temperature at write time", "log"),
    ("rpm-vs-temp", chart_scatter, "目標轉速 vs 溫度", "Target rpm vs temperature", "log"),
    ("curve-vs-macos", chart_curves, "macOS 自動 vs cool42 曲線", "macOS auto vs cool42 curves", "todo"),
]
GROUPS = {"main": ("主打", "Headline"), "ab": ("A/B 實測", "A/B test"), "log": ("近 4 天 log", "4-day log"),
          "todo": ("對照（待補）", "Comparison (TODO)")}


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
        ge90=sum(1 for x in w if x["temp"] >= 90), hot_segs=len(hot_segments(w)),
        n6080=sum(1 for x in w if 60 <= x["temp"] < 80), n6075=sum(1 for x in w if 60 <= x["temp"] < 75), ge100=sum(1 for x in w if x["temp"] >= 100),
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
    T["hook-timeline"] = ([L("時間", "time"), L("控制溫度", "control temp"), L("當下轉速", "fan rpm"), L("powermetrics P-core GHz（硬體）", "powermetrics P-core GHz (hardware)")],
                          [[x["t"].strftime("%m-%d %H:%M:%S"), f"{x['temp']}°C", f"{x['rpm']:,}", f"{x['ghz']:.2f}" if x["ghz"] else "—"]
                           for x in D["ev"]["writes"] if x["temp"] >= 90])
    for m, k in (("ab-temp", "temp"), ("ab-rpm", "rpm")):
        T[m] = ([L("組", "group"), L("時間", "time"), L("段內秒", "s into run"), "load", L("溫度 °C", "temp °C"), L("轉速 rpm", "fan rpm")],
                [[r["group"], r["time"], r["sec"], r["load"], r["temp"], f"{r['rpm']:,}"] for r in D["samples"]])
    T["ab-pcore"] = ([L("時段（當時曲線皆為 A）", "period (curve A active in all)"), L("時間", "time"), "P-Cluster MHz", "E-Cluster MHz", "CPU W", "pressure"],
                     [[L("A 段前", "before A") if r["group"] == "A" else L("B 後（已還原 A）", "after B (A restored)"), r["time"], f"{r['pMHz']:,}", f"{r['eMHz']:,}", f"{r['cpuW']:.1f}", r["pressure"]] for r in D["pm"]])
    T["daily-max"] = ([L("日期", "date"), L("結算最高", "summary max"), L("log 行最高", "log max"), L("降頻 s", "throttled s"), L("hook 等待", "hook waits"), L("擋下", "denials"), "critical s"],
                      [[d["date"] + (L("（部分）", " (partial)") if d.get("partial") else ""), d["max"], d["logmax"], d["throttle"], d["waits"], d["denies"], d.get("critical")] for d in D["daily"]])
    T["daily-control"] = ([L("日期", "date"), L("接管", "takeovers"), L("交還自動", "hand-backs"), L("預熱", "pre-warms")], [[d["date"], d["takeovers"], d["handbacks"], d["boosts"]] for d in D["daily"]])
    bins = Counter((x["temp"] // 5) * 5 for x in D["ev"]["writes"])
    T["temp-hist"] = ([L("溫度區間", "temp bin"), L("寫入次數", "writes"), L("佔比", "share")], [[f"{b}–{b + 4}°C", bins[b], f"{bins[b] / s['writes'] * 100:.1f}%"] for b in sorted(bins)])
    tg = defaultdict(list)
    for x in D["ev"]["writes"]:
        if x["target"] is not None:
            tg[(x["temp"] // 5) * 5].append(x["target"])
    T["rpm-vs-temp"] = ([L("溫度區間", "temp bin"), L("次數", "count"), L("目標中位 rpm", "median target rpm"), L("目標最高 rpm", "max target rpm"), L("曲線 B 對應 rpm", "curve B rpm")],
                        [[f"{b}–{b + 4}°C", len(v), f"{st.median(v):,.0f}", f"{max(v):,}", f"{interp(D['curveB'], b + 2.5):,.0f}"] for b, v in sorted(tg.items())])
    T["curve-vs-macos"] = ([L("來源", "source"), L("溫度", "temp"), L("轉速", "rpm"), L("說明", "note")],
                           [[L("曲線 A", "curve A"), "→".join(str(t) for t, _ in D["curveA"]), "→".join(str(r) for _, r in D["curveA"]), "config-A.json"],
                            [L("曲線 B", "curve B"), "→".join(str(t) for t, _ in D["curveB"]), "→".join(str(r) for _, r in D["curveB"]), L("config-B.json（現行預設）", "config-B.json (current default)")],
                            [L("macOS 自動（接管前一刻）", "macOS auto (right before takeover)"), f"n={s['takeovers']}",
                             L(f"中位 {s['macos_rpm_med']:,.0f}、最高 {s['macos_rpm_max']:,}", f"median {s['macos_rpm_med']:,.0f}, max {s['macos_rpm_max']:,}"),
                             L("cool42.log 接管那一行的 🌀 值", "🌀 value on the takeover line in cool42.log")],
                            [L("README 第一次接管", "README, first takeover"), "105°C", "1,774", L("原始 log 已不在，照文件引用", "original log is gone; quoted from the docs")],
                            [L("外部資料", "external data"), "105–107°C", "~2,100", "MacRumors / theenterprisemac"],
                            [L("待補", "TODO"), "—", "—", L("perf_vs_temp.py：同負載、固定轉速的穩態溫度／時脈／ops/J", "perf_vs_temp.py: steady-state temp / clock / ops/J at the same load and fixed rpm")]])
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
    days = D["daily"]
    if LANG == "en":
        return {
            "hook-timeline": f"Over {s['hours']:.1f} h there were {s['hot_segs']} hot periods (split on gaps > 5 min; {s['ge90']} writes with control temp ≥ 90 °C, max {s['max_log']} °C, {s['ge100']} at ≥ 100 °C); the hook waited {s['waits']} times, denied {s['denies']} times, and thermal pressure was non-Nominal for {s['throttle']} s. The log doesn't record every pass, so how many Bash calls went through the hook in those periods is unknown. Inference: if heavy commands ran then, the v1 “wait at 90 °C” threshold would have made them wait.",
            "ab-temp": f"After dropping the first 60 s: A mean {A['temp']:.1f} °C ({A['tmin']}–{A['tmax']}) → B mean {B['temp']:.1f} °C ({B['tmin']}–{B['tmax']}), only {B['temp'] - A['temp']:.1f} °C warmer.",
            "ab-rpm": f"A mean {A['rpm']:,.0f} rpm → B mean {B['rpm']:,.0f} rpm, {A['rpm'] - B['rpm']:,.0f} slower (−{(1 - B['rpm'] / A['rpm']) * 100:.0f}%); fan-law estimate ≈ −{50 * math.log10(A['rpm'] / B['rpm']):.1f} dB (inferred, not measured).",
            "ab-pcore": f"Of 9 powermetrics samples, 8 read 3936 MHz and 1 read 3950; pressure {s['pm_pressure'].get('Nominal', 0)}/9 Nominal — but all were taken while curve A was active: 3 before A (05:00:41–47) and 6 about 3 minutes after B ended and A was restored (05:19–05:20). There are no samples inside the 5-minute B run, so this chart can't be used to say “B doesn't throttle”. Whether 3936 is the all-core power limit is an inference; in the 09-20 to 09-23 log the median frequency at ≥ 90 °C is 3.64 GHz.",
            "daily-max": "Daily peak (log values) " + ", ".join(f"{d['date'][5:]} {d['logmax']} °C" for d in days) + "; summary values (int-truncated) " + ", ".join(f"{d['max']:.0f}" for d in days) + f". 09-23 runs to 23:42. Over 4 days: {s['throttle']} s throttled (pressure non-Nominal) in total, {s['waits']} hook waits.",
            "daily-control": "Handed back to macOS auto " + ", ".join(f"{d['date'][5:]} {d['handbacks']}" for d in days) + f" times ({s['handbacks']} total); {s['takeovers']} takeovers, {s['boosts']} pre-warms ({s['early']} ended early). Inferred in control ≈ {s['ctrl_hours']:.1f}/{s['hours']:.1f} h ({s['ctrl_pct']:.0f}%, sleep not excluded).",
            "temp-hist": f"60–79 °C accounts for {s['n6080'] / s['writes'] * 100:.0f}% (60–74 °C: {s['n6075'] / s['writes'] * 100:.0f}%). Across {s['writes']:,} writes the control temp median is {s['temp_med']:.0f} °C, mean {s['temp_mean']:.1f} °C; only {s['ge90']} are ≥ 90 °C ({s['ge90'] / s['writes'] * 100:.1f}%). This is a distribution of write moments, not of time.",
            "rpm-vs-temp": f"{s['targets']:,} target rpm values: median {s['target_med']:,.0f} rpm, mean {s['target_mean']:,.0f}, max {s['target_max']:,} ({s['target_ge3000']} at ≥ 3000); never reached 4900. Inference: points below the curve are the EMA still catching up while heating; points above are the −300 rpm-per-round limit while cooling and the 3000 rpm pre-warm.",
            "curve-vs-macos": f"Right before takeover, macOS auto ran a median {s['macos_rpm_med']:,.0f} rpm (n={s['takeovers']}); the README records only 1,774 rpm at 105 °C, while cool42 curve B already gives 2,600 at 85 °C. No same-load steady-state comparison yet — to be filled in by perf_vs_temp.py.",
        }
    return {
        "hook-timeline": f"{s['hours']:.1f} 小時內有 {s['hot_segs']} 段高溫期間（間隔 >5 分鐘分段；控制溫度 ≥90°C 的寫入共 {s['ge90']} 筆，最高 {s['max_log']}°C、≥100°C {s['ge100']} 次），hook 等待 {s['waits']} 次、擋下 {s['denies']} 次、thermal pressure 非 Nominal {s['throttle']} 秒。log 不記每次放行，不知道這些期間實際有幾次 Bash 經過 hook。推論：若這些期間有重指令，第一版「90°C 就等」的門檻會讓它等。",
        "ab-temp": f"丟前 60 秒後 A 均 {A['temp']:.1f}°C（{A['tmin']}–{A['tmax']}）→ B 均 {B['temp']:.1f}°C（{B['tmin']}–{B['tmax']}），只多 {B['temp'] - A['temp']:.1f}°C。",
        "ab-rpm": f"A 均 {A['rpm']:,.0f} rpm → B 均 {B['rpm']:,.0f} rpm，少轉 {A['rpm'] - B['rpm']:,.0f}（−{(1 - B['rpm'] / A['rpm']) * 100:.0f}%），風扇定律推估約 −{50 * math.log10(A['rpm'] / B['rpm']):.1f} dB（推論值，非實測）。",
        "ab-pcore": f"9 筆 powermetrics 中 8 筆 3936 MHz、1 筆 3950，pressure {s['pm_pressure'].get('Nominal', 0)}/9 Nominal —— 但全部是在 A 曲線生效時量的：A 段前 3 筆（05:00:41–47）、B 結束並還原成 A 約 3 分鐘後 6 筆（05:19–05:20）。B 段 5 分鐘內沒有取樣，這張圖不能拿來說「B 不降頻」。3936 是否為全核功耗上限是推論；09-20～23 的 log 裡 ≥90°C 時的頻率中位是 3.64 GHz。",
        "daily-max": "每日最高（log 值）" + "、".join(f"{d['date'][5:]} {d['logmax']}°C" for d in D["daily"]) + "；結算值（Int 截斷）" + "、".join(f"{d['max']:.0f}" for d in D["daily"]) + f"。09-23 至 23:42。4 天降頻（pressure 非 Nominal）合計 {s['throttle']} 秒，hook 等待 {s['waits']} 次。",
        "daily-control": "交還 macOS 自動 " + "、".join(f"{d['date'][5:]} {d['handbacks']}" for d in D["daily"]) + f" 次（共 {s['handbacks']}）；接管 {s['takeovers']} 次、預熱 {s['boosts']} 次（{s['early']} 次提早結束）。推論接管時間約 {s['ctrl_hours']:.1f}/{s['hours']:.1f} 小時（{s['ctrl_pct']:.0f}%，未扣睡眠）。",
        "temp-hist": f"60–79°C 佔 {s['n6080'] / s['writes'] * 100:.0f}%（60–74°C 佔 {s['n6075'] / s['writes'] * 100:.0f}%）。{s['writes']:,} 筆寫入的溫度中位 {s['temp_med']:.0f}°C、平均 {s['temp_mean']:.1f}°C；≥90°C 只有 {s['ge90']} 筆（{s['ge90'] / s['writes'] * 100:.1f}%）。這是寫入時刻分布，不是時間佔比。",
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
.bar select{font:inherit;font-size:13px;border:1px solid var(--border);background:var(--surface);color:var(--ink2);border-radius:999px;padding:5px 10px;max-width:min(200px,100%)}
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
html[data-lang="en"] .l-zh,html:not([data-lang="en"]) .l-en{display:none!important}
.bar .seg{display:inline-flex;border:1px solid var(--border);border-radius:999px;overflow:hidden}
.bar .seg button{border:0;border-radius:0;padding:5px 11px}
"""

# 在 CSS 之前先決定語言，避免先閃一下另一種語言：?lang=en|zh ＞ 上次選的 ＞ 瀏覽器語言
HTML_LANG_BOOT = r"""
(function(){var l=null;try{var m=/[?&]lang=(zh|en)\b/.exec(location.search);if(m)l=m[1];else l=localStorage.getItem('cool42viz-lang')}catch(e){}
if(l!=='zh'&&l!=='en')l=/^zh\b/i.test(navigator.language||'')?'zh':'en';document.documentElement.dataset.lang=l;
document.documentElement.lang=l==='en'?'en':'zh-Hant-TW'})();
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
  function hide(){tt.style.display='none';document.querySelectorAll('.xhair').forEach(function(x){x.setAttribute('visibility','hidden')})}
  document.addEventListener('pointermove',function(e){var el=e.target.closest&&e.target.closest('[data-tip]');if(el)show(el,e);else if(tt.style.display==='block')hide()});
  document.addEventListener('focusin',function(e){if(e.target.hasAttribute&&e.target.hasAttribute('data-tip'))show(e.target)});
  document.addEventListener('focusout',function(){hide()});
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
  // 語言
  var root=document.documentElement,lbs=[].slice.call(document.querySelectorAll('.bar button[data-lang]'));
  function setLang(l,save){root.dataset.lang=l;root.lang=l==='en'?'en':'zh-Hant-TW';
    document.title=l==='en'?'cool42 data comparison':'cool42 數據比對';
    lbs.forEach(function(b){b.setAttribute('aria-pressed',b.dataset.lang===l)});
    [one].concat([].slice.call(one.options)).forEach(function(o){var t=o.getAttribute('data-'+l);if(!t)return;if(o===one)o.setAttribute('aria-label',t);else o.textContent=t});
    hide();if(save){try{localStorage.setItem('cool42viz-lang',l)}catch(e){}}}
  lbs.forEach(function(b){b.addEventListener('click',function(){setLang(b.dataset.lang,true)})});
  setLang(root.dataset.lang==='en'?'en':'zh',false);
  // 亮暗（按鈕文字＝按下去會變成的樣子）
  var tb=document.getElementById('theme');
  tb.addEventListener('click',function(){var dark=root.dataset.theme?root.dataset.theme==='dark':matchMedia('(prefers-color-scheme: dark)').matches;root.dataset.theme=dark?'light':'dark';
    tb.innerHTML=dark?'<span class="l-zh">暗色</span><span class="l-en">Dark</span>':'<span class="l-zh">亮色</span><span class="l-en">Light</span>'});
})();
"""

SOURCES = {
    "hook-timeline": ("extras/viz/data/cool42-log-20260920_20260923.txt（/var/log/cool42.log 快照）＋每日結算＋stats.json",
                      "extras/viz/data/cool42-log-20260920_20260923.txt (snapshot of /var/log/cool42.log) + daily summaries + stats.json"),
    "ab-temp": ("docs/ab-test-2026-09-16/samples.txt、timeline.txt", "docs/ab-test-2026-09-16/samples.txt, timeline.txt"),
    "ab-rpm": ("docs/ab-test-2026-09-16/samples.txt、timeline.txt", "docs/ab-test-2026-09-16/samples.txt, timeline.txt"),
    "ab-pcore": ("docs/ab-test-2026-09-16/powermetrics-A.txt、powermetrics-B.txt；原廠區間引自同目錄 README（外部資料）",
                 "docs/ab-test-2026-09-16/powermetrics-A.txt, powermetrics-B.txt; the stock range is quoted from the README in that folder (external data)"),
    "daily-max": ("cool42.log「今日統計結算」3 行＋extras/viz/data/stats-2026-09-23.json（約 23:48–23:50 的快照）",
                  "3 daily-summary lines (今日統計結算) in cool42.log + extras/viz/data/stats-2026-09-23.json (snapshot taken ~23:48–23:50)"),
    "daily-control": ("cool42.log「交還自動」「目標」「預熱」行", "cool42.log hand-back (交還自動), target (目標) and pre-warm (預熱) lines"),
    "temp-hist": ("cool42.log 寫入行", "cool42.log write lines"),
    "rpm-vs-temp": ("cool42.log 寫入行＋docs/ab-test-2026-09-16/config-B.json", "cool42.log write lines + docs/ab-test-2026-09-16/config-B.json"),
    "curve-vs-macos": ("config-A/B.json、cool42.log 接管行、README「實測」段、外部資料",
                       "config-A/B.json, cool42.log takeover lines, the README “measured” section, external data"),
}


def lang_block(D, lang):
    """某一語言的整份內容片段（header、tiles、每張圖的 zh/en 內容、缺數據清單、footer）。"""
    global LANG
    prev, LANG = LANG, lang
    try:
        s = D["summary"]
        T = tables(D)
        C = conclusions(D)
        ix = 1 if lang == "en" else 0
        figs = {}
        for cid, fn, name_zh, name_en, g in CHARTS:
            name = L(name_zh, name_en)
            svg = fn(D, CSS_THEME, True, False)
            head, rows = T[cid]
            tbl = "<table><thead><tr>" + "".join(f"<th>{esc(h)}</th>" for h in head) + "</tr></thead><tbody>" + \
                  "".join("<tr>" + "".join(f"<td>{esc('—' if c is None else c)}</td>" for c in r) + "</tr>" for r in rows) + "</tbody></table>"
            todo = f'<span class="todo">{L("待補：perf_vs_temp.py", "TODO: perf_vs_temp.py")}</span>' if cid == "curve-vs-macos" else ""
            static = f"docs/img/charts/{cid}{'-en' if lang == 'en' else ''}-light.svg / -dark.svg"
            figs[cid] = (f'<div class="grp">{esc(GROUPS[g][ix])}</div>'
                         f'<h2>{esc(name)}{todo}</h2><p class="con">{esc(C[cid])}</p><div class="svgw">{svg}</div>'
                         f'<p class="src">{L("來源：", "Source: ")}{esc(SOURCES[cid][ix])} · {L("靜態圖：", "static: ")}{static}</p>'
                         f'<details><summary>{L(f"表格檢視（{len(rows):,} 列）", f"Table view ({len(rows):,} rows)")}</summary><div class="tw">{tbl}</div></details>')
        A, B = s["A"], s["B"]
        if lang == "en":
            header = (f'<h1>cool42 data comparison</h1><p>While AI writes code, cool42 lets it queue on thermal pressure by itself and '
                      f'wait only when macOS reports throttling (thermal pressure non-Nominal). Everything below is real data from this Mac: '
                      f'the A/B test (2026-09-16) + guard log {esc(s["log_first"])} → {esc(s["log_last"])}.</p>')
            tiles = f"""
<div class="tiles">
  <div class="tile hero"><div class="lab">Hot periods → hook waits</div><div class="val">{s['hot_segs']} → {s['waits']}</div><div class="sub">last {s['hours']:.1f} h; {s['ge90']} writes ≥ 90 °C; {s['denies']} denials, {s['throttle']} s non-Nominal pressure</div></div>
  <div class="tile"><div class="lab">A/B fan speed</div><div class="val">−{(1 - B['rpm'] / A['rpm']) * 100:.0f}%</div><div class="sub">{A['rpm']:,.0f} → {B['rpm']:,.0f} rpm</div></div>
  <div class="tile"><div class="lab">A/B control temp</div><div class="val">+{B['temp'] - A['temp']:.1f}°C</div><div class="sub">{A['temp']:.1f} → {B['temp']:.1f}°C</div></div>
  <div class="tile"><div class="lab">P-core HW clock (curve A)</div><div class="val">3936</div><div class="sub">MHz · 9/9 Nominal; not measured during B</div></div>
  <div class="tile"><div class="lab">Hand-backs to macOS auto</div><div class="val">{s['handbacks']}</div><div class="sub">inferred in control ≈ {s['ctrl_pct']:.0f}% of the time</div></div>
</div>"""
            gaps = """
<section class="gap"><h2>Missing data (can't be claimed until filled in)</h2><ul>
<li><b>macOS default vs cool42 at the same load, steady state</b>: the A/B has only two cool42 curves and no “stock auto” group. Stock 105–107 °C / ~2,100 rpm / P-core 3300–3800 MHz are external web data. <span class="todo">TODO: perf_vs_temp.py</span> (needs sudo + an idle Mac).</li>
<li><b>Clock and pressure during B</b>: all 9 powermetrics samples fall outside the 5-minute A/B windows, and all while curve A was active (before A, 05:00:41–47; 05:19–05:20, after B ended and ab.sh restored A). Claiming “B doesn't throttle” needs a re-run with in-run logging.</li>
<li><b>Total time for the same job</b>: never measured, so no “X% faster” claim.</li>
<li><b>Real throttle → hook wait → released again</b>: 0 times in the last 4 days, so there is no real instance of the headline feature's “wait” step; it needs a controlled reproduction.</li>
<li><b>Throttled seconds during the A/B</b>: guard didn't record throttleSeconds back then; 9/9 Nominal was sampled under curve A and can't stand in for B.</li>
<li><b>Evenly spaced temperature series</b>: the log only records SMC writes and history.json keeps only 5 minutes. The distribution chart is not a share of time.</li>
<li>n = 1 Mac mini M4; logs before 09-20 are gone, so historical numbers in README / CHANGELOG can only be quoted from the docs.</li>
</ul></section>"""
            footer = ('Generator: <code>python3 extras/viz/build_charts.py</code> (standard library only, hand-built SVG). Palette validated with dataviz '
                      'validate_palette.js (light / dark all-pairs PASS); light-mode aqua is below 3:1 contrast, compensated with direct labels and table views. '
                      'Inferred values are marked as such.')
        else:
            header = (f'<h1>cool42 數據比對</h1><p>AI 寫程式時自己看熱壓力排隊，只在 macOS 回報降頻（thermal pressure 非 Nominal）才等。'
                      f'以下全部是本機真實數據：A/B 實測（2026-09-16）＋ guard log {esc(s["log_first"])} → {esc(s["log_last"])}。</p>')
            tiles = f"""
<div class="tiles">
  <div class="tile hero"><div class="lab">高溫期間 → hook 等待</div><div class="val">{s['hot_segs']} 段 → {s['waits']}</div><div class="sub">近 {s['hours']:.1f} 小時；{s['ge90']} 筆 ≥90°C 寫入；擋下 {s['denies']} 次、pressure 非 Nominal {s['throttle']} 秒</div></div>
  <div class="tile"><div class="lab">A/B 風扇轉速</div><div class="val">−{(1 - B['rpm'] / A['rpm']) * 100:.0f}%</div><div class="sub">{A['rpm']:,.0f} → {B['rpm']:,.0f} rpm</div></div>
  <div class="tile"><div class="lab">A/B 控制溫度</div><div class="val">+{B['temp'] - A['temp']:.1f}°C</div><div class="sub">{A['temp']:.1f} → {B['temp']:.1f}°C</div></div>
  <div class="tile"><div class="lab">P-core 硬體時脈（A 曲線時）</div><div class="val">3936</div><div class="sub">MHz · 9/9 Nominal；B 段內未量</div></div>
  <div class="tile"><div class="lab">交還 macOS 自動</div><div class="val">{s['handbacks']} 次</div><div class="sub">推論接管約 {s['ctrl_pct']:.0f}% 時間</div></div>
</div>"""
            gaps = """
<section class="gap"><h2>缺的數據（不補就不能宣稱）</h2><ul>
<li><b>macOS 預設 vs cool42 同負載穩態</b>：A/B 只有兩條 cool42 曲線，沒有「原廠自動」組。原廠 105–107°C / ~2,100 rpm / P-core 3300–3800 MHz 是外部網路資料。<span class="todo">待補：perf_vs_temp.py</span>（需 sudo＋空機）。</li>
<li><b>B 段內的時脈與 pressure</b>：powermetrics 9 筆都在 A/B 5 分鐘視窗外，而且都在 A 曲線生效時（A 段前 05:00:41–47；B 結束、ab.sh 還原成 A 之後的 05:19–05:20）。要主張「B 不降頻」需重做 A/B 並在段內同步記錄。</li>
<li><b>同一工作總耗時</b>：沒量過，不能宣稱「快 X%」。</li>
<li><b>真的降頻 → hook 等待 → 恢復放行</b>：近 4 天 0 次，沒有實例可展示主打功能的「等」那一段；需受控重現。</li>
<li><b>A/B 期間的降頻秒數</b>：當時 guard 尚未記錄 throttleSeconds；9/9 Nominal 是 A 曲線時的取樣，不能代替 B 段。</li>
<li><b>等間隔溫度時間序列</b>：log 只在寫 SMC 時記錄；history.json 只留 5 分鐘。分布圖不能當時間佔比。</li>
<li>n=1 台 Mac mini M4；09-20 之前的 log 已不在，README／CHANGELOG 的歷史數字只能照文件引用。</li>
</ul></section>"""
            footer = ('產生器：<code>python3 extras/viz/build_charts.py</code>（標準庫、自產 SVG）。色盤經 dataviz validate_palette.js 驗證（亮／暗 all-pairs PASS）；'
                      '亮色 aqua 對比不足 3:1，已以直接標籤與表格補足。推論值皆有標明。')
        return dict(header=header, tiles=tiles, figs=figs, gaps=gaps, footer=footer)
    finally:
        LANG = prev


def build_html(D):
    """單檔雙語頁：zh / en 內容都在頁內，用 html[data-lang] 切換（不需重新產生）。"""
    Z, E = lang_block(D, "zh"), lang_block(D, "en")
    both = lambda a, b, tag="div": f'<{tag} class="l-zh">{a}</{tag}><{tag} class="l-en" lang="en">{b}</{tag}>'
    figs = "".join(f'<section class="fig" data-id="{cid}" data-g="{g}">{both(Z["figs"][cid], E["figs"][cid])}</section>'
                   for cid, _, _, _, g in CHARTS)
    sp = lambda a, b: f'<span class="l-zh">{esc(a)}</span><span class="l-en">{esc(b)}</span>'
    btns = [f'<button data-f="all" aria-pressed="true">{sp("全部", "All")}</button>'] + \
           [f'<button data-f="{g}">{sp(*GROUPS[g])}</button>' for g in GROUPS] + \
           ['<select id="one" aria-label="只看一張圖" data-zh="只看一張圖" data-en="Show one chart">'
            '<option value="" data-zh="只看一張…" data-en="Just one chart…">只看一張…</option>' +
            "".join(f'<option value="{cid}" data-zh="{esc(nz)}" data-en="{esc(ne)}">{esc(nz)}</option>' for cid, _, nz, ne, _ in CHARTS) + '</select>']
    langsw = ('<span class="seg" role="group" aria-label="語言 / Language">'
              '<button type="button" data-lang="zh" aria-pressed="true">中文</button>'
              '<button type="button" data-lang="en" aria-pressed="false">English</button></span>')
    return f"""<!doctype html>
<html lang="zh-Hant-TW"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>cool42 數據比對</title><meta name="description" content="okle42 cool42：A/B 實測與近 4 天 guard log 的真實數據圖 · real data from the A/B test and 4 days of guard log">
<script>{HTML_LANG_BOOT}</script>
<style>{HTML_CSS}</style></head>
<body><main>
<header><div class="brand">okle42 · cool42</div>{both(Z["header"], E["header"])}</header>
{both(Z["tiles"], E["tiles"])}
<nav class="bar" aria-label="切換圖">{''.join(btns)}<span class="sp"></span>{langsw}<button id="theme" type="button">{sp("切換亮暗", "Light / dark")}</button></nav>
{figs}
{both(Z["gaps"], E["gaps"])}
<footer>{both(Z["footer"], E["footer"], "span")}</footer>
</main><div id="tt" role="tooltip"></div>
<script>{HTML_JS}</script></body></html>"""


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", action="store_true", help="改讀 /var/log/cool42.log 與 /var/db/cool42/stats.json")
    ap.add_argument("--lang", choices=("zh", "en", "both"), default="both",
                    help="靜態 SVG 產哪種語言：zh＝<name>-light/-dark.svg、en＝<name>-en-light/-dark.svg、both（預設）兩種都產；互動頁一律雙語")
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
    global LANG
    written = []
    for lang in (("zh", "en") if a.lang == "both" else (a.lang,)):
        LANG = lang
        suffix = "-en" if lang == "en" else ""
        for cid, fn, _, _, _ in CHARTS:
            for mode in ("light", "dark"):
                path = os.path.join(OUT_IMG, f"{cid}{suffix}-{mode}.svg")
                with open(path, "w", encoding="utf-8") as f:
                    f.write(fn(D, THEMES[mode], False, True))
                written.append(os.path.relpath(path, ROOT))
    LANG = "zh"
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
    print(f"SVG {len(written)} 張 → docs/img/charts/；互動頁 → {os.path.relpath(OUT_HTML, ROOT)}" + ("" if a.no_desktop else "（已複製到桌面）"))


if __name__ == "__main__":
    main()
