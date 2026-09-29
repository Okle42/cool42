import SwiftUI
import Charts
import Cool42Core

// cool42 面板：選單列常駐，只讀資料（不需 root），每 3 秒更新一次。
// 視窗是一個浮動 NSPanel（不是 MenuBarExtra 的 popover）：點選單列圖示開 / 關、可拖到任何地方、
// 點到別的視窗不會消失、跨 Space、位置與高度記住。這套和 ghosts 的控制條同一種做法。

// MARK: - 在地化

/// 介面字串一律走 L()：key 就是繁中原文（開發語言 zh-Hant），英文在 Resources/en.lproj/Localizable.strings，依系統語言切換。
/// 不用 SwiftUI 的 LocalizedStringKey 字面值（插值會變成 %lld / %@ 之類的 key，很難對齊），
/// 所以 key 都是 L("…") 的字串常值，scripts/check-l10n.py 才抽得到、檢查得到英文表有沒有漏。
/// 不需翻譯的字（cool42、數字＋單位）用 Text(verbatim:)，免得被拿去查表。
enum L10n {
    /// 放 *.lproj 的 bundle：
    ///   .app：make-app.sh 把 *.lproj 複製到 Contents/Resources → Bundle.main
    ///   swift build / swift run：SwiftPM 把 Resources 打成執行檔旁邊的 cool42_cool42-panel.bundle
    /// 不用 Bundle.module：它找不到 bundle 會 fatalError，而且離屏截圖的暫存 package 沒有這個 target
    static let container: Bundle = {
        if Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") != nil { return .main }
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent(),
           let b = Bundle(url: dir.appendingPathComponent("cool42_cool42-panel.bundle")) { return b }
        return .main
    }()
    /// 自己挑語言，不交給 Bundle：非主 bundle 會跟著「主程式選的語言」走，swift run 時主程式沒有 lproj、
    /// 永遠算成 en（實測 zh-Hant-TW 系統也一樣）。系統語言都對不上（法文、簡中⋯）時退到 en
    static let language: String =
        Bundle.preferredLocalizations(from: container.localizations, forPreferences: Locale.preferredLanguages + ["en"]).first ?? "zh-Hant"
    /// 該語言的 .lproj 當成 bundle 查表；找不到（例如只剩 key）就查 container，查不到回傳 key（繁中原文）
    static let bundle: Bundle = container.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? container
}

func L(_ key: String) -> String { L10n.bundle.localizedString(forKey: key, value: key, table: nil) }
/// 帶參數：key 裡用 printf 格式（Int 用 %ld、Double 用 %.0f 等），英文版的格式符號要一樣（check-l10n.py 會比對）
func L(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let panelWidth: CGFloat = PanelView.contentWidth + 2 * PanelView.edgePadding   // 320 + 兩側 16
    let monitor = Monitor()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var host: NSHostingView<PanelView>?
    lazy var settings = SettingsWindowController(monitor: monitor)

    static func main() {
        // 改名前的面板偏好（com.cool42.panel）搬一次；要在 AppDelegate() 之前，Monitor 初始化就會讀 UserDefaults
        LegacyDefaults.migrateOnce()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 不顯示 Dock 圖示
        NSApp.mainMenu = buildMainMenu()      // 選單列看不到（accessory app），但 ⌘, ⌘Q ⌘W 與文字欄位的拷貝／貼上靠它
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            // 溫度每 3 秒變一次：等寬數字，選單列上的圖示才不會跟著左右抖
            b.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = L("cool42：按一下顯示／隱藏面板，按右鍵打開選單")
        }
        updateStatusItem()
        monitor.onTick = { [weak self] in self?.updateStatusItem() }
        monitor.onHide = { [weak self] in self?.hidePanel() }
        monitor.onShowOnboarding = { [weak self] in self?.showOnboarding() }
        monitor.onShowSettings = { [weak self] tab in self?.settings.show(tab: tab) }
        // 通知：只設 delegate、讀授權狀態（不會跳授權視窗；第一次真的要發通知時才請求）
        Notifier.shared.onAuthChange = { [weak self] a in self?.monitor.notifyAuth = a }
        Notifier.shared.onOpen = { [weak self] in self?.showPanel() }
        Notifier.shared.start()
        monitor.onContentHeight = { [weak self] h in self?.fitHeight(to: h) }
        buildPanel()
        if UserDefaults.standard.object(forKey: "panel.open") as? Bool ?? true { showPanel() }
        // 首次啟動導覽：只自動出現一次
        if !Onboarding.shown { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showOnboarding() } }
    }

    /// 從 Finder 再打開一次（app 已在跑）：打開設定視窗——純選單列 app 的圖示被使用者藏起來時，這是唯一找得回來的路
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show(tab: nil)
        return false
    }

    private let onboarding = OnboardingWindow()
    @objc func showOnboarding() { onboarding.show() }
    @objc func showSettings() { settings.show(tab: nil) }

    /// 看不到的主選單：App（設定⋯ ⌘,、結束 ⌘Q）、編輯（文字欄位的還原／拷貝／貼上）、視窗（關閉 ⌘W）
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            host.submenu = m
            main.addItem(host)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        sub("cool42", [
            item(L("設定⋯"), #selector(showSettings), ",", target: self),
            .separator(),
            item(L("結束cool42面板"), #selector(quit), "q", target: self),
        ])
        sub(L("編輯"), [
            item(L("還原"), Selector(("undo:")), "z"),
            item(L("重做"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("剪下"), #selector(NSText.cut(_:)), "x"),
            item(L("拷貝"), #selector(NSText.copy(_:)), "c"),
            item(L("貼上"), #selector(NSText.paste(_:)), "v"),
            item(L("全選"), #selector(NSText.selectAll(_:)), "a"),
        ])
        sub(L("視窗"), [item(L("關閉"), #selector(NSWindow.performClose(_:)), "w")])
        return main
    }

    /// 選單列：template SF Symbol（系統依選單列深淺上色，狀態靠「換形狀」不靠顏色）＋等寬溫度字。
    /// 原本是彩色 emoji 圓點，HIG 要求選單列圖示用 SF Symbol 或 template image。
    /// 降頻時圖示右上角多一隻烏龜、hot 時右下角多一個點（StatusIcon 合成，仍是 template）；「只顯示圖示」時不放溫度字
    private func updateStatusItem() {
        guard let b = statusItem?.button else { return }
        let st = monitor.menuState
        b.image = StatusIcon.image(symbol: st.symbol, throttled: st.throttled, hotDot: st.hot)
        let showTemp = monitor.showTempInMenuBar
        // 溫度字固定寬度（三位數的寬度，不足補 figure space）：96° → 109° 時選單列其他圖示不會被推來推去
        b.attributedTitle = NSAttributedString(string: showTemp ? st.title : "", attributes: [.font: b.font ?? NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
        b.imagePosition = showTemp ? .imageLeading : .imageOnly
        // VoiceOver 念得到目前狀態（不只「cool42 溫度」）
        b.setAccessibilityLabel(st.accessibility)
    }

    private func buildPanel() {
        // 外觀跟系統走（淺 / 深色都有對應色值），不鎖死 darkAqua
        let host = NSHostingView(rootView: PanelView(monitor: monitor))
        // 視窗大小由 fitHeight 管（量內容高度再設 frame）；不讓 hosting view 用自己的 intrinsic／min／max size 撐住內容區——
        // 撐住時 contentView 會比視窗高（實測 970 vs 894），標題列被裁在視窗上緣外
        host.sizingOptions = []
        self.host = host
        // 無邊框：不要 .titled／.utilityWindow 那層視窗外框與標題列背景（原本玻璃上多蓋一層霧），圓角與陰影自己來
        let p = GlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 760),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.title = "cool42"                         // 看不到，但 VoiceOver 與截圖工具靠它認
        p.isMovableByWindowBackground = true      // 抓任何空白處都能拖
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true           // Slider / segmented 點了才拿 key，平常不搶焦點
        p.hidesOnDeactivate = false               // 切到別的 app 也留著（刻意偏離 HIG：常駐監控，可隨時關）
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.setAccessibilityLabel(L("cool42面板"))
        panel = p
        p.appearance = GlassStyle.nsAppearance
        applyBackground()
        // 設定視窗調外觀／透明度：外觀換 NSAppearance（玻璃在 viewDidChangeEffectiveAppearance 自己重算），透明度重套玻璃色調
        NotificationCenter.default.addObserver(forName: GlassStyle.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, let p = self.panel else { return }
            p.appearance = GlassStyle.nsAppearance
            let root = p.contentView?.subviews.first
            if !GlassStyle.effectiveBlur, let s = root as? ScrimPanelBackground {
                s.needsDisplay = true
                WindowBlur.set(p, radius: GlassStyle.blurRadius)
            } else if #available(macOS 26.0, *), GlassStyle.effectiveBlur, let g = root as? TintedGlassView {
                g.applyStyle()
            } else {
                if GlassStyle.effectiveBlur { WindowBlur.set(p, radius: 0) }   // 切回 Apple 玻璃：拿掉自訂的視窗模糊
                self.applyBackground()
            }
            p.invalidateShadow()
        }
        // 使用者切「減少透明度」「增加對比」時即時換底。這個通知發在 NSWorkspace 自己的 notificationCenter，
        // 掛在 NotificationCenter.default 永遠收不到（原本就是這樣：切了設定要重開面板才換）
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.applyBackground() }
        p.setFrameAutosaveName("cool42.panel")
        if !p.setFrameUsingName("cool42.panel") {
            // 第一次：貼螢幕右上角（選單列圖示這時還沒定位，不能拿它的座標）
            let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let h = min(760, vf.height - 16)
            p.setFrame(NSRect(x: vf.maxX - Self.panelWidth - 12, y: vf.maxY - h - 8, width: Self.panelWidth, height: h), display: false)
        }
        monitor.panelWindow = p
        fitHeight(to: monitor.contentHeight)   // 內容高度可能在 panel 指派前就量好了
    }

    /// 視窗底材質（功能層）：
    ///   macOS 26+  NSGlassEffectView，深色外觀加深色 tint（和 Dock、桌面 widget 同一種「深、通透」），見 GlassStyle
    ///   macOS 14–25 NSVisualEffectView .popover（跟選單列 popover 同一種材質，浮動面板要 state = .active）
    ///   「減少透明度」開著：不用玻璃，改實色 Neon.panelBG —— 面板字很密，實色底最好讀
    /// 面板裡不再有實心卡片（玻璃上疊灰板＝霧灰色的主因），分組靠留白與分隔線
    private func applyBackground() {
        guard let p = panel, let host else { return }
        host.removeFromSuperview()
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        let r = Neon.windowRadius
        let root: NSView
        let forced = GlassStyle.fallback
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || forced == "solid" {
            let solid = SolidPanelBackground()
            solid.radius = r
            root = solid
            host.frame = solid.bounds
            solid.addSubview(host)
        } else if !GlassStyle.effectiveBlur {
            WindowBlur.set(p, radius: GlassStyle.blurRadius)
            let scrim = ScrimPanelBackground()
            scrim.radius = r
            root = scrim
            host.frame = scrim.bounds
            scrim.addSubview(host)
        } else if #available(macOS 26.0, *), forced != "legacy" {
            let glass = TintedGlassView()
            glass.cornerRadius = r
            glass.applyStyle()
            root = glass
            host.frame = glass.bounds
            glass.contentView = host   // 內容一定放 contentView，不要把 glass 當兄弟 view 墊在後面
        } else {
            let fx = NSVisualEffectView()
            fx.material = .popover
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.maskImage = .roundedMask(radius: r)   // behind-window 模糊只能靠 maskImage 裁圓角（layer.cornerRadius 裁不到）
            // .popover 會跟著底下變：深色壓在白網頁上洗成中灰（≈ 110/255）、淺色壓在深色桌布上暗成 ≈ 144，霓虹數字只剩 1.7–3:1
            // → 墊一層色（深色黑 0.55、淺色白 0.60），見 LegacyDimView
            let dim = LegacyDimView(frame: fx.bounds)
            dim.radius = r
            dim.autoresizingMask = [.width, .height]
            fx.addSubview(dim)
            host.frame = fx.bounds
            fx.addSubview(host)
            root = fx
        }
        // 視窗的 contentView 是一個普通容器：材質 view 與窗緣是它的兩個子 view（不在 NSGlassEffectView 裡塞別的子 view）。
        // 直接把玻璃設成 contentView 時，視窗高度變了它會留著舊的上緣位移（實測 contentView 970、視窗 894，標題列被裁掉）
        let container = NSView(frame: NSRect(origin: .zero, size: p.frame.size))
        root.frame = container.bounds
        root.autoresizingMask = [.width, .height]
        container.addSubview(root)
        let edge = PanelEdgeView(radius: r, glass: root is GlassMaterial)
        edge.frame = container.bounds
        edge.autoresizingMask = [.width, .height]
        container.addSubview(edge)
        p.contentView = container
        // 用約束把內容區釘在視窗框上：自動換算的 autoresizing 約束會留著一個 −76 的上緣位移（視窗從 967 縮到 891 之後），
        // 內容區就比視窗高、標題列被裁在上緣外
        if let frameView = container.superview {
            container.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
                container.topAnchor.constraint(equalTo: frameView.topAnchor),
                container.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
            ])
        }
        material = root
        syncHostFrame()
    }
    private weak var material: NSView?

    /// 內容高度變了：把視窗調成剛好（上緣不動、不超過螢幕；真的放不下才捲動）
    private func fitHeight(to contentH: CGFloat) {
        guard let p = panel, contentH > 0 else { return }
        let vf = (p.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let h = min(contentH, vf.height - 16)
        guard abs(p.frame.height - h) > 1 else { return }
        var f = p.frame
        f.origin.y += f.height - h   // 保持頂邊
        f.size.height = h
        if f.minY < vf.minY + 8 { f.origin.y = vf.minY + 8 }   // 長高時碰到 Dock 就整個往上推
        // 「減少動態效果」開著就直接跳到新高度，不做縮放動畫
        p.setFrame(f, display: true, animate: p.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        syncHostFrame()
    }

    /// 內容區與 hosting view 一律貼齊視窗（保險：無邊框視窗換過 contentView 後，偶爾會留著舊高度）
    private func syncHostFrame() {
        guard let p = panel, let host, let container = p.contentView else { return }
        container.layoutSubtreeIfNeeded()
        let b = container.bounds
        for v in container.subviews where v.frame != b { v.frame = b }
        if let m = material, host.frame != m.bounds { host.frame = m.bounds }
        p.invalidateShadow()
    }

    func windowDidResize(_ notification: Notification) { syncHostFrame() }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            // 選單項目不放圖示（macOS 27 預設隱藏選單圖示）、不顯示快捷鍵；用不到的項目隱藏而不是變暗
            menu.addItem(withTitle: panel.isVisible ? L("隱藏面板") : L("顯示面板"), action: #selector(togglePanel), keyEquivalent: "")
            menu.addItem(withTitle: L("設定⋯"), action: #selector(showSettings), keyEquivalent: "")
            let temp = menu.addItem(withTitle: L("在選單列顯示溫度"), action: #selector(toggleMenuBarTemp), keyEquivalent: "")
            temp.state = monitor.showTempInMenuBar ? .on : .off
            // 緊急交還：guard 沒跑時改設定檔沒人讀，不放
            if monitor.snapshot?.guardRunning ?? false {
                menu.addItem(.separator())
                if monitor.config.mode == "auto", let prev = monitor.emergencyPrevMode {
                    menu.addItem(withTitle: L("恢復「%@」", modeDisplayName(prev)), action: #selector(emergencyRestore), keyEquivalent: "")
                } else if monitor.config.mode != "auto" {
                    menu.addItem(withTitle: L("交還原廠控制⋯"), action: #selector(emergencyHandBack), keyEquivalent: "")
                }
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: L("cool42是做什麼的？"), action: #selector(showOnboarding), keyEquivalent: "")
            menu.addItem(withTitle: L("重新啟動面板"), action: #selector(relaunch), keyEquivalent: "")
            menu.addItem(withTitle: L("結束cool42面板"), action: #selector(quit), keyEquivalent: "")
            for i in menu.items { i.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil   // 用完拿掉，左鍵才會回到 action
        } else {
            togglePanel()
        }
    }

    /// 點選單列圖示：面板開在別台螢幕時先搬過來（不是關掉）
    @objc func togglePanel() {
        if panel.isVisible {
            if bringToStatusItemScreen() { panel.orderFront(nil) } else { hidePanel() }
        } else {
            showPanel()
        }
    }
    /// 開機自動開、點通知、點圖示都走這裡，所以都會先搬到圖示那台螢幕
    func showPanel() {
        bringToStatusItemScreen()
        panel.orderFront(nil)
        // 視窗第一次上螢幕才有 windowNumber，建背景時設的模糊半徑可能沒生效，顯示時再套一次
        if !GlassStyle.effectiveBlur { WindowBlur.set(panel, radius: GlassStyle.blurRadius) }
        fitHeight(to: monitor.contentHeight)
        UserDefaults.standard.set(true, forKey: "panel.open")
        monitor.tick()
    }
    /// 記住的位置在別台螢幕（或那台已拔掉）時，搬到選單列圖示所在螢幕、貼圖示下方（規則見 PanelPlacement）。
    /// 剛啟動時圖示還沒排進選單列、位置不可信：每 0.25 秒再試，最多 5 秒（不可信時直接搬曾把面板丟到左上角）
    @discardableResult
    private func bringToStatusItemScreen(retry: Int = 0) -> Bool {
        guard let p = panel else { return false }
        guard let bw = statusItem?.button?.window, let scr = bw.screen,
              PanelPlacement.anchorIsValid(button: bw.frame, screen: scr.frame) else {
            if retry < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, self.panel.isVisible else { return }
                    self.bringToStatusItemScreen(retry: retry + 1)
                }
            }
            return false
        }
        guard let f = PanelPlacement.relocated(panel: p.frame, anchorMidX: bw.frame.midX,
                                               screen: scr.frame, visible: scr.visibleFrame) else { return false }
        p.setFrame(f, display: p.isVisible)
        return true
    }
    func hidePanel() {
        panel.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "panel.open")
        monitor.tick()
    }
    @objc func toggleMenuBarTemp() { monitor.showTempInMenuBar.toggle() }
    @objc func emergencyHandBack() { PanelView.confirmEmergency(monitor: monitor) }
    @objc func emergencyRestore() { monitor.emergencyRestore() }
    @objc func relaunch() { monitor.relaunch() }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - 面板視窗與玻璃

/// 無邊框 panel 預設不能變 key：Esc、segmented 的鍵盤操作要它能拿 key（becomesKeyOnlyIfNeeded 仍讓它平常不搶焦點）
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 玻璃樣式（2026-09-25 與 Dock／桌面 widget 並排實測四輪後選定，對照圖 docs/img/screens/glass-compare.png）：
///   深淺兩種外觀都用 .clear ＋ tint（深色黑 0.70、淺色白 0.62）：
///   - .regular 會依背景自己調亮度：深色星空上被抬成霧灰（≈ 38/255，Dock ≈ 12），底下換成白網頁整片洗成淺灰（≈ 150），
///     淺色外觀壓在深色桌布上又變成中灰（≈ 90），霓虹數字對比都掉到 1.1–2:1，而 NSGlassEffectView 不會替內容換深淺色。
///   - .clear 不自適應，所以一定要配一層暗化／提亮（HIG：clear 要加深色層），tint 就是那一層；
///     實測深色：星空底 ≈ 10、白網頁底 ≈ 50；淺色：星空底 ≈ 193、白網頁底 ≈ 250。
///   regular 的白 tint 不會提亮（實測 0.45 → 0.80 反而更暗），所以淺色也用 clear。
///   淺色 tint 第二輪（同日）從 0.80 降到 0.62：0.80 壓在白網頁上是 255（純白、完全看不到底下），跟使用者要的通透相反；
///     0.55／0.65／0.72 各截四種背景量過，0.62 配上壓暗一階的淺色霓虹色，星空底上大數字仍 ≥ 3:1（見 Neon 的淺色值）。
///     代價：淺色壓在深色桌布上時次要字（系統 secondaryLabel）約 3.5:1 —— 系統次要字在純白上也只有約 4:1，這是系統色本身的上限
/// 開發比對用：-glass.style regular|clear、-glass.tint 0…1（深色）、-glass.lightTint 0…1（淺色）、
///   -glass.fallback solid|legacy（強制走「減少透明度」實色底／macOS 14–25 的 NSVisualEffectView，截圖檢查用）
enum GlassStyle {
    static func num(_ key: String) -> Double? {
        if let v = UserDefaults.standard.object(forKey: key) as? Double { return v }
        return UserDefaults.standard.string(forKey: key).flatMap(Double.init)
    }
    static var clear: Bool { UserDefaults.standard.string(forKey: "glass.style") != "regular" }
    /// 使用者在設定視窗調的透明度 0…1（預設 0.2 ＝ 上面實測選定的 0.70／0.62）。
    /// 色調 = 預設值 × (1.2 − t)：t=0 → ×1.2（最清楚），t=1 → ×0.2（最通透，字在亮背景上會難讀）
    static let transparencyKey = "panel.transparency"
    static let defaultTransparency = 0.2
    static var transparency: Double {
        get { min(max(num(transparencyKey) ?? defaultTransparency, 0), 1) }
        set { UserDefaults.standard.set(newValue, forKey: transparencyKey); NotificationCenter.default.post(name: changed, object: nil) }
    }
    static var factor: Double { 1.2 - transparency }
    static var darkTint: Double { min((num("glass.tint") ?? 0.70) * factor, 0.95) }
    static var lightTint: Double { min((num("glass.lightTint") ?? 0.62) * factor, 0.95) }
    /// 面板外觀：system（跟隨系統）／light／dark
    static let appearanceKey = "panel.appearance"
    static var appearance: String {
        get { UserDefaults.standard.string(forKey: appearanceKey) ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: appearanceKey); NotificationCenter.default.post(name: changed, object: nil) }
    }
    static var nsAppearance: NSAppearance? {
        switch appearance { case "light": return NSAppearance(named: .aqua); case "dark": return NSAppearance(named: .darkAqua); default: return nil }
    }
    /// 模糊背景：開＝Apple 玻璃（NSGlassEffectView 一定會模糊並提亮背景，調色調只能在深 ↔ 霧灰之間走，看不到後面）；
    /// 關＝不模糊的半透明疊層，桌布與後面視窗清楚可見（HUD 風）。2026-09-25 使用者回饋「透明度只是變灰變淺」後加的
    static let blurKey = "panel.blur"
    static var blur: Bool {
        // bool(forKey:) 也吃命令列的 "-panel.blur NO"（字串）；as? Bool 只認真的布林值
        get { UserDefaults.standard.object(forKey: blurKey) == nil ? true : UserDefaults.standard.bool(forKey: blurKey) }
        set { UserDefaults.standard.set(newValue, forKey: blurKey); NotificationCenter.default.post(name: changed, object: nil) }
    }
    /// 自訂模糊度（模糊背景關掉時）：0＝完全不模糊的真透明，最大 40（視窗背景模糊半徑，單位約為 pt）
    static let blurRadiusKey = "panel.blurRadius"
    static let maxBlurRadius = 40.0
    static var blurRadius: Double {
        get { min(max(num(blurRadiusKey) ?? 0, 0), maxBlurRadius) }
        set { UserDefaults.standard.set(newValue, forKey: blurRadiusKey); NotificationCenter.default.post(name: changed, object: nil) }
    }
    /// 實際走哪種底：使用者關掉模糊背景，但這台 macOS 找不到自訂模糊 API 時，仍用 Apple 玻璃
    /// （有模糊、字讀得到），不退成完全不模糊——除非使用者把模糊度設 0（本來就要真透明，不需要 API）
    static var effectiveBlur: Bool { blur || (!WindowBlur.available && blurRadius > 0) }
    /// 疊層濃度：t=0 → 0.85（最清楚），t=1 → 0.10（幾乎全透）；預設 t=0.2 → 0.70，和玻璃深色預設同濃度
    static var scrimAlpha: Double { 0.85 - 0.75 * transparency }
    static let changed = Notification.Name("cool42.panelLookChanged")
    static var fallback: String? { UserDefaults.standard.string(forKey: "glass.fallback") }
}

/// 「增加對比」：系統設定，或外觀本身是高對比。
/// 截圖要看這條分支不能靠 NSAppearance(named: .accessibilityHighContrast*)——實測它會退回一般 aqua／darkAqua，
/// 所以另有開發用旗標 forceHC（-glass.forceHC YES，或截圖工具在程式裡設），不必去切使用者的系統設定
enum A11y {
    static var forceHC = UserDefaults.standard.bool(forKey: "glass.forceHC")
    static func increaseContrast(_ ap: NSAppearance? = nil) -> Bool {
        if forceHC || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { return true }
        let a = ap ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let m = a.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        return m == .accessibilityHighContrastAqua || m == .accessibilityHighContrastDarkAqua
    }
    static func isDark(_ ap: NSAppearance) -> Bool {
        let m = ap.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        return m == .darkAqua || m == .accessibilityHighContrastDarkAqua
    }
}

/// 標記「這是玻璃」（PanelEdgeView 依此決定邊緣光；舊系統編譯時不能直接寫 NSGlassEffectView 型別判斷）
protocol GlassMaterial {}
@available(macOS 26.0, *)
final class TintedGlassView: NSGlassEffectView, GlassMaterial {
    func applyStyle() {
        let ap = effectiveAppearance
        let dark = A11y.isDark(ap)
        style = GlassStyle.clear ? .clear : .regular
        var a = dark ? GlassStyle.darkTint : GlassStyle.lightTint
        // 「增加對比」：底色再壓實一點（系統玻璃自己也會變霧），字與背景的差距優先於通透
        if A11y.increaseContrast(ap) { a = max(a, dark ? 0.85 : 0.90) }
        tintColor = a <= 0 ? nil : dark ? NSColor(srgbRed: 0, green: 0, blue: 0.02, alpha: a) : NSColor(white: 1, alpha: a)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

/// 「減少透明度」時的實色底：圓角自己裁，顏色在 updateLayer 依外觀重算（CGColor 不會自己跟著深淺色變）
final class SolidPanelBackground: NSView {
    var radius: CGFloat = 16
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Neon.panelSolidColor.cgColor }
    }
}

/// 視窗背景模糊半徑。AppKit 沒有公開 API（NSGlassEffectView／NSVisualEffectView 都不能調半徑），
/// 只能用 SkyLight 私有的 SLSSetWindowBackgroundBlurRadius（iTerm2、kitty、Alacritty 的背景模糊也是用它）。
/// 同一個函式有兩個名字：SLS*（SkyLight 現名）與 CGS*（CoreGraphics 舊名，Apple 改名時保留做相容），
/// macOS 27.0 兩個都在。執行時用 dlsym 依序找：新名字 → 舊名字；都找不到（未來 macOS 拿掉）就不做事，
/// 面板改走 Apple 玻璃（見 GlassStyle.effectiveBlur），健康檢查亮燈，不會當掉
enum WindowBlur {
    private typealias MainConn = @convention(c) () -> Int32
    private typealias SetRadius = @convention(c) (Int32, Int32, Int32) -> Int32
    private static let handle = dlopen(nil, RTLD_NOW)
    private static func sym<T>(_ names: [String], as: T.Type) -> (T, String)? {
        for n in names { if let p = dlsym(handle, n) { return (unsafeBitCast(p, to: T.self), n) } }
        return nil
    }
    private static let mainConnSym = sym(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConn.self)
    private static let setRadiusSym = sym(["SLSSetWindowBackgroundBlurRadius", "CGSSetWindowBackgroundBlurRadius"], as: SetRadius.self)
    private static var mainConn: MainConn? { mainConnSym?.0 }
    private static var setRadius: SetRadius? { setRadiusSym?.0 }
    /// 開發用：-blur.simulateMissing YES 模擬未來 macOS 拿掉這個函式（驗證退回 Apple 玻璃與健康檢查亮燈）
    static let simulateMissing = UserDefaults.standard.bool(forKey: "blur.simulateMissing")
    static var available: Bool { !simulateMissing && mainConn != nil && setRadius != nil }
    /// 健康檢查顯示用：實際找到的是哪個名字
    static var symbolName: String? { simulateMissing ? nil : setRadiusSym?.1 }
    static func set(_ w: NSWindow, radius: Double) {
        guard available, let mainConn, let setRadius, w.windowNumber > 0 else { return }
        _ = setRadius(mainConn(), Int32(w.windowNumber), Int32(radius.rounded()))
    }
}

/// 模糊背景關掉時的底：不模糊的半透明色層（深色黑、淺色白），濃度跟著透明度滑桿。
/// 標成 GlassMaterial 讓窗緣用和玻璃一樣的上下緣方向光
final class ScrimPanelBackground: NSView, GlassMaterial {
    var radius: CGFloat = 16
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        var a = GlassStyle.scrimAlpha
        if A11y.increaseContrast(effectiveAppearance) { a = max(a, 0.85) }
        layer?.backgroundColor = A11y.isDark(effectiveAppearance)
            ? NSColor(srgbRed: 0, green: 0, blue: 0.02, alpha: a).cgColor
            : NSColor(white: 1, alpha: a).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// 舊系統（macOS 14–25）材質上的色層（跟 clear 玻璃配 tint 同一個道理）：
///   深色黑 0.55（.popover 壓在白網頁上會洗成 ≈ 110/255）、淺色白 0.60（壓在深色桌布上會暗成 ≈ 144，霓虹數字只剩 1.8:1）
final class LegacyDimView: NSView {
    var radius: CGFloat = 16
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = A11y.isDark(effectiveAppearance) ? NSColor(white: 0, alpha: 0.55).cgColor : NSColor(white: 1, alpha: 0.60).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// 窗緣光。和 Dock、桌面 widget 同一種「有方向的光」（2026-09-25 在同一張整螢幕截圖上逐像素量）：
///   Dock 只有上下緣亮（≈ 83/255），往內 28 → 21 → 18 → 16 漸淡到底色 12；左右兩側幾乎沒有亮邊。widget 也一樣（上緣 60、側邊 0）。
///   原本一圈均勻 1pt 白 0.26 的描邊四邊都 ≈ 88、往內一格直接掉到 13，看起來像 HUD 外框。
/// 所以玻璃分支：1pt 邊用垂直漸層（上下 0.26、側邊中段 0，靠近圓角處才亮起來）＋上下緣內側 6pt 柔光；
/// 實色／舊系統材質：系統分隔線色一圈；「增加對比」：均勻加粗的 label 色邊（這時要清楚，不要光影）
final class PanelEdgeView: NSView {
    let radius: CGFloat
    let glass: Bool
    private let rim = CAGradientLayer()
    private let rimMask = CALayer()
    private let topGlow = CAGradientLayer()
    private let bottomGlow = CAGradientLayer()
    /// 側邊從亮轉淡的距離（pt）：比圓角大一點，圓角整段都是亮的
    static let fade: CGFloat = 36
    static let glowDepth: CGFloat = 6

    init(radius: CGFloat, glass: Bool) {
        self.radius = radius; self.glass = glass
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 不擋滑鼠

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func updateLayer() {
        guard let l = layer else { return }
        let ap = effectiveAppearance
        let hc = A11y.increaseContrast(ap)
        let dark = A11y.isDark(ap)
        l.cornerRadius = radius
        l.cornerCurve = .continuous
        l.masksToBounds = true
        let b = l.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let directional = glass && !hc
        if !directional {
            // 均勻邊：高對比加粗，實色／舊系統材質用分隔線色
            [rim, topGlow, bottomGlow].forEach { $0.removeFromSuperlayer() }
            l.borderWidth = hc ? 1.5 : 1
            let c: NSColor = hc ? NSColor.labelColor.withAlphaComponent(0.55) : NSColor.separatorColor
            ap.performAsCurrentDrawingAppearance { l.borderColor = c.cgColor }
            return
        }
        l.borderWidth = 0
        for sub in [rim, topGlow, bottomGlow] where sub.superlayer !== l { l.addSublayer(sub) }
        // 1pt 邊：垂直漸層上色，mask 是同圓角（continuous）的 1pt border，只露出邊
        // 側邊：玻璃自己就有一條 ≈ 31/255 的邊，再加只會比 Dock（側邊 ≈ 0）更像外框，所以深色側邊不補
        let (edge, side): (CGFloat, CGFloat) = dark ? (0.26, 0) : (0.60, 0.14)
        let f = min(0.45, Self.fade / max(b.height, 1))
        rim.frame = b
        rim.colors = [edge, side, side, edge].map { NSColor(white: 1, alpha: $0).cgColor }
        rim.locations = [0, NSNumber(value: Double(f)), NSNumber(value: Double(1 - f)), 1]
        rim.startPoint = CGPoint(x: 0.5, y: 0); rim.endPoint = CGPoint(x: 0.5, y: 1)
        rimMask.frame = b
        rimMask.cornerRadius = radius
        rimMask.cornerCurve = .continuous
        rimMask.borderWidth = 1
        rimMask.borderColor = NSColor.black.cgColor
        rim.mask = rimMask
        // 內側柔光：只在深色（淺色玻璃本身就亮，再加白只會糊）
        let g: CGFloat = dark ? 0.075 : 0
        let d = Self.glowDepth
        for (layer, atTop) in [(topGlow, true), (bottomGlow, false)] {
            layer.isHidden = g == 0
            layer.frame = CGRect(x: 0, y: atTop ? b.height - d - 1 : 1, width: b.width, height: d)
            layer.colors = [NSColor(white: 1, alpha: g).cgColor, NSColor(white: 1, alpha: 0).cgColor]
            // 從貼邊那一側往內淡掉（layer 座標 y 向上：上緣光從 y = 1 往 0 淡）
            layer.startPoint = CGPoint(x: 0.5, y: atTop ? 1 : 0)
            layer.endPoint = CGPoint(x: 0.5, y: atTop ? 0 : 1)
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

extension NSImage {
    /// NSVisualEffectView.maskImage 用的圓角遮罩（capInsets 讓它隨視窗大小拉伸）
    static func roundedMask(radius r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

// MARK: - 資料

@Observable
final class Monitor {
    var snapshot: Snapshot?
    var history: [HistoryPoint] = []
    var config = Config.load(path: nil)
    var draft = Config.load(path: nil)   // 設定視窗裡編輯中的設定
    /// 開始編輯時的設定（draft 的比較基準）：dirty 看 draft 和它差在哪；套用時只把差的欄位疊到最新的設定檔上
    /// （Config.applyingPanelEdits），編輯期間別處改的鍵（手動、CLI、MCP）不會被舊 draft 蓋回
    var draftBase = Config.load(path: nil)
    var saveMessage: String? = nil
    var saveFailed = false               // saveMessage 是不是錯誤（紅字）；不再靠比對字串前綴，換語言才不會失效
    /// 選單有沒有打開。關著的時候只更新標題（讀一個 JSON，不開 SMC、不畫圖）
    var panelOpen = false { didSet { if panelOpen { reloadConfig(); tick() } } }
    @ObservationIgnored weak var panelWindow: NSWindow? = nil
    @ObservationIgnored var onTick: (() -> Void)? = nil   // 每輪取樣後更新選單列標題
    @ObservationIgnored var onHide: (() -> Void)? = nil   // 面板右上角 ✕
    @ObservationIgnored var onContentHeight: ((CGFloat) -> Void)? = nil
    @ObservationIgnored var contentHeight: CGFloat = 0 {
        didSet { if contentHeight != oldValue { onContentHeight?(contentHeight) } }
    }
    let intervalOpen: TimeInterval = 3
    let intervalIdle: TimeInterval = 5
    private var timer: Timer?
    private var localHistory: [HistoryPoint] = []   // guard 沒跑時自己取樣的備援

    // 提示音：進入過熱 / 降頻響「熱」、回到正常響「冷」。開關存 UserDefaults（面板本地）；
    // 音效檔三層：config 的 sounds.overheat / cooldown → app 內建 Sounds/overheat.m4a、cooldown.m4a → 系統音
    static let hotSound = "Basso", coldSound = "Glass"
    var hotSoundOn: Bool { didSet { UserDefaults.standard.set(hotSoundOn, forKey: "sound.hot") } }
    var coldSoundOn: Bool { didSet { UserDefaults.standard.set(coldSoundOn, forKey: "sound.cold") } }
    @ObservationIgnored private var wasHot: Bool? = nil          // 上一輪是不是熱的；nil = 還沒取樣，第一輪不響
    @ObservationIgnored private var awaitingCool = false         // 響過「熱」之後上鎖，等降到 cooldownBelow 響「冷」才解鎖
    @ObservationIgnored private var lastSound = Date.distantPast
    @ObservationIgnored private var configMtime: Date? = nil
    @ObservationIgnored private var playing: NSSound? = nil   // 抓住正在播的，不然 mp3 播到一半被釋放

    // 選單列：只顯示圖示／圖示＋溫度（面板本地偏好，不進 /etc 設定）
    var showTempInMenuBar: Bool { didSet { UserDefaults.standard.set(showTempInMenuBar, forKey: "menubar.showTemp"); onTick?() } }
    // 通知：開關存 UserDefaults；授權狀態由 Notifier 回報
    var notifyOn: Bool { didSet { UserDefaults.standard.set(notifyOn, forKey: "notify.on") } }
    var notifyAuth: Notifier.Auth = .unknown
    @ObservationIgnored private var notifyState = NotifyState()
    // 「今天」時間軸與健康檢查（面板開著才更新）
    /// 熱度格和「今天」一次只展開一個（兩個都開時面板約 1,080pt，1080p 螢幕放不下、要捲動）
    var showToday: Bool { didSet {
        UserDefaults.standard.set(showToday, forKey: "today.show")
        if showToday { if showSensors { showSensors = false }; refreshToday(force: true) }
    } }
    var todayEvents: [DayEvent] = []
    var health: [HealthItem] = []
    @ObservationIgnored private var hookMarks = HookMarks()
    @ObservationIgnored private var todayStamp: (Date, Date?, UInt64)? = nil   // 上次讀的時間、log mtime、大小
    @ObservationIgnored private var healthTime = Date.distantPast
    /// 緊急交還原廠前的模式（有值才顯示「恢復」）
    var emergencyPrevMode: String? { didSet { UserDefaults.standard.set(emergencyPrevMode, forKey: "emergency.prevMode") } }
    @ObservationIgnored var onShowOnboarding: (() -> Void)? = nil
    // 情境與噪音上限：專注模式授權與目前狀態（面板讀、寫旗標給 guard）、展開編輯中的規則
    var focusAuth: FocusWatcher.Auth = .unavailable
    var focusNow: Bool? = nil
    var editingProfile: Int? = nil
    /// 打開設定視窗（指定分頁；nil＝上次看的那頁）
    @ObservationIgnored var onShowSettings: ((SettingsTab?) -> Void)? = nil

    // 各感測器明細：只有面板展開「各感測器」時才每輪讀 73 個 key，收合不花這個成本
    var showSensors: Bool { didSet {
        UserDefaults.standard.set(showSensors, forKey: "sensors.show")
        if showSensors { if showToday { showToday = false }; readSensors() }
    } }
    var sensorTemps: [String: Double] = [:]
    /// 健康檢查亮紅燈時熱度格先收起來（面板才放得下紅燈＋其他監控）；使用者自己再展開就照他的（只到這次紅燈結束）
    var sensorsDespiteHealth = false

    init() {
        hotSoundOn = UserDefaults.standard.object(forKey: "sound.hot") as? Bool ?? true
        coldSoundOn = UserDefaults.standard.object(forKey: "sound.cold") as? Bool ?? true
        let sensorsOpen = UserDefaults.standard.bool(forKey: "sensors.show")
        showSensors = sensorsOpen
        showTempInMenuBar = UserDefaults.standard.object(forKey: "menubar.showTemp") as? Bool ?? true
        notifyOn = UserDefaults.standard.object(forKey: "notify.on") as? Bool ?? true
        showToday = UserDefaults.standard.bool(forKey: "today.show") && !sensorsOpen   // 舊版兩個都開過：留熱度格
        emergencyPrevMode = UserDefaults.standard.string(forKey: "emergency.prevMode")
        smcOpened = (try? SMC.open()) != nil
        tick()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: panelOpen ? intervalOpen : intervalIdle, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick()
            if (self.timer?.timeInterval ?? 0) != (self.panelOpen ? self.intervalOpen : self.intervalIdle) { self.schedule() }
        }
    }

    var windowVisible: Bool { panelWindow?.isVisible ?? false }

    func tick() {
        // 設定檔被改了（另一個 session、手動編輯）就跟上，門檻和音檔才會即時生效；只 stat 一次，閒置也做
        let m = Config.mtime(config.loadedFrom)
        if m != configMtime { configMtime = m; reloadConfig() }
        // guard 在跑：只讀快照檔；沒跑才自己開 SMC
        let s = Snapshot.takeFast(config: config)
        snapshot = s
        checkSound(s)
        checkNotify(s)
        pollFocus()
        hookMarks.observe(s.stats)
        onTick?()
        let open = windowVisible
        if open != panelOpen { panelOpen = open; return }   // didSet 會再叫一次 tick
        guard panelOpen else { return }
        if showSensors { readSensors() }
        refreshToday()
        refreshHealth()
        if s.guardRunning {
            history = History.load()
        } else {
            localHistory.append(HistoryPoint(time: s.time, cpu: s.cpuMax, gpu: s.gpuMax, rpm: s.fans.first?.rpm ?? 0, target: nil))
            localHistory.removeAll { Date().timeIntervalSince($0.time) > History.keep }
            history = localHistory
        }
    }

    /// 一趟「過熱 → 涼了」只響兩聲：控制溫度 ≥ overheatAbove（或 CPU / GPU 降頻、或到 critical）的瞬間響「熱」並上鎖；
    /// 之後不熱了且控制溫度降到 cooldownBelow 以下才響「冷」並解鎖。中間在門檻上下抖動不會再叫；20 秒內也不連響
    private func checkSound(_ s: Snapshot) {
        let hot = s.controlTemp >= config.overheatAbove || s.level == .critical || s.throttling || s.gpuThrottling
        defer { wasHot = hot }
        guard let was = wasHot else { return }
        if hot, !was, !awaitingCool {
            awaitingCool = true
            if hotSoundOn, Date().timeIntervalSince(lastSound) > 20 { play(hot: true) }
        }
        if !hot, awaitingCool, s.controlTemp < config.cooldownBelow {
            awaitingCool = false
            if coldSoundOn, Date().timeIntervalSince(lastSound) > 20 { play(hot: false) }
        }
    }

    /// 通知三個時刻：開始降頻、進入 critical、恢復正常（以一段過熱為單位，見 NotifyState）
    private func checkNotify(_ s: Snapshot) {
        let kinds = notifyState.step(throttled: s.throttling || s.gpuThrottling, level: s.level)
        guard notifyOn else { return }
        for k in kinds {
            switch k {
            case .throttle:
                // 兩句：原因＋現在溫度。hook 那句只在真的裝了 hook 時才講
                let hook = Health.hookInstalled() ? L("AI的重工作會先等降溫。") : ""
                Notifier.shared.post(.throttle, title: L("Mac開始降頻"),
                                     body: L("原因：%@。目前%.0f°C。", s.throttleReason, s.controlTemp) + hook)
            case .critical:
                let hook = Health.hookInstalled() ? L("新的重工作會先被擋下，直到降溫。") : ""
                Notifier.shared.post(.critical, title: L("溫度%.0f°C，已達critical", s.controlTemp),
                                     body: hook + L("打開面板看是誰在吃CPU。"))
            case .recovered:
                Notifier.shared.post(.recovered, title: L("已恢復正常"), body: L("溫度回到%.0f°C，沒有降頻。", s.controlTemp))
            }
        }
    }

    /// 專注模式：有 focus 規則（已套用的設定）才讀、寫旗標；面板收著也照做（guard 要一直知道）
    private func pollFocus() {
        let a = FocusWatcher.shared.auth
        if a != focusAuth { focusAuth = a }
        let f = FocusWatcher.shared.poll(needed: config.profiles.contains { $0.hasFocus })
        if f != focusNow { focusNow = f }
    }

    func requestFocusAccess() {
        FocusWatcher.shared.request { [weak self] a in self?.focusAuth = a; self?.pollFocus() }
    }

    /// 今天的事件：log 有變才重讀，展開時最多每 15 秒一次、收合時 60 秒一次（force：剛展開時）。
    /// 收合時也要讀：標題列的摘要（「降頻 n 次 · 共 n 件」）靠它，原本只在展開時讀，收合就永遠顯示「沒有事件」
    func refreshToday(force: Bool = false) {
        let minInterval: TimeInterval = showToday ? 15 : 60
        let attrs = try? FileManager.default.attributesOfItem(atPath: DayLog.path)
        let mtime = attrs?[.modificationDate] as? Date
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        if !force, let (t, m, sz) = todayStamp, (m == mtime && sz == size) || Date().timeIntervalSince(t) < minInterval {
            // log 沒變時仍要併入新的 hook 記號
            if m == mtime && sz == size { mergeHookMarks() }
            return
        }
        todayStamp = (Date(), mtime, size)
        logEvents = DayLog.parse(DayLog.todayLines())
        mergeHookMarks()
    }
    @ObservationIgnored private var logEvents: [DayEvent] = []
    /// 併入 hook 記號、新的在上。超過 20 件時先保住降頻／過熱／AI 等待這類重要事件，預熱補剩下的名額
    private func mergeHookMarks() {
        let all = (logEvents + HookMarks.todayEvents()).sorted { $0.time > $1.time }
        var shown = all
        if all.count > DayLog.maxShown {
            let minor: Set<DayEvent.Kind> = [.boost, .boostSkip]
            let important = all.filter { !minor.contains($0.kind) }.prefix(DayLog.maxShown)
            let boosts = all.filter { minor.contains($0.kind) }.prefix(DayLog.maxShown - important.count)
            shown = (Array(important) + boosts).sorted { $0.time > $1.time }
        }
        let th = all.filter { $0.kind == .throttleStart }.count
        let bo = all.filter { $0.kind == .boost }.reduce(0) { $0 + ($1.boost?.count ?? 1) }
        if shown != todayEvents || totalToday != all.count || th != todayThrottles || bo != todayBoosts {
            todayEvents = shown; totalToday = all.count; todayThrottles = th; todayBoosts = bo
        }
    }
    /// 今天總共幾件（todayEvents 可能只是其中 20 件）、降頻幾次、預熱幾次（併起來的預熱行各自的 count 加總）
    var totalToday = 0
    var todayThrottles = 0
    var todayBoosts = 0

    /// 健康檢查：面板開著時每 30 秒一次
    func refreshHealth(force: Bool = false) {
        guard force || Date().timeIntervalSince(healthTime) > 30 else { return }
        healthTime = Date()
        let h = Health.run(snapshot: snapshot, config: config)
        if h != health { health = h }
        if sensorsDespiteHealth, !h.contains(where: { $0.severity == .bad }) { sensorsDespiteHealth = false }
    }

    /// 緊急交還原廠：只把設定檔的 mode 改成 auto（其他欄位照舊），走面板寫設定檔的同一條路（使用者可寫、不需要 root），
    /// guard 偵測到 mtime 變了會熱重載並把風扇交還 SMC。原本的模式記在 UserDefaults，按「恢復」就改回去
    func emergencyAuto() {
        do {
            var c = try Config.loadOrError(path: nil)
            guard c.mode != "auto" else { return }
            let prev = c.mode
            c.mode = "auto"
            try c.save()
            emergencyPrevMode = prev
            afterEmergencyWrite(L("已交還macOS原廠控制"))
        } catch {
            saveMessage = L("寫入失敗：%@", error.localizedDescription); saveFailed = true
        }
    }

    func emergencyRestore() {
        guard let prev = emergencyPrevMode else { return }
        do {
            var c = try Config.loadOrError(path: nil)
            c.mode = prev
            try c.save()
            emergencyPrevMode = nil
            afterEmergencyWrite(L("已恢復「%@」模式", modeDisplayName(prev)))
        } catch {
            saveMessage = L("寫入失敗：%@", error.localizedDescription); saveFailed = true
        }
    }

    /// 面板上的一鍵模式切換：直接寫設定檔的 mode（其他欄位照舊、設定視窗裡未套用的編輯保留），guard 熱重載。
    /// 切到「自動」也記下原本的模式，右鍵選單才有「恢復」
    func setModeNow(_ mode: String) {
        do {
            var c = try Config.loadOrError(path: nil)
            guard c.mode != mode else { return }
            let prev = c.mode
            c.mode = mode
            try c.validate()
            try c.save()
            emergencyPrevMode = mode == "auto" ? prev : nil
            afterEmergencyWrite(L("已切換為「%@」模式", modeDisplayName(mode)))
        } catch {
            saveMessage = L("寫入失敗：%@", error.localizedDescription); saveFailed = true
        }
    }

    /// 換提示音檔：跟模式切換一樣直接寫設定檔（選檔本身就是確認，不走「套用」）；path = nil 還原成 app 內建音效。
    /// 只動 sounds.overheat / cooldown，未套用的其他編輯（門檻、曲線…）疊回新設定檔上保留
    func setSoundFileNow(hot: Bool, path: String?) {
        do {
            var c = try Config.loadOrError(path: nil)
            var s = c.sounds ?? .init()
            let stored = path.map { NSString(string: $0).abbreviatingWithTildeInPath }
            if hot { s.overheat = stored } else { s.cooldown = stored }
            c.sounds = s
            try c.validate()
            try c.save()
            config = Config.load(path: nil)
            rebaseDraft(onto: config)
            configMtime = Config.mtime(config.loadedFrom)
            saveMessage = path.map { L("提示音已換成「%@」", ($0 as NSString).lastPathComponent) } ?? L("提示音已還原成內建音效")
            saveFailed = false
        } catch {
            saveMessage = L("寫入失敗：%@", error.localizedDescription); saveFailed = true
        }
    }

    /// 設定檔有沒有自訂這個提示音（決定要不要顯示「還原成內建音效」）
    func hasCustomSound(hot: Bool) -> Bool {
        let s = Config.load(path: nil).sounds
        return !((hot ? s?.overheat : s?.cooldown) ?? "").isEmpty
    }

    private func afterEmergencyWrite(_ msg: String) {
        config = Config.load(path: nil)
        // 其他未套用的編輯保留（疊到新的設定檔上），模式跟著設定檔走
        rebaseDraft(onto: config, dropping: [.mode])
        configMtime = Config.mtime(config.loadedFrom)
        saveMessage = msg; saveFailed = false
        tick()
    }

    /// config 有指定音檔就播它（現讀一次設定檔，改了不用重開面板），沒有就用 app 內建的，再沒有退回系統音
    func play(hot: Bool) {
        playing?.stop()
        if let path = soundPath(hot: hot), let snd = NSSound(contentsOfFile: path, byReference: true) {
            playing = snd
        } else {
            playing = NSSound(named: hot ? Self.hotSound : Self.coldSound)
        }
        playing?.play()
        lastSound = Date()
    }

    /// 讀每個 CPU / GPU 感測器。key 用 guard 掃好寫在快照裡的（面板平常只讀快照，不會自己掃），沒有才掃一次
    @ObservationIgnored private var sensorKeys: [String] = []
    @ObservationIgnored private var smcOpened = false
    func readSensors() {
        if !smcOpened { smcOpened = (try? SMC.open()) != nil }
        guard smcOpened else { return }
        if sensorKeys.isEmpty {
            if let saved = Snapshot.load(), let ck = saved.cpuKeys, !ck.isEmpty {
                sensorKeys = ck + (saved.gpuKeys ?? [])
            } else {
                let prefixes = config.cpuPrefixes + config.gpuPrefixes
                sensorKeys = SMC.scanTemperatureKeys().map(\.0).filter { k in prefixes.contains { k.hasPrefix($0) } }
            }
        }
        var out: [String: Double] = [:]
        for k in sensorKeys { if let t = SMC.readDouble(k), SMC.plausibleTemp(t) { out[k] = t } }
        sensorTemps = out
    }

    /// 實際會播的音檔：config 指定（存在才算）→ app bundle 內建 → nil（系統音）
    func soundPath(hot: Bool) -> String? {
        let snd = Config.load(path: nil).sounds
        if let raw = hot ? snd?.overheat : snd?.cooldown, !raw.isEmpty {
            let path = NSString(string: raw).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        for ext in ["m4a", "mp3", "aiff", "wav"] {
            if let p = Bundle.main.path(forResource: hot ? "overheat" : "cooldown", ofType: ext, inDirectory: "Sounds") { return p }
        }
        return nil
    }

    /// 面板上編輯提示音門檻：draft.sounds 缺席時先建一個，其他欄位保留
    var draftOverheatAbove: Double {
        get { draft.overheatAbove }
        set { var x = draft.sounds ?? .init(); x.overheatAbove = newValue; draft.sounds = x }
    }
    var draftCooldownBelow: Double {
        get { draft.cooldownBelow }
        set { var x = draft.sounds ?? .init(); x.cooldownBelow = newValue; draft.sounds = x }
    }

    /// 重新啟動面板：由 LaunchAgent 管的就 kickstart，不然直接 open 自己的 bundle
    func relaunch() {
        let bundle = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.4; launchctl kickstart -k gui/$(id -u)/com.cool42.panel 2>/dev/null || open \"\(bundle)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// 外部（手動編輯、另一台面板）改了設定檔也跟上
    func reloadConfig() {
        let fresh = Config.load(path: nil)
        rebaseDraft(onto: fresh)
        config = fresh
        // 模式已經不是 auto（套用了別的模式、別處改了設定檔）：「恢復」按鈕就沒有意義了
        if fresh.mode != "auto", emergencyPrevMode != nil { emergencyPrevMode = nil }
    }

    /// 設定檔換了（別處改的、面板一鍵切模式）：使用者還沒套用的編輯疊到新的設定檔上，其餘欄位跟著新的走。
    /// dropping：這些欄位的編輯作廢、直接用新值（例如一鍵切模式之後的 mode）
    private func rebaseDraft(onto fresh: Config, dropping: Set<Config.PanelField> = []) {
        let base = draftBase
        var edited = draft
        if dropping.contains(.mode) { edited.mode = base.mode }
        draft = Config.applyingPanelEdits(base: base, draft: edited, onto: fresh)
        draftBase = fresh
    }

    /// 使用者在設定視窗改了、還沒套用的欄位（比的是開始編輯時的 draftBase，不是設定檔最新值）
    var edits: Set<Config.PanelField> { Config.panelEdits(base: draftBase, draft: draft) }
    var fanDirty: Bool { !edits.isDisjoint(with: [.mode, .fixedRPM, .includeGPU, .curve]) }
    var soundDirty: Bool { !edits.isDisjoint(with: [.overheatAbove, .cooldownBelow]) }
    var profileDirty: Bool { !edits.isDisjoint(with: [.maxRPM, .profiles]) }
    var dirty: Bool { !edits.isEmpty }

    /// 寫回設定檔，guard 會偵測 mtime 自動重載。
    /// 先重讀磁碟上最新的設定檔，只把使用者改過的欄位疊上去再寫（三方合併），別處在編輯期間改的鍵保留
    func apply() {
        do {
            if let (name, problem) = firstProfileProblem {
                saveMessage = L("規則「%@」：%@", name, problem); saveFailed = true; return
            }
            // 設定檔壞掉（解析失敗）時不寫：寫下去會把使用者手改到一半的檔整個蓋掉
            let latest = try Config.loadOrError(path: nil)
            let merged = Config.applyingPanelEdits(base: draftBase, draft: draft, onto: latest)
            try merged.validate()   // guard 會拒絕載入的設定不寫出去（它會保留舊設定，面板卻以為套用了）
            try merged.save()
            config = Config.load(path: nil)
            configMtime = Config.mtime(config.loadedFrom)
            draft = config
            draftBase = config
            if config.mode != "auto" { emergencyPrevMode = nil }
            saveMessage = L("已套用（%@）", ((config.loadedFrom ?? "") as NSString).lastPathComponent)
            saveFailed = false
        } catch {
            saveMessage = L("寫入失敗：%@", error.localizedDescription)
            saveFailed = true
        }
    }

    func revert() { draft = config; draftBase = config; saveMessage = nil; saveFailed = false; editingProfile = nil }

    /// 名稱在第一次用到時就換成目前語言；它同時是 segmented 的 tag（同一次執行內一致即可）。
    /// 曲線本身在 Cool42Core（Config.presetCurves），情境規則的 "curve": "quiet" 用的是同一份
    static let presets: [(String, [Config.Point])] = Config.presetIDs.map { (presetName($0), Config.presetCurves[$0] ?? Config().curve) }
    static func presetName(_ id: String) -> String {
        switch Config.presetID(id) {
        case "quiet": return L("安靜")
        case "balanced": return L("均衡")
        case "performance": return L("強力")
        default: return id
        }
    }

    /// 選單列項目：符號（依狀態換形狀）、標題（等寬溫度）、VoiceOver 名稱（含狀態）
    /// throttled：圖示右上角加烏龜；hot：右下角加點（等級形狀照舊，兩件事同時看得到）
    struct MenuState { var symbol: String; var title: String; var accessibility: String; var throttled = false; var hot = false }
    var menuState: MenuState {
        guard let s = snapshot else { return MenuState(symbol: "fan", title: "", accessibility: L("cool42，讀取中")) }
        let t = Int(s.controlTemp.rounded())
        let throttled = s.throttling || s.gpuThrottling
        let state = throttled ? L("%@，降頻中（%@）", s.level.label, s.throttleReason) : s.level.label
        // 不足三位數前面補 figure space（U+2007，和數字同寬）
        let digits = String(t)
        let title = " " + String(repeating: "\u{2007}", count: max(0, 3 - digits.count)) + digits + "°"
        return MenuState(symbol: s.level.symbol, title: title, accessibility: L("cool42，控制溫度%ld度，%@", t, state),
                         throttled: throttled, hot: s.level == .hot)
    }
}

extension Level {
    var color: Color {
        switch self {
        case .ok: return .green
        case .warm: return .yellow
        case .hot: return .orange
        case .critical: return .red
        }
    }
    var label: String {
        switch self {
        case .ok: return L("正常")
        case .warm: return L("偏溫")
        case .hot: return L("過熱")
        case .critical: return L("危險")
        }
    }
    /// 選單列 template 圖示：溫度計刻度往上走，危險改三角形（不同形狀，不只靠顏色）
    var symbol: String {
        switch self {
        case .ok: return "thermometer.low"
        case .warm: return "thermometer.medium"
        case .hot: return "thermometer.high"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - 漸層微光風格

/// 霓虹線 + 線下漸層消失。發光用三層同路徑線疊出來（Charts 的 mark 不能 blur）
/// 每個霓虹色都有四版：淺 / 深 × 一般 / 增加對比。深色是原本的霓虹；淺色把同一色相壓暗
/// （淺色玻璃 tint 0.62 壓在深色桌布上底色 ≈ 193/255，淺色值再壓暗一階，大數字才維持 ≥ 3:1）。
/// 面板沒有實心卡片了（直接壓在玻璃上），所以霓虹色只給「大數字、圖表線、狀態點」：
///   大數字（title2 semibold ≥ 3:1）、圖表線與狀態點（非文字 ≥ 3:1）—— 在深色 tint 玻璃與淺色玻璃上實測過（docs/img/screens/glass-*）；
///   一般說明字、標籤一律 .primary / .secondary（系統 vibrant），不上霓虹色
enum Neon {
    typealias RGBA = (Double, Double, Double, Double)
    /// 動態色：NSColor 依當下 appearance 解析，SwiftUI 與 NSWindow 背景都吃得到
    /// hcLight / hcDark：系統「增加對比」時用的色值；沒給就沿用一般版，再把透明度乘 highContrast（髮絲線、格線這類淡色用）
    static func dynamic(_ name: String, light: RGBA, dark: RGBA, hcLight: RGBA? = nil, hcDark: RGBA? = nil,
                        highContrast: Double = 1) -> NSColor {
        NSColor(name: NSColor.Name("cool42." + name)) { ap in
            let m = ap.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let isDark = m == .darkAqua || m == .accessibilityHighContrastDarkAqua
            let hc = m == .accessibilityHighContrastAqua || m == .accessibilityHighContrastDarkAqua
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || A11y.forceHC
            let c = hc ? ((isDark ? hcDark : hcLight) ?? (isDark ? dark : light)) : (isDark ? dark : light)
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: min(1, c.3 * (hc ? highContrast : 1)))
        }
    }
    static let cyan   = Color(nsColor: dynamic("cyan",   light: (0.00, 0.41, 0.63, 1), dark: (0.16, 0.87, 0.96, 1), hcLight: (0.00, 0.36, 0.56, 1), hcDark: (0.45, 0.93, 1.00, 1)))
    static let green  = Color(nsColor: dynamic("green",  light: (0.04, 0.44, 0.20, 1), dark: (0.36, 0.95, 0.55, 1), hcLight: (0.02, 0.38, 0.17, 1), hcDark: (0.55, 1.00, 0.70, 1)))
    static let purple = Color(nsColor: dynamic("purple", light: (0.42, 0.26, 0.85, 1), dark: (0.72, 0.56, 1.00, 1), hcLight: (0.34, 0.18, 0.72, 1), hcDark: (0.82, 0.72, 1.00, 1)))
    static let amber  = Color(nsColor: dynamic("amber",  light: (0.55, 0.31, 0.00, 1), dark: (1.00, 0.72, 0.30, 1), hcLight: (0.50, 0.29, 0.00, 1), hcDark: (1.00, 0.82, 0.50, 1)))
    static let red    = Color(nsColor: dynamic("red",    light: (0.75, 0.11, 0.20, 1), dark: (1.00, 0.36, 0.42, 1), hcLight: (0.66, 0.06, 0.15, 1), hcDark: (1.00, 0.55, 0.60, 1)))
    /// 「減少透明度」時的實色視窗底（正式 app 平常用玻璃，見 AppDelegate.applyBackground）；離屏截圖也用它當底。
    /// 取樣自實機玻璃（深色 clear＋tint 0.70 壓在星空上 ≈ 10/255、淺色 ≈ 225–255），關掉透明度時看起來還是同一個面板
    static let panelSolidColor = dynamic("panelSolid", light: (0.965, 0.966, 0.975, 1), dark: (0.04, 0.04, 0.063, 1))
    /// 窗緣 1pt 亮邊（Dock、桌面 widget 那種上下亮、側邊淡的光）：離屏截圖畫框用，實機由 PanelEdgeView 畫同一組值
    static let rim = Color(nsColor: dynamic("rim", light: (0, 0, 0, 0.10), dark: (1, 1, 1, 0.26)))
    static let rimSide = Color(nsColor: dynamic("rimSide", light: (0, 0, 0, 0.04), dark: (1, 1, 1, 0.07)))   // 離屏實色底沒有玻璃自己的邊，補一點
    /// 離屏截圖用的窗緣漸層（上下亮、中段淡；fade 是從上下緣算起幾 pt 轉淡，跟 PanelEdgeView 一樣）
    static func rimGradient(height: CGFloat) -> LinearGradient {
        let f = min(0.45, PanelEdgeView.fade / max(height, 1))
        return LinearGradient(stops: [.init(color: rim, location: 0), .init(color: rimSide, location: f),
                                      .init(color: rimSide, location: 1 - f), .init(color: rim, location: 1)],
                              startPoint: .top, endPoint: .bottom)
    }
    static let panelBG = Color(nsColor: panelSolidColor)
    /// 視窗圓角（玻璃 / 舊系統材質 / 截圖外框共用）。量自同一張整螢幕截圖：桌面 widget 與 Dock 的圓角 ≈ 26pt
    /// （逐列量輪廓、和圓弧比對），原本 16 並排時明顯比較尖（不像同一家族）
    static let windowRadius: CGFloat = 26
    /// 圖表底：極淡的井（不是實心板），只讓圖的範圍看得出來
    static let plotBG  = Color(nsColor: dynamic("plotBG", light: (0, 0, 0, 0.03), dark: (1, 1, 1, 0.035), highContrast: 2))
    /// 一般視窗（導覽頁）裡的淡底框；面板本身不用
    static let cardBG  = Color(nsColor: dynamic("cardBG", light: (0, 0, 0, 0.035), dark: (1, 1, 1, 0.05)))
    /// 卡片 / 視窗邊的髮絲線、圖表格線、座標字
    static let hairline = Color(nsColor: dynamic("hairline", light: (0, 0, 0, 0.08), dark: (1, 1, 1, 0.08), highContrast: 3))
    static let grid     = Color(nsColor: dynamic("grid", light: (0, 0, 0, 0.07), dark: (1, 1, 1, 0.06), highContrast: 2.5))
    static let axis     = Color(nsColor: .secondaryLabelColor)
    /// 間距節奏（4pt 基準）：區段內 6、區段上下各 10（分隔線兩側）、視窗邊 16
    static let sectionPadding: CGFloat = 10
    /// 圖表井、紅燈提示框的圓角：跟視窗同心（內圓角 ＝ 外圓角 − 視窗邊距 16）
    static let plotRadius: CGFloat = windowRadius - 16
    static let stackSpacing: CGFloat = 6
    /// 字級角色：macOS 可讀下限 10pt（HIG），所以最小字就是 caption2；會跳動的數字一律等寬數字
    static let axisFont = Font.caption2.monospacedDigit()
    static let valueFont = Font.system(.title2, design: .rounded, weight: .semibold).monospacedDigit()

    /// 發光線、發光點的暈：只在深色外觀出現（淺色底上彩色暈只會讓線變粗變糊）；「增加對比」也關掉
    static func halo(_ c: Color, _ alpha: Double) -> Color {
        let base = NSColor(c)
        return Color(nsColor: NSColor(name: nil) { ap in
            guard A11y.isDark(ap), !A11y.increaseContrast(ap) else { return .clear }
            var out = NSColor.clear
            ap.performAsCurrentDrawingAppearance { out = (base.usingColorSpace(.sRGB) ?? base).withAlphaComponent(alpha) }
            return out
        })
    }

    /// 線下漸層：上濃下淡到透明
    static func fade(_ c: Color, top: Double = 0.45) -> LinearGradient {
        LinearGradient(colors: [c.opacity(top), c.opacity(0.12), c.opacity(0)], startPoint: .top, endPoint: .bottom)
    }
}

extension Level {
    var neon: Color {
        switch self {
        case .ok: return Neon.green
        case .warm: return Neon.amber
        case .hot: return Neon.amber
        case .critical: return Neon.red
        }
    }
}

/// 三層疊出來的發光線：寬淡暈 → 中暈 → 細實線（暈只在深色外觀，見 Neon.halo）
@ChartContentBuilder
func glowLine<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, series: String, color: Color, smooth: Bool = true) -> some ChartContent {
    LineMark(x: x, y: y, series: .value("s", series + "•halo")).foregroundStyle(Neon.halo(color, 0.10)).lineStyle(.init(lineWidth: 10, lineCap: .round, lineJoin: .round)).interpolationMethod(smooth ? .catmullRom : .linear).accessibilityHidden(true)
    LineMark(x: x, y: y, series: .value("s", series + "•glow")).foregroundStyle(Neon.halo(color, 0.28)).lineStyle(.init(lineWidth: 4.5, lineCap: .round, lineJoin: .round)).interpolationMethod(smooth ? .catmullRom : .linear).accessibilityHidden(true)
    LineMark(x: x, y: y, series: .value("s", series)).foregroundStyle(color).lineStyle(.init(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).interpolationMethod(smooth ? .catmullRom : .linear)
}

/// 發光點：大暈 + 小實點
@ChartContentBuilder
func glowPoint<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, color: Color, size: CGFloat = 40) -> some ChartContent {
    PointMark(x: x, y: y).foregroundStyle(Neon.halo(color, 0.18)).symbolSize(size * 4).accessibilityHidden(true)
    PointMark(x: x, y: y).foregroundStyle(Neon.halo(color, 0.45)).symbolSize(size * 1.8).accessibilityHidden(true)
    PointMark(x: x, y: y).foregroundStyle(color).symbolSize(size)
}

/// 所有圖共用的底：plot 背景、淡格線、隱藏 X 軸
struct NeonPlot: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing) { _ in
                AxisGridLine().foregroundStyle(Neon.grid)
                AxisValueLabel().font(Neon.axisFont).foregroundStyle(Neon.axis)
            } }
            .chartPlotStyle { $0.background(Neon.plotBG).clipShape(RoundedRectangle(cornerRadius: Neon.plotRadius, style: .continuous)) }
    }
}

/// 霓虹發光只在深色外觀出現：淺色底上的彩色陰影只會讓字糊掉。
/// 「增加對比」或「降低亮部效果」（macOS 26.4+）開著也關掉：發光會讓字邊變糊、就是使用者想減少的亮部效果
struct NeonGlow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.self) private var env
    let color: Color
    let radius: CGFloat
    private var reduceHighlight: Bool {
        if #available(macOS 26.4, *) { return env.accessibilityReduceHighlightingEffects }
        return false
    }
    func body(content: Content) -> some View {
        let on = scheme == .dark && contrast != .increased && !A11y.increaseContrast() && !reduceHighlight
        return content.shadow(color: on ? color : .clear, radius: radius)
    }
}

/// 面板區段：沒有底色（玻璃上不再疊實心卡片），上下留白；區段之間由 PanelView 放分隔線
struct PanelSection: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.vertical, Neon.sectionPadding).frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func neonPlot() -> some View { modifier(NeonPlot()) }
    func neonGlow(_ color: Color, radius: CGFloat) -> some View { modifier(NeonGlow(color: color, radius: radius)) }
    func panelSection() -> some View { modifier(PanelSection()) }
}

// MARK: - 畫面

struct PanelView: View {
    var monitor: Monitor
    static let contentWidth: CGFloat = 320
    static let edgePadding: CGFloat = 16      // 視窗邊距（4pt 節奏；原本 14）

    var body: some View {
        // 內容量出多高，視窗就多高。放得下就不包 ScrollView：
        // 包著的話，視窗從矮長到剛好時 NSScrollView 會停在捲過的位置（標題列被推出去、底下空一截）；只有螢幕真的放不下才捲
        ViewThatFits(in: .vertical) {
            measured.frame(maxHeight: .infinity, alignment: .top)
            ScrollView(.vertical, showsIndicators: false) { measured }
        }
        .frame(width: AppDelegate.panelWidth)
        .onExitCommand { monitor.onHide?() }   // Esc 隱藏面板（面板拿到 key 時）
        .onAppear { monitor.tick() }
    }

    private var measured: some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { monitor.contentHeight = g.size.height }
                .onChange(of: g.size.height) { _, h in monitor.contentHeight = h }
        })
    }

    /// 面板只做監控：狀態 → 溫度 → 熱度格 → 風扇 → 頻率 → 今日 → 模式切換。設定全在設定視窗（⌘,）。
    /// 沒有卡片：區段之間一條系統分隔線，區段上下各 10pt —— 1080p 螢幕上不捲動就看得完
    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = monitor.snapshot {
                header(s).padding(.bottom, Neon.sectionPadding)
                healthBanner.padding(.bottom, Neon.sectionPadding)
                Divider()
                tempCard(s).panelSection()
                sensorGrid.panelSection().padding(.top, -4)
                Divider()
                fanCard(s).panelSection()
                if s.pcoreMHz != nil {
                    Divider()
                    freqCard(s).panelSection()
                }
                timeAxis.padding(.bottom, Neon.sectionPadding)
                Divider()
                statsRow(s).panelSection()
                Divider()
                todayCard.panelSection()
                Divider()
                modeRow(s).panelSection()
                Divider()
                footer.padding(.top, Neon.sectionPadding)
            } else {
                Label(L("讀取SMC中⋯"), systemImage: "thermometer.medium").foregroundStyle(.secondary).padding()
            }
        }
        .padding(Self.edgePadding)
        .frame(width: Self.contentWidth + 2 * Self.edgePadding)
    }

    /// 標題列：名稱 + 狀態 chip，下面一行「結論」——現在能不能全力開工
    func header(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: "cool42").font(.headline)
                Spacer()
                if let b = s.boostUntil, b > Date() {
                    chipLabel(L("預熱%ld秒", Int(b.timeIntervalSinceNow)), Neon.cyan, symbol: "wind", onGlass: true)
                }
                // guard 沒跑時由頂部提示與狀態列講，chip 不再重複
                if s.guardRunning {
                    chipLabel(L("guard執行中"), Color.secondary, symbol: "checkmark.shield", onGlass: true)
                }
                Button { monitor.onHide?() } label: {
                    Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())   // macOS 可點範圍至少 20pt
                }
                .buttonStyle(.plain)
                .help(L("隱藏面板（按一下選單列圖示可再打開）"))
                .accessibilityLabel(L("隱藏面板"))
            }
            .padding(.bottom, 2)
            statusLine(s)
            if let top = s.topProcesses, !top.isEmpty { busyLine(top) }
        }
    }

    /// 現在誰在吃 CPU：前兩名，一行
    func busyLine(_ top: [TopProcess]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(top.prefix(2).enumerated()), id: \.offset) { i, p in
                if i > 0 { Text(verbatim: "·").foregroundStyle(.quaternary) }
                Text(verbatim: String(format: "%.0f%%", p.cpuPercent)).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(.primary)
                Text(verbatim: p.command).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let d = p.cwd { Text(verbatim: d).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
    }

    /// onGlass：chip 在卡片外（直接壓在玻璃上）→ 字用 .primary（vibrant），狀態色只給圖示與淡底；卡片內的 chip 才用彩色字
    func chipLabel(_ text: String, _ color: Color, symbol: String? = nil, onGlass: Bool = false) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(color) }
            Text(verbatim: text).monospacedDigit().foregroundStyle(onGlass ? Color.primary : color)
        }
        .lineLimit(1).fixedSize()   // chip 一律單行，不被擠成直排
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(onGlass ? 0.18 : 0.14), in: Capsule())
    }

    /// 一句話結論：全速 / 降頻中 / 溫度危險 / 沒有頻率資料
    func statusLine(_ s: Snapshot) -> some View {
        let (icon, text, color): (String, String, Color) = {
            if !s.guardRunning {
                // 風扇停在手動時不能說「由macOS控制」
                if let f = s.fans.first, f.manual { return ("exclamationmark.triangle.fill", L("guard沒在執行，風扇停在手動%.0f rpm", f.target), Neon.red) }
                return ("exclamationmark.triangle.fill", L("guard沒在執行，風扇由macOS控制"), Neon.amber)
            }
            if s.level == .critical { return ("flame.fill", L("溫度%.0f°C已達critical，hook會擋下工作", s.controlTemp), Neon.red) }
            // 原因用 throttleReason：時脈降頻時 pressure 仍是 Nominal，不能寫成「降頻中（正常）」
            if s.throttling { return ("tortoise.fill", L("降頻中（%@）· hook會讓工作等", s.throttleReason), Neon.red) }
            if s.gpuThrottling { return ("tortoise.fill", L("GPU熱降頻中（CLTM %.0f%%）· hook會讓工作等", s.gpuThrottlePercent ?? 0), Neon.red) }
            if s.pcoreMHz == nil { return ("questionmark.circle", L("沒有頻率資料，改用溫度判斷（%@）", s.level.label), Neon.amber) }
            if (s.pcoreMHz ?? 0) < 100 { return ("moon.zzz.fill", L("閒置 · 未降頻"), Neon.green) }
            return ("bolt.fill", L("全速運作%.2f GHz · 未降頻", (s.pcoreMHz ?? 0) / 1000), Neon.green)
        }()
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.callout).foregroundStyle(color).neonGlow(color.opacity(0.8), radius: 4)
            // 字在卡片外、直接壓在玻璃上 → .primary（vibrant）；狀態色只上在前面的 SF Symbol（形狀也不同，不只靠顏色）
            Text(verbatim: text).font(.callout.weight(.semibold)).foregroundStyle(.primary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            // 今日降頻秒數不在這裡重複：下面統計列的「降頻」格已經是紅字
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 三張卡：標題 + 目前值 + 5 分鐘曲線

    var window: ClosedRange<Date> { Date().addingTimeInterval(-History.keep)...Date() }

    func card<Chart: View>(title: String, @ViewBuilder value: () -> some View, @ViewBuilder chart: () -> Chart) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .lastTextBaseline) {
                Text(verbatim: title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(1).layoutPriority(1)   // 標題先拿到完整寬度，數值那邊自己挑放得下的版本
                Spacer(minLength: 8)
                value()
            }
            chart()
        }
    }

    func bigValue(_ v: String, _ color: Color, unit: String = "") -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(v).font(Neon.valueFont).foregroundStyle(color).neonGlow(color.opacity(0.5), radius: 5)
            if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    func tempCard(_ s: Snapshot) -> some View {
        card(title: L("溫度")) {
            // 放不下就依序拿掉次要資訊（SSD → GPU 使用率），不讓「GPU」「降頻」被擠成直排（英文標題較長、GPU 降頻時多一個 chip）
            ViewThatFits(in: .horizontal) {
                tempValues(s, showActive: true, showSSD: true)
                tempValues(s, showActive: true, showSSD: false)
                tempValues(s, showActive: false, showSSD: false)
            }
        } chart: {
            Chart {
                RuleMark(y: .value("hot", monitor.config.hotTemp)).foregroundStyle(Neon.amber.opacity(0.35)).lineStyle(.init(dash: [3]))
                RuleMark(y: .value("crit", monitor.config.criticalTemp)).foregroundStyle(Neon.red.opacity(0.35)).lineStyle(.init(dash: [3]))
                ForEach(monitor.history, id: \.time) { p in
                    AreaMark(x: .value("t", p.time), yStart: .value("b", 30), yEnd: .value("cpu", p.cpu), series: .value("s", "cpu•a"))
                        .foregroundStyle(Neon.fade(Neon.cyan, top: 0.35)).interpolationMethod(.catmullRom)
                }
                ForEach(monitor.history, id: \.time) { p in
                    glowLine(x: .value("t", p.time), y: .value("gpu", p.gpu), series: "gpu", color: Neon.green)
                }
                ForEach(monitor.history, id: \.time) { p in
                    glowLine(x: .value("t", p.time), y: .value("cpu", p.cpu), series: "cpu", color: Neon.cyan)
                }
                if let last = monitor.history.last {
                    glowPoint(x: .value("t", last.time), y: .value("cpu", last.cpu), color: Neon.cyan, size: 14)
                    glowPoint(x: .value("t", last.time), y: .value("gpu", last.gpu), color: Neon.green, size: 14)
                }
            }
            .chartXScale(domain: window)
            .chartYScale(domain: 30...110)
            .neonPlot()
            .frame(height: 84)
            .accessibilityLabel(L("溫度走勢，最近5分鐘"))
            .accessibilityValue(L("CPU %.0f度，GPU %.0f度", s.cpuMax, s.gpuMax))
        }
    }

    func tempValues(_ s: Snapshot, showActive: Bool, showSSD: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) { legend("CPU", Neon.cyan); bigValue(String(format: "%.0f°", s.cpuMax), Neon.cyan) }
            HStack(spacing: 4) {
                legend("GPU", Neon.green); bigValue(String(format: "%.0f°", s.gpuMax), Neon.green)
                if showActive, let a = s.gpuActive { Text(verbatim: String(format: "%.0f%%", a)).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
                if s.gpuThrottling { chipLabel(L("降頻"), Neon.red) }
            }
            if showSSD, let ssd = s.ssd { Text(verbatim: String(format: "SSD %.0f°", ssd)).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
        }
        .lineLimit(1)
    }

    /// 各感測器熱度格：P-core / E-core / GPU 三組，一格一個感測器，顏色隨溫度；滑過看 key 與度數
    /// 熱度格現在要不要展開：使用者的偏好；紅燈時先收起來（不改偏好，紅燈消失就恢復）
    var sensorsShown: Bool { monitor.showSensors && (badHealth.isEmpty || monitor.sensorsDespiteHealth) }

    var sensorGrid: some View {
        DisclosureGroup(isExpanded: Binding(get: { sensorsShown }, set: { v in
            if badHealth.isEmpty { monitor.showSensors = v; monitor.sensorsDespiteHealth = false }
            else { monitor.sensorsDespiteHealth = v; if v { monitor.showSensors = true } }
        })) {
            VStack(alignment: .leading, spacing: 8) {
                sensorGroup("P-core", prefix: "Tp")
                sensorGroup("E-core", prefix: "Te")
                sensorGroup("GPU", prefix: "Tg")
                HStack(spacing: 8) {
                    ForEach([40, 60, 80, 95], id: \.self) { t in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tempColor(Double(t))).frame(width: 8, height: 8)
                            Text(verbatim: "\(t)°").font(Neon.axisFont).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(L("風扇看最熱的那一格")).font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill").font(.caption).foregroundStyle(.secondary)
                Text(L("熱度格")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if sensorsShown {
                    Text(L("%ld個感測器", monitor.sensorTemps.count)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    func sensorGroup(_ name: String, prefix: String) -> some View {
        let items = monitor.sensorTemps.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
        let hi = items.map(\.value).max()
        let avg = items.isEmpty ? nil : items.map(\.value).reduce(0, +) / Double(items.count)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.primary).frame(width: 44, alignment: .leading)
                if let hi, let avg {
                    // 小字不用霓虹色（淺色玻璃壓在深色桌布上只有 3.8–4.3:1）：字用 .primary，狀態色給前面的點
                    HStack(spacing: 3) {
                        Circle().fill(tempText(hi)).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(L("最熱%.0f°", hi)).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(.primary)
                    }
                    Text(L("平均%.0f°", avg)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "—").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: "×\(items.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 14, maximum: 14), spacing: 3)], alignment: .leading, spacing: 3) {
                ForEach(items, id: \.key) { k, t in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tempColor(t))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))   // 淺色底上黃 / 綠格才分得出邊
                        .frame(width: 14, height: 14)
                        .neonGlow(t >= monitor.config.hotTemp ? tempColor(t).opacity(0.7) : .clear, radius: 3)
                        .help(String(format: "%@  %.1f°C", k, t))
                        .accessibilityLabel(L("%@ %@，%.0f度", name, k, t))
                }
            }
        }
    }

    /// 溫度當文字色用：跟統計格、曲線門檻線共用 config 的 warm / hot / critical 門檻（Level.neon：hot 琥珀、critical 紅），
    /// 不再另訂一套（原本 90°C 就紅字，92° 紅、97° 琥珀互相矛盾）。格子本身仍用 tempColor 連續漸層
    func tempText(_ t: Double) -> Color { monitor.config.level(for: t).neon }

    /// 溫度 → 顏色：40 藍青、60 綠、80 琥珀、95+ 紅，中間線性混色（格子本身兩種外觀共用同一組，色票才對得上）
    func tempColor(_ t: Double) -> Color {
        let stops: [(Double, (Double, Double, Double))] = [
            (40, (0.16, 0.55, 0.96)), (60, (0.36, 0.95, 0.55)), (80, (1.00, 0.72, 0.30)), (95, (1.00, 0.36, 0.42)),
        ]
        if t <= stops[0].0 { let c = stops[0].1; return Color(red: c.0, green: c.1, blue: c.2) }
        if t >= stops.last!.0 { let c = stops.last!.1; return Color(red: c.0, green: c.1, blue: c.2) }
        for i in 1..<stops.count where t <= stops[i].0 {
            let (a, b) = (stops[i - 1], stops[i])
            let f = (t - a.0) / (b.0 - a.0)
            return Color(red: a.1.0 + (b.1.0 - a.1.0) * f, green: a.1.1 + (b.1.1 - a.1.1) * f, blue: a.1.2 + (b.1.2 - a.1.2) * f)
        }
        return Neon.cyan
    }

    func fanCard(_ s: Snapshot) -> some View {
        let f = s.fans.first
        return card(title: L("風扇")) {
            HStack(spacing: 8) {
                if let f, f.manual { Text(L("目標%.0f", f.target)).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
                else { Text(L("macOS自動")).font(.caption2).foregroundStyle(.secondary) }
                bigValue(String(format: "%.0f", f?.rpm ?? 0), Neon.purple, unit: "rpm")
            }
        } chart: {
            Chart {
                ForEach(monitor.history, id: \.time) { p in
                    AreaMark(x: .value("t", p.time), y: .value("rpm", p.rpm), series: .value("s", "rpm•a"))
                        .foregroundStyle(Neon.fade(Neon.purple, top: 0.5)).interpolationMethod(.catmullRom)
                }
                ForEach(monitor.history.filter { $0.target != nil }, id: \.time) { p in
                    LineMark(x: .value("t", p.time), y: .value("target", p.target ?? 0), series: .value("s", "target"))
                        .foregroundStyle(Color.secondary).lineStyle(.init(lineWidth: 1, dash: [2, 3]))
                }
                ForEach(monitor.history, id: \.time) { p in
                    glowLine(x: .value("t", p.time), y: .value("rpm", p.rpm), series: "rpm", color: Neon.purple)
                }
                if let last = monitor.history.last {
                    glowPoint(x: .value("t", last.time), y: .value("rpm", last.rpm), color: Neon.purple, size: 14)
                }
            }
            .chartXScale(domain: window)
            .chartYScale(domain: 0...((f?.max ?? 5000) * 1.06))   // 滿速時目前點不被裁半顆
            .chartYAxis { AxisMarks(position: .trailing, values: [1000, 2000, 3000, 4000]) { v in
                AxisGridLine().foregroundStyle(Neon.grid)
                AxisValueLabel { if let r = v.as(Int.self) { Text(verbatim: "\(r / 1000)k").font(Neon.axisFont).foregroundStyle(Neon.axis) } }
            } }
            .chartXAxis(.hidden)
            .chartPlotStyle { $0.background(Neon.plotBG).clipShape(RoundedRectangle(cornerRadius: Neon.plotRadius, style: .continuous)) }
            .frame(height: 56)
            .accessibilityLabel(L("風扇轉速走勢，最近5分鐘"))
            .accessibilityValue(String(format: "%.0f RPM", f?.rpm ?? 0))
        }
    }

    func freqCard(_ s: Snapshot) -> some View {
        let p = s.pcoreMHz ?? 0
        let idle = p < 100
        return card(title: L("P-core頻率")) {
            HStack(spacing: 8) {
                if s.throttling { chipLabel(L("降頻（%@）", s.throttleReason), Neon.red) }
                else if !idle, let e = s.ecoreMHz { Text(String(format: "E %.1f", e / 1000)).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
                if idle {
                    // 閒置時不用大字（視覺層級不該比其他卡的數值重），改小字＋最近一次的非閒置值
                    Text(L("閒置")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if let last = monitor.history.last(where: { ($0.pMHz ?? 0) >= 100 })?.pMHz {
                        Text(L("上次%.2f GHz", last / 1000)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                else { bigValue(String(format: "%.2f", p / 1000), s.throttling ? Neon.red : Neon.green, unit: "GHz") }
            }
        } chart: {
            Chart {
                ForEach(monitor.history.filter { ($0.pMHz ?? 0) >= 100 }, id: \.time) { p in   // 閒置（0）不畫，留缺口
                    AreaMark(x: .value("t", p.time), yStart: .value("b", 0.9), yEnd: .value("GHz", (p.pMHz ?? 0) / 1000), series: .value("s", "p•a"))
                        .foregroundStyle(Neon.fade(Neon.green, top: 0.3)).interpolationMethod(.catmullRom)
                }
                ForEach(monitor.history.filter { ($0.pMHz ?? 0) >= 100 }, id: \.time) { p in
                    glowLine(x: .value("t", p.time), y: .value("GHz", (p.pMHz ?? 0) / 1000), series: "p", color: Neon.green)
                }
                if let last = monitor.history.last, (last.pMHz ?? 0) >= 100 {
                    glowPoint(x: .value("t", last.time), y: .value("GHz", (last.pMHz ?? 0) / 1000), color: Neon.green, size: 14)
                }
            }
            .chartXScale(domain: window)
            .chartYScale(domain: 0.9...4.5)
            .neonPlot()
            .frame(height: 56)
            .accessibilityLabel(L("P-core頻率走勢，最近5分鐘"))
            .accessibilityValue(idle ? L("閒置") : String(format: "%.2f GHz", p / 1000))
        }
    }

    /// 三張卡共用的時間軸
    var timeAxis: some View {
        HStack {
            Text(L("5分鐘前"))
            Spacer()
            Text(L("現在"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)   // 軸文字對 VoiceOver 隱藏，圖表本身有描述
        .padding(.horizontal, 8)
        .padding(.top, -4)
    }

    func legend(_ name: String, _ color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 3) {
            if dashed {
                Rectangle().fill(color).frame(width: 10, height: 1).overlay(Rectangle().stroke(style: .init(lineWidth: 1, dash: [2, 2])).foregroundStyle(color))
            } else {
                Capsule().fill(color).frame(width: 10, height: 2).neonGlow(color.opacity(0.8), radius: 2)
            }
            Text(verbatim: name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize()
    }

    @ViewBuilder
    func statsRow(_ s: Snapshot) -> some View {
        if let st = s.stats {
            // 六格擠一列時 caption2 會被縮到 8pt（低於 macOS 最小字級 10pt）→ 改 3×2，不再縮字
            Grid(horizontalSpacing: 4, verticalSpacing: 6) {
                GridRow {
                    stat(L("今日最高"), String(format: "%.0f°", st.maxTemp), color: monitor.config.level(for: st.maxTemp).neon)
                    stat(L("降頻"), Format.hms(st.throttleSeconds), color: st.throttleSeconds > 0 ? Neon.red : .secondary)
                    stat(L("AI等待／擋下"), "\(st.hookWaits)/\(st.hookDenies)", color: .secondary)
                }
                GridRow {
                    stat(Level.hot.label, Format.hms(st.hotSeconds), color: st.hotSeconds > 0 ? Neon.amber : .secondary)
                    stat(Level.critical.label, Format.hms(st.criticalSeconds), color: st.criticalSeconds > 0 ? Neon.red : .secondary)
                    stat(L("預熱"), "\(st.boosts)", color: .secondary)
                }
            }
        }
    }

    func stat(_ name: String, _ v: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: v).font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit()).foregroundStyle(color).lineLimit(1)
            Text(verbatim: name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: 控制區

    /// draft 曲線對應到哪個預設（沒有就是自訂）
    var currentPresetName: String? {
        let d = monitor.draft.curve.map { [$0.temp, $0.rpm] }
        return Monitor.presets.first { $0.1.map { [$0.temp, $0.rpm] } == d }?.0
    }

    /// 三組預設曲線：標準 segmented（鍵盤、VoiceOver、增加對比都由系統處理）。
    /// 曲線被微調過、對不上任何預設時多一段「自訂」並選中，下面的展開列寫「編輯自訂曲線的點」
    var presetChips: some View {
        Picker(L("預設曲線"), selection: Binding<String?>(
            get: { currentPresetName },
            set: { name in if let pts = Monitor.presets.first(where: { $0.0 == name })?.1 { monitor.draft.curve = pts } })) {
            ForEach(Monitor.presets, id: \.0) { name, _ in Text(verbatim: name).tag(Optional(name)) }
            // 曲線被微調過：多一段「自訂」並選中它（selection 才有對應的 tag）；點它不會改曲線
            if currentPresetName == nil { Text(L("自訂")).tag(String?.none) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    /// 曲線預覽：X 溫度、Y 轉速；畫 draft 曲線、hot/critical 門檻、目前溫度與風扇位置
    func curvePreview(_ s: Snapshot, fixed: Double?, fmin: Double, fmax: Double) -> some View {
        let pts = monitor.draft.curve.sorted { $0.temp < $1.temp }
        let tNow = min(max(s.controlTemp, 40), 108)
        let rpmNow = s.fans.first?.rpm ?? fmin
        // 曲線兩端延伸到圖的邊界
        let ext: [(Double, Double)] = pts.isEmpty ? [] : [(40, pts.first!.rpm)] + pts.map { ($0.temp, $0.rpm) } + [(108, pts.last!.rpm)]
        return Chart {
            RuleMark(x: .value("hot", monitor.config.hotTemp)).foregroundStyle(Neon.amber.opacity(0.3)).lineStyle(.init(dash: [3]))
            RuleMark(x: .value("crit", monitor.config.criticalTemp)).foregroundStyle(Neon.red.opacity(0.3)).lineStyle(.init(dash: [3]))
            if let fixed {
                AreaMark(x: .value("t", 40), yStart: .value("a", fmin), yEnd: .value("rpm", fixed), series: .value("s", "fa")).foregroundStyle(Neon.fade(Neon.cyan, top: 0.3))
                AreaMark(x: .value("t", 108), yStart: .value("a", fmin), yEnd: .value("rpm", fixed), series: .value("s", "fa")).foregroundStyle(Neon.fade(Neon.cyan, top: 0.3))
                glowLine(x: .value("t", 40.0), y: .value("rpm", fixed), series: "f", color: Neon.cyan, smooth: false)
                glowLine(x: .value("t", 108.0), y: .value("rpm", fixed), series: "f", color: Neon.cyan, smooth: false)
            } else {
                ForEach(Array(ext.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("t", p.0), yStart: .value("a", fmin), yEnd: .value("rpm", p.1), series: .value("s", "a")).foregroundStyle(Neon.fade(Neon.cyan, top: 0.35))
                }
                ForEach(Array(ext.enumerated()), id: \.offset) { _, p in
                    glowLine(x: .value("t", p.0), y: .value("rpm", p.1), series: "c", color: Neon.cyan, smooth: false)
                }
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    PointMark(x: .value("t", p.temp), y: .value("rpm", p.rpm)).foregroundStyle(Neon.cyan).symbolSize(14)
                }
            }
            // 目前位置
            RuleMark(x: .value("now", tNow)).foregroundStyle(s.level.neon.opacity(0.45)).lineStyle(.init(lineWidth: 1))
            glowPoint(x: .value("now", tNow), y: .value("rpm", rpmNow), color: s.level.neon, size: 28)
            PointMark(x: .value("now", tNow), y: .value("rpm", rpmNow)).opacity(0)
                // 點貼著圖頂（風扇快滿速）時字往下放，不然會被 plot 邊界切掉
                .annotation(position: rpmNow > fmin + (fmax - fmin) * 0.8 ? (tNow > 85 ? .bottomLeading : .bottomTrailing) : (tNow > 85 ? .leading : .trailing),
                            alignment: .center, spacing: 6) {
                    Text(verbatim: String(format: "%.0f° · %.0f rpm", s.controlTemp, rpmNow)).font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(s.level.neon)
                }
        }
        .chartXScale(domain: 40...108)
        // 上下各留一點：風扇到 fmin / fmax 時目前點才不會被 plot 的圓角裁掉半顆
        .chartYScale(domain: (fmin - (fmax - fmin) * 0.05)...(fmax + (fmax - fmin) * 0.06))
        .chartXAxis { AxisMarks(values: [50, 60, 70, 80, 90, 100]) { v in
            AxisGridLine().foregroundStyle(Neon.grid)
            // anchor .top：字的中心對齊刻度（預設是字的左緣對刻度，看起來整排往右偏約 2.5°）
            AxisValueLabel(anchor: .top) { if let t = v.as(Int.self) { Text(verbatim: "\(t)°").font(Neon.axisFont).foregroundStyle(Neon.axis) } }
        } }
        .chartYAxis { AxisMarks(position: .trailing, values: [1000, 2000, 3000, 4000]) { v in
            AxisGridLine().foregroundStyle(Neon.grid)
            AxisValueLabel { if let r = v.as(Int.self) { Text(verbatim: "\(r / 1000)k").font(Neon.axisFont).foregroundStyle(Neon.axis) } }
        } }
        .chartPlotStyle { $0.background(Neon.plotBG).clipShape(RoundedRectangle(cornerRadius: Neon.plotRadius, style: .continuous)) }
        .frame(height: 100)
        .accessibilityLabel(fixed == nil ? L("風扇曲線預覽") : L("固定轉速預覽"))
        .accessibilityValue(L("目前%.0f度，%.0f RPM", s.controlTemp, rpmNow))
    }

    /// 一鍵模式切換：直接寫設定檔（不走「套用」），guard 幾秒內熱重載。曲線形狀、固定轉速在設定視窗調
    func modeRow(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("風扇模式")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Picker(L("風扇模式"), selection: Binding(get: { monitor.config.mode }, set: { monitor.setModeNow($0) })) {
                    Text(L("曲線")).tag("curve")
                    Text(L("固定")).tag("fixed")
                    Text(L("自動")).tag("auto")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .disabled(!s.guardRunning)   // guard 沒跑時改設定檔沒人讀
                .help(s.guardRunning ? L("曲線：cool42照曲線提早加速；固定：固定轉速；自動：交還macOS原廠控制") : L("guard沒在執行，切換不會生效"))
            }
            // 模式的一句說明＋上一次切換／寫入的結果（錯誤要看得到）
            HStack(spacing: 4) {
                if let m = monitor.saveMessage, monitor.saveFailed {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Neon.red)
                    Text(verbatim: m).foregroundStyle(.primary).lineLimit(2)
                } else {
                    Text(verbatim: modeDetail(s)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
        }
    }

    func modeDetail(_ s: Snapshot) -> String {
        switch monitor.config.mode {
        case "fixed": return L("固定%ld rpm · 在設定裡調整", Int(monitor.config.fixedRPM))
        case "auto": return L("macOS原廠控制 · cool42只監看")
        default:
            let name = Monitor.presets.first { $0.1.map { [$0.temp, $0.rpm] } == monitor.config.curve.map { [$0.temp, $0.rpm] } }?.0 ?? L("自訂")
            return L("「%@」曲線 · 在設定裡調整", name)
        }
    }

    /// 設定視窗裡有還沒套用的變更：頁尾上方一行提示，按了打開那一頁（面板上本來看不到設定視窗的狀態）
    @ViewBuilder
    var pendingSettingsLine: some View {
        if monitor.dirty {
            Button {
                monitor.onShowSettings?(monitor.fanDirty ? .fan : monitor.profileDirty ? .profiles : .sounds)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Neon.amber)
                    Text(L("設定有未套用的變更")).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Text(L("打開設定⋯")).foregroundStyle(.secondary)
                }
                .font(.caption2)
                .frame(minHeight: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("在設定視窗按「套用」才會寫入設定檔"))
            .padding(.bottom, 6)
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            pendingSettingsLine
            footerButtons
        }
    }

    var footerButtons: some View {
        // 文字按鈕前加 SF Symbol：一眼看得出是能按的動作，不是說明文字
        HStack(spacing: 14) {
            Button { monitor.onShowSettings?(nil) } label: { Label(L("設定⋯"), systemImage: "gearshape") }
                .keyboardShortcut(",", modifiers: .command)
                .help(L("打開設定視窗（⌘,）"))
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/cool42.log")) } label: { Label(L("記錄檔"), systemImage: "doc.text") }
                .help(L("打開%@", "/var/log/cool42.log"))
            Spacer(minLength: 4)
            Text(verbatim: "cool42 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).layoutPriority(-1)
        }
        .labelStyle(FooterLabelStyle())
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// 頁尾：小圖示 + 字，間距比系統預設 Label 緊（面板寬只有 320）
struct FooterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.imageScale(.small); configuration.title }
            .lineLimit(1).fixedSize()   // 按鈕字一律單行（英文「Config File」放不下時先讓版本號讓位，不折成兩行）
            .frame(minHeight: 20).contentShape(Rectangle())   // 文字按鈕可點範圍至少 20pt 高
    }
}
