#!/bin/bash
# 需要 root 的步驟（由 install.sh 透過系統密碼視窗呼叫）。參數：$1 = 專案目錄，$2 = 使用者名稱
set -euo pipefail
SRC="$1"; USER_NAME="$2"
mkdir -p /usr/local/bin /etc/cool42
cp "$SRC/.build/release/cool42" /usr/local/bin/cool42
chmod 755 /usr/local/bin/cool42
[ -f /etc/cool42/config.json ] || cp "$SRC/config.example.json" /etc/cool42/config.json
# 設定檔交給使用者可寫，面板才能改模式/曲線；guard 偵測到修改會自動重載
chown "$USER_NAME" /etc/cool42/config.json
cp "$SRC/launchd/com.cool42.guard.plist" /Library/LaunchDaemons/
chown root:wheel /Library/LaunchDaemons/com.cool42.guard.plist
launchctl bootout system/com.cool42.guard 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.cool42.guard.plist
