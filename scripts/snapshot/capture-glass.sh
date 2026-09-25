#!/bin/bash
# 實機 Liquid Glass 截圖（開發用）：用 cool42-snapshot --live 跑真的 PanelApp.swift 面板（無邊框 NSPanel＋NSGlassEffectView、即時 guard 資料），
# 後面墊受控背景，深 / 淺色各截一張 → OUT_DIR/glass-{dark,light}-{stars,web}.png
#   stars＝深色星空桌布（和 Dock 底下同一類）、web＝白色網頁（最容易把玻璃洗白）；另有 bright／dark／vivid 漸層
# 離屏的 render-panel.sh 畫不出玻璃（cacheDisplay 拿不到 behind-window 合成），這支才看得到實際外觀。
#
#   scripts/snapshot/capture-glass.sh OUT_DIR [--lang en] [選項…]   （--lang 要緊接在 OUT_DIR 後面）
#     --hc                 再加 *-hc 幾張：強制面板自己的「增加對比」分支（A11y.forceHC；系統設定本身不去切）
#     --backdrops a,b      背景（預設 stars,web）      --looks dark,light   只截某些外觀
#     --full               另存整個螢幕 full-*.png（面板預設放在 x=400，左下角桌面 widget 與 Dock 留在畫面裡當參照）
#     --at-x N             面板左緣位置               --settings           改截設定視窗每個分頁 settings-{分頁}-{外觀}.png
#     --dirty-close        設定視窗改一個曲線點（不套用）後按關閉，截確認單 settings-dirty-close.png（截完捨棄，不寫設定檔）
#     -glass.style clear|regular  -glass.tint 0…1  -glass.lightTint 0…1  -glass.fallback solid|legacy   玻璃參數比對
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
# -onboarding.shown YES：截圖用的 defaults 網域是全新的，不讓首次導覽視窗跳出來擋住面板
"$BIN" --live "$OUT" -onboarding.shown YES "$@" ${LANG_ARGS[@]+"${LANG_ARGS[@]}"}
