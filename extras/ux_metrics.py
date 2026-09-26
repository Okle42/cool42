#!/usr/bin/env python3
"""從 guard log 量「風扇有多吵、多煩」：按日輸出交還自動、接管、預熱、預熱提早結束比例、每小時風扇目標變更次數。

只讀 log、不碰 SMC、不需要 root（/var/log/cool42.log 是 644）。

用法：
    python3 extras/ux_metrics.py                                 # 讀 /var/log/cool42.log，按日列表＋整段合計
    python3 extras/ux_metrics.py --since "2026-09-26 00:00"      # 以改版時間點切成「之前 / 之後」兩段比較
    python3 extras/ux_metrics.py --log ./cool42.log --json       # 別的 log 檔、輸出 JSON

欄位定義（對應 guard 寫的 log 字串）：
    接管      從「交還自動」狀態（或 guard 剛啟動）第一次寫目標轉速：「→ 目標 N rpm」且前一狀態是自動
    交還      「→ 交還自動」
    預熱事件  boost_events：「預熱 N rpm 到 …」的行數。同一波預熱被延長（例如 swift build 連跑）時每個事件各記一行，
              所以這是事件數、不是預熱次數（被學習略過的另計「略過預熱」）
    預熱波次  boost_waves：一波 = 上一波已過期（到了「到 <until>」的時間）、已提早結束或 guard 重啟之後的第一個預熱事件
    提早結束  「預熱提早結束」（每波最多一次）；early_end_ratio_per_wave = 提早結束 ÷ 預熱波次
    目標變更/時  （「→ 目標」＋「→ 交還自動」）÷ 當天 log 涵蓋時數（首行到末行；涵蓋不到 1 小時的日子以 1 小時計）
    加碼      「預熱加碼」（預熱從 boostStartRPM 升到 boostRPM）
    學到      「學到：X 不再預熱」
"""
import argparse
import json
import re
import sys
from collections import OrderedDict
from datetime import datetime

STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (.*)$")
FIELDS = ["takeovers", "handbacks", "boost_events", "boost_waves", "early_end", "escalations", "learned", "skipped", "target_changes"]
BOOST = re.compile(r"^預熱 \d+ rpm 到 (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")


def parse(path):
    """逐行產出 (datetime, message)。沒有時間戳的行（stderr 殘留）略過"""
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = STAMP.match(line.rstrip("\n"))
            if not m:
                continue
            try:
                t = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
            except ValueError:
                continue
            yield t, m.group(2)


def new_bucket():
    b = {k: 0 for k in FIELDS}
    b["first"] = None
    b["last"] = None
    return b


def collect(path):
    """回傳 OrderedDict[date] -> bucket，以及事件清單（給 --since 切段用）"""
    days = OrderedDict()
    auto = True  # guard 啟動時是交還狀態，第一次寫目標算接管
    events = []  # (datetime, field)
    wave_until = None  # 目前這一波預熱到期時間；None = 沒有進行中的波
    for t, msg in parse(path):
        d = t.strftime("%Y-%m-%d")
        b = days.setdefault(d, new_bucket())
        b["first"] = b["first"] or t
        b["last"] = t
        fields = []
        # 字首是產品名：改名前的 log 是舊名，跳過第一個字再比
        after_name = msg.split(" ", 1)[-1]
        if after_name.startswith("guard 啟動"):
            auto = True
            wave_until = None
        elif after_name.startswith("guard 結束"):
            auto = True  # SIGTERM 結束會保持轉速，但重啟後 guard 第一輪一定重寫目標，同樣記為接管
        elif "→ 交還自動" in msg or "風扇交還自動" in msg:
            fields += ["handbacks", "target_changes"]
            auto = True
        elif "→ 目標 " in msg and " rpm" in msg:
            fields.append("target_changes")
            if auto:
                fields.append("takeovers")
            auto = False
        elif msg.startswith("預熱提早結束"):
            fields.append("early_end")
            wave_until = None
        elif msg.startswith("預熱加碼"):
            fields.append("escalations")
        elif msg.startswith("預熱 ") and " rpm 到 " in msg:
            fields.append("boost_events")
            m = BOOST.match(msg)
            until = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S") if m else t
            if wave_until is None or t >= wave_until:
                fields.append("boost_waves")
                wave_until = until
            else:
                wave_until = max(wave_until, until)
        elif msg.startswith("學到："):
            fields.append("learned")
        elif msg.startswith("略過預熱"):
            fields.append("skipped")
        for f in fields:
            b[f] += 1
            events.append((t, f))
    return days, events


def hours(b):
    if not b["first"]:
        return 0.0
    return max(1.0, (b["last"] - b["first"]).total_seconds() / 3600)


def summarize(buckets):
    """把多天合成一段：總數、每日平均、比例、每小時目標變更"""
    tot = {k: sum(b[k] for b in buckets) for k in FIELDS}
    n = len(buckets)
    h = sum(hours(b) for b in buckets)
    return {
        "days": n,
        "hours": round(h, 1),
        "total": tot,
        "per_day": {k: round(tot[k] / n, 1) if n else 0 for k in FIELDS},
        "early_end_ratio_per_wave": round(tot["early_end"] / tot["boost_waves"], 3) if tot["boost_waves"] else None,
        "target_changes_per_hour": round(tot["target_changes"] / h, 2) if h else None,
    }


def split_since(path, since):
    """以 since 切兩段，各自按日分桶（跨 since 的那天會被切成兩個半天桶）"""
    before, after = OrderedDict(), OrderedDict()
    for t, msg in parse(path):
        target = after if t >= since else before
        d = t.strftime("%Y-%m-%d")
        b = target.setdefault(d, new_bucket())
        b["first"] = b["first"] or t
        b["last"] = t
    # 重算一次各欄位（沿用 collect 的狀態機，才不會在切點把接管判錯）
    _, events = collect(path)
    for t, f in events:
        target = after if t >= since else before
        target[t.strftime("%Y-%m-%d")][f] += 1
    return before, after


def fmt_ratio(r):
    return "—" if r is None else f"{r * 100:.0f}%"


def print_table(days):
    head = (f"{'日期':<10}  {'涵蓋h':>5}  {'接管':>4}  {'交還':>4}  {'預熱事件':>8}  {'預熱波次':>8}  {'提早結束':>8}  {'比例/波':>6}  "
            f"{'加碼':>4}  {'學到':>4}  {'略過':>4}  {'目標變更/h':>9}")
    print(head)
    for d, b in days.items():
        h = hours(b)
        ratio = fmt_ratio(b["early_end"] / b["boost_waves"] if b["boost_waves"] else None)
        print(f"{d:<10}  {h:>5.1f}  {b['takeovers']:>4}  {b['handbacks']:>4}  {b['boost_events']:>8}  {b['boost_waves']:>8}  {b['early_end']:>8}  {ratio:>6}  "
              f"{b['escalations']:>4}  {b['learned']:>4}  {b['skipped']:>4}  {b['target_changes'] / h:>9.2f}")


def print_summary(name, s):
    t, p = s["total"], s["per_day"]
    print(f"{name}：{s['days']} 天、{s['hours']} 小時")
    print(f"  接管 {t['takeovers']}（{p['takeovers']}/日）、交還 {t['handbacks']}（{p['handbacks']}/日）、"
          f"預熱 {t['boost_waves']} 波（{p['boost_waves']}/日；事件 {t['boost_events']} 行）、"
          f"提早結束 {t['early_end']}（按波次 {fmt_ratio(s['early_end_ratio_per_wave'])}）")
    print(f"  加碼 {t['escalations']}、學到 {t['learned']}、略過預熱 {t['skipped']}；目標變更 {s['target_changes_per_hour']}/小時")


def main():
    ap = argparse.ArgumentParser(description="cool42 log 使用體驗指標")
    ap.add_argument("--log", default="/var/log/cool42.log")
    ap.add_argument("--since", help="改版時間點，例如 '2026-09-26 00:00'；切成之前 / 之後比較")
    ap.add_argument("--json", action="store_true", help="輸出 JSON")
    a = ap.parse_args()
    try:
        days, _ = collect(a.log)
    except OSError as e:
        sys.exit(f"讀不到 {a.log}：{e}")
    if not days:
        sys.exit(f"{a.log} 沒有可解析的 log 行")

    out = {"log": a.log, "days": {d: {k: b[k] for k in FIELDS} | {"hours": round(hours(b), 1)} for d, b in days.items()},
           "all": summarize(list(days.values()))}
    since = None
    if a.since:
        try:
            since = datetime.fromisoformat(a.since)
        except ValueError:
            sys.exit(f"--since 看不懂：{a.since}（用 'YYYY-MM-DD HH:MM'）")
        before, after = split_since(a.log, since)
        out["since"] = a.since
        out["before"] = summarize(list(before.values())) if before else None
        out["after"] = summarize(list(after.values())) if after else None

    if a.json:
        print(json.dumps(out, ensure_ascii=False, indent=2, default=str))
        return
    print_table(days)
    print()
    print_summary("全部", out["all"])
    if since:
        print()
        for name in ("before", "after"):
            s = out[name]
            label = f"{'之前' if name == 'before' else '之後'}（{'<' if name == 'before' else '≥'} {a.since}）"
            if s:
                print_summary(label, s)
            else:
                print(f"{label}：沒有資料")


if __name__ == "__main__":
    main()
