#!/bin/bash
# 截圖情境的實機取樣（開發用）：閒置 40 秒 → ffmpeg 真實重負載 240 秒（每 5 秒存 state + sensors）→ 收尾存 history
#   scripts/snapshot/capture-load.sh OUT_DIR   之後 python3 scripts/snapshot/build-scenarios.py OUT_DIR
# 會讓機器滿載 4 分鐘、風扇拉高；跑之前先 cool42 check。只讀檔與 SMC，不需要 root
set -u
D="${1:?用法：capture-load.sh OUT_DIR}"
mkdir -p "$D/idle" "$D/load"
for i in $(seq 1 8); do
  cp /var/run/cool42/state.json "$D/idle/state-$i.json"; cool42 sensors > "$D/idle/sensors-$i.txt"; sleep 5
done
cp /var/run/cool42/history.json "$D/idle/history.json"
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=3840x2160:rate=60 -t 100000 -c:v libx264 -preset medium -f null - &
FF=$!
for i in $(seq 1 48); do
  sleep 5; cp /var/run/cool42/state.json "$D/load/state-$i.json"; cool42 sensors > "$D/load/sensors-$i.txt"
  [ $i -eq 24 ] && cp /var/run/cool42/history.json "$D/load/history-mid.json"
done
cp /var/run/cool42/history.json "$D/load/history.json"
kill $FF; wait $FF 2>/dev/null
echo done > "$D/capture.done"
