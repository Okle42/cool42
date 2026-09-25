import AppKit
import SwiftUI

// 首次啟動導覽：三頁、只自動出現一次（UserDefaults onboarding.shown），可略過；
// 之後從設定視窗「關於與檢查」或選單列右鍵選單「cool42是做什麼的？」再打開。
// 不在這裡要任何權限（HIG Onboarding：權限等第一次用到功能時才要）

enum Onboarding {
    static let shownKey = "onboarding.shown"
    static var shown: Bool { UserDefaults.standard.bool(forKey: shownKey) }
    static let pageCount = 3
}

struct OnboardingPage {
    var symbol: String
    var title: String
    var points: [String]
    /// 第二頁的檔案清單：分組（安裝時放的／執行時會寫的），每組是 路徑＋用途
    var fileGroups: [(String, [(String, String)])] = []

    static var all: [OnboardingPage] {
        [
            OnboardingPage(symbol: "fan", title: L("cool42提早轉風扇，減少降頻"), points: [
                L("每5秒看一次CPU與GPU溫度，照曲線比macOS原廠更早把風扇轉起來，減少熱到降頻的機會；重負載下仍可能降頻，這時hook會讓AI的重工作先等。"),
                L("Claude Code跑重指令前會先問cool42：真的在降頻才請它等一下，其他時候照常全速。"),
                L("這個面板讀溫度、風扇和今天發生了什麼；只有你改設定、或用了專注模式規則時，才會寫入設定檔與專注模式旗標。"),
            ]),
            OnboardingPage(symbol: "lock.shield", title: L("為什麼需要root常駐程式"), points: [
                L("macOS只允許root寫入風扇轉速，所以控制風扇的guard以系統LaunchDaemon常駐，開機就接手。"),
                L("cool42不連網路、不收集資料，只會動下面這些檔案。面板與hook都不需要root。"),
            ], fileGroups: [
                (L("安裝時放的"), [
                    ("/Library/LaunchDaemons/com.cool42.guard.plist", L("開機啟動guard")),
                    ("/usr/local/bin/cool42", L("指令列工具與guard本體")),
                    ("/etc/newsyslog.d/cool42.conf", L("記錄檔輪替")),
                    ("/Applications/cool42 Panel.app", L("這個面板")),
                    ("~/Library/LaunchAgents/com.cool42.panel.plist", L("登入時打開面板")),
                    ("~/.claude/settings.json", L("Claude Code hook（有安裝才有）")),
                ]),
                (L("執行時會寫的"), [
                    ("/var/run/cool42/", L("guard：即時狀態與5分鐘曲線")),
                    ("/var/db/cool42/", L("guard：今日統計、預熱學習")),
                    ("/var/log/cool42.log", L("guard：記錄檔（自動輪替）")),
                    ("/etc/cool42/config.json", L("面板：設定（你也能直接改）")),
                    ("~/.config/cool42/focus.json", L("面板：專注模式旗標（有專注模式規則才寫）")),
                ]),
            ]),
            OnboardingPage(symbol: "arrow.uturn.backward.circle", title: L("隨時可以交還原廠"), points: [
                L("guard在執行時，面板上的「自動」、選單列右鍵的「交還原廠控制⋯」或設定視窗的「緊急交還原廠」，幾秒內就把風扇交回macOS，不需要密碼；之後按「恢復」就回到原本的模式。"),
                L("在終端機執行sudo cool42 fan auto，也會立刻交還。"),
                L("完整移除：在cool42資料夾執行./uninstall.sh。會移除guard、指令列工具、面板、hook與專注模式旗標，設定檔保留。"),
            ]),
        ]
    }
}

struct OnboardingView: View {
    @State var page: Int = 0
    var onDone: () -> Void = {}
    static let width: CGFloat = 440

    var body: some View {
        let pages = OnboardingPage.all
        VStack(alignment: .leading, spacing: 16) {
            // 三頁疊在一起、只顯示目前這頁：視窗高度固定在最高那頁，翻頁時按鈕列不會上下跳（也不會被裁掉）
            ZStack(alignment: .topLeading) {
                ForEach(0..<pages.count, id: \.self) { i in
                    pageContent(pages[i]).opacity(i == page ? 1 : 0).accessibilityHidden(i != page)
                }
            }
            HStack(spacing: 8) {
                // 頁碼：形狀＋文字（VoiceOver 念「第1頁，共3頁」）
                HStack(spacing: 5) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Circle().fill(i == page ? Color.primary : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement().accessibilityLabel(L("第%ld頁，共%ld頁", page + 1, pages.count))
                Spacer()
                if page < pages.count - 1 {
                    Button(L("略過")) { onDone() }
                }
                if page > 0 { Button(L("上一步")) { page -= 1 } }
                // 主要動作一顆 prominent（每畫面 ≤ 1–2 顆）
                if page < pages.count - 1 {
                    Button(L("下一步")) { page += 1 }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button(L("完成")) { onDone() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: Self.width)
    }

    func pageContent(_ p: OnboardingPage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: p.symbol).font(.system(.largeTitle)).foregroundStyle(Neon.cyan)
                    .frame(width: 44).accessibilityHidden(true)
                Text(verbatim: p.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(p.points.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(verbatim: t).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !p.fileGroups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(p.fileGroups, id: \.0) { head, files in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: head).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(files, id: \.0) { path, what in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: path).font(.caption.monospaced()).foregroundStyle(.primary).textSelection(.enabled)
                                    Text(verbatim: what).font(.caption).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Neon.cardBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Neon.hairline, lineWidth: 0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 導覽視窗：一般的標題視窗（可用 ⌘W／紅色按鈕關），不可縮放，置中
final class OnboardingWindow {
    private var window: NSWindow?

    func show() {
        UserDefaults.standard.set(true, forKey: Onboarding.shownKey)
        // 每次打開都從第一頁開始（重建內容；視窗本身沿用，位置不跳）
        let host = NSHostingView(rootView: OnboardingView(onDone: { [weak self] in self?.close() }))
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("歡迎使用cool42")
            w.isReleasedWhenClosed = false
            w.center()
            return w
        }()
        w.contentView = host
        w.setContentSize(host.fittingSize)
        window = w
        NSApp.activate(ignoringOtherApps: true)   // accessory app：不先 activate，視窗會被壓在別的 app 後面
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}
