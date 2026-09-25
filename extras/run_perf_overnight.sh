#!/bin/bash
# 過夜跑 perf_vs_temp.py：「macOS 原廠自動 vs cool42 曲線」同機同負載穩態對照。
#
# 用法（在 Ghostty 等終端機裡跑，開頭會問一次 sudo 密碼）：
#   extras/run_perf_overnight.sh                         # 預設 --modes curve auto --repeat 2 --sample 90 --gpu
#   extras/run_perf_overnight.sh --cpu-only              # 不加 GPU 負載
#   extras/run_perf_overnight.sh --modes curve auto 3000 # 其餘參數原樣交給 perf_vs_temp.py
#   LOAD_MAX=2 WAIT_IDLE_MIN=60 extras/run_perf_overnight.sh
#   extras/run_perf_overnight.sh --dry-run               # 只做檢查並印計畫，不問密碼、不量測
#
# 流程：檢查 cool42 / guard → 空閒檢查（load avg 門檻，不空閒就等，逾時放棄並通知）→
#       sudo 一次（背景續期，等空閒期間不會過期）→ caffeinate 防睡 → 備份設定檔 → sudo 跑量測 →
#       腳本自己再比對一次設定檔、不一致就寫回 → macOS 通知。
# log 與結果：~/cool42-perf-<時間>/（run.log 是整段終端輸出，其餘見 docs/perf-vs-temp.md）
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PERF="${HERE}/perf_vs_temp.py"
CONFIG="/etc/cool42/config.json"
LOAD_MAX="${LOAD_MAX:-3.0}"            # 1 分鐘 load avg 高於此值就算不空閒
WAIT_IDLE_MIN="${WAIT_IDLE_MIN:-30}"   # 最多等空閒幾分鐘
# 以 root 執行的直譯器：預設用系統的 /usr/bin/python3（root 擁有、使用者改不了），不用 PATH 上使用者可寫的 Homebrew python。
# 系統那份不能用（沒裝 Command Line Tools）才退回 PATH 上的 python3；要指定就 PYTHON=/path/to/python3
if [ -n "${PYTHON:-}" ]; then PY="${PYTHON}"
elif /usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then PY=/usr/bin/python3
else PY="$(command -v python3 || echo /usr/bin/python3)"; fi
STAMP="$(date +%Y%m%d-%H%M)"
OUT="$HOME/cool42-perf-${STAMP}"

DRY=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1; done
# 使用者沒給 --modes / --repeat / --sample 就用過夜預設
EXTRA=()
case " $* " in *" --modes "*) ;; *) EXTRA+=(--modes curve auto) ;; esac
case " $* " in *" --repeat "*) ;; *) EXTRA+=(--repeat 2) ;; esac
case " $* " in *" --sample "*) ;; *) EXTRA+=(--sample 90) ;; esac
# 預設 CPU＋GPU 一起滿載（要抓原廠降頻，只跑 CPU 在 108°C 內抓不到）；只要 CPU 就給 --cpu-only
CPU_ONLY=0; ARGS=()
for a in "$@"; do if [ "$a" = "--cpu-only" ]; then CPU_ONLY=1; else ARGS+=("$a"); fi; done
set -- ${ARGS[@]+"${ARGS[@]}"}
case " $* " in *" --gpu "*) ;; *) [ "${CPU_ONLY}" = 1 ] || EXTRA+=(--gpu) ;; esac

notify() {  # $1 標題 $2 內容
  local t="${1//\"/\'}" m="${2//\"/\'}"
  osascript -e "display notification \"$m\" with title \"$t\" sound name \"Glass\"" >/dev/null 2>&1 || true
}
say() { printf '%s\n' "$*"; }

loadavg1() { sysctl -n vm.loadavg | awk '{print $2}'; }
over_max() { awk -v a="$1" -v b="${LOAD_MAX}" 'BEGIN{exit !(a>b)}'; }
show_heavy() {
  say "  目前最吃 CPU 的程式（請先關掉重程式：Xcode、瀏覽器分頁、Docker、Blender、Fusion、影片轉檔、其他 Claude session 的 build…）："
  ps -Aco pcpu=,comm= -r | head -6 | awk '{ $1=sprintf("%5.1f%%", $1); print "    " $0 }'
}

# ---------- 前置檢查 ----------
[ "$(uname)" = "Darwin" ] || { say "只支援 macOS"; exit 1; }
[ -f "${PERF}" ] || { say "找不到 ${PERF}"; exit 1; }
command -v cool42 >/dev/null 2>&1 || [ -x /usr/local/bin/cool42 ] || { say "找不到 cool42，先安裝"; exit 1; }
COOL42="$(command -v cool42 || echo /usr/local/bin/cool42)"
[ -f "${CONFIG}" ] || { say "找不到 ${CONFIG}：guard 沒載入設定檔就不會熱重載，量不了"; exit 1; }
if ! "${COOL42}" status --json | "${PY}" -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("guardRunning") else 1)'; then
  say "cool42 guard 沒在跑；先跑 cool42 doctor 看原因"; exit 1
fi

if [ "${DRY}" = 1 ]; then
  say "== run_perf_overnight dry-run =="
  la="$(loadavg1)"
  if over_max "${la}"; then say "空閒檢查：load avg ${la} > ${LOAD_MAX}，實跑時會等最多 ${WAIT_IDLE_MIN} 分鐘"; show_heavy
  else say "空閒檢查：load avg ${la} ≤ ${LOAD_MAX}，可以開跑"; fi
  say "實跑會：sudo 一次 → caffeinate -ims → sudo ${PY} perf_vs_temp.py ${EXTRA[*]:-} $* --out-dir ${OUT}"
  say "log：${OUT}/run.log；完成用 macOS 通知"
  echo
  exec "${PY}" "${PERF}" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
fi

mkdir -p "${OUT}" || exit 1
LOG="${OUT}/run.log"
exec > >(tee -a "${LOG}") 2>&1
say "== cool42 過夜量測 $(date '+%Y-%m-%d %H:%M') =="
say "輸出：${OUT}"

# ---------- sudo（先問，背景續期） ----------
say "需要 sudo（powermetrics 要 root）。輸入一次密碼後就可以離開，跑完會跳通知。"
sudo -v || { say "sudo 驗證失敗"; exit 1; }
( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
KEEPALIVE=$!

# 防睡：跟著這支腳本的 PID，腳本結束就放手。不帶 -d：螢幕可以關（少一份 WindowServer 負載），系統不睡
caffeinate -ims -w $$ &
CAFF=$!

cleanup() {
  kill "${KEEPALIVE}" "${CAFF}" 2>/dev/null
  # 備份不存在或是空檔（還沒拍、或拍失敗）就絕不寫回：寫回用「> CONFIG」，會先把設定檔清成 0 byte
  [ -s "${OUT}/config.backup.json" ] || return 0
  # 設定檔若和開跑前不同（例如量測程式被 kill -9），原位寫回（不換 inode、不改擁有者）
  if ! cmp -s "${OUT}/config.backup.json" "${CONFIG}"; then
    if cat "${OUT}/config.backup.json" > "${CONFIG}" 2>/dev/null || sudo -n sh -c "cat '${OUT}/config.backup.json' > '${CONFIG}'"; then
      say "⚠ 設定檔和開跑前不同，已由啟動腳本寫回"
    else
      say "⚠⚠ 設定檔和開跑前不同且寫不回去：cp ${OUT}/config.backup.json ${CONFIG}"
      notify "cool42 量測：設定檔要手動還原" "cp ~/cool42-perf-${STAMP}/config.backup.json ${CONFIG}"
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---------- 空閒檢查 ----------
deadline=$(( $(date +%s) + WAIT_IDLE_MIN * 60 ))
while :; do
  la="$(loadavg1)"
  if ! over_max "${la}"; then say "空閒檢查通過：load avg ${la} ≤ ${LOAD_MAX}"; break; fi
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    say "等了 ${WAIT_IDLE_MIN} 分鐘 load avg 仍是 ${la}（> ${LOAD_MAX}），這次不量"; show_heavy
    notify "cool42 量測沒跑" "機器一直不空閒（load avg ${la}），看 ~/cool42-perf-${STAMP}/run.log"
    exit 2
  fi
  say "$(date +%H:%M) load avg ${la} > ${LOAD_MAX}，等空閒（最晚 $(date -r "${deadline}" +%H:%M)）"; show_heavy
  sleep 60
done

# ---------- 備份（第二道保險：量測腳本若被 kill -9，cleanup 還能寫回） ----------
# 放在空閒等待之後、量測前一刻：等待期間使用者在面板改的設定要算進去，不然結束時會被較舊的備份蓋回去。
# 先寫暫存檔、比對一致才改名：cp 寫到一半失敗（磁碟滿）也不會留下殘缺的備份
if cp -p "${CONFIG}" "${OUT}/config.backup.json.tmp" && cmp -s "${CONFIG}" "${OUT}/config.backup.json.tmp" \
   && [ -s "${OUT}/config.backup.json.tmp" ]; then
  mv "${OUT}/config.backup.json.tmp" "${OUT}/config.backup.json"
else
  say "備份設定檔失敗（${OUT} 寫不進去？），這次不量"
  notify "cool42 量測沒跑" "備份設定檔失敗，看 ~/cool42-perf-${STAMP}/run.log"
  exit 1
fi

# ---------- 量測 ----------
T0=$(date +%s)
sudo -n "${PY}" "${PERF}" ${EXTRA[@]+"${EXTRA[@]}"} "$@" --out-dir "${OUT}"
RC=$?
MIN=$(( ($(date +%s) - T0) / 60 ))
sudo -n chown -R "$(id -u):$(id -g)" "${OUT}" 2>/dev/null

if [ "${RC}" = 0 ]; then
  say "完成（${MIN} 分鐘）：${OUT}/summary.md"
  notify "cool42 量測完成" "${MIN} 分鐘；結果在 ~/cool42-perf-${STAMP}/summary.md"
else
  say "量測結束但不完整（exit ${RC}，${MIN} 分鐘），看 ${LOG}"
  notify "cool42 量測未完成（exit ${RC}）" "看 ~/cool42-perf-${STAMP}/run.log"
fi
exit "${RC}"
