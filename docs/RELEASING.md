# 發布 cool42 release

目標：陌生人不用 clone、不用裝 swift，一行裝好。

```bash
brew install okle42/tap/cool42 && cool42-setup
```

或不用 Homebrew（curl 下載不會帶 quarantine）：

```bash
V=1.0.3; curl -fsSL "https://github.com/Okle42/cool42/releases/download/v$V/cool42-$V-arm64.zip" -o /tmp/cool42.zip \
  && rm -rf /tmp/cool42 && ditto -xk /tmp/cool42.zip /tmp/cool42 && /tmp/cool42/cool42-$V/install.sh
```

## 相關檔案

| 檔案 | 用途 |
|---|---|
| `scripts/make-release.sh` | release build → 組 `cool42 Panel.app`＋CLI/guard＋安裝檔 → 簽章 → （可選）公證 → `dist/cool42-<ver>-arm64.zip` ＋ `.sha256` |
| `scripts/install-from-release.sh` | 打包進 zip 後叫 `install.sh`（Homebrew 裝成 `cool42-setup`）。不需原始碼、不需 swift；`--uninstall` 移除、`--skip-claude` 不動 Claude Code、`--cask` 表示面板已在 `/Applications`（從 Caskroom 執行會自動判斷） |
| `install.sh`（專案根目錄） | 原始碼安裝（先 `swift build`），跟以前一樣，沒有改動 |
| `~/github-repos/homebrew-tap/Casks/cool42.rb` | Homebrew cask（本機骨架，GitHub 上要叫 `Okle42/homebrew-tap`） |

zip 內容：

```
cool42-<ver>/
  cool42 Panel.app/          選單列面板（含內建提示音）
  bin/cool42                 CLI；guard 是同一個 binary（安裝時建 cool42-guard symlink）
  install.sh  uninstall.sh   安裝／移除
  install/                   LaunchDaemon plist、newsyslog、Claude Code hook 片段
  scripts/                   install-hook.py、install-mcp.sh
  mcp/cool42_mcp.py          MCP server（用 uv 跑）
  config.example.json  LICENSE  README*.md  CHANGELOG.md
  VERSION  SIGNING  COMMIT   版本號、簽章模式（adhoc / developer-id / notarized，install.sh 會讀）、打包的 commit
```

`make-release.sh` 只打包**已 commit** 的內容：把 `RELEASE_REF`（預設 `HEAD`，也可以 `RELEASE_REF=v1.0.3`）用 `git archive` 匯出到
`$TMPDIR/cool42-release-src` 再建置（`--scratch-path $TMPDIR/cool42-release-build`），工作目錄裡沒 commit 的改動會列出警告但不會混進 release，
也不會動到開發用的 `.build/`。

安裝後的位置：`/usr/local/bin/cool42`、`/usr/local/bin/cool42-guard`、`/Library/LaunchDaemons/com.cool42.guard.plist`、
`/usr/local/share/cool42/`（MCP server 跟移除腳本從這裡跑，所以 zip 解壓目錄裝完就能刪）、`/etc/cool42/config.json`、
`/Applications/cool42 Panel.app`、`~/Library/LaunchAgents/com.cool42.panel.plist`。

## 一、還沒有 Apple Developer 帳號時（ad-hoc）

```bash
scripts/make-release.sh            # 版本號取 CHANGELOG.md 第一個「## x.y.z」；也可以 scripts/make-release.sh 1.0.4
```

會印出警告：ad-hoc 簽章、沒公證。這種包可以自己測、可以給願意手動信任的人，但瀏覽器下載後 Gatekeeper 會擋。
`install.sh` 讀到 `SIGNING=adhoc` 時會替安裝好的 CLI 與 app 清掉 `com.apple.quarantine`，所以用 `./install.sh` 裝還是能跑；
雙擊 app 則會被擋。**正式對外發布一定要走第二節。**

## 二、買了 Apple Developer Program 之後（一次性設定）

### 1. 建 Developer ID Application 憑證

最簡單：Xcode → Settings → Accounts → 登入 Apple ID → 選 Team → Manage Certificates → 左下「+」→ **Developer ID Application**。
（沒 Xcode 的話：developer.apple.com → Certificates → + → Developer ID Application，用「鑰匙圈存取 → 憑證輔助程式 → 從憑證授權要求憑證」產 CSR 上傳，下載後雙擊裝進登入鑰匙圈。）

確認：

```bash
security find-identity -v -p codesigning
#   1) ABCDEF… "Developer ID Application: Okle42 (TEAMID1234)"
```

引號裡整串就是 `DEVELOPER_ID_APP`。

### 2. 建 notarytool 的 keychain profile

二選一：

**App 專用密碼**（個人帳號最簡單）：appleid.apple.com → 登入與安全性 → App 專用密碼 → 產一組。

```bash
xcrun notarytool store-credentials okle42-notary \
  --apple-id "<Apple ID 信箱>" \
  --team-id  "TEAMID1234" \
  --password "<App 專用密碼 xxxx-xxxx-xxxx-xxxx>"
```

**App Store Connect API key**（多人或 CI 用）：App Store Connect → Users and Access → Integrations → Keys → 產一把 Developer 權限的 key，下載 `.p8`。

```bash
xcrun notarytool store-credentials okle42-notary \
  --key ~/keys/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <Issuer ID>
```

密碼存在登入鑰匙圈，腳本只用 profile 名字，不會把密碼寫進任何檔案。確認：

```bash
xcrun notarytool history --keychain-profile okle42-notary
```

### 3. 打簽章＋公證的包

```bash
export DEVELOPER_ID_APP="Developer ID Application: Okle42 (TEAMID1234)"
export NOTARY_PROFILE="okle42-notary"
scripts/make-release.sh
```

腳本會：

1. `codesign --force --options runtime --timestamp` 由內而外簽 `bin/cool42`（identifier `com.cool42.cli`）、面板執行檔、`cool42 Panel.app`
2. `codesign --verify --strict` 驗證
3. 打 zip → `xcrun notarytool submit --wait`；狀態不是 `Accepted` 就刪 zip 並印出看 log 的指令
4. `xcrun stapler staple` 把票釘在 `.app` 上（裸 CLI binary 不能 staple，Gatekeeper 會上網查票）→ `stapler validate` → `spctl --assess` → 重新打 zip
5. 產 `.sha256`

只設 `DEVELOPER_ID_APP` 不設 `NOTARY_PROFILE` 也可以跑，會簽章但不公證，並印警告。

### 4. 驗證

```bash
V=1.0.3; T=$(mktemp -d); ditto -xk dist/cool42-$V-arm64.zip "$T"
codesign -dv --verbose=4 "$T/cool42-$V/bin/cool42" 2>&1 | grep -E 'Authority|Timestamp|flags'   # 要看到 Developer ID、Timestamp、runtime
spctl --assess --type execute -vv "$T/cool42-$V/cool42 Panel.app"                                  # source=Notarized Developer ID
xcrun stapler validate "$T/cool42-$V/cool42 Panel.app"
cat "$T/cool42-$V/SIGNING"                                                                         # notarized
```

第一次公證後要在一台乾淨的 Mac（或新使用者帳號）上實裝一次，確認 hardened runtime 下 guard 還能讀寫 SMC、
能叫起 powermetrics、面板能播提示音。目前判斷這些都不需要額外 entitlement（IOKit user client、spawn 子程序、AVFoundation 播檔都不受 hardened runtime 限制），但這是推論，還沒實測。

## 三、發布（每次都要使用者點頭）

以下每一步都是對外動作，執行前先確認：

1. `CHANGELOG.md` 最上面是新版本；`scripts/make-app.sh` 裡寫死的 `CFBundleShortVersionString` 一起改（原始碼安裝顯示的版本號）
2. `git tag v<ver>` 並 push tag
3. 上傳 release：
   ```bash
   gh release create v1.0.3 dist/cool42-1.0.3-arm64.zip dist/cool42-1.0.3-arm64.zip.sha256 --title "cool42 1.0.3" --notes-file <notes>
   ```
4. 更新 tap（見下一節）並 push `Okle42/homebrew-tap`

## 四、更新 Homebrew tap

```bash
~/github-repos/homebrew-tap/bin/bump-cool42.sh ~/github-repos/cool42/dist/cool42-1.0.3-arm64.zip
cd ~/github-repos/homebrew-tap && ruby -c Casks/cool42.rb && git diff
```

push 之前可以先在本機試裝（會真的安裝、會要密碼、會取代正在跑的 guard）：

```bash
brew tap okle42/tap ~/github-repos/homebrew-tap     # 用本機路徑當 tap
brew install --cask okle42/tap/cool42 && cool42-setup
```

注意 cask 的 `url` 指向 GitHub release，所以 release 要先上傳，sha256 也必須是**上傳的那個 zip** 的值（公證後重新打的 zip，sha256 會跟 ad-hoc 那顆不同）。

cask 做的事：`app` 把面板放進 `/Applications`，`binary` 把包裡的 `install.sh` 連成 `cool42-setup`；使用者再跑 `cool42-setup`
（CLI、guard、支援檔、LaunchAgent、Claude Code hook/MCP，會要一次密碼）。

為什麼不用 `postflight` 自動跑：Homebrew 7.0.2 對 `postflight` 印 deprecated（要改 `postflight_steps`），而 `postflight_steps`
的 `run` 在 Homebrew 的 sandbox 裡執行、只能寫宣告過的路徑，寫不了 LaunchDaemon／`~/Library/LaunchAgents`／`~/.claude`，也叫不出系統密碼視窗。

移除：`brew uninstall cool42` 只收掉面板（guard 照跑）——因為 `brew upgrade` 會先 uninstall 舊版再裝新版，如果 uninstall 就拆 guard，
升級後到重跑 `cool42-setup` 之前風扇沒人管。完整移除用 `brew uninstall --zap cool42`（跑 `install.sh --uninstall --keep-app`、刪 `/etc/cool42` 與 log），
或 `/usr/local/share/cool42/uninstall.sh`。升級：`brew upgrade cool42 && cool42-setup`。

之後有 Developer ID 可以考慮的長期做法（推論，未實作）：面板 app 內建 `Contents/Library/LaunchDaemons/` 並用 `SMAppService.daemon` 註冊 guard，
第一次開面板時由系統跳授權，就不需要 `cool42-setup`；這需要 guard 跟 app 同一個 Team ID 簽章，ad-hoc 做不到。

## 附：為什麼 release 安裝不直接用 scripts/install-root.sh

`install-root.sh` 會從 `.build/release/` 拿 binary，並且一律 `codesign --sign -` 重簽成 ad-hoc。
release 包沒有 `.build/`，而 Developer ID 簽章一旦被重簽就失效，所以 `install-from-release.sh` 自帶 root 步驟：
簽章有效就保留、壞了才補 ad-hoc；其餘（寫暫存檔再 `mv` 換 inode、等 guard 真的消失再 bootstrap、清 1.0.2 以前的 `/tmp` 檔）照原本的做法。
兩邊的 root 步驟改動時要一起看。
