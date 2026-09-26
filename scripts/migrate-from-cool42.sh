#!/bin/bash
# 從改名前的 cool42 搬到 cool42（cool42 原名 cool42，2026-09-27 改名）。
#
#   scripts/migrate-from-cool42.sh --dry-run    只印計畫，不動任何東西（不要密碼）
#   scripts/migrate-from-cool42.sh              執行搬遷（跳一次系統密碼視窗）；跑完再 ./install.sh 裝 cool42
#   scripts/migrate-from-cool42.sh --detect     有舊版殘留就 exit 0、沒有 exit 1（install.sh 用）
#   其他參數：--skip-claude（不動 Claude Code 的 hook 與 MCP）、--mcp-script PATH（新 MCP server 的路徑，預設本專案 mcp/cool42_mcp.py）
#
# 會做的事（每一步先檢查、做完驗證，失敗就停並印還原方法；已經搬過的步驟會略過，可以重跑）：
#   root（最先做；系統密碼視窗，做法同 install.sh；按取消就什麼都沒動）：停舊 guard（bootout com.cool42.guard）並把風扇交還 macOS →
#     /etc/cool42/config.json 複製到 /etc/cool42/（內容、擁有者、權限不變；hookAllowCommands 的 "cool42" 換成 "cool42"）→
#     /var/db/cool42 的統計與預熱學習、/var/log/cool42*.log 接到 cool42 的位置 →
#     舊 LaunchDaemon plist、舊 CLI、舊 newsyslog 設定、/var/run/cool42、/usr/local/share/cool42、1.0.2 以前的 /tmp 檔收進備份區
#   使用者層級：備份面板偏好（defaults export com.cool42.panel）→ 停舊面板、收掉舊 LaunchAgent 與 /Applications 的舊 app →
#     ~/.config/cool42 → ~/.config/cool42；~/.claude/settings.json 的 cool42 hook 換成 cool42（先備份）；
#     claude mcp remove cool42 → add cool42；最後提示 ~/.claude/scripts/statusline.py 裡讀 /var/run/cool42 的地方（只提示，不改）
#
# 不直接刪任何東西：舊檔一律 mv 到 ~/cool42-migration-backup-<時間>/removed/<原路徑>，新位置的檔案是複製後逐檔比對過的。
# 還原：sudo bash ~/cool42-migration-backup-<時間>/restore.sh（把 manifest.tsv 記下的舊檔搬回原位、還原 settings.json、重新載入舊 guard）
# 面板偏好不在這裡搬：新面板第一次啟動時自己從 com.cool42.panel 補讀（Cool42Core/LegacyDefaults.swift），舊網域不刪。
set -Eeuo pipefail   # -E：ERR trap 也要在函式裡生效，任何一步失敗都走 die 印還原方法

OLD_LABEL_GUARD="com.cool42.guard"
OLD_LABEL_PANEL="com.cool42.panel"
OLD_APP="/Applications/cool42 Panel.app"
NEW_APP="/Applications/cool42 Panel.app"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO="$(cd "$(dirname "$SELF")/.." && pwd)"

DRY=0; DETECT=0; SKIP_CLAUDE=0; MCP_SCRIPT="$REPO/mcp/cool42_mcp.py"
B=""   # 備份目錄；建立之後 die 才會印還原方法

say()  { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
restore_hint() {
  if [ -n "$B" ] && [ -f "$B/restore.sh" ]; then
    echo "  已經做完的步驟都記在 $B/manifest.tsv，還原方法：" >&2
    echo "    sudo bash '$B/restore.sh'    # 把移走的舊檔搬回原位、還原 settings.json、重新載入舊 guard" >&2
    echo "  之後照它最後印的指令，用一般使用者身分把舊面板與 MCP server 裝回去。" >&2
  elif [ "$DRY" = 0 ]; then
    echo "  還沒有動到任何檔案，不需要還原。" >&2
  fi
}
die() { echo "✗ $*" >&2; restore_hint; exit 1; }
trap 'die "第 $LINENO 行失敗：$BASH_COMMAND"' ERR

# 執行或（--dry-run 時）只印出指令
run() {
  if [ "$DRY" = 1 ]; then
    # 不用 printf %q：它會把中文路徑印成 $'\xxx' 跳脫碼，看不懂。只有含空白或特殊字元的參數才加單引號
    local a out=""
    for a in "$@"; do
      if [[ "$a" =~ ^[A-Za-z0-9_./:@%+=,~-]+$ ]]; then out+="$a "; else out+="'${a//\'/\'\\\'\'}' "; fi
    done
    printf '    [dry-run] %s\n' "$out"
  else "$@"; fi
}
exists() { [ -e "$1" ] || [ -L "$1" ]; }
record() { [ "$DRY" = 1 ] || { local IFS=$'\t'; printf '%s\n' "$*" >> "$B/manifest.tsv"; }; }

# /usr/bin/python3 在沒裝 Command Line Tools 的機器上是會跳安裝視窗的 stub，先確認是真的 python（同 install-from-release.sh）
have_python() {
  local p; p="$(command -v python3 2>/dev/null)" || return 1
  [ "$p" != "/usr/bin/python3" ] && return 0
  xcode-select -p >/dev/null 2>&1
}

# 舊檔收進備份區：mv 到 $B/removed/<原路徑>，驗證原位置沒了、備份區有了，記進 manifest
retire() {
  local p="$1" dest
  exists "$p" || return 0
  # root 階段建的 removed/ 是 root 擁有，一般使用者階段寫不進去 → 分開放（restore.sh 照 manifest 的實際路徑搬回，不受影響）
  if [ "$(id -u)" = 0 ]; then dest="$B/removed$p"; else dest="$B/removed-user$p"; fi
  say "  • 收進備份區：$p"
  run mkdir -p "$(dirname "$dest")"
  run mv "$p" "$dest"
  [ "$DRY" = 1 ] && return 0
  exists "$p" && die "移不走：$p"
  exists "$dest" || die "備份區找不到剛移過去的：$dest"
  record moved "$p" "$dest"
}

# 複製到新位置（不覆蓋），逐位元組比對＋擁有者／權限比對
carry() {
  local src="$1" dst="$2"
  exists "$src" || return 0
  if exists "$dst"; then say "  • 略過：$dst 已存在，不覆蓋（舊的 $src 照樣收進備份區）"; return 0; fi
  say "  • 複製：$src → $dst"
  run mkdir -p "$(dirname "$dst")"
  run cp -p "$src" "$dst"
  [ "$DRY" = 1 ] && return 0
  cmp -s "$src" "$dst" || die "複製後內容不符：$dst"
  [ "$(stat -f '%u:%g:%p' "$src")" = "$(stat -f '%u:%g:%p' "$dst")" ] || die "複製後擁有者或權限不符：${dst}（$(stat -f '%Su:%Sg %Sp' "$dst")）"
  record created "$dst"
}

# ───────────── 偵測 ─────────────
root_leftovers() {
  local p
  for p in /Library/LaunchDaemons/$OLD_LABEL_GUARD.plist /usr/local/bin/cool42 /usr/local/bin/cool42-guard /usr/local/bin/cool42.new \
           /etc/cool42 /etc/newsyslog.d/cool42.conf /var/db/cool42 /var/run/cool42 /usr/local/share/cool42 \
           /var/log/cool42.log /var/log/cool42.err.log \
           /tmp/cool42.json /tmp/cool42.json.tmp /tmp/cool42.history.json /tmp/cool42.history.json.tmp /tmp/cool42.events; do
    if exists "$p"; then echo "$p"; fi
  done
  shopt -s nullglob
  for p in /var/log/cool42.log.* /var/log/cool42.err.log.*; do echo "$p"; done
  shopt -u nullglob
}
guard_loaded() { launchctl print "system/$OLD_LABEL_GUARD" >/dev/null 2>&1; }
settings_has_old_hook() { [ -f "$HOME/.claude/settings.json" ] && grep -q 'cool42 hook' "$HOME/.claude/settings.json"; }
# user scope 的 MCP 設定在 ~/.claude.json；只看有沒有剛好叫 "cool42" 的字串（便宜，不用 claude mcp get 去連 server）
mcp_maybe_old() { [ -f "$HOME/.claude.json" ] && grep -q '"cool42"' "$HOME/.claude.json"; }
user_leftovers() {
  exists "$HOME/Library/LaunchAgents/$OLD_LABEL_PANEL.plist" && echo "$HOME/Library/LaunchAgents/$OLD_LABEL_PANEL.plist"
  exists "$OLD_APP" && echo "$OLD_APP"
  exists "$HOME/.config/cool42" && echo "$HOME/.config/cool42"
  pgrep -x cool42-panel >/dev/null 2>&1 && echo "（執行中的 cool42-panel）"
  settings_has_old_hook && echo "$HOME/.claude/settings.json 裡的 cool42 hook"
  mcp_maybe_old && echo "Claude Code MCP server cool42（~/.claude.json）"
  return 0
}
anything_left() {
  guard_loaded && return 0
  [ -n "$(root_leftovers)" ] && return 0
  [ -n "$(user_leftovers)" ] && return 0
  return 1
}

# ───────────── root 階段（由 as_root 呼叫自己：--root-stage <備份目錄> <使用者> <dry>） ─────────────
root_stage() {
  B="$1"; local user_name="$2"; DRY="$3"
  if [ "$DRY" = 0 ]; then
    [ "$(id -u)" = 0 ] || die "--root-stage 需要 root"
    [ -d "$B" ] && [ ! -L "$B" ] && [ -f "$B/manifest.tsv" ] || die "備份目錄不對：$B"
  fi

  say "▶ [root] 停舊 guard"
  local stopped=0
  if guard_loaded; then
    run launchctl bootout "system/$OLD_LABEL_GUARD" || true
    if [ "$DRY" = 0 ]; then
      # guard 收到 SIGTERM 會先寫最後一次快照才退出，launchd 還沒清完前 print 仍查得到
      for _ in $(seq 1 30); do guard_loaded || break; sleep 0.5; done
      guard_loaded && die "舊 guard 停不下來（launchctl print system/$OLD_LABEL_GUARD 還查得到）"
      record guard-was-loaded "/Library/LaunchDaemons/$OLD_LABEL_GUARD.plist"
    fi
    stopped=1
    if [ "$DRY" = 1 ]; then say "  • 會停掉舊 guard（等它真的從 launchd 消失，最多 15 秒）"; else say "  • 舊 guard 已停"; fi
  else
    say "  • 舊 guard 沒在跑，略過"
  fi
  # guard 收 SIGTERM 會維持目前轉速（等 launchd 重啟接管）；這次不會重啟了，要明確交還 macOS。只在這一輪真的停了它才做
  if [ "$stopped" = 1 ] && [ -x /usr/local/bin/cool42 ]; then
    say "  • 風扇交還 macOS 自動控制"
    run /usr/local/bin/cool42 fan auto || warn "cool42 fan auto 失敗；裝好 cool42 之後 guard 會重新接管，或手動 sudo cool42 fan auto"
  fi

  say "▶ [root] 設定檔 /etc/cool42/config.json → /etc/cool42/config.json"
  if [ -f /etc/cool42/config.json ]; then
    if [ ! -d /etc/cool42 ]; then run mkdir -m 755 /etc/cool42; run chown root:wheel /etc/cool42; fi
    carry /etc/cool42/config.json /etc/cool42/config.json
  else
    say "  • 沒有 /etc/cool42/config.json，略過"
  fi
  fix_allow_list /etc/cool42/config.json

  say "▶ [root] 統計與預熱學習 /var/db/cool42 → /var/db/cool42"
  if [ -d /var/db/cool42 ]; then
    if [ ! -d /var/db/cool42 ]; then
      run mkdir -m "$(stat -f '%Lp' /var/db/cool42)" /var/db/cool42
      run chown "$(stat -f '%u:%g' /var/db/cool42)" /var/db/cool42
    fi
    local f
    for f in /var/db/cool42/*; do [ -f "$f" ] && carry "$f" "/var/db/cool42/$(basename "$f")"; done
  else
    say "  • 沒有 /var/db/cool42，略過"
  fi

  say "▶ [root] guard log /var/log/cool42*.log → /var/log/cool42*.log（面板的「今天」時間軸與 extras 的統計接得上）"
  local l any=0
  shopt -s nullglob
  for l in /var/log/cool42.log /var/log/cool42.log.* /var/log/cool42.err.log /var/log/cool42.err.log.*; do
    [ -f "$l" ] || continue
    any=1; carry "$l" "/var/log/cool42.${l#/var/log/cool42.}"
  done
  shopt -u nullglob
  [ "$any" = 1 ] || say "  • 沒有舊 log，略過"

  say "▶ [root] 收掉舊的 LaunchDaemon、CLI、newsyslog、執行期檔案（mv 進備份區，不刪）"
  local p
  while IFS= read -r p; do [ -n "$p" ] && retire "$p"; done < <(root_leftovers)
  [ -n "$(root_leftovers)" ] && [ "$DRY" = 0 ] && die "還有舊檔沒收掉：$(root_leftovers | tr '\n' ' ')"
  say "  • 完成"
  : "$user_name"   # 保留參數：設定檔擁有者用 cp -p 原樣帶過去，不需要另外 chown
}

# 設定檔 hookAllowCommands 裡的 "cool42"（CLI 自己的名字）換成 "cool42"；只動那一個值，其他排版照舊
fix_allow_list() {
  local f="$1"
  if [ "$DRY" = 1 ]; then
    local src="$f"; [ -f "$src" ] || src=/etc/cool42/config.json
    if [ -f "$src" ] && grep -q '"cool42"' "$src"; then say "  • hookAllowCommands 的 \"cool42\" 換成 \"cool42\"（${f}）"; fi
    return 0
  fi
  [ -f "$f" ] || return 0
  grep -q '"cool42"' "$f" || return 0
  have_python || { warn "沒有可用的 python3：請手動把 $f 的 hookAllowCommands 裡的 \"cool42\" 改成 \"cool42\""; return 0; }
  local before; before="$(stat -f '%u:%g:%p' "$f")"
  local out
  out="$(python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]
raw = open(p, encoding="utf-8").read()
d = json.loads(raw)
cmds = d.get("hookAllowCommands")
if not isinstance(cmds, list) or "cool42" not in cmds:
    print("skip"); sys.exit(0)
new = []
for c in cmds:
    c = "cool42" if c == "cool42" else c
    if c not in new:
        new.append(c)
want = dict(d); want["hookAllowCommands"] = new
# 優先只換那一個字串，保留原本的排版；對不上（例如出現不只一次、或 cool42 已在清單裡）才整份重寫
out = raw.replace('"cool42"', '"cool42"') if raw.count('"cool42"') == 1 and "cool42" not in cmds else json.dumps(want, ensure_ascii=False, indent=2) + "\n"
assert json.loads(out) == want, "改寫結果和預期不符"
with open(p, "r+", encoding="utf-8") as fh:   # 就地寫：同一個 inode，擁有者與權限不變
    fh.seek(0); fh.write(out); fh.truncate()
print("ok")
PY
)" || die "改寫 $f 的 hookAllowCommands 失敗"
  [ "$(stat -f '%u:%g:%p' "$f")" = "$before" ] || die "改寫後 $f 的擁有者或權限變了"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "cool42" not in d.get("hookAllowCommands", [])' "$f" || die "$f 改寫後驗證失敗"
  [ "$out" = "ok" ] && say "  • hookAllowCommands 的 \"cool42\" 已換成 \"cool42\"（${f}）"
  return 0
}

# ───────────── 使用者層級 ─────────────
as_root() {
  if [ "$(id -u)" = "0" ]; then "$@"
  elif sudo -n true 2>/dev/null; then sudo "$@"
  else
    # 同 install.sh：沒有 TTY（Claude Code 的 ! 指令）也能跑的系統密碼視窗
    osascript - "$@" <<'AS'
on run argv
  set cmd to ""
  repeat with a in argv
    set cmd to cmd & quoted form of (a as text) & " "
  end repeat
  do shell script cmd with administrator privileges with prompt "cool42 需要管理員權限，把改名前的 cool42 daemon、設定與統計搬過來"
end run
AS
  fi
}

write_restore_script() {
  cat > "$B/restore.sh" <<'SH'
#!/bin/bash
# 由 scripts/migrate-from-cool42.sh 產生：把這次搬遷收進備份區的舊檔搬回原位。用法：sudo bash restore.sh
set -uo pipefail
B="$(cd "$(dirname "$0")" && pwd)"
M="$B/manifest.tsv"
[ "$(id -u)" = 0 ] || { echo "請用 sudo bash $0（有些舊檔在 /etc、/var、/Library）"; exit 1; }
# 已經裝了 cool42 的話先停它，免得兩個 guard 搶風扇
launchctl bootout system/com.cool42.guard 2>/dev/null && echo "已停 cool42 guard"
tail -r "$M" | while IFS=$'\t' read -r kind a b; do
  case "$kind" in
    moved)
      if [ -e "$a" ] || [ -L "$a" ]; then echo "略過（原位置已經有東西）：$a"
      else mkdir -p "$(dirname "$a")" && mv "$b" "$a" && echo "已搬回 $a"; fi ;;
    copied) cp -p "$b" "$a" && echo "已還原 $a" ;;
    created) echo "保留搬遷時建立的新檔：${a}（要清掉請自己處理）" ;;
  esac
done
if grep -q '^guard-was-loaded' "$M" && [ -f /Library/LaunchDaemons/com.cool42.guard.plist ]; then
  launchctl bootstrap system /Library/LaunchDaemons/com.cool42.guard.plist && echo "已重新載入舊 guard（com.cool42.guard）"
fi
U="$(stat -f '%Su' "$B")"
echo
echo "接著用一般使用者（${U}）執行："
if grep -q $'^moved\t.*/LaunchAgents/com.cool42.panel.plist' "$M"; then
  echo "  launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.cool42.panel.plist    # 舊面板"
fi
if [ -f "$B/mcp-cool42.txt" ]; then
  echo "  claude mcp remove --scope user cool42; 照 $B/mcp-cool42.txt 的 Command/Args 重新 claude mcp add --scope user cool42 -- …"
fi
SH
  chmod 755 "$B/restore.sh"
}

user_stage_panel() {
  say "▶ 面板偏好備份（面板偏好本身由新面板第一次啟動時讀過來）"
  if defaults read "$OLD_LABEL_PANEL" >/dev/null 2>&1; then
    say "  • defaults export $OLD_LABEL_PANEL → 備份區"
    run defaults export "$OLD_LABEL_PANEL" "$B/$OLD_LABEL_PANEL.plist"
    [ "$DRY" = 1 ] || plutil -lint "$B/$OLD_LABEL_PANEL.plist" >/dev/null || die "面板偏好備份檔不是有效的 plist"
  else
    say "  • 沒有 $OLD_LABEL_PANEL 偏好，略過"
  fi

  say "▶ 停舊面板、收掉舊 LaunchAgent 與 app"
  if launchctl print "gui/$(id -u)/$OLD_LABEL_PANEL" >/dev/null 2>&1; then
    run launchctl bootout "gui/$(id -u)/$OLD_LABEL_PANEL" || true
  fi
  if pgrep -x cool42-panel >/dev/null 2>&1; then run pkill -x cool42-panel || true; fi
  if [ "$DRY" = 0 ]; then
    for _ in $(seq 1 20); do pgrep -x cool42-panel >/dev/null 2>&1 || break; sleep 0.25; done
    pgrep -x cool42-panel >/dev/null 2>&1 && die "舊面板 cool42-panel 關不掉"
  fi
  retire "$HOME/Library/LaunchAgents/$OLD_LABEL_PANEL.plist"
  retire "$OLD_APP"
  say "  • 完成"
}

user_stage_config() {
  say "▶ 使用者層設定 ~/.config/cool42 → ~/.config/cool42（專注模式旗標、使用者層 config.json）"
  local old="$HOME/.config/cool42" new="$HOME/.config/cool42"
  if [ ! -d "$old" ]; then say "  • 沒有 ${old}，略過"; return 0; fi
  local f
  for f in "$old"/*; do [ -f "$f" ] && carry "$f" "$new/$(basename "$f")"; done
  fix_allow_list "$new/config.json"
  retire "$old"
}

user_stage_claude() {
  if [ "$SKIP_CLAUDE" = 1 ]; then say "▶ 略過 Claude Code hook／MCP（--skip-claude）"; return 0; fi

  local s="$HOME/.claude/settings.json"
  say "▶ Claude Code hook：$s 的 cool42 hook 換成 cool42"
  if settings_has_old_hook; then
    have_python || die "沒有可用的 python3，無法安全改 ${s}；請手動把 \"/usr/local/bin/cool42 hook\" 改成 \"/usr/local/bin/cool42 hook\" 後重跑"
    say "  • 備份 $s → 備份區，再精準改 hooks.PreToolUse 裡那一條"
    if [ "$DRY" = 0 ]; then
      cp -p "$s" "$B/settings.json"
      cmp -s "$s" "$B/settings.json" || die "settings.json 備份失敗"
      record copied "$s" "$B/settings.json"
      python3 - "$s" <<'PY' || die "改寫 settings.json 失敗（原檔已備份，沒有動到）"
import json, os, shutil, sys, tempfile
p = sys.argv[1]
s = json.load(open(p, encoding="utf-8"))
pre = s.get("hooks", {}).get("PreToolUse", [])
has_new = any("cool42 hook" in h.get("command", "") for e in pre for h in e.get("hooks", []))
out = []
for e in pre:
    hooks = e.get("hooks", [])
    kept = []
    for h in hooks:
        c = h.get("command", "")
        if "cool42 hook" in c:
            if has_new:
                continue                       # 已經有 cool42 hook：舊的直接拿掉，不重複
            h = dict(h); h["command"] = c.replace("cool42 hook", "cool42 hook"); has_new = True
        kept.append(h)
    if hooks and not kept:
        continue                               # 這個 matcher 只剩舊 hook：整條拿掉
    if hooks:
        e = dict(e); e["hooks"] = kept
    out.append(e)
s["hooks"]["PreToolUse"] = out
text = json.dumps(s, ensure_ascii=False, indent=2) + "\n"
chk = json.loads(text)
cmds = [h.get("command", "") for e in chk["hooks"]["PreToolUse"] for h in e.get("hooks", [])]
assert not any("cool42 hook" in c for c in cmds) and any("cool42 hook" in c for c in cmds), "改寫結果不對"
d = os.path.dirname(p)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.json.")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(text)
shutil.copymode(p, tmp)
os.replace(tmp, p)
PY
      settings_has_old_hook && die "改完 settings.json 還有 cool42 hook"
      grep -q 'cool42 hook' "$s" || die "改完 settings.json 找不到 cool42 hook"
    else
      say "    [dry-run] cp -p $s $B/settings.json；hooks.PreToolUse 裡 \"…/cool42 hook\" → \"…/cool42 hook\"（已有 cool42 hook 就只拿掉舊的）"
    fi
  else
    say "  • settings.json 裡沒有 cool42 hook，略過"
  fi
  if [ ! -x /usr/local/bin/cool42 ]; then
    warn "/usr/local/bin/cool42 還沒裝：搬遷後到跑完 ./install.sh 之前（舊的 cool42 CLI 已收進備份區），Claude Code 每次 Bash 呼叫的 hook 會出現 command not found（不會擋工作）。請接著跑 ./install.sh"
  fi

  say "▶ Claude Code MCP server：cool42 → cool42"
  if ! command -v claude >/dev/null 2>&1; then say "  • 找不到 claude CLI，略過"; return 0; fi
  if claude mcp get cool42 >/dev/null 2>&1; then
    say "  • 記下舊設定（claude mcp get cool42 → 備份區 mcp-cool42.txt），再移除"
    if [ "$DRY" = 0 ]; then
      claude mcp get cool42 > "$B/mcp-cool42.txt" 2>&1 || true
      claude mcp remove --scope user cool42 >/dev/null 2>&1 || claude mcp remove cool42 >/dev/null 2>&1 || die "claude mcp remove cool42 失敗"
      claude mcp get cool42 >/dev/null 2>&1 && die "claude mcp remove cool42 之後還查得到"
      record mcp-removed cool42 "$B/mcp-cool42.txt"
    else
      run claude mcp remove --scope user cool42
    fi
  else
    say "  • 沒有叫 cool42 的 MCP server，略過移除"
  fi
  if claude mcp get cool42 >/dev/null 2>&1; then
    say "  • cool42 MCP server 已經註冊，略過"
  elif ! command -v uv >/dev/null 2>&1; then
    warn "找不到 uv（MCP server 用它跑），cool42 MCP 沒註冊；裝好 uv 後跑 scripts/install-mcp.sh"
  else
    say "  • 註冊 cool42：$MCP_SCRIPT"
    run claude mcp add --scope user cool42 -- uv run --script --quiet "$MCP_SCRIPT"
    [ "$DRY" = 1 ] || claude mcp get cool42 >/dev/null 2>&1 || die "claude mcp add cool42 之後查不到"
  fi
}

statusline_hint() {
  local sl="$HOME/.claude/scripts/statusline.py"
  [ -f "$sl" ] && grep -q '/var/run/cool42' "$sl" || return 0
  echo
  say "ℹ️  $sl 讀的是舊路徑 /var/run/cool42（這支腳本不改它），裝好 cool42 後狀態列的溫度會消失。要改的話："
  grep -n '/var/run/cool42' "$sl" | sed 's/^/     /'
  say "     改法：把 /var/run/cool42 換成 /var/run/cool42（例如 sed -i '' 's#/var/run/cool42#/var/run/cool42#g' \"$sl\"，改前先備份）"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY=1 ;;
      --detect) DETECT=1 ;;
      --skip-claude) SKIP_CLAUDE=1 ;;
      --mcp-script) MCP_SCRIPT="${2:?--mcp-script 要給路徑}"; shift ;;
      --root-stage) shift; root_stage "$@"; exit 0 ;;
      -h|--help) sed -n '2,8p' "$SELF"; exit 0 ;;
      *) die "不認得的參數：$1（可用 --dry-run / --detect / --skip-claude / --mcp-script PATH）" ;;
    esac
    shift
  done

  if [ "$DETECT" = 1 ]; then if anything_left; then exit 0; else exit 1; fi; fi
  [ "$(id -u)" != "0" ] || die "請用一般使用者身分執行（需要 root 的步驟會自己跳系統密碼視窗），不要 sudo"

  say "cool42 搬遷：從改名前的 cool42 搬過來$([ "$DRY" = 1 ] && echo '（dry-run：只印計畫，不動任何東西）')"
  if ! anything_left; then say "沒有偵測到 cool42 的殘留，不需要搬遷。"; exit 0; fi
  say "偵測到的舊版項目："
  { guard_loaded && echo "（執行中的 guard ${OLD_LABEL_GUARD}）"; root_leftovers; user_leftovers; } | sed 's/^/  - /'
  exists "$NEW_APP" && say "（已經有 ${NEW_APP}，保留不動）"

  if [ "$DRY" = 1 ]; then
    B="$HOME/cool42-migration-backup-YYYYmmdd-HHMMSS"
  else
    B="$HOME/cool42-migration-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -m 700 "$B" || die "建不了備份目錄 $B"
    : > "$B/manifest.tsv"
    write_restore_script
  fi
  say "備份目錄：$B"
  echo

  # root 階段放最前面：密碼視窗按取消（osascript -128）時，使用者層的東西（面板、LaunchAgent、settings.json）都還沒動，
  # 舊 guard 和舊面板照常在跑，不需要 restore.sh
  if [ "$DRY" = 1 ]; then
    say "▶ 以下是 root 階段（實際執行時會跳一次系統密碼視窗）"
    root_stage "$B" "$(id -un)" 1
  else
    say "▶ root 階段（會跳系統密碼視窗）"
    as_root /bin/bash "$SELF" --root-stage "$B" "$(id -un)" 0 || die "root 階段失敗或密碼視窗被取消（使用者層的面板與設定都還沒動）"
    # 驗證 root 階段真的做完（osascript 路徑看不到 root 端的 exit code 以外的東西）
    guard_loaded && die "舊 guard 還在跑"
    [ -z "$(root_leftovers)" ] || die "root 階段之後還有舊檔：$(root_leftovers | tr '\n' ' ')"
  fi
  echo
  user_stage_panel
  echo
  user_stage_config
  echo
  user_stage_claude
  statusline_hint

  echo
  if [ "$DRY" = 1 ]; then
    say "（dry-run 結束，沒有動任何東西。實際執行：${SELF}）"
  else
    say "✅ 搬遷完成。舊檔都在 ${B}（還原：sudo bash '$B/restore.sh'）。"
    say "   接下來跑 ./install.sh 裝 cool42（install.sh 自己呼叫這支時會接著裝）。確認沒問題後備份目錄可以刪（裡面有 root 的檔案，要 sudo rm -rf）。"
  fi
}

main "$@"
