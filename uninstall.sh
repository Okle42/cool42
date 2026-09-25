#!/bin/bash
set -uo pipefail
sudo launchctl bootout system/com.cool42.guard 2>/dev/null
sudo /usr/local/bin/cool42 fan auto 2>/dev/null   # guard 收 SIGTERM 會保持轉速（等重啟接管），移除時要明確交還
sudo rm -rf /Library/LaunchDaemons/com.cool42.guard.plist /usr/local/bin/cool42 /usr/local/bin/cool42-guard /etc/newsyslog.d/cool42.conf /var/db/cool42 /var/run/cool42 /tmp/cool42.json /tmp/cool42.history.json /tmp/cool42.events
launchctl bootout "gui/$(id -u)/com.cool42.panel" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/com.cool42.panel.plist"
pkill -x cool42-panel 2>/dev/null
rm -rf "/Applications/cool42 Panel.app"
# 面板寫給 guard 的專注模式旗標；~/.config/cool42/config.json（使用者層設定檔）若有就保留，目錄空了才刪
rm -f "$HOME/.config/cool42/focus.json"
rmdir "$HOME/.config/cool42" 2>/dev/null
command -v claude >/dev/null && claude mcp remove --scope user cool42 >/dev/null 2>&1 && echo "已移除 Claude Code MCP server"
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(p):
    s = json.load(open(p)); pre = s.get("hooks", {}).get("PreToolUse", [])
    s["hooks"]["PreToolUse"] = [e for e in pre if not any("cool42 hook" in h.get("command", "") for h in e.get("hooks", []))]
    json.dump(s, open(p, "w"), ensure_ascii=False, indent=2); print("已移除 Claude Code hook")
PY
echo "已移除 daemon、CLI、面板與專注模式旗標（設定檔 /etc/cool42/config.json 保留）。風扇已交還 SMC 自動控制。"
