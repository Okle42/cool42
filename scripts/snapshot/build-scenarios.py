#!/usr/bin/env python3
"""把 capture-load.sh 抓到的真實取樣整理成截圖情境檔（scripts/snapshot/scenarios/*.json）。

  python3 scripts/snapshot/build-scenarios.py CAPTURE_DIR

idle / load：直接取自實機 state.json、history.json 與 `cool42 sensors`（SMC，不需 root）。
throttle：**受控情境、不是實機紀錄** —— 近 94 小時的 /var/log/cool42.log 裡降頻 0 秒，沒有真實降頻可截。
  以 load 的真實取樣為底，只改 thermal pressure、P-core 頻率、溫度與風扇（數值見 THROTTLE），情境檔的 note 會寫明。

隱私：topProcesses 的 cwd 一律拿掉；閒置情境不帶 process 清單（實機當時是瀏覽器與 WindowServer）。
"""
import json, os, re, sys, glob

cap = sys.argv[1]
out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scenarios")
os.makedirs(out_dir, exist_ok=True)

def sensors(path):
    d = {}
    for line in open(path):
        m = re.match(r"^(T[peg]\w\w)\s+([\d.]+)", line)
        if m: d[m.group(1)] = float(m.group(2))
    return d

def samples(phase):
    out = []
    for p in glob.glob(os.path.join(cap, phase, "state-*.json")):
        i = re.search(r"state-(\d+)", p).group(1)
        out.append((int(i), json.load(open(p)), sensors(os.path.join(cap, phase, f"sensors-{i}.txt"))))
    return sorted(out, key=lambda x: x[0])

def strip(s):
    s = dict(s)
    s.pop("cpuKeys", None); s.pop("gpuKeys", None)
    if s.get("topProcesses"):
        s["topProcesses"] = [{k: v for k, v in p.items() if k != "cwd"} for p in s["topProcesses"]]
    return s

def dump(name, snap, hist, sens, note, **extra):
    doc = {"note": note, "snapshot": snap, "history": hist, "sensors": {k: round(v, 1) for k, v in sorted(sens.items())}, **extra}
    path = os.path.join(out_dir, name + ".json")
    json.dump(doc, open(path, "w"), ensure_ascii=False, indent=1)
    print(path, f"cpu {snap['cpuMax']:.1f}°C  fan {snap['fans'][0]['rpm']:.0f}  P {snap.get('pcoreMHz')}  sensors {len(sens)}  history {len(hist)}")

# 閒置：取 CPU 最冷的一筆
idle = samples("idle")
i, s, sens = min(idle, key=lambda x: x[1]["cpuMax"])
s = strip(s); s["topProcesses"] = None; s["boostUntil"] = None
dump("idle", s, json.load(open(os.path.join(cap, "idle", "history.json"))), sens,
     f"實機取樣（Mac mini M4，閒置，idle/state-{i}.json）")

# 重載：ffmpeg libx264 4K 編碼跑到最後一筆
load = samples("load")
i, s, sens = load[-1]
s = strip(s)
s["topProcesses"] = [p for p in (s.get("topProcesses") or []) if p["name"] == "ffmpeg"] or None
s["boostUntil"] = None
hist = json.load(open(os.path.join(cap, "load", "history.json")))
dump("load", s, hist, sens, f"實機取樣（Mac mini M4，ffmpeg libx264 4K 編碼約 4 分鐘，load/state-{i}.json）")

# 降頻：受控情境
THROTTLE = {"pressure": "Moderate", "pcoreMHz": 3520, "dT": 5.0, "rpm": 4900, "throttleSeconds": 34, "hookWaits": 1}
t = json.loads(json.dumps(s))
t["thermalPressure"] = THROTTLE["pressure"]
t["pcoreMHz"] = THROTTLE["pcoreMHz"]
for k in ("cpuMax", "cpuAvg", "controlTemp"): t[k] = s[k] + THROTTLE["dT"]
t["level"] = "hot" if t["controlTemp"] >= 95 else s["level"]
t["fans"][0]["rpm"] = t["fans"][0]["target"] = THROTTLE["rpm"]
t["guardTargetRPM"] = THROTTLE["rpm"]
t["stats"] = dict(t.get("stats") or {}, throttleSeconds=THROTTLE["throttleSeconds"], hookWaits=THROTTLE["hookWaits"],
                  maxTemp=max((t.get("stats") or {}).get("maxTemp", 0), t["controlTemp"]))
th = json.loads(json.dumps(hist))
n = len(th)
for j, p in enumerate(th[-8:]):       # 最後 40 秒：溫度爬升、風扇頂滿、P-core 掉到 3.5 GHz
    f = (j + 1) / 8
    p["cpu"] += THROTTLE["dT"] * f; p["rpm"] = p["rpm"] + (THROTTLE["rpm"] - p["rpm"]) * f
    if p.get("pMHz"): p["pMHz"] = p["pMHz"] + (THROTTLE["pcoreMHz"] - p["pMHz"]) * f
tsens = {k: v + THROTTLE["dT"] if k[:2] in ("Tp", "Te") else v for k, v in sens.items()}
dump("throttle", t, th, tsens,
     "受控情境（非實機紀錄）：以 load 的實機取樣為底，pressure 改 Moderate、P-core 3.52 GHz（落在外部報告的原廠 M4 mini 降頻區間 3.3–3.8 GHz）、"
     "CPU 感測器 +5°C、風扇 4900。近 94 小時實機 log 降頻 0 秒，沒有真實降頻畫面可截。")
