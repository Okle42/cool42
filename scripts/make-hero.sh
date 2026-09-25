#!/bin/bash
# README 的 hero 圖：docs/img/screens/hero.png（中文）／hero-en.png（英文，面板也用英文介面）
#   左邊文案＋2026-09-25 同機實測的三個數字（寫死在 scripts/snapshot/main.swift 的 renderHero，出處見 docs/perf-2026-09-25/README.md），
#   右邊是 load 情境（實機取樣：ffmpeg 4K 編碼）的面板上半部。
# 面板是離屏渲染的實色底（等同「減少透明度」），不是 macOS 26+ 預設的玻璃外觀，見 scripts/render-panel.sh。
#
#   scripts/make-hero.sh [zh|en]    （不給就兩種都做）
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${COOL42_SNAPSHOT_WORK:-${TMPDIR:-/tmp}/cool42-snapshot}"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"
BIN="$WORK/.build/release/cool42-snapshot"
for L in ${1:-zh en}; do
  SRC="$WORK/hero-src-$L"; mkdir -p "$SRC"
  if [ "$L" = "en" ]; then
    COOL42_SNAPSHOT_ARGS="--only dark" "$REPO/scripts/render-panel.sh" --lang en "$SRC" load >/dev/null
    PANEL="$SRC/panel-load-en-dark.png"; OUT="$REPO/docs/img/screens/hero-en.png"
  else
    COOL42_SNAPSHOT_ARGS="--only dark" "$REPO/scripts/render-panel.sh" "$SRC" load >/dev/null
    PANEL="$SRC/panel-load-dark.png"; OUT="$REPO/docs/img/screens/hero.png"
  fi
  "$BIN" --hero "$PANEL" "$L" "$SRC/hero-2x.png" >/dev/null
  # 2560×1440 → 1920×1080（README 顯示寬度用不到 2x，檔案小一半以上）
  "$FFMPEG" -hide_banner -loglevel error -y -i "$SRC/hero-2x.png" -vf "scale=1920:-1:flags=lanczos" "$OUT"
  echo "$OUT"
done
