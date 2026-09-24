#!/bin/bash
# 打 release 包：release build → 組 cool42 Panel.app＋CLI/guard＋安裝所需檔 → 簽章（Developer ID 或 ad-hoc）→ 公證（可選）
#   → dist/cool42-<version>-arm64.zip ＋ .sha256
#
# 用法：scripts/make-release.sh [version]      # 不給就取 CHANGELOG.md 第一個「## x.y.z」
# 簽章開關（環境變數，兩個都有才會公證）：
#   DEVELOPER_ID_APP="Developer ID Application: Okle42 (TEAMID)"   有 → codesign --options runtime --timestamp
#   NOTARY_PROFILE="okle42-notary"                                  有 → xcrun notarytool submit --wait ＋ stapler staple
#   都沒有 → ad-hoc 簽章並印警告（陌生人下載後會被 Gatekeeper 擋，安裝腳本會替 ad-hoc 版清掉 quarantine）
#
# 不動 .build/：用 --scratch-path 指到 $TMPDIR 下獨立目錄，不會跟開發中的建置互搶
# 只用已 commit 的原始碼：RELEASE_REF=v1.0.3 scripts/make-release.sh 可以指定 tag/分支（預設 HEAD）
# 不會停掉或覆蓋本機正在跑的 guard / 面板（那是 install.sh / make-app.sh 的事）
set -euo pipefail
TMPDIR="${TMPDIR:-/tmp}"
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# 只打包已 commit 的內容：把 RELEASE_REF（預設 HEAD）export 到暫存區再建置，工作目錄裡沒 commit 的改動不會混進 release
REF="${RELEASE_REF:-HEAD}"
COMMIT="$(git rev-parse --verify "$REF^{commit}")" || { echo "✗ 找不到 git ref：$REF"; exit 1; }
if [ -n "$(git status --porcelain -- Sources Package.swift Sounds install mcp scripts config.example.json)" ]; then
  echo "⚠️  工作目錄有未 commit 的改動（下面列出），release 只會用 ${REF}（${COMMIT:0:7}）的內容："
  git status --short -- Sources Package.swift Sounds install mcp scripts config.example.json | sed 's/^/    /'
fi
SRC="$(mktemp -d "${TMPDIR%/}/cool42-release-src.XXXXXX")"
WORK=""
trap 'rm -rf "$SRC" ${WORK:+"$WORK"}' EXIT
git archive "$COMMIT" | tar -x -C "$SRC"
# 只打包已 commit 的內容：$REF 裡沒有 release 安裝腳本就直接失敗，不拿工作目錄那份頂替
[ -f "$SRC/scripts/install-from-release.sh" ] || { echo "✗ $REF 裡沒有 scripts/install-from-release.sh，先 commit 再打包"; exit 1; }
cd "$SRC"

VERSION="${1:-${VERSION:-}}"
if [ -z "$VERSION" ]; then
  VERSION="$(grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md | sed -E 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ 版本號格式不對：'$VERSION'"; exit 1; }
# RELEASE_REF 是 tag 時，tag 名稱必須是 v$VERSION（避免拿 v1.0.3 的程式碼打成 1.0.4 的包）
if git -C "$ROOT" show-ref --verify --quiet "refs/tags/$REF" || git -C "$ROOT" show-ref --verify --quiet "refs/tags/${REF#refs/tags/}"; then
  [ "${REF#refs/tags/}" = "v$VERSION" ] || { echo "✗ RELEASE_REF=$REF 是 tag，但版本號是 $VERSION（應為 v$VERSION）"; exit 1; }
fi
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count "$COMMIT")"
NAME="cool42-$VERSION"
ZIP="$ROOT/dist/$NAME-arm64.zip"
APP_NAME="cool42 Panel.app"
BUNDLE_ID="com.cool42.panel"

SCRATCH="${COOL42_RELEASE_SCRATCH:-${TMPDIR%/}/cool42-release-build}"
WORK="$(mktemp -d "${TMPDIR%/}/cool42-release.XXXXXX")"
STAGE="$WORK/$NAME"

if [ -n "${DEVELOPER_ID_APP:-}" ]; then
  MODE="developer-id"
  security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID_APP" \
    || { echo "✗ keychain 裡找不到簽章身分：${DEVELOPER_ID_APP}（security find-identity -v -p codesigning 看看）"; exit 1; }
  if [ -n "${NOTARY_PROFILE:-}" ]; then MODE="notarized"; fi
else
  MODE="adhoc"
fi

echo "▶ cool42 ${VERSION}（build ${BUILD_NUMBER}，${REF} = ${COMMIT:0:7}）簽章模式：$MODE"
echo "▶ swift build -c release --scratch-path $SCRATCH"
swift build -c release --arch arm64 --scratch-path "$SCRATCH" 2>&1 | tail -1
BIN_DIR="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)"
for b in cool42 cool42-panel; do
  [ -x "$BIN_DIR/$b" ] || { echo "✗ 找不到 $BIN_DIR/$b"; exit 1; }
  # 只准依賴系統函式庫，不然陌生人的機器跑不起來
  if otool -L "$BIN_DIR/$b" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)'; then
    echo "✗ $b 連結到非系統函式庫（上面列出），release 包不能帶這種 binary"; exit 1
  fi
done

echo "▶ 組裝 $STAGE"
mkdir -p "$STAGE/bin" "$STAGE/install" "$STAGE/scripts" "$STAGE/mcp"
cp "$BIN_DIR/cool42" "$STAGE/bin/cool42"
chmod 755 "$STAGE/bin/cool42"

# 面板 .app（Info.plist 與 scripts/make-app.sh 同一份內容，只是版本號跟著 release 走）
APP="$STAGE/$APP_NAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Sounds"
cp "$BIN_DIR/cool42-panel" "$APP/Contents/MacOS/cool42-panel"
cp Sounds/*.m4a "$APP/Contents/Resources/Sounds/"
cp -R Sources/cool42-panel/Resources/*.lproj "$APP/Contents/Resources/"   # 介面字串 zh-Hant＋en（同 make-app.sh）
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>cool42 Panel</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hant</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hant</string><string>en</string></array>
  <key>CFBundleDisplayName</key><string>cool42 Panel</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>cool42-panel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 安裝所需檔：install-from-release.sh 在包裡叫 install.sh（陌生人直覺會找這個名字）
cp scripts/install-from-release.sh "$STAGE/install.sh"
cat > "$STAGE/uninstall.sh" <<'SH'
#!/bin/bash
# 移除 cool42（daemon、CLI、面板、Claude Code hook/MCP）。/etc/cool42/config.json 保留
exec "$(cd "$(dirname "$0")" && pwd)/install.sh" --uninstall "$@"
SH
cp install/com.cool42.guard.plist install/newsyslog-cool42.conf install/claude-settings.snippet.json "$STAGE/install/"
cp scripts/install-hook.py scripts/install-mcp.sh "$STAGE/scripts/"
cp mcp/cool42_mcp.py "$STAGE/mcp/"
cp config.example.json LICENSE README.md README.en.md CHANGELOG.md "$STAGE/"
chmod 755 "$STAGE/install.sh" "$STAGE/uninstall.sh" "$STAGE/scripts/install-hook.py" "$STAGE/scripts/install-mcp.sh" "$STAGE/mcp/cool42_mcp.py"
echo "$VERSION" > "$STAGE/VERSION"
echo "$MODE" > "$STAGE/SIGNING"
echo "$COMMIT" > "$STAGE/COMMIT"

# ── 簽章 ──
# 由內而外：先簽 CLI 與 app 內的執行檔，再簽 bundle。不用 --deep（Apple 不建議拿來簽）
if [ "$MODE" = "adhoc" ]; then
  echo "⚠️  沒有設定 DEVELOPER_ID_APP：用 ad-hoc 簽章。"
  echo "⚠️  這個包沒有公證，陌生人用瀏覽器下載後 Gatekeeper 會擋（安裝腳本會替 ad-hoc 版清 quarantine）；"
  echo "⚠️  正式對外發布前請照 docs/RELEASING.md 設好 Developer ID 與 notarytool profile 再打一次。"
  SIGN=(codesign --force --sign -)
  SIGN_BIN=("${SIGN[@]}" --identifier com.cool42.cli)
else
  SIGN=(codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP")
  SIGN_BIN=("${SIGN[@]}" --identifier com.cool42.cli)
fi
"${SIGN_BIN[@]}" "$STAGE/bin/cool42"
"${SIGN[@]}" "$APP/Contents/MacOS/cool42-panel"
"${SIGN[@]}" "$APP"
codesign --verify --strict --verbose=2 "$STAGE/bin/cool42"
codesign --verify --deep --strict --verbose=2 "$APP"
# 包內逐檔 sha256：install.sh 在 root 端核對，被改過就中止（ad-hoc 版沒有身分可驗，只能靠這份清單＋zip 本身的 .sha256）
(cd "$STAGE" && find . -type f ! -name SHA256SUMS ! -path "./$APP_NAME/*" | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done > SHA256SUMS)

mkdir -p "$ROOT/dist"
rm -f "$ZIP" "$ZIP.sha256"
make_zip() { (cd "$WORK" && ditto -c -k --sequesterRsrc --keepParent "$NAME" "$ZIP"); }
make_zip

# ── 公證 ──
if [ "$MODE" = "notarized" ]; then
  echo "▶ xcrun notarytool submit（profile：${NOTARY_PROFILE}，會等 Apple 回覆，通常 1–10 分鐘）"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$WORK/notary.json" || true
  cat "$WORK/notary.json"; echo
  STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$WORK/notary.json" 2>/dev/null || true)"
  if [ "$STATUS" != "Accepted" ]; then
    SUB_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$WORK/notary.json" 2>/dev/null || true)"
    echo "✗ 公證沒過（status=${STATUS}）。看原因：xcrun notarytool log $SUB_ID --keychain-profile $NOTARY_PROFILE"
    rm -f "$ZIP"; exit 1
  fi
  # 票只能釘在 .app 上（裸 CLI binary 不能 staple，Gatekeeper 會上網查票）；釘完重新打 zip
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  rm -f "$ZIP"; make_zip
elif [ "$MODE" = "developer-id" ]; then
  echo "⚠️  有 Developer ID 但沒設 NOTARY_PROFILE：已簽章、未公證。陌生人下載後 Gatekeeper 仍會擋。"
fi

(cd "$ROOT/dist" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
SHA="$(awk '{print $1}' "$ZIP.sha256")"
echo
echo "✅ $ZIP"
echo "   sha256 $SHA"
echo "   簽章模式 $MODE"
echo "   Homebrew cask：version \"$VERSION\" / sha256 \"$SHA\""
