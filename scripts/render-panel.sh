#!/bin/bash
# 面板離屏截圖（開發用，不進正式產品）：把 PanelApp.swift 的 PanelView 餵情境資料，渲染成 @2x PNG（亮 / 暗各一）。
# 不開視窗、不需要螢幕錄製或輔助使用權限：NSHostingView 放進不顯示的 borderless NSWindow，再用 cacheDisplay 輸出。
#
# ⚠ 這些截圖的視窗底是實色 Neon.panelBG（＝使用者開了「減少透明度」時的外觀），不是 macOS 26+ 預設的 Liquid Glass：
#   cacheDisplay 畫不出 behind-window 的玻璃合成。實機玻璃外觀用 scripts/snapshot/capture-glass.sh 截
#   （跑真的 NSPanel，面板後面墊受控背景，用 screencapture 截；需要終端機已有螢幕錄製權限）。
#
#   scripts/render-panel.sh                 → docs/img/screens/panel-{idle,load,throttle}-{light,dark}.png
#   scripts/render-panel.sh OUT_DIR [情境…]  → 指定輸出目錄與情境（情境檔在 scripts/snapshot/scenarios/*.json）
#   scripts/render-panel.sh --lang en [OUT_DIR [情境…]] → 英文介面，檔名 panel-{情境}-en-{light,dark}.png
#     （也可用環境變數 COOL42_SNAPSHOT_LANG=en；不給就跟系統語言）
#   COOL42_SNAPSHOT_ARGS="--variant fixed,dirty"   → 疊示意狀態檢查字串長度（見 scripts/snapshot/main.swift 開頭）
#   scripts/render-panel.sh OUT_DIR onboarding menubar → 首次啟動導覽三頁、選單列圖示各狀態（不是情境檔）
#
# 做法：executableTarget 無法被 import，所以在暫存目錄建一個 SwiftPM package，
# symlink Sources/CSMC、Sources/Cool42Core，複製 PanelApp.swift 並拿掉 @main，再加上 scripts/snapshot/main.swift。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
UI_LANG="${COOL42_SNAPSHOT_LANG:-}"
if [ "${1:-}" = "--lang" ]; then UI_LANG="${2:?--lang 要給語言代碼，例如 en}"; shift 2; fi
OUT="${1:-$REPO/docs/img/screens}"; shift || true
WORK="${COOL42_SNAPSHOT_WORK:-${TMPDIR:-/tmp}/cool42-snapshot}"
VERSION="$(sed -n 's/.*CFBundleShortVersionString<\/key><string>\([^<]*\)<.*/\1/p' "$REPO/scripts/make-app.sh" | head -1)"

mkdir -p "$WORK/Sources/snapshot" "$OUT"
ln -sfn "$REPO/Sources/CSMC" "$WORK/Sources/CSMC"
ln -sfn "$REPO/Sources/Cool42Core" "$WORK/Sources/Cool42Core"
# COOL42_PANEL_SRC 可指向另一份 PanelApp.swift（例如 git show 出來的舊版），拿來做改版前後對照
sed 's/^@main$//' "${COOL42_PANEL_SRC:-$REPO/Sources/cool42-panel/PanelApp.swift}" > "$WORK/Sources/snapshot/PanelApp.swift"
# 面板其他原始檔（StatusIcon、Notifier、Timeline、Health、Onboarding⋯，含子目錄）一起帶進來；先清掉上次留下的，免得刪掉的檔還在
find "$WORK/Sources/snapshot" -name '*.swift' ! -name PanelApp.swift ! -name main.swift -delete
find "$WORK/Sources/snapshot" -mindepth 1 -type d -empty -delete
if [ -z "${COOL42_PANEL_SRC:-}" ]; then
  (cd "$REPO/Sources/cool42-panel" && find . -name '*.swift' ! -name PanelApp.swift) | while read -r f; do
    mkdir -p "$WORK/Sources/snapshot/$(dirname "$f")"
    cp "$REPO/Sources/cool42-panel/$f" "$WORK/Sources/snapshot/$f"
  done
fi
cp "$REPO/scripts/snapshot/main.swift" "$WORK/Sources/snapshot/main.swift"
# 舊版沒有 Neon.hairline：補一個同值的，main.swift 才編得過
grep -q "static let hairline" "$WORK/Sources/snapshot/PanelApp.swift" || \
  printf '\nextension Neon { static let hairline = Color.white.opacity(0.08) }\n' >> "$WORK/Sources/snapshot/PanelApp.swift"
cat > "$WORK/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.cool42.snapshot</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hant</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-dev}</string>
</dict></plist>
PLIST
cat > "$WORK/Package.swift" <<PKG
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "cool42-snapshot",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSMC", path: "Sources/CSMC"),
        .target(name: "Cool42Core", dependencies: ["CSMC"], path: "Sources/Cool42Core", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "cool42-snapshot", dependencies: ["Cool42Core"], path: "Sources/snapshot",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "$WORK/Info.plist"])]),
    ]
)
PKG
swift build --package-path "$WORK" -c release --product cool42-snapshot 2>&1 | grep -E "error|warning: unre|Compiling|Build" | grep -v "^\[" || true
BIN="$WORK/.build/release/cool42-snapshot"
[ -x "$BIN" ] || { echo "建置失敗" >&2; exit 1; }
# 介面字串：沒有 app bundle 時 Bundle.main 就是執行檔所在目錄，把 *.lproj 放旁邊（舊版 PanelApp.swift 沒用到也無妨）
BIN_DIR="$(cd "$(dirname "$BIN")" && pwd -P)"
rm -rf "$BIN_DIR"/*.lproj
cp -R "$REPO/Sources/cool42-panel/Resources/"*.lproj "$BIN_DIR/"
if [ $# -eq 0 ]; then set -- idle load throttle; fi
for sc in "$@"; do
  case "$sc" in
    # 不是情境檔：onboarding＝首次啟動導覽三頁、menubar＝選單列圖示各狀態（亮 / 暗）
    onboarding|menubar) "$BIN" "--$sc" "$OUT/$sc${UI_LANG:+-$UI_LANG}" ${UI_LANG:+--lang "$UI_LANG"} ;;
    *) "$BIN" "$REPO/scripts/snapshot/scenarios/$sc.json" "$OUT/panel-$sc${UI_LANG:+-$UI_LANG}" ${UI_LANG:+--lang "$UI_LANG"} ${COOL42_SNAPSHOT_ARGS:-} ;;
  esac
done
