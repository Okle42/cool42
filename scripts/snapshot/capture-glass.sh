#!/bin/bash
# 實機 Liquid Glass 截圖（開發用）：用 cool42-snapshot --live 跑真的 PanelApp.swift 面板（NSPanel＋NSGlassEffectView、即時 guard 資料），
# 後面墊受控背景（亮 / 暗 / 花俏），淺 / 深色各截一張 → OUT_DIR/glass-{light,dark}-{bright,dark,vivid}.png
# 離屏的 render-panel.sh 畫不出玻璃（cacheDisplay 拿不到 behind-window 合成），這支才看得到實際外觀。
#
#   scripts/snapshot/capture-glass.sh OUT_DIR [--hc] [--lang en]
#     --hc：再加 accessibilityHighContrast 外觀（檢查面板配色；系統「增加對比」本身不去切）
#
# 不跑 make-app.sh、不動已安裝的面板與使用者設定；會在選單列多出一個暫時的 cool42 圖示，截完自己結束。
# 需要終端機已有「螢幕錄製」權限：先用 CGPreflightScreenCaptureAccess 檢查（不會跳授權視窗），沒有就停。
# 注意：面板顯示的是即時資料，「誰在吃 CPU」那一行會帶行程指令與目錄，要進 repo 前先看過圖。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?要給輸出目錄}"; shift
mkdir -p "$OUT"
WORK="${COOL42_SNAPSHOT_WORK:-${TMPDIR:-/tmp}/cool42-snapshot}"
PF="$WORK/preflight"
mkdir -p "$WORK"
[ -x "$PF" ] || { printf 'import CoreGraphics\nexit(CGPreflightScreenCaptureAccess() ? 0 : 1)\n' > "$WORK/preflight.swift"; swiftc -O "$WORK/preflight.swift" -o "$PF"; }
"$PF" || { echo "終端機沒有螢幕錄製權限，不截（不會自己去要權限）" >&2; exit 1; }
"$REPO/scripts/render-panel.sh" "$WORK/scratch-render" idle >/dev/null   # 建好 cool42-snapshot
BIN="$WORK/.build/release/cool42-snapshot"
LANG_ARGS=()
if [ "${1:-}" = "--lang" ]; then LANG_ARGS=(-AppleLanguages "(${2})"); shift 2; fi
"$BIN" --live "$OUT" "$@" ${LANG_ARGS[@]+"${LANG_ARGS[@]}"}
