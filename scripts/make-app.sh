#!/bin/bash
# 把 cool42-panel 打包成選單列 .app（LSUIElement，無 Dock 圖示），裝到 /Applications 並設開機啟動（使用者層級，不需 sudo）
set -euo pipefail
cd "$(dirname "$0")/.."
APP="/Applications/cool42 Panel.app"
BIN=".build/release/cool42-panel"
# 每次都建（增量很快）：只看執行檔在不在的話，改過原始碼後會把舊執行檔和新的 *.lproj 包在一起
swift build -c release --product cool42-panel 2>&1 | tail -1
[ -x "$BIN" ] || { echo "✗ 建置失敗：找不到 $BIN" >&2; exit 1; }

pkill -x cool42-panel 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/cool42-panel"
# 內建提示音（config 沒指定音檔時用）
mkdir -p "$APP/Contents/Resources/Sounds"
cp Sounds/*.m4a "$APP/Contents/Resources/Sounds/"
# 介面字串（zh-Hant 開發語言＋en），依系統語言切換；面板用 Bundle.main 讀 Contents/Resources/*.lproj
cp -R Sources/cool42-panel/Resources/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>cool42 Panel</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hant</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hant</string><string>en</string></array>
  <key>CFBundleDisplayName</key><string>cool42 Panel</string>
  <key>CFBundleIdentifier</key><string>com.cool42.panel</string>
  <key>CFBundleExecutable</key><string>cool42-panel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleShortVersionString</key><string>1.0.3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSFocusStatusUsageDescription</key><string>cool42會讀取專注模式是否開啟，套用你為專注模式設定的風扇規則。</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null || true

# 開機自動啟動（LaunchAgent）
AGENT="$HOME/Library/LaunchAgents/com.cool42.panel.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.cool42.panel</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/cool42-panel</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/com.cool42.panel" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "✅ 面板已裝到 $APP 並啟動（選單列右上角），開機自動啟動"
