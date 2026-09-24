#!/usr/bin/env python3
"""面板在地化檢查（只用標準庫＋macOS 內建 plutil）。

  python3 scripts/check-l10n.py

檢查 Sources/cool42-panel/*.swift：
  1. 每個 L("…") 的 key 在 en.lproj/Localizable.strings 都有英文（漏了就是英文介面冒出中文）
  2. en 表裡沒有用不到的 key
  3. key 與英文值的 printf 格式符號（%@、%ld、%.0f…）順序、種類一樣（不一樣會印錯或當掉）
  4. 程式碼裡沒有「沒包 L()」的中文字串常值（註解不算）
有問題就列出來並以 1 結束。
"""
import json, os, re, subprocess, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "Sources", "cool42-panel")
RES = os.path.join(SRC, "Resources")

LIT = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
CJK = re.compile(r"[　-鿿＀-￯]")
FMT = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaA%]")


def strip_comment(line):
    """拿掉行尾 // 註解（字串裡的 // 不算）"""
    out, i, in_str = [], 0, False
    while i < len(line):
        c = line[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < len(line):
                out.append(line[i + 1]); i += 2; continue
            if c == '"': in_str = False
        else:
            if line.startswith("//", i): break
            if c == '"': in_str = True
            out.append(c)
        i += 1
    return "".join(out)


def unescape(s):
    return s.encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8") if "\\" in s else s


def load_strings(path):
    r = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"{path} 格式錯誤：{r.stderr.strip()}")
    return json.loads(r.stdout) if r.stdout.strip() else {}


def fmts(s):
    return [m for m in FMT.findall(s) if m != "%%"]


keys, problems = {}, []
for name in sorted(os.listdir(SRC)):
    if not name.endswith(".swift"): continue
    for n, raw in enumerate(open(os.path.join(SRC, name), encoding="utf-8"), 1):
        line = strip_comment(raw.rstrip("\n"))
        if line.lstrip().startswith("///"): continue
        for m in LIT.finditer(line):
            lit = m.group(1)
            wrapped = line[:m.start()].rstrip().endswith("L(")
            if wrapped:
                keys.setdefault(unescape(lit), f"{name}:{n}")
            elif CJK.search(lit):
                problems.append(f"{name}:{n} 中文字串沒包 L()：\"{lit}\"")

en = load_strings(os.path.join(RES, "en.lproj", "Localizable.strings"))
zh_path = os.path.join(RES, "zh-Hant.lproj", "Localizable.strings")
if not os.path.exists(zh_path):
    problems.append("缺 zh-Hant.lproj/Localizable.strings（繁中系統會選不到繁中）")

for k, where in keys.items():
    if k not in en:
        problems.append(f"{where} en 缺：\"{k}\"")
    elif fmts(k) != fmts(en[k]):
        problems.append(f"{where} 格式符號不一致：\"{k}\" {fmts(k)} → \"{en[k]}\" {fmts(en[k])}")
for k in en:
    if k not in keys:
        problems.append(f"en 多餘（程式沒用到）：\"{k}\"")
for k, v in en.items():
    if CJK.search(v):
        problems.append(f"en 值還有中文：\"{k}\" = \"{v}\"")
    if "..." in v:
        problems.append(f"en 值用了三個句點（Apple 用單一字元 …）：\"{v}\"")

print(f"L() key {len(keys)} 個、en 表 {len(en)} 筆")
if problems:
    print("\n".join(problems))
    sys.exit(1)
print("OK")
