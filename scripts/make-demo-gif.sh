#!/bin/bash
# docs/img/demo.gif（中文）／docs/img/demo-en.gif（英文說明文字）：
#   面板閒置 → 重負載（熱度格轉紅、轉速拉高）→ 降頻（受控情境）→ Claude Code 跑 build 時 hook 等降溫 → 放行
# 幀全部離屏渲染（scripts/render-panel.sh 建的 cool42-snapshot），不錄螢幕、不需權限。只用 ffmpeg 組 GIF。
#
#   scripts/make-demo-gif.sh        → docs/img/demo.gif
#   scripts/make-demo-gif.sh en     → docs/img/demo-en.gif（面板 UI 本身仍是中文，說明文字與終端機註解是英文）
set -euo pipefail
LANG_OUT="${1:-zh}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${COOL42_SNAPSHOT_WORK:-${TMPDIR:-/tmp}/cool42-snapshot}"
FR="$WORK/gif-frames-$LANG_OUT"; mkdir -p "$FR"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"
"$REPO/scripts/render-panel.sh" "$FR" idle >/dev/null     # 順便建好 cool42-snapshot
BIN="$WORK/.build/release/cool42-snapshot"
SC="$REPO/scripts/snapshot/scenarios"

if [ "$LANG_OUT" = "en" ]; then
  S0="Idle: quiet fan, guard on watch"
  B0="The heat grid has one cell per SMC sensor: 73 P-core, E-core and GPU sensors on an M4. The fan follows the hottest cell. (Panel UI is in Traditional Chinese.)"
  S1="Heavy load: grid turns red, fan ramps up"
  B1="Real capture: ffmpeg 4K encode. 92°C, P-core 3.93 GHz, pressure Nominal — hot but not throttled, so the AI keeps going at full speed."
  S2="Throttling: pressure Moderate"; T2="Simulated · not a recorded event"
  B2="P-core drops to 3.52 GHz. Only now does the hook make the AI's heavy command wait."
  FRAMES="$REPO/scripts/snapshot/terminal-frames-en.json"; OUT="$REPO/docs/img/demo-en.gif"
else
  S0="閒置：風扇安靜、guard 待命"
  B0="熱度格一格一個 SMC 感測器：M4 上 P-core、E-core、GPU 共 73 個。風扇看的是最熱那一格。"
  S1="重負載：熱度格轉紅、風扇拉高"
  B1="實機取樣：ffmpeg 4K 編碼。溫度 92°C、P-core 3.93 GHz、pressure Nominal —— 熱但沒降頻，AI 照常全速開工。"
  S2="macOS 回報降頻：pressure Moderate"; T2="受控情境 · 非實機紀錄"
  B2="P-core 掉到 3.52 GHz。只有這時，hook 才讓 AI 的重指令先等降溫。"
  FRAMES="$REPO/scripts/snapshot/terminal-frames.json"; OUT="$REPO/docs/img/demo.gif"
fi

"$BIN" "$SC/idle.json" "$FR/p0" --stage "$S0" --body "$B0"
i=1
for t in 0.2 0.4 0.6 0.8 1.0; do
  "$BIN" "$SC/idle.json" "$FR/p$i" --mix "$SC/load.json" --t $t --stage "$S1" --body "$B1"
  i=$((i + 1))
done
"$BIN" "$SC/throttle.json" "$FR/p6" --stage "$S2" --tag "$T2" --body "$B2"
"$BIN" --terminal "$FRAMES" "$FR"

# 每幀停留秒數（concat demuxer：最後一幀要重複一次 duration 才會生效）
LIST="$FR/list.txt"; : > "$LIST"
add() { echo "file '$FR/$1.png'" >> "$LIST"; echo "duration $2" >> "$LIST"; }
add p0 2.0; add p1 0.35; add p2 0.35; add p3 0.35; add p4 0.35; add p5 2.2; add p6 2.6
add term-1-wait 1.8; add term-2-wait 1.8; add term-3-pass 3.2
echo "file '$FR/term-3-pass.png'" >> "$LIST"

"$FFMPEG" -hide_banner -loglevel error -y -f concat -safe 0 -i "$LIST" \
  -vf "fps=10,scale=880:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" \
  -loop 0 "$OUT"
ls -la "$OUT"
