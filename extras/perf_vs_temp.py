#!/usr/bin/env python3
"""同一台 Apple Silicon、同一個固定 CPU 負載，量「macOS 原廠自動 vs cool42 曲線 vs 固定轉速」到穩態的差別。

每個檔位：切 cool42 設定（走 guard 熱重載，不直接碰 SMC）→ 確認 guard 真的切過去 →
等溫度（與非固定檔位的轉速）穩定 → 取樣 powermetrics，記錄溫度、rpm、P-core 頻率、CPU 功率、
工作量（sha256 計數）、ops/J、thermal pressure。

檔位（--modes，依序執行，可重複 --repeat 次做 A/B/A/B）：
    curve   使用者現行設定檔裡的曲線（mode=curve，曲線原封不動）
    auto    mode=auto：guard 把風扇交還 SMC，由 macOS 原廠控制（guard 仍在跑、仍讀溫度）
    3000    固定 3000 rpm（mode=fixed, fixedRPM=3000）；也可寫 fixed:3000

用法（要 sudo：powermetrics 需要 root）：
    python3 extras/perf_vs_temp.py --dry-run                        # 不碰 root、不寫設定，只印計畫與預估時間
    sudo python3 extras/perf_vs_temp.py                             # 預設 curve → auto
    sudo python3 extras/perf_vs_temp.py --modes curve auto --repeat 2 --sample 90
    sudo python3 extras/perf_vs_temp.py --modes curve auto 4900 3000 2000
    sudo python3 extras/perf_vs_temp.py --load-cmd "ffmpeg -i in.mov -f null -"   # 自訂負載（工作量改以 MHz/W 近似）
    過夜跑請用 extras/run_perf_overnight.sh（空閒檢查、防睡、完成通知）。

安全：
  * 控制溫度 ≥ --abort-temp 就放棄該檔（所有檔位）；固定轉速檔位另外在 pressure 進 Heavy 時放棄。
    curve / auto 本身就是會自己保護晶片的控制策略，Heavy 是要量的結果，照樣取樣並記錄。
  * 結束（正常、Ctrl-C、SIGTERM/SIGHUP、例外）一律把設定檔「原位元組」寫回，guard 熱重載回原設定。
    直接覆寫不換 inode，檔案擁有者不變，面板照樣能寫。
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import multiprocessing as mp
import os
import platform
import pwd
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

COOL42 = shutil.which("cool42") or "/usr/local/bin/cool42"
POWERMETRICS = "/usr/bin/powermetrics"
# launchd 的 guard 不帶 --config，只讀 Config.defaultPaths[0]；熱重載只盯它載入的那一份
GUARD_CONFIG = "/etc/cool42/config.json"
GUARD_LOG = "/var/log/cool42.log"
PRESSURE_RANK = {"Nominal": 0, "Moderate": 1, "Heavy": 2, "Trapping": 3, "Sleeping": 4}
PM_OVERHEAD_S = 10   # powermetrics 啟動 + 收尾的估算餘裕（用於時間上限估算）


class Interrupted(BaseException):
    """SIGTERM / SIGHUP 轉成例外，走同一條 finally 還原路徑。
    繼承 BaseException（和 KeyboardInterrupt 一樣）：不會被沿路的 `except Exception` 吞掉，
    尤其不能在 write_config_bytes 的 write 與 truncate 之間被吃掉、留下半新半舊的 JSON。"""


# ---------- 檔位 ----------

class Mode:
    def __init__(self, kind: str, rpm: float | None = None):
        self.kind, self.rpm = kind, rpm

    @property
    def label(self) -> str:
        return f"fixed-{self.rpm:.0f}" if self.kind == "fixed" else self.kind

    @property
    def title(self) -> str:
        if self.kind == "fixed":
            return f"固定 {self.rpm:.0f} rpm"
        return {"curve": "cool42 曲線", "auto": "macOS 原廠自動"}[self.kind]


def parse_modes(tokens: list[str]) -> list[Mode]:
    out = []
    for t in tokens:
        t = t.strip().lower()
        if t in ("curve", "auto"):
            out.append(Mode(t))
            continue
        m = re.fullmatch(r"(?:fixed[:=]?)?(\d+(?:\.\d+)?)(?:rpm)?", t)
        if not m:
            raise argparse.ArgumentTypeError(f"看不懂檔位 {t!r}：用 curve、auto、或轉速數字（例如 3000 / fixed:3000）")
        out.append(Mode("fixed", float(m.group(1))))
    return out


def mode_config(base: dict, mode: Mode) -> dict:
    """以原設定為底，只改 mode（與 fixedRPM）；曲線、門檻、提示音全部原封不動。"""
    cfg = json.loads(json.dumps(base))
    cfg["mode"] = mode.kind
    if mode.kind == "fixed":
        cfg["fixedRPM"] = float(mode.rpm)
    return cfg


# ---------- cool42 / powermetrics ----------

def cool42_status() -> dict:
    p = subprocess.run([COOL42, "status", "--json"], capture_output=True, text=True, timeout=20)
    if p.returncode != 0:
        raise RuntimeError(f"cool42 status 失敗：{p.stderr.strip()}")
    return json.loads(p.stdout)


def s_temp(s: dict) -> float:
    return float(s.get("controlTemp") or s.get("cpuMax") or 0)


def s_rpm(s: dict) -> float | None:
    fans = s.get("fans") or []
    return float(fans[0]["rpm"]) if fans else None


def fan_limits(s: dict) -> tuple[float, float]:
    fans = s.get("fans") or []
    if not fans:
        return 0.0, 5000.0
    return float(fans[0].get("min", 0)), float(fans[0].get("max", 5000))


def boost_active(s: dict) -> bool:
    b = s.get("boostUntil")
    if not b:
        return False
    try:
        t = datetime.fromisoformat(str(b).replace("Z", "+00:00"))
        return t > datetime.now(timezone.utc)
    except ValueError:
        return True


def write_config_bytes(path: str, data: bytes) -> None:
    """原位覆寫（O_TRUNC，不換 inode、不改擁有者）。guard 讀到半截會保留舊設定、下一輪重試。"""
    with open(path, "r+b") as f:
        f.seek(0)
        f.write(data)
        f.truncate()
        f.flush()
        os.fsync(f.fileno())


def write_config(path: str, cfg: dict) -> None:
    write_config_bytes(path, (json.dumps(cfg, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode())


def parse_powermetrics(out: str) -> dict:
    def avg(pattern: str):
        vals = [float(m) for m in re.findall(pattern, out)]
        return sum(vals) / len(vals) if vals else None
    pressures = re.findall(r"Current pressure level:\s*(\w+)", out)
    return {
        "cpu_mw": avg(r"CPU Power:\s*([\d.]+)\s*mW"),
        "gpu_mw": avg(r"GPU Power:\s*([\d.]+)\s*mW"),
        "pcluster_mhz": avg(r"P-Cluster HW active frequency:\s*([\d.]+)\s*MHz"),
        "ecluster_mhz": avg(r"E-Cluster HW active frequency:\s*([\d.]+)\s*MHz"),
        "pressure_worst": worst_pressure(pressures),
        "pm_samples": len(re.findall(r"CPU Power:", out)),
    }


def worst_pressure(levels) -> str | None:
    levels = [l for l in levels if l]
    return max(levels, key=lambda l: PRESSURE_RANK.get(l, -1)) if levels else None


# ---------- 固定 CPU 負載 ----------

def _worker(counter, stop):
    """每 worker 一直做 sha256，每 2000 次把計數器 +1。工作量固定、可跨檔位比較。"""
    signal.signal(signal.SIGINT, signal.SIG_IGN)   # Ctrl-C 交給主行程處理，worker 等 stop 旗標
    data = b"cool42-perf-vs-temp" * 8
    while not stop.value:
        h = data
        for _ in range(2000):
            h = hashlib.sha256(h).digest()
        with counter.get_lock():
            counter.value += 1


class HashLoad:
    def __init__(self, workers: int):
        self.workers = workers
        self.counter = mp.Value("q", 0)
        self.stop = mp.Value("b", 0)
        self.procs = [mp.Process(target=_worker, args=(self.counter, self.stop), daemon=True) for _ in range(workers)]

    def describe(self) -> str:
        return f"{self.workers} 個 sha256 worker"

    def start(self):
        for p in self.procs:
            p.start()

    def read(self) -> int:
        return self.counter.value

    def close(self):
        self.stop.value = 1
        for p in self.procs:
            if p.pid is None:
                continue
            p.join(timeout=5)
            if p.is_alive():
                p.kill()


class CmdLoad:
    """自訂負載指令；結束時 kill 整個 process group。工作量沒法量，只能用頻率近似。"""
    def __init__(self, cmd: str):
        self.cmd = cmd
        self.proc = None

    def describe(self) -> str:
        return f"指令 {self.cmd}"

    def start(self):
        self.proc = subprocess.Popen(self.cmd, shell=True, start_new_session=True,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def read(self) -> int:
        return 0

    def close(self):
        if self.proc and self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)


# ---------- 時間估算 ----------

def step_bounds(args) -> tuple[int, int]:
    """單一檔位的（最短, 最長）秒數，全部由參數推出，不是量測值。"""
    lo = args.min_settle + args.sample
    hi = args.confirm_timeout + args.settle_max + args.sample + PM_OVERHEAD_S
    return lo, hi


def fmt_dur(sec: float) -> str:
    sec = int(round(sec))
    if sec < 60:
        return f"{sec} 秒"
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{h} 小時 {m} 分" if h else (f"{m} 分 {s} 秒" if s and m < 10 else f"{m} 分")


# ---------- 主流程各步 ----------

def apply_mode(mode: Mode, base: dict, path: str, args, log) -> dict:
    """寫設定並確認 guard 已熱重載到該檔位；逾時丟 RuntimeError（外層會還原）。"""
    before = cool42_status()
    prev_target = before.get("guardTargetRPM")
    write_config(path, mode_config(base, mode))
    fmin, fmax = fan_limits(before)
    want = min(max(mode.rpm, fmin), fmax) if mode.kind == "fixed" else None
    t0 = time.time()
    s = before
    while time.time() - t0 < args.confirm_timeout:
        time.sleep(2)
        s = cool42_status()
        if not s.get("guardRunning"):
            raise RuntimeError("guard 停了（guardRunning=false），無法繼續")
        if s.get("guardMode") != mode.kind:
            continue
        tgt = s.get("guardTargetRPM")
        if mode.kind == "auto" and tgt is None:
            break
        if mode.kind == "curve":
            break
        if mode.kind == "fixed" and tgt is not None:
            # 斜率限制讓目標一輪最多動 maxRampUp/Down，所以「已經朝新值移動」就算切過去了
            if abs(tgt - want) <= 160 or prev_target is None or abs(tgt - want) < abs(prev_target - want) - 1:
                break
    else:
        raise RuntimeError(f"guard {args.confirm_timeout}s 內沒切到 {mode.label}（guardMode={s.get('guardMode')}, "
                           f"target={s.get('guardTargetRPM')}）：可能沒載入 {path} 或解析失敗，看 {GUARD_LOG}")
    tgt = s.get("guardTargetRPM")
    log(f"   guard 已切到 {mode.label}（{time.time() - t0:.0f}s，目標 {'交還 SMC' if tgt is None else f'{tgt:.0f} rpm'}）")
    return s


def wait_for_steady(mode: Mode, args, log) -> tuple[str, str, list]:
    """回傳 (state, reason, trace)。state: converged / timeout（仍取樣）/ aborted（不取樣）。"""
    trace = []
    t0 = time.time()
    need = max(2, args.settle_window // args.poll)
    while True:
        s = cool42_status()
        temp, rpm, pr = s_temp(s), s_rpm(s), s.get("thermalPressure")
        trace.append({"t": round(time.time() - t0, 1), "temp": temp, "rpm": rpm, "pcore": s.get("pcoreMHz"),
                      "pressure": pr, "boost": boost_active(s)})
        el = trace[-1]["t"]
        log(f"    t+{el:4.0f}s  {temp:5.1f}°C  {rpm or 0:5.0f}rpm  P={s.get('pcoreMHz') or 0:4.0f}MHz  {pr or '-'}"
            f"{'  [預熱中]' if trace[-1]['boost'] else ''}")
        if temp >= args.abort_temp:
            return "aborted", f"溫度 {temp:.1f}°C ≥ {args.abort_temp:g}，中止", trace
        if mode.kind == "fixed" and PRESSURE_RANK.get(pr or "Nominal", 0) >= PRESSURE_RANK["Heavy"]:
            return "aborted", f"thermal pressure {pr}（固定轉速檔位），中止", trace
        win = trace[-need:]
        if el >= args.min_settle and len(win) >= need:
            dt = max(w["temp"] for w in win) - min(w["temp"] for w in win)
            rpms = [w["rpm"] for w in win if w["rpm"] is not None]
            dr = (max(rpms) - min(rpms)) if rpms else 0
            if dt < args.settle_delta and (mode.kind == "fixed" or dr < args.settle_rpm_delta):
                return "converged", f"穩態（{args.settle_window}s 內 ΔT {dt:.1f}°C、Δrpm {dr:.0f}）", trace
        if el > args.settle_max:
            return "timeout", f"超過 {args.settle_max}s 未收斂，以現況取樣", trace
        time.sleep(args.poll)


def sample_mode(mode: Mode, load, args, log, pm_path: str) -> dict:
    """powermetrics 取樣 --sample 秒，期間每 --poll 秒讀 cool42 溫度/轉速取平均。"""
    c0 = load.read()
    t0 = time.time()
    with open(pm_path, "w") as pmf:
        pm = subprocess.Popen([POWERMETRICS, "--samplers", "cpu_power,gpu_power,thermal", "-i", "1000",
                               "-n", str(args.sample)], stdout=pmf, stderr=subprocess.STDOUT)
        polls, aborted = [], None
        try:
            while pm.poll() is None:
                if time.time() - t0 > args.sample + 30:
                    pm.kill()
                    raise RuntimeError("powermetrics 逾時")
                s = cool42_status()
                polls.append(s)
                if s_temp(s) >= args.abort_temp:
                    aborted = f"取樣中溫度 {s_temp(s):.1f}°C ≥ {args.abort_temp:g}，中止"
                    pm.terminate()
                    break
                time.sleep(args.poll)
        finally:
            if pm.poll() is None:
                pm.terminate()
                try:
                    pm.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pm.kill()
    dt = time.time() - t0
    ops = load.read() - c0
    if pm.returncode not in (0, None) and not aborted:
        with open(pm_path) as f:
            raise RuntimeError(f"powermetrics 失敗（{pm.returncode}）：{f.read()[-300:]}")
    with open(pm_path) as f:
        pmd = parse_powermetrics(f.read())
    temps = [s_temp(s) for s in polls]
    rpms = [r for r in (s_rpm(s) for s in polls) if r is not None]
    cpu_w = (pmd["cpu_mw"] or 0) / 1000 or None
    pcore = pmd["pcluster_mhz"] or (sum(p.get("pcoreMHz") or 0 for p in polls) / len(polls) if polls else None)
    row = {
        "temp_c": mean(temps), "temp_max_c": max(temps) if temps else None,
        "cpu_max_c": mean([s.get("cpuMax") for s in polls]), "gpu_max_c": mean([s.get("gpuMax") for s in polls]),
        "rpm_actual": mean(rpms), "rpm_min": min(rpms) if rpms else None, "rpm_max": max(rpms) if rpms else None,
        "pcore_mhz": pcore, "ecore_mhz": pmd["ecluster_mhz"],
        "cpu_w": cpu_w, "gpu_w": (pmd["gpu_mw"] or 0) / 1000,
        "pressure": worst_pressure([pmd["pressure_worst"]] + [s.get("thermalPressure") for s in polls]),
        "ops": ops, "sample_s": round(dt, 1), "pm_samples": pmd["pm_samples"],
        "boost_seen": any(boost_active(s) for s in polls),
        "powermetrics_file": os.path.basename(pm_path),
    }
    row["ops_per_s"] = ops / dt if (dt and ops) else None
    row["ops_per_j"] = ops / (cpu_w * dt) if (cpu_w and dt and ops) else None
    row["mhz_per_w"] = pcore / cpu_w if (cpu_w and pcore) else None
    if aborted:
        row["abort_during_sample"] = aborted
    return row


def mean(vals):
    vals = [v for v in vals if v is not None]
    return sum(vals) / len(vals) if vals else None


# ---------- 輸出 ----------

CSV_COLS = ["step", "rep", "mode", "rpm_set", "state", "measured", "settle_s", "temp_c", "temp_max_c", "cpu_max_c",
            "gpu_max_c", "rpm_actual", "rpm_min", "rpm_max", "pcore_mhz", "ecore_mhz", "cpu_w", "gpu_w", "ops",
            "sample_s", "ops_per_s", "ops_per_j", "mhz_per_w", "pressure", "boost_seen", "reason", "started_at"]


def write_outputs(out_dir: str, meta: dict, results: list) -> None:
    with open(os.path.join(out_dir, "results.json"), "w") as f:
        json.dump({"meta": meta, "results": results}, f, ensure_ascii=False, indent=2)
    with open(os.path.join(out_dir, "results.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(CSV_COLS)
        for r in results:
            w.writerow(["" if r.get(c) is None else (f"{r[c]:.4g}" if isinstance(r[c], float) else r[c]) for c in CSV_COLS])
    with open(os.path.join(out_dir, "summary.md"), "w") as f:
        f.write(render_markdown(meta, results))


def aggregate(results: list) -> dict:
    """依檔位彙總有量到的列：平均值與（重複 ≥2 次時）最小–最大。"""
    keys = ["temp_c", "temp_max_c", "rpm_actual", "pcore_mhz", "cpu_w", "ops_per_s", "ops_per_j", "mhz_per_w", "settle_s"]
    agg = {}
    for r in results:
        a = agg.setdefault(r["mode"], {"mode": r["mode"], "title": r["title"], "n": 0, "n_total": 0, "rows": [],
                                       "pressures": [], "aborted": []})
        a["n_total"] += 1
        if not r.get("measured"):
            a["aborted"].append(r.get("reason"))
            continue
        a["n"] += 1
        a["rows"].append(r)
        a["pressures"].append(r.get("pressure"))
    for a in agg.values():
        for k in keys:
            vals = [r.get(k) for r in a["rows"] if r.get(k) is not None]
            a[k] = sum(vals) / len(vals) if vals else None
            a[k + "_range"] = (min(vals), max(vals)) if len(vals) >= 2 else None
        a["pressure"] = worst_pressure(a["pressures"])
    return agg


def _f(v, fmt="{:.1f}", dash="—"):
    return dash if v is None else fmt.format(v)


def _pct(a, b):
    return None if (a is None or b in (None, 0)) else (a / b - 1) * 100


def render_markdown(meta: dict, results: list) -> str:
    agg = aggregate(results)
    L = []
    L.append("# macOS 原廠自動 vs cool42 曲線：同機同負載穩態對照\n")
    L.append(f"- 機器：{meta.get('chip')}（{meta.get('model')}），macOS {meta.get('macos')}，{meta.get('ncpu')} 核")
    L.append(f"- 時間：{meta.get('started_at')} → {meta.get('finished_at') or '（未完成）'}")
    L.append(f"- 負載：{meta.get('load')}；每檔取樣 {meta['args']['sample']} 秒；穩態判準 "
             f"{meta['args']['settle_window']} 秒內 ΔT < {meta['args']['settle_delta']}°C"
             f"（非固定檔位另要 Δrpm < {meta['args']['settle_rpm_delta']:g}），最短 {meta['args']['min_settle']} 秒、最長 {meta['args']['settle_max']} 秒")
    L.append(f"- 順序：{' → '.join(meta.get('plan', []))}")
    L.append(f"- 起始：控制溫度 {_f(meta.get('start_temp'))}°C，load avg {meta.get('start_loadavg')}")
    if meta.get("curve"):
        L.append("- cool42 曲線（量測時的設定）：" + "、".join(f"{p['temp']:g}°C→{p['rpm']:g}" for p in meta["curve"]))
    if meta.get("interrupted"):
        L.append(f"- ⚠ 量測未跑完：{meta['interrupted']}")
    L.append("")
    L.append("## 各檔位穩態（有量到的平均；重複 ≥2 次附最小–最大）\n")
    L.append("| 檔位 | n | 控制溫度 °C | 風扇 rpm | P-core MHz | CPU W | ops/s | ops/J | worst pressure | 到穩態 s |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")

    def cell(a, k, fmt):
        v = _f(a.get(k), fmt)
        rg = a.get(k + "_range")
        return v if not rg else f"{v}（{fmt.format(rg[0])}–{fmt.format(rg[1])}）"
    for a in agg.values():
        if a["n"] == 0:
            L.append(f"| {a['title']} | 0/{a['n_total']} | 未量到：{'；'.join(x or '?' for x in a['aborted'])} |||||||||")
            continue
        L.append(f"| {a['title']} | {a['n']}/{a['n_total']} | {cell(a, 'temp_c', '{:.1f}')} | {cell(a, 'rpm_actual', '{:.0f}')} | "
                 f"{cell(a, 'pcore_mhz', '{:.0f}')} | {cell(a, 'cpu_w', '{:.2f}')} | {cell(a, 'ops_per_s', '{:.1f}')} | "
                 f"{cell(a, 'ops_per_j', '{:.2f}')} | {a['pressure'] or '—'} | {cell(a, 'settle_s', '{:.0f}')} |")
    notes = [r for r in results if r.get("measured") and (r.get("state") == "timeout" or r.get("boost_seen"))]
    for r in notes:
        L.append(f"\n- 第 {r['step']} 步 {r['title']}：" + "；".join(
            x for x in [r["reason"] if r.get("state") == "timeout" else None,
                        "取樣期間 guard 預熱中（有 hook 事件混入）" if r.get("boost_seen") else None] if x))
    L.append("")

    c, a = agg.get("curve"), agg.get("auto")
    L.append("## 原廠 vs cool42\n")
    if not (c and a and c["n"] and a["n"]):
        L.append("curve 與 auto 沒有都量到，無法對照。\n")
    else:
        L.append("| 指標 | macOS 原廠自動 | cool42 曲線 | 差（cool42 − 原廠） |")
        L.append("|---|---|---|---|")
        dt = None if (c["temp_c"] is None or a["temp_c"] is None) else c["temp_c"] - a["temp_c"]
        L.append(f"| 穩態控制溫度 | {_f(a['temp_c'])} °C | {_f(c['temp_c'])} °C | {_f(dt, '{:+.1f}')} °C |")
        for k, name, fmt in [("pcore_mhz", "P-core 頻率", "{:.0f} MHz"), ("rpm_actual", "風扇轉速", "{:.0f} rpm"),
                             ("cpu_w", "CPU 功率", "{:.2f} W"), ("ops_per_s", "工作量 ops/s", "{:.1f}"),
                             ("ops_per_j", "能效 ops/J", "{:.2f}")]:
            L.append(f"| {name} | {_f(a[k], fmt)} | {_f(c[k], fmt)} | {_f(_pct(c[k], a[k]), '{:+.1f}')} % |")
        L.append(f"| worst thermal pressure | {a['pressure'] or '—'} | {c['pressure'] or '—'} | |")
        L.append("")
        # 重複量測的散佈：差距比散佈小就不下結論
        for k, name in [("ops_per_j", "ops/J"), ("pcore_mhz", "P-core 頻率")]:
            ra, rc = a.get(k + "_range"), c.get(k + "_range")
            if ra and rc and a[k] and c[k]:
                spread = max((ra[1] - ra[0]) / a[k], (rc[1] - rc[0]) / c[k]) * 100
                diff = abs(_pct(c[k], a[k]) or 0)
                verdict = "差距大於重複量測散佈" if diff > spread else "差距落在重複量測散佈內，不足以下結論"
                L.append(f"- {name}：兩者差 {diff:.1f}%，同檔位重複量測散佈最大 {spread:.1f}% → {verdict}")
        if a["n"] < 2 or c["n"] < 2:
            L.append("- 每個檔位只量到 1 次，沒有散佈可比；要下結論建議 `--repeat 2` 以上（A/B/A/B）。")
        L.append("")
        L.append("### 噪音推估（推論，不是量測）\n")
        if a["rpm_actual"] and c["rpm_actual"]:
            db = 50 * math.log10(c["rpm_actual"] / a["rpm_actual"])
            L.append(f"本次沒有用麥克風量噪音。依風扇相似律（同一顆風扇，聲功率約與轉速 5 次方成正比，"
                     f"ΔL ≈ 50·log10(rpm₂/rpm₁)），cool42 曲線平均 {c['rpm_actual']:.0f} rpm 對原廠 {a['rpm_actual']:.0f} rpm，"
                     f"推估約 **{db:+.1f} dB**。實際聽感還受機殼共振、音調與環境噪音影響，只能當量級參考。")
        else:
            L.append("缺轉速資料，無法推估。")
        L.append("")
    L.append("## 讀法與限制\n")
    L.append("- ops = 每 worker 每 2000 次 sha256 記 1 次；ops/J 用 powermetrics 的 CPU Power（不含 DRAM、風扇、整機）。")
    L.append("- 頻率與功率來自 powermetrics 硬體計數器（`P-Cluster HW active frequency`、`CPU Power`）；溫度與轉速來自 cool42 status。")
    L.append("- 「macOS 原廠自動」= cool42 設定 mode=auto：guard 仍在跑但把風扇交還 SMC，不寫任何轉速。")
    L.append("- 同一台機器、同一負載、同一天；室溫沒控制，順序效應用 A/B/A/B 重複緩解。")
    L.append("- 原始資料：results.json（含每檔穩態過程）、results.csv、pm/*.txt（powermetrics 原始輸出）、perf.log。\n")
    return "\n".join(L)


# ---------- 環境 ----------

def real_user() -> tuple[int | None, int | None, str]:
    """sudo 底下找回真正的使用者（輸出檔要給他、預設輸出放他家目錄）。"""
    uid = os.environ.get("SUDO_UID")
    if uid and os.geteuid() == 0:
        pw = pwd.getpwuid(int(uid))
        return pw.pw_uid, pw.pw_gid, pw.pw_dir
    return None, None, os.path.expanduser("~")


def sh(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return ""


def env_meta() -> dict:
    return {
        "chip": sh(["sysctl", "-n", "machdep.cpu.brand_string"]) or platform.processor(),
        "model": sh(["sysctl", "-n", "hw.model"]),
        "macos": sh(["sw_vers", "-productVersion"]),
        "ncpu": os.cpu_count(),
        "python": platform.python_version(),
    }


def top_busy(s: dict, threshold: float = 50) -> list[str]:
    return [f"{p.get('name', '?')} {p.get('cpuPercent', 0):.0f}%" for p in (s.get("topProcesses") or [])
            if (p.get("cpuPercent") or 0) > threshold]


# ---------- dry-run ----------

def dry_run(args, modes: list[Mode], cfg_path: str) -> None:
    print("== perf_vs_temp dry-run（不需 root、不寫設定、不啟動負載、不跑 powermetrics）==\n")
    base = None
    try:
        with open(cfg_path) as f:
            base = json.load(f)
        print(f"設定檔：{cfg_path}（可讀，現行 mode={base.get('mode')}，fixedRPM={base.get('fixedRPM')}）")
        print("  曲線：" + "  ".join(f"{p['temp']:g}°C→{p['rpm']:g}" for p in base.get("curve", [])))
        print(f"  可寫：{'是' if os.access(cfg_path, os.W_OK) else '否（sudo 跑時以 root 寫入）'}")
    except FileNotFoundError:
        print(f"⚠ 找不到 {cfg_path}：guard 用內建預設、不會熱重載，實跑會直接中止")
    except Exception as e:
        print(f"⚠ 讀不了 {cfg_path}：{e}")
    s = None
    if os.path.exists(COOL42):
        try:
            s = cool42_status()
            fmin, fmax = fan_limits(s)
            print(f"cool42：guard {'跑著' if s.get('guardRunning') else '沒跑（實跑會中止）'}，guardMode={s.get('guardMode')}，"
                  f"現在 {s_temp(s):.1f}°C / {s_rpm(s) or 0:.0f} rpm，風扇範圍 {fmin:.0f}–{fmax:.0f} rpm")
            busy = top_busy(s)
            if busy:
                print("⚠ 現在有重活：" + "、".join(busy))
        except Exception as e:
            print(f"⚠ cool42 status 失敗：{e}")
    else:
        print(f"⚠ 找不到 cool42（{COOL42}）")
    la = os.getloadavg()
    print(f"load avg：{la[0]:.2f} {la[1]:.2f} {la[2]:.2f}（{os.cpu_count()} 核）")
    print(f"powermetrics：{'有' if os.path.exists(POWERMETRICS) else '沒有'}；實跑需 root：{'是（目前不是 root）' if os.geteuid() else '是（目前是 root）'}")
    print(f"\n負載：{'指令 ' + args.load_cmd if args.load_cmd else f'{args.workers} 個 sha256 worker'}")
    print(f"安全：控制溫度 ≥ {args.abort_temp:g}°C 中止該檔；固定轉速檔位 pressure ≥ Heavy 也中止；結束一律寫回原設定位元組\n")
    lo, hi = step_bounds(args)
    steps = [(rep, m) for rep in range(1, args.repeat + 1) for m in modes]
    print("計畫：")
    for i, (rep, m) in enumerate(steps, 1):
        change = f"mode={m.kind}" + (f", fixedRPM={m.rpm:g}" if m.kind == "fixed" else "")
        warn = ""
        if m.kind == "fixed" and s:
            fmin, fmax = fan_limits(s)
            if not (fmin <= m.rpm <= fmax):
                warn = f"  ⚠ 超出 {fmin:.0f}–{fmax:.0f}，guard 會夾到範圍內"
        extra = "（Heavy 照樣取樣）" if m.kind != "fixed" else ""
        print(f"  {i:2d}. 第 {rep} 輪  {m.title:<14} 設定改 {change}{extra}{warn}")
    print(f"  最後：寫回原設定（{'原 mode=' + str(base.get('mode')) if base else '原檔'}），確認 guard 重載")
    print(f"\n預估：每檔 {fmt_dur(lo)}（最快收斂）～ {fmt_dur(hi)}（上限）；"
          f"{len(steps)} 檔共 {fmt_dur(lo * len(steps))} ～ {fmt_dur(hi * len(steps))}")
    uid, gid, home = real_user()
    print(f"輸出：{args.out_dir or os.path.join(home, 'cool42-perf-<時間>')}/  perf.log results.json results.csv summary.md pm/*.txt")


# ---------- main ----------

def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--modes", nargs="+", default=["curve", "auto"], metavar="MODE",
                    help="檔位順序：curve、auto、或固定轉速數字（預設 curve auto）")
    ap.add_argument("--rpm", nargs="+", type=float, default=[], help="（舊參數）額外附加的固定轉速檔位，接在 --modes 後面")
    ap.add_argument("--repeat", type=int, default=1, help="整組檔位重複幾輪（2 = A/B/A/B，才看得出散佈）")
    ap.add_argument("--workers", type=int, default=os.cpu_count(), help="hash 負載的行程數（預設全部核心）")
    ap.add_argument("--load-cmd", help="用自訂指令當負載（例如 ffmpeg / blender）；此時工作量用 P-cluster MHz/W 近似")
    ap.add_argument("--sample", type=int, default=60, help="每檔穩態後 powermetrics 取樣秒數")
    ap.add_argument("--poll", type=int, default=5, help="讀 cool42 status 的間隔（秒）；guard 本身 5 秒一輪")
    ap.add_argument("--settle-window", type=int, default=60, help="穩態判定視窗（秒）")
    ap.add_argument("--settle-delta", type=float, default=1.5, help="視窗內溫度變化小於此值才算穩態（°C）")
    ap.add_argument("--settle-rpm-delta", type=float, default=200, help="curve/auto 檔位視窗內轉速變化也要小於此值（rpm）")
    ap.add_argument("--min-settle", type=int, default=120, help="每檔至少等多久才判穩態（秒；避免剛切檔、風扇還在爬就誤判）")
    ap.add_argument("--settle-max", type=int, default=480, help="每檔最多等多久（秒），到了以現況取樣並標記未收斂")
    ap.add_argument("--confirm-timeout", type=int, default=25, help="寫設定後等 guard 熱重載確認的上限（秒）")
    ap.add_argument("--abort-temp", type=float, default=103, help="控制溫度到此值就放棄該檔（所有檔位）")
    ap.add_argument("--config", default=GUARD_CONFIG, help=f"guard 讀的設定檔（預設 {GUARD_CONFIG}，launchd guard 只讀這份）")
    ap.add_argument("--out-dir", default=None, help="輸出資料夾（預設 ~/cool42-perf-<時間>/，sudo 下是原使用者的家目錄）")
    ap.add_argument("--dry-run", action="store_true", help="不碰 root、不寫設定、不跑負載，只印計畫與預估時間")
    return ap


def main(argv: list[str] | None = None) -> int:
    ap = build_parser()
    args = ap.parse_args(argv)
    try:
        modes = parse_modes(args.modes) + [Mode("fixed", r) for r in args.rpm]
    except argparse.ArgumentTypeError as e:
        ap.error(str(e))
    if args.repeat < 1 or args.sample < 5 or args.poll < 1:
        ap.error("--repeat ≥ 1、--sample ≥ 5、--poll ≥ 1")
    cfg_path = args.config

    if args.dry_run:
        dry_run(args, modes, cfg_path)
        return 0

    if os.geteuid() != 0:
        sys.exit("需要 sudo：powermetrics 要 root（先用 --dry-run 看計畫）")
    if not os.path.exists(COOL42):
        sys.exit(f"找不到 cool42（{COOL42}）")
    if not os.path.exists(cfg_path):
        sys.exit(f"找不到 {cfg_path}：guard 沒載入設定檔就不會熱重載，切檔位不會生效")
    with open(cfg_path, "rb") as f:
        backup = f.read()
    try:
        base = json.loads(backup)
    except ValueError as e:
        sys.exit(f"{cfg_path} 不是合法 JSON：{e}")

    uid, gid, home = real_user()
    out_dir = args.out_dir or os.path.join(home, f"cool42-perf-{datetime.now():%Y%m%d-%H%M}")
    os.makedirs(os.path.join(out_dir, "pm"), exist_ok=True)
    logf = open(os.path.join(out_dir, "perf.log"), "a")

    def log(msg: str):
        # 終端機關掉（SIGHUP、tee 斷掉）時 print 會 BrokenPipe；log 檔照寫，不能讓它打斷還原
        try:
            print(msg, flush=True)
        except OSError:
            pass
        if not logf.closed:
            logf.write(msg + "\n")
            logf.flush()

    restored = {"done": False}

    def restore(reason: str):
        if restored["done"]:
            return
        restored["done"] = True
        try:
            write_config_bytes(cfg_path, backup)
            log(f"已寫回原設定（{reason}）")
        except OSError as e:
            log(f"⚠⚠ 寫回原設定失敗：{e}；請手動確認 {cfg_path}")
            return
        # 確認 guard 已重載回原模式（盡力而為，不拋錯）
        want = base.get("mode", "curve")
        for _ in range(max(1, args.confirm_timeout // 2)):
            try:
                if cool42_status().get("guardMode") == want:
                    log(f"guard 已回到原模式 {want}")
                    return
            except Exception:
                pass
            time.sleep(2)
        log(f"⚠ {args.confirm_timeout}s 內沒看到 guard 回到 {want}，請看 {GUARD_LOG}")

    def on_signal(signum, frame):
        raise Interrupted(signal.Signals(signum).name)
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGHUP, on_signal)

    steps = [(rep, m) for rep in range(1, args.repeat + 1) for m in modes]
    lo, hi = step_bounds(args)
    meta = {**env_meta(), "started_at": f"{datetime.now():%Y-%m-%d %H:%M:%S}", "finished_at": None,
            "plan": [f"{m.title}#{rep}" for rep, m in steps], "curve": base.get("curve"),
            "original_mode": base.get("mode"), "args": vars(args), "load": None,
            "start_loadavg": " ".join(f"{x:.2f}" for x in os.getloadavg()), "interrupted": None}
    results = []
    load = None
    run_t0 = time.time()
    try:
        s0 = cool42_status()
        meta["start_temp"] = s_temp(s0)
        log(f"== cool42 perf-vs-temp  {meta['started_at']} ==")
        log(f"{meta['chip']}（{meta['model']}），macOS {meta['macos']}，{meta['ncpu']} 核，起始 {s_temp(s0):.1f}°C，"
            f"load avg {meta['start_loadavg']}，原設定 mode={base.get('mode')}")
        if not s0.get("guardRunning"):
            raise RuntimeError("cool42 guard 沒在跑，切檔位不會生效；先把 guard 起來（cool42 doctor）")
        busy = top_busy(s0)
        if busy:
            log("⚠ 現在有別的重活在跑，量出來會混到：" + "、".join(busy) + "；10 秒後繼續，Ctrl-C 取消")
            time.sleep(10)
        log(f"計畫 {len(steps)} 檔：{' → '.join(meta['plan'])}")
        log(f"預估 {fmt_dur(lo * len(steps))}（全部最快收斂）～ {fmt_dur(hi * len(steps))}（上限）")

        load = CmdLoad(args.load_cmd) if args.load_cmd else HashLoad(args.workers)
        meta["load"] = load.describe()
        load.start()
        log(f"負載已啟動：{meta['load']}")
        for i, (rep, mode) in enumerate(steps, 1):
            el = time.time() - run_t0
            left = len(steps) - i + 1
            log(f"\n-- [{i}/{len(steps)}] {mode.title}（第 {rep} 輪）  已過 {fmt_dur(el)}，剩餘預估 "
                f"{fmt_dur(lo * left)}～{fmt_dur(hi * left)} --")
            row = {"step": i, "rep": rep, "mode": mode.label, "title": mode.title, "rpm_set": mode.rpm,
                   "started_at": f"{datetime.now():%H:%M:%S}"}
            results.append(row)
            st = time.time()
            apply_mode(mode, base, cfg_path, args, log)
            state, reason, trace = wait_for_steady(mode, args, log)
            row.update({"state": state, "reason": reason, "settle_s": round(time.time() - st, 1), "trace": trace})
            log(f"   {reason}")
            if state == "aborted":
                row["measured"] = False
                last = trace[-1] if trace else {}
                row.update({"temp_c": last.get("temp"), "rpm_actual": last.get("rpm"), "pcore_mhz": last.get("pcore"),
                            "pressure": last.get("pressure")})
                continue
            log(f"   取樣 {args.sample}s ...")
            pm_file = os.path.join(out_dir, "pm", f"{i:02d}-{mode.label}-r{rep}.txt")
            srow = sample_mode(mode, load, args, log, pm_file)
            row.update(srow)
            row["measured"] = "abort_during_sample" not in srow
            if not row["measured"]:
                row["state"], row["reason"] = "aborted", srow["abort_during_sample"]
            log(f"   => {_f(row.get('temp_c'))}°C  {_f(row.get('rpm_actual'), '{:.0f}')}rpm  "
                f"P={_f(row.get('pcore_mhz'), '{:.0f}')}MHz  CPU {_f(row.get('cpu_w'), '{:.2f}')}W  "
                f"ops/s={_f(row.get('ops_per_s'))}  ops/J={_f(row.get('ops_per_j'), '{:.2f}')}  {row.get('pressure') or '-'}")
    except KeyboardInterrupt:
        meta["interrupted"] = "使用者中斷（Ctrl-C）"
        log("\n使用者中斷")
    except Interrupted as e:
        meta["interrupted"] = f"收到 {e}"
        log(f"\n收到 {e}，收尾")
    except Exception as e:
        meta["interrupted"] = f"例外：{e}"
        log(f"\n⚠ 例外：{e}")
    finally:
        # 收尾期間三種訊號都不理：再按一次 Ctrl-C、關機時 launchd 的 TERM、終端機被關掉的 HUP 都不能打斷還原
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        # 先還原設定、再停負載：HashLoad.close() 每個 worker join 最多 5 秒（10 核最多約 50 秒），不能擋在還原前面
        restore(meta["interrupted"] or "量測完成")
        if load:
            load.close()
        meta["finished_at"] = f"{datetime.now():%Y-%m-%d %H:%M:%S}"
        meta["elapsed_s"] = round(time.time() - run_t0, 1)
        try:
            write_outputs(out_dir, meta, results)
        except Exception as e:
            log(f"⚠ 寫輸出失敗：{e}")
        log(f"\n總耗時 {fmt_dur(meta['elapsed_s'])}")
        logf.close()
        if uid is not None:   # sudo 下產出的檔案還給原使用者
            for root, dirs, files in os.walk(out_dir):
                for n in [root] + [os.path.join(root, x) for x in files]:
                    try:
                        os.chown(n, uid, gid)
                    except OSError:
                        pass

    try:
        print("\n" + render_markdown(meta, results))
        print(f"輸出：{out_dir}/  summary.md  results.json  results.csv  perf.log  pm/")
    except OSError:
        pass
    return 1 if meta["interrupted"] else 0


if __name__ == "__main__":
    sys.exit(main())
