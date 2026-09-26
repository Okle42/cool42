#!/bin/bash
# 一鍵安裝：release 建置 → CLI → 設定檔 → guard LaunchDaemon(root) → Claude Code hook + MCP → 選單列面板
# root 步驟走 macOS 系統密碼視窗，所以在沒有 TTY 的環境（Claude Code 的 ! 指令）也能跑
set -euo pipefail
cd "$(dirname "$0")"
SRC="$(pwd)"

echo "▶ swift build -c release"
swift build -c release 2>&1 | tail -1

if pgrep -f "Macs Fan Control.app/Contents/MacOS" >/dev/null; then
  echo "⚠️  Macs Fan Control 正在執行，會和 cool42 guard 互搶風扇。請先退出它（含選單列常駐）。"
  exit 1
fi

# cool42 原名 cool42：偵測到改名前的安裝就先搬（設定、統計、log、hook、MCP 一起帶過來；舊檔收進 ~/cool42-migration-backup-*）
if ./scripts/migrate-from-cool42.sh --detect; then
  if [ "$(id -u)" = "0" ]; then
    echo "⚠️  偵測到改名前的 cool42。請用一般使用者身分先跑 ./scripts/migrate-from-cool42.sh（或直接 ./install.sh，不要 sudo）"
    exit 1
  fi
  echo "▶ 偵測到改名前的 cool42，先搬遷（先看計畫：./scripts/migrate-from-cool42.sh --dry-run）"
  ./scripts/migrate-from-cool42.sh
fi

echo "▶ 安裝 CLI、設定檔、guard LaunchDaemon（會跳出系統密碼視窗）"
if [ "$(id -u)" = "0" ]; then
  ./scripts/install-root.sh "$SRC" "${SUDO_USER:-$(id -un)}"
elif sudo -n true 2>/dev/null; then
  sudo ./scripts/install-root.sh "$SRC" "$(id -un)"
else
  osascript -e "do shell script \"'$SRC/scripts/install-root.sh' '$SRC' '$(id -un)'\" with administrator privileges with prompt \"cool42 需要管理員權限安裝風扇控制 daemon\""
fi
sleep 3
/usr/local/bin/cool42 status

echo "▶ Claude Code hook"
./scripts/install-hook.py

echo "▶ Claude Code MCP server"
./scripts/install-mcp.sh

echo "▶ 選單列面板"
./scripts/make-app.sh

echo
echo "✅ 全部完成。log：tail -f /var/log/cool42.log"
