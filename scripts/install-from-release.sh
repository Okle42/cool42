#!/bin/bash
# 從 release zip 安裝 cool42（不需要原始碼、不需要 swift）。打包後在 zip 裡叫 install.sh。
# 原始碼安裝請用專案根目錄的 install.sh（會先 swift build），兩條路裝出來的東西一樣。
#
#   ./install.sh                  安裝或升級：CLI＋guard LaunchDaemon(root)＋選單列面板＋Claude Code hook/MCP
#   ./install.sh --skip-claude    不動 Claude Code 的 hook 與 MCP
#   ./install.sh --cask           面板 .app 已由 Homebrew 放進 /Applications（從 Caskroom 以 cool42-setup 執行時會自動判斷）
#   ./install.sh --uninstall      移除（/etc/cool42/config.json 保留）；加 --keep-app 不刪 /Applications 的面板
#
# root 步驟：有 sudo 快取或 TTY 就走 sudo，否則跳 macOS 系統密碼視窗。
# 支援檔會裝到 /usr/local/share/cool42（MCP server 從那裡跑、之後也可以用那裡的 uninstall.sh 移除），
# 所以下載的 zip 解壓目錄裝完可以直接刪掉。
set -euo pipefail

APP_NAME="cool42 Panel.app"
APP="/Applications/$APP_NAME"
SHARE="/usr/local/share/cool42"
LABEL_GUARD="com.cool42.guard"
LABEL_PANEL="com.cool42.panel"

# Homebrew 會把這支腳本 symlink 成 $(brew --prefix)/bin/cool42-setup，要順著 symlink 找回 release 目錄
SELF_PATH="$0"
while [ -L "$SELF_PATH" ]; do
  link="$(readlink "$SELF_PATH")"
  case "$link" in /*) SELF_PATH="$link" ;; *) SELF_PATH="$(dirname "$SELF_PATH")/$link" ;; esac
done
SELF_DIR="$(cd "$(dirname "$SELF_PATH")" && pwd)"

die() { echo "✗ $*" >&2; exit 1; }

# 以 root 執行 "$@"：已是 root → 直接跑；有 sudo 快取或 TTY → sudo；都沒有（例如 brew postflight、Claude Code 的 ! 指令）→ 系統密碼視窗
as_root() {
  if [ "$(id -u)" = "0" ]; then "$@"
  elif sudo -n true 2>/dev/null || [ -t 0 ]; then sudo "$@"
  else
    osascript - "$@" <<'AS'
on run argv
  set cmd to ""
  repeat with a in argv
    set cmd to cmd & quoted form of (a as text) & " "
  end repeat
  do shell script cmd with administrator privileges with prompt "cool42 需要管理員權限來安裝／移除風扇控制 daemon"
end run
AS
  fi
}

# /usr/bin/python3 在沒裝 Command Line Tools 的機器上是會跳安裝視窗的 stub，先確認是真的 python
have_python() {
  local p; p="$(command -v python3 2>/dev/null)" || return 1
  [ "$p" != "/usr/bin/python3" ] && return 0
  xcode-select -p >/dev/null 2>&1
}

wait_guard_gone() {
  for _ in $(seq 1 20); do launchctl print "system/$LABEL_GUARD" >/dev/null 2>&1 || return 0; sleep 0.5; done
}

# ───────────── root 步驟（由 as_root 呼叫自己） ─────────────
root_install() {
  local src="$1" user_name="$2"
  [ -x "$src/bin/cool42" ] || die "payload 裡沒有 bin/cool42：$src"
  # 使用者可寫的暫存區只當來源：先複製到 root 自己用 mktemp 建、只有 root 能寫的目錄，之後的驗證、執行、安裝都用這份，
  # 同 uid 的程式就沒辦法在驗證完到安裝之間把檔案換掉（TOCTOU）
  local pay; pay="$(mktemp -d /var/tmp/cool42-root.XXXXXX)" || die "建不了 root 暫存目錄"
  trap 'rm -rf "$pay"' EXIT
  cp -R "$src/." "$pay/"
  chown -R root:wheel "$pay"; chmod -R go-w "$pay"
  verify_payload "$pay"
  mkdir -p /usr/local/bin /etc/cool42 /etc/newsyslog.d "$(dirname "$SHARE")"

  # 不能就地 cp 覆寫：舊 binary 的簽章快取還在，kernel 會用 OS_REASON_CODESIGNING 殺掉新 process。寫暫存檔再 mv 換 inode
  cp "$pay/bin/cool42" /usr/local/bin/cool42.new
  chmod 755 /usr/local/bin/cool42.new
  chown root:wheel /usr/local/bin/cool42.new
  if [ "$(cat "$pay/SIGNING" 2>/dev/null)" = "adhoc" ]; then
    # 沒公證的 binary 帶 quarantine 會被 Gatekeeper 擋在 launchd 門外
    xattr -c /usr/local/bin/cool42.new 2>/dev/null || true
  fi
  # 簽章一律不重簽：驗證失敗就中止（被竄改的 binary 不能被悄悄重簽成 ad-hoc 再以 root 裝進 LaunchDaemon）
  codesign --verify --strict /usr/local/bin/cool42.new 2>/dev/null || { rm -f /usr/local/bin/cool42.new; die "bin/cool42 簽章驗證失敗，中止安裝"; }
  mv -f /usr/local/bin/cool42.new /usr/local/bin/cool42
  ln -sf cool42 /usr/local/bin/cool42-guard   # daemon 用這個名字啟動，登入項目才分得清

  # 支援檔（MCP server、hook 片段、移除腳本）放固定位置，zip 解壓目錄裝完就能刪
  rm -rf "$SHARE.new"
  mkdir -p "$SHARE.new"
  for f in install.sh uninstall.sh install scripts mcp config.example.json LICENSE README.md README.en.md CHANGELOG.md VERSION SIGNING COMMIT; do
    if [ -e "$pay/$f" ]; then cp -R "$pay/$f" "$SHARE.new/"; fi
  done
  xattr -cr "$SHARE.new" 2>/dev/null || true
  chown -R root:wheel "$SHARE.new"
  chmod -R go-w,a+rX "$SHARE.new"
  rm -rf "$SHARE"; mv "$SHARE.new" "$SHARE"

  [ -f /etc/cool42/config.json ] || cp "$pay/config.example.json" /etc/cool42/config.json
  # 設定檔交給使用者可寫，面板才能改模式/曲線；guard 偵測到修改會自動重載
  chown "$user_name" /etc/cool42/config.json
  cp "$pay/install/newsyslog-cool42.conf" /etc/newsyslog.d/cool42.conf
  cp "$pay/install/com.cool42.guard.plist" /Library/LaunchDaemons/
  chown root:wheel /Library/LaunchDaemons/com.cool42.guard.plist
  chmod 644 /Library/LaunchDaemons/com.cool42.guard.plist

  # bootout 後 guard 要先把風扇交還再退出，launchd 還沒清完就 bootstrap 會回 5 (I/O error)，等它真的消失再裝
  launchctl bootout "system/$LABEL_GUARD" 2>/dev/null || true
  wait_guard_gone
  # 1.0.2 以前的執行期檔案放 /tmp（有 symlink 風險），升級時清掉
  rm -rf /tmp/cool42.json /tmp/cool42.json.tmp /tmp/cool42.history.json /tmp/cool42.history.json.tmp /tmp/cool42.events
  for i in 1 2 3; do
    launchctl bootstrap system /Library/LaunchDaemons/com.cool42.guard.plist && return 0
    echo "bootstrap 失敗，重試 ${i}…"; sleep 2
  done
  die "guard LaunchDaemon 啟動失敗，看 /var/log/cool42.err.log"
}

# payload 完整性：SHA256SUMS（打包時產生）逐檔核對；Developer ID / 公證版另外要求 codesign 驗證通過，失敗就中止、不重簽
verify_payload() {
  local pay="$1" signing
  signing="$(cat "$pay/SIGNING" 2>/dev/null || echo unknown)"
  if [ -f "$pay/SHA256SUMS" ]; then
    (cd "$pay" && /usr/bin/shasum -a 256 -c -s SHA256SUMS) || die "SHA256SUMS 核對失敗：release 目錄內容被改過，中止安裝"
  elif [ "$signing" = "adhoc" ]; then
    die "ad-hoc 版缺 SHA256SUMS，無法確認內容沒被改過，中止安裝（請重新下載 release）"
  fi
  case "$signing" in
    developer-id|notarized)
      codesign --verify --strict "$pay/bin/cool42" || die "bin/cool42 的 Developer ID 簽章驗證失敗，中止安裝"
      ;;
    adhoc)
      codesign --verify --strict "$pay/bin/cool42" || die "bin/cool42 的 ad-hoc 簽章驗證失敗，中止安裝"
      ;;
    *) die "不認得的簽章模式：${signing}" ;;
  esac
}

root_uninstall() {
  launchctl bootout "system/$LABEL_GUARD" 2>/dev/null || true
  wait_guard_gone
  # guard 收 SIGTERM 會保持轉速（等重啟接管），移除時要明確交還
  if [ -x /usr/local/bin/cool42 ]; then /usr/local/bin/cool42 fan auto 2>/dev/null || true; fi
  rm -rf /Library/LaunchDaemons/com.cool42.guard.plist /usr/local/bin/cool42 /usr/local/bin/cool42-guard \
         /etc/newsyslog.d/cool42.conf /var/db/cool42 /var/run/cool42 "$SHARE" \
         /tmp/cool42.json /tmp/cool42.history.json /tmp/cool42.events
}

# ───────────── 使用者層級步驟 ─────────────
install_panel_agent() {
  local agent="$HOME/Library/LaunchAgents/$LABEL_PANEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL_PANEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/cool42-panel</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$LABEL_PANEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$agent"
}

do_install() {
  local cask=0 skip_claude=0
  for a in "$@"; do
    case "$a" in
      --cask) cask=1 ;;
      --skip-claude) skip_claude=1 ;;
      *) die "不認得的參數：${a}（可用 --cask / --skip-claude / --uninstall）" ;;
    esac
  done
  [ "$(id -u)" != "0" ] || die "請用一般使用者身分執行（需要 root 的步驟會自己要密碼），不要 sudo ./install.sh"
  [ "$(uname -m)" = "arm64" ] || die "cool42 只支援 Apple Silicon（這台是 $(uname -m)）"
  local major; major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 14 ] || die "需要 macOS 14 以上（這台是 $(sw_vers -productVersion)）"
  [ -x "$SELF_DIR/bin/cool42" ] || die "找不到 $SELF_DIR/bin/cool42。這支腳本要在解壓後的 release 目錄裡執行；原始碼安裝請用專案根目錄的 install.sh"
  # 從 Caskroom 執行（cool42-setup）時，app 已被 brew 搬到 /Applications，自動當成 --cask
  if [ "$cask" = 0 ] && [ ! -d "$SELF_DIR/$APP_NAME" ] && [ -d "$APP" ] && [[ "$SELF_DIR" == */Caskroom/* ]]; then cask=1; fi
  if [ "$cask" = 0 ] && [ ! -d "$SELF_DIR/$APP_NAME" ]; then die "找不到 $SELF_DIR/$APP_NAME"; fi
  if pgrep -f "Macs Fan Control.app/Contents/MacOS" >/dev/null; then
    die "Macs Fan Control 正在執行，會和 cool42 guard 互搶風扇。請先退出它（含選單列常駐）再裝"
  fi

  local signing; signing="$(cat "$SELF_DIR/SIGNING" 2>/dev/null || echo unknown)"
  echo "▶ cool42 $(cat "$SELF_DIR/VERSION" 2>/dev/null || echo '?')（簽章：${signing}）"
  if [ "$signing" = "adhoc" ]; then echo "⚠️  這是未公證的 ad-hoc 版本，安裝時會清掉 quarantine 屬性讓它能執行"; fi

  # 解壓目錄常在 ~/Downloads（受 TCC 保護），root 讀那裡可能跳「存取下載項目」視窗。先搬到暫存區再交給 root
  PAYLOAD="$(mktemp -d "${TMPDIR:-/tmp}/cool42-install.XXXXXX")"
  trap 'rm -rf "$PAYLOAD"' EXIT
  local pay="$PAYLOAD"
  for f in bin install.sh uninstall.sh install scripts mcp config.example.json LICENSE README.md README.en.md CHANGELOG.md VERSION SIGNING COMMIT SHA256SUMS; do
    if [ -e "$SELF_DIR/$f" ]; then cp -R "$SELF_DIR/$f" "$pay/"; fi
  done
  chmod -R a+rX "$pay"; chmod a+rx "$pay"
  # 先在使用者這邊核對一次（及早報錯）；root 那邊會在自己的目錄再核對一次才安裝
  if [ -f "$pay/SHA256SUMS" ]; then (cd "$pay" && /usr/bin/shasum -a 256 -c -s SHA256SUMS) || die "SHA256SUMS 核對失敗：release 目錄內容被改過"; fi

  echo "▶ 安裝 CLI、guard LaunchDaemon、支援檔到 ${SHARE}（需要管理員密碼）"
  # root 不直接執行使用者可寫目錄裡的 install.sh：先複製到 root 擁有的暫存目錄、核對 SHA256SUMS，再從那份執行
  as_root /bin/bash -c 'set -e; d="$(mktemp -d /var/tmp/cool42-boot.XXXXXX)"; trap "rm -rf \"$d\"" EXIT; cp "$1/install.sh" "$d/install.sh"; [ -f "$1/SHA256SUMS" ] && cp "$1/SHA256SUMS" "$d/SHA256SUMS"; if [ -f "$d/SHA256SUMS" ]; then want="$(awk "\$2==\"install.sh\"{print \$1}" "$d/SHA256SUMS")"; have="$(/usr/bin/shasum -a 256 "$d/install.sh" | awk "{print \$1}")"; [ -n "$want" ] && [ "$want" = "$have" ] || { echo "install.sh 與 SHA256SUMS 不符，中止" >&2; exit 1; }; fi; /bin/bash "$d/install.sh" --root-install "$1" "$2"' _ "$pay" "$(id -un)"
  sleep 3
  /usr/local/bin/cool42 status || echo "⚠️  guard 可能還在啟動，稍後再跑 cool42 status"

  echo "▶ 選單列面板"
  pkill -x cool42-panel 2>/dev/null || true
  if [ "$cask" = 0 ]; then
    rm -rf "$APP"
    ditto "$SELF_DIR/$APP_NAME" "$APP" || die "無法寫入 /Applications（帳號要是管理員）"
  fi
  [ -d "$APP" ] || die "找不到 $APP"
  if [ "$signing" = "adhoc" ]; then xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true; fi
  install_panel_agent
  echo "  面板已啟動（選單列右上角），開機自動啟動"

  if [ "$skip_claude" = 1 ]; then
    echo "▶ 略過 Claude Code hook/MCP（--skip-claude）"
  elif ! command -v claude >/dev/null && [ ! -d "$HOME/.claude" ]; then
    echo "▶ 沒偵測到 Claude Code，略過 hook/MCP。之後裝了 Claude Code 再跑 $SHARE/scripts/install-hook.py 與 $SHARE/scripts/install-mcp.sh"
  else
    echo "▶ Claude Code hook"
    if have_python; then python3 "$SHARE/scripts/install-hook.py"
    else echo "  沒有可用的 python3，請手動把 $SHARE/install/claude-settings.snippet.json 合併進 ~/.claude/settings.json"; fi
    echo "▶ Claude Code MCP server"
    "$SHARE/scripts/install-mcp.sh" || echo "  ⚠️  MCP 註冊失敗（不影響風扇控制與 hook）"
  fi

  echo
  echo "✅ 完成。log：tail -f /var/log/cool42.log；移除：$SHARE/uninstall.sh"
}

do_uninstall() {
  local keep_app=0
  for a in "$@"; do
    case "$a" in
      --keep-app) keep_app=1 ;;
      *) die "不認得的參數：$a" ;;
    esac
  done
  [ "$(id -u)" != "0" ] || die "請用一般使用者身分執行（需要 root 的步驟會自己要密碼）"

  if [ -e /Library/LaunchDaemons/com.cool42.guard.plist ] || [ -e /usr/local/bin/cool42 ] || [ -e "$SHARE" ] \
     || launchctl print "system/$LABEL_GUARD" >/dev/null 2>&1; then
    echo "▶ 停止並移除 guard、CLI、支援檔（需要管理員密碼）"
    # 從 /usr/local/share/cool42 執行時，root 步驟會刪掉那個目錄，所以先把自己複製到暫存區再交給 root
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cool42-uninstall.XXXXXX")"
    cp "$SELF_PATH" "$tmp"
    chmod a+rx "$tmp"
    as_root /bin/bash "$tmp" --root-uninstall
    rm -f "$tmp"
  else
    echo "▶ 沒有裝 guard/CLI（可能沒跑過 cool42-setup），略過需要管理員密碼的步驟"
  fi

  launchctl bootout "gui/$(id -u)/$LABEL_PANEL" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$LABEL_PANEL.plist"
  pkill -x cool42-panel 2>/dev/null || true
  [ "$keep_app" = 1 ] || rm -rf "$APP"

  if command -v claude >/dev/null; then
    claude mcp remove --scope user cool42 >/dev/null 2>&1 && echo "已移除 Claude Code MCP server" || true
  fi
  if [ -f "$HOME/.claude/settings.json" ] && have_python; then
    python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
s = json.load(open(p)); pre = s.get("hooks", {}).get("PreToolUse", [])
kept = [e for e in pre if not any("cool42 hook" in h.get("command", "") for h in e.get("hooks", []))]
if len(kept) != len(pre):
    s["hooks"]["PreToolUse"] = kept
    json.dump(s, open(p, "w"), ensure_ascii=False, indent=2); print("已移除 Claude Code hook")
PY
  fi
  echo "已移除 daemon、CLI、面板（/etc/cool42/config.json 保留）。風扇已交還 SMC 自動控制。"
}

main() {
  case "${1:-}" in
    --root-install) shift; [ "$(id -u)" = "0" ] || die "--root-install 需要 root"; root_install "$@" ;;
    --root-uninstall) [ "$(id -u)" = "0" ] || die "--root-uninstall 需要 root"; root_uninstall ;;
    --uninstall) shift; do_uninstall "$@" ;;
    *) do_install "$@" ;;
  esac
}

# 整支包在 main 裡：移除時會刪掉 /usr/local/share/cool42 裡正在跑的這支腳本，先讀完再執行才安全
main "$@"
exit
