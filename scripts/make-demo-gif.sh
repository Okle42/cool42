#!/bin/bash
# docs/img/demo.gif：面板閒置 → 重負載（熱度格轉紅、轉速拉高）→ 降頻（受控情境）→ Claude Code 跑 build 時 hook 等降溫 → 放行
# 幀全部離屏渲染（scripts/render-panel.sh 建的 cool42-snapshot），不錄螢幕、不需權限。只用 ffmpeg 組 GIF。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${COOL42_SNAPSHOT_WORK:-${TMPDIR:-/tmp}/cool42-snapshot}"
FR="$WORK/gif-frames"; mkdir -p "$FR"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"
"$REPO/scripts/render-panel.sh" "$FR" idle >/dev/null     # 順便建好 cool42-snapshot
BIN="$WORK/.build/release/cool42-snapshot"
SC="$REPO/scripts/snapshot/scenarios"

"$BIN" "$SC/idle.json" "$FR/p0" --stage "閒置：風扇安靜，guard 在背景看著" \
  --body "熱度格一格一個 SMC 感測器：M4 上 P-core、E-core、GPU 共 73 個。風扇看的是最熱那一格。"
i=1
for t in 0.2 0.4 0.6 0.8 1.0; do
  "$BIN" "$SC/idle.json" "$FR/p$i" --mix "$SC/load.json" --t $t --stage "重負載：熱度格轉紅、風扇拉高" \
    --body "實機取樣：ffmpeg 4K 編碼。溫度 92°C、P-core 3.93 GHz、pressure Nominal —— 熱但沒降頻，AI 照常全速開工。"
  i=$((i + 1))
done
"$BIN" "$SC/throttle.json" "$FR/p6" --stage "真的降頻了：pressure Moderate" --tag "受控情境 · 非實機紀錄" \
  --body "P-core 掉到 3.52 GHz。只有這時，hook 才讓 AI 的重指令先等降溫。"
"$BIN" --terminal "$REPO/scripts/snapshot/terminal-frames.json" "$FR"

# 每幀停留秒數（concat demuxer：最後一幀要重複一次 duration 才會生效）
LIST="$FR/list.txt"; : > "$LIST"
add() { echo "file '$FR/$1.png'" >> "$LIST"; echo "duration $2" >> "$LIST"; }
add p0 2.0; add p1 0.35; add p2 0.35; add p3 0.35; add p4 0.35; add p5 2.2; add p6 2.6
add term-1-wait 1.8; add term-2-wait 1.8; add term-3-pass 3.2
echo "file '$FR/term-3-pass.png'" >> "$LIST"

OUT="$REPO/docs/img/demo.gif"
"$FFMPEG" -hide_banner -loglevel error -y -f concat -safe 0 -i "$LIST" \
  -vf "fps=10,scale=880:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" \
  -loop 0 "$OUT"
ls -la "$OUT"
