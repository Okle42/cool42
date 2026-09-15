#!/bin/bash
set -uo pipefail
sudo launchctl bootout system/com.cool42.guard 2>/dev/null
sudo rm -rf /Library/LaunchDaemons/com.cool42.guard.plist /usr/local/bin/cool42 /etc/newsyslog.d/cool42.conf /tmp/cool42.json /tmp/cool42.history.json /tmp/cool42.events
launchctl bootout "gui/$(id -u)/com.cool42.panel" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/com.cool42.panel.plist"
pkill -x cool42-panel 2>/dev/null
rm -rf "/Applications/cool42 Panel.app"
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(p):
    s = json.load(open(p)); pre = s.get("hooks", {}).get("PreToolUse", [])
    s["hooks"]["PreToolUse"] = [e for e in pre if not any("cool42 hook" in h.get("command", "") for h in e.get("hooks", []))]
    json.dump(s, open(p, "w"), ensure_ascii=False, indent=2); print("已移除 Claude Code hook")
PY
echo "已移除 daemon、CLI、面板（/etc/cool42/config.json 保留）。風扇已交還 SMC 自動控制。"
