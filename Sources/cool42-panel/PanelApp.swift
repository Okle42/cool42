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
    /// 視窗高度跟著內容走（展開感測器就長高、收起就縮回），直到使用者自己拖過高度為止
    private var autoHeight = UserDefaults.standard.object(forKey: "panel.autoHeight") as? Bool ?? true
    private var programmaticResize = false

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 不顯示 Dock 圖示
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
        monitor.onContentHeight = { [weak self] h in self?.fitHeight(to: h) }
        buildPanel()
        if UserDefaults.standard.object(forKey: "panel.open") as? Bool ?? true { showPanel() }
    }

    /// 選單列：template SF Symbol（系統依選單列深淺上色，狀態靠「換形狀」不靠顏色）＋等寬溫度字。
    /// 原本是彩色 emoji 圓點，HIG 要求選單列圖示用 SF Symbol 或 template image
    private func updateStatusItem() {
        guard let b = statusItem?.button else { return }
        let st = monitor.menuState
        let img = NSImage(systemSymbolName: st.symbol, accessibilityDescription: nil)
        img?.isTemplate = true
        b.image = img
        b.title = st.title
        // VoiceOver 念得到目前狀態（不只「cool42 溫度」）
        b.setAccessibilityLabel(st.accessibility)
    }

    private func buildPanel() {
        // 外觀跟系統走（淺 / 深色都有對應色值），不鎖死 darkAqua
        let host = NSHostingView(rootView: PanelView(monitor: monitor))
        self.host = host
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 760),
            styleMask: [.titled, .fullSizeContentView, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.title = "cool42"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.isMovableByWindowBackground = true      // 抓卡片任何空白處都能拖
        p.isOpaque = false
        p.hasShadow = true
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true           // Stepper / Slider 點了才拿 key，平常不搶焦點
        p.hidesOnDeactivate = false               // 切到別的 app 也留著
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.delegate = self
        // 寬鎖死，高度可拖（內容超過就捲）
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) - 20
        p.contentMinSize = NSSize(width: Self.panelWidth, height: 360)
        p.contentMaxSize = NSSize(width: Self.panelWidth, height: maxH)
        panel = p
        applyBackground()
        // 使用者切「減少透明度」「增加對比」時即時換底
        NotificationCenter.default.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.applyBackground() }
        p.setFrameAutosaveName("cool42.panel")
        if !p.setFrameUsingName("cool42.panel") {
            // 第一次：貼螢幕右上角（選單列圖示這時還沒定位，不能拿它的座標）
            let h = min(760, maxH)
            let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = vf.maxX - Self.panelWidth - 12
            let y = vf.maxY - h - 8
            p.setFrame(NSRect(x: x, y: y, width: Self.panelWidth, height: h), display: false)
        }
        monitor.panelWindow = p
        fitHeight(to: monitor.contentHeight)   // 內容高度可能在 panel 指派前就量好了
    }

    /// 視窗底材質（功能層）：
    ///   macOS 26+  NSGlassEffectView（Liquid Glass，regular）—— 系統在「減少透明度」會自己變霧、「增加對比」會自己加邊
    ///   macOS 14–25 NSVisualEffectView .popover（跟選單列 popover 同一種材質，浮動面板要 state = .active）
    ///   「減少透明度」開著：兩種都不用，改實色 Neon.panelBG（不透明版）—— 面板字很密，實色底最好讀
    /// 卡片是內容層，仍用 Neon.cardBG 實色，不上玻璃（不做玻璃疊玻璃）
    private func applyBackground() {
        guard let p = panel, let host else { return }
        host.removeFromSuperview()
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            p.backgroundColor = Neon.panelSolidColor
            p.contentView = host
        } else if #available(macOS 26.0, *) {
            p.backgroundColor = .clear
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = Neon.windowRadius
            p.contentView = glass
            host.frame = glass.bounds
            glass.contentView = host   // 內容一定放 contentView，不要把 glass 當兄弟 view 墊在後面
        } else {
            p.backgroundColor = .clear
            let fx = NSVisualEffectView()
            fx.material = .popover
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = Neon.windowRadius
            fx.layer?.cornerCurve = .continuous
            fx.layer?.masksToBounds = true
            host.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            ])
            p.contentView = fx
        }
        p.invalidateShadow()
    }

    /// 內容高度變了：autoHeight 時把視窗調成剛好（上緣不動、不超過螢幕）
    private func fitHeight(to contentH: CGFloat) {
        guard autoHeight, let p = panel, contentH > 0 else { return }
        let maxH = ((p.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 20
        let h = min(max(contentH, 360), maxH)
        guard abs(p.frame.height - h) > 1 else { return }
        var f = p.frame
        f.origin.y += f.height - h   // 保持頂邊
        f.size.height = h
        programmaticResize = true
        // 「減少動態效果」開著就直接跳到新高度，不做縮放動畫
        p.setFrame(f, display: true, animate: p.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        programmaticResize = false
    }

    /// 使用者自己拖了高度 → 之後不再自動跟內容；右鍵選單可以恢復
    func windowDidResize(_ notification: Notification) {
        // setFrameAutosaveName 在 buildPanel 裡就會發這個通知，那時 panel 還沒指派
        guard let p = panel, !programmaticResize, p.isVisible else { return }
        if autoHeight { autoHeight = false; UserDefaults.standard.set(false, forKey: "panel.autoHeight") }
    }

    @objc private func resumeAutoHeight() {
        autoHeight = true
        UserDefaults.standard.set(true, forKey: "panel.autoHeight")
        fitHeight(to: monitor.contentHeight)
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            // 選單項目不放圖示（macOS 27 預設隱藏選單圖示）、不顯示快捷鍵；用不到的項目隱藏而不是變暗
            menu.addItem(withTitle: panel.isVisible ? L("隱藏面板") : L("顯示面板"), action: #selector(togglePanel), keyEquivalent: "")
            if !autoHeight { menu.addItem(withTitle: L("恢復自動調整高度"), action: #selector(resumeAutoHeight), keyEquivalent: "") }
            menu.addItem(.separator())
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

    @objc func togglePanel() { panel.isVisible ? hidePanel() : showPanel() }
    func showPanel() {
        panel.orderFront(nil)
        fitHeight(to: monitor.contentHeight)
        UserDefaults.standard.set(true, forKey: "panel.open")
        monitor.tick()
    }
    func hidePanel() {
        panel.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "panel.open")
        monitor.tick()
    }
    @objc func relaunch() { monitor.relaunch() }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - 資料

@Observable
final class Monitor {
    var snapshot: Snapshot?
    var history: [HistoryPoint] = []
    var config = Config.load(path: nil)
    var draft = Config.load(path: nil)   // 面板上編輯中的設定
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

    // 各感測器明細：只有面板展開「各感測器」時才每輪讀 73 個 key，收合不花這個成本
    var showSensors: Bool { didSet { UserDefaults.standard.set(showSensors, forKey: "sensors.show"); if showSensors { readSensors() } } }
    var sensorTemps: [String: Double] = [:]

    init() {
        hotSoundOn = UserDefaults.standard.object(forKey: "sound.hot") as? Bool ?? true
        coldSoundOn = UserDefaults.standard.object(forKey: "sound.cold") as? Bool ?? true
        showSensors = UserDefaults.standard.bool(forKey: "sensors.show")
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
        onTick?()
        let open = windowVisible
        if open != panelOpen { panelOpen = open; return }   // didSet 會再叫一次 tick
        guard panelOpen else { return }
        if showSensors { readSensors() }
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
        if !dirty { draft = fresh }
        config = fresh
    }

    var fanDirty: Bool {
        draft.mode != config.mode || draft.fixedRPM != config.fixedRPM || draft.includeGPU != config.includeGPU ||
        draft.curve.map { [$0.temp, $0.rpm] } != config.curve.map { [$0.temp, $0.rpm] }
    }
    var soundDirty: Bool { draft.overheatAbove != config.overheatAbove || draft.cooldownBelow != config.cooldownBelow }
    var dirty: Bool { fanDirty || soundDirty }

    /// 寫回設定檔，guard 會偵測 mtime 自動重載
    func apply() {
        do {
            try draft.save()
            config = Config.load(path: nil)
            draft = config
            saveMessage = L("已套用（%@）", ((config.loadedFrom ?? "") as NSString).lastPathComponent)
            saveFailed = false
        } catch {
            saveMessage = L("寫入失敗：%@", error.localizedDescription)
            saveFailed = true
        }
    }

    func revert() { draft = config; saveMessage = nil; saveFailed = false }

    /// 名稱在第一次用到時就換成目前語言；它同時是 segmented 的 tag（同一次執行內一致即可）
    static let presets: [(String, [Config.Point])] = [
        (L("安靜"), [.init(temp: 65, rpm: 1000), .init(temp: 80, rpm: 1600), .init(temp: 90, rpm: 2400), .init(temp: 95, rpm: 3400), .init(temp: 99, rpm: 4900)]),
        (L("均衡"), Config().curve),   // A/B 實測：重載 87°C / 3150 rpm，不降頻
        (L("強力"), [.init(temp: 55, rpm: 1000), .init(temp: 65, rpm: 1800), .init(temp: 75, rpm: 3000), .init(temp: 85, rpm: 4200), .init(temp: 90, rpm: 4900)]),
    ]

    /// 選單列項目：符號（依狀態換形狀）、標題（等寬溫度）、VoiceOver 名稱（含狀態）
    struct MenuState { var symbol: String; var title: String; var accessibility: String }
    var menuState: MenuState {
        guard let s = snapshot else { return MenuState(symbol: "fan", title: "", accessibility: L("cool42，讀取中")) }
        let t = Int(s.controlTemp.rounded())
        let throttled = s.throttling || s.gpuThrottling
        let symbol = throttled ? "tortoise.fill" : s.level.symbol
        let state = throttled ? L("降頻中") : s.level.label
        return MenuState(symbol: symbol, title: " \(t)°", accessibility: L("cool42，控制溫度%ld度，%@", t, state))
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
/// 每個文字色都有四版：淺 / 深 × 一般 / 增加對比。深色是原本的霓虹；淺色把同一色相壓暗，
/// 卡片白底上 ≥ 4.5:1（WCAG 公式算過：cyan 4.8、green 5.0、purple 6.1、amber 5.2、red 5.4）；增加對比版淺色 ≥ 7:1。
/// 這些對比值只在卡片底上成立，所以霓虹色字只放在卡片裡（Neon.cardBG 是近實色）；
/// 卡片外直接壓在玻璃上的字一律用 .primary / .secondary（系統 vibrant），狀態色只上在 SF Symbol
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
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let c = hc ? ((isDark ? hcDark : hcLight) ?? (isDark ? dark : light)) : (isDark ? dark : light)
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: min(1, c.3 * (hc ? highContrast : 1)))
        }
    }
    static let cyan   = Color(nsColor: dynamic("cyan",   light: (0.00, 0.47, 0.70, 1), dark: (0.16, 0.87, 0.96, 1), hcLight: (0.00, 0.36, 0.56, 1), hcDark: (0.45, 0.93, 1.00, 1)))
    static let green  = Color(nsColor: dynamic("green",  light: (0.05, 0.50, 0.24, 1), dark: (0.36, 0.95, 0.55, 1), hcLight: (0.02, 0.38, 0.17, 1), hcDark: (0.55, 1.00, 0.70, 1)))
    static let purple = Color(nsColor: dynamic("purple", light: (0.42, 0.26, 0.85, 1), dark: (0.72, 0.56, 1.00, 1), hcLight: (0.34, 0.18, 0.72, 1), hcDark: (0.82, 0.72, 1.00, 1)))
    static let amber  = Color(nsColor: dynamic("amber",  light: (0.62, 0.36, 0.00, 1), dark: (1.00, 0.72, 0.30, 1), hcLight: (0.50, 0.29, 0.00, 1), hcDark: (1.00, 0.82, 0.50, 1)))
    static let red    = Color(nsColor: dynamic("red",    light: (0.80, 0.13, 0.22, 1), dark: (1.00, 0.36, 0.42, 1), hcLight: (0.66, 0.06, 0.15, 1), hcDark: (1.00, 0.55, 0.60, 1)))
    /// 「減少透明度」時的實色視窗底（正式 app 平常用玻璃，見 AppDelegate.applyBackground）；離屏截圖也用它當底
    static let panelSolidColor = dynamic("panelSolid", light: (0.965, 0.966, 0.975, 1), dark: (0.06, 0.07, 0.11, 1))
    static let panelBG = Color(nsColor: panelSolidColor)
    /// 視窗圓角（玻璃 / 舊系統材質 / 截圖外框共用）
    static let windowRadius: CGFloat = 16
    static let plotBG  = Color(nsColor: dynamic("plotBG", light: (0, 0, 0, 0.035), dark: (0, 0, 0, 0.28)))
    /// 卡片是彩色字的「固定的底」：玻璃（macOS 26+）或 popover 材質下，桌布透過來的顏色不能決定霓虹字的對比。
    /// 深色原本是白 0.045（等於透明，4.5:1 只在實色底上成立）→ 改成接近實色的深藍灰 0.88；
    /// 疊在實色 panelBG 上的樣子和舊版幾乎一樣（≈ 0.10, 0.11, 0.15），玻璃上則不再透出桌布
    static let cardBG  = Color(nsColor: dynamic("cardBG", light: (1, 1, 1, 0.88), dark: (0.10, 0.11, 0.15, 0.88)))
    /// 卡片 / 視窗邊的髮絲線、圖表格線、座標字
    static let hairline = Color(nsColor: dynamic("hairline", light: (0, 0, 0, 0.08), dark: (1, 1, 1, 0.08), highContrast: 3))
    static let grid     = Color(nsColor: dynamic("grid", light: (0, 0, 0, 0.07), dark: (1, 1, 1, 0.06), highContrast: 2.5))
    static let axis     = Color(nsColor: .secondaryLabelColor)
    /// 間距節奏（4pt 基準）：卡片內 12、卡片之間 8、「看狀態」與「改設定」兩群之間 16
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 12
    static let plotRadius: CGFloat = 4    // 同心圓角：卡片 12 − 內距 8 左右
    static let stackSpacing: CGFloat = 8
    static let groupSpacing: CGFloat = 16
    /// 字級角色：macOS 可讀下限 10pt（HIG），所以最小字就是 caption2；會跳動的數字一律等寬數字
    static let axisFont = Font.caption2.monospacedDigit()
    static let valueFont = Font.system(.title2, design: .rounded, weight: .semibold).monospacedDigit()

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

/// 三層疊出來的發光線：寬淡暈 → 中暈 → 細實線
@ChartContentBuilder
func glowLine<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, series: String, color: Color, smooth: Bool = true) -> some ChartContent {
    LineMark(x: x, y: y, series: .value("s", series + "•halo")).foregroundStyle(color.opacity(0.10)).lineStyle(.init(lineWidth: 10, lineCap: .round, lineJoin: .round)).interpolationMethod(smooth ? .catmullRom : .linear).accessibilityHidden(true)
    LineMark(x: x, y: y, series: .value("s", series + "•glow")).foregroundStyle(color.opacity(0.28)).lineStyle(.init(lineWidth: 4.5, lineCap: .round, lineJoin: .round)).interpolationMethod(smooth ? .catmullRom : .linear).accessibilityHidden(true)
    LineMark(x: x, y: y, series: .value("s", series)).foregroundStyle(color).lineStyle(.init(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).interpolationMethod(smooth ? .catmullRom : .linear)
}

/// 發光點：大暈 + 小實點
@ChartContentBuilder
func glowPoint<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, color: Color, size: CGFloat = 40) -> some ChartContent {
    PointMark(x: x, y: y).foregroundStyle(color.opacity(0.18)).symbolSize(size * 4).accessibilityHidden(true)
    PointMark(x: x, y: y).foregroundStyle(color.opacity(0.45)).symbolSize(size * 1.8).accessibilityHidden(true)
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
        let on = scheme == .dark && contrast != .increased && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast && !reduceHighlight
        return content.shadow(color: on ? color : .clear, radius: radius)
    }
}

/// 卡片外框：統一內距、圓角、底色與髮絲線
struct NeonCard: ViewModifier {
    var padding: CGFloat = Neon.cardPadding
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Neon.cardBG, in: RoundedRectangle(cornerRadius: Neon.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Neon.cardRadius, style: .continuous).strokeBorder(Neon.hairline, lineWidth: 0.5))
    }
}

extension View {
    func neonPlot() -> some View { modifier(NeonPlot()) }
    func neonGlow(_ color: Color, radius: CGFloat) -> some View { modifier(NeonGlow(color: color, radius: radius)) }
    func neonCard(padding: CGFloat = Neon.cardPadding) -> some View { modifier(NeonCard(padding: padding)) }
}

// MARK: - 畫面

struct PanelView: View {
    var monitor: Monitor
    static let contentWidth: CGFloat = 320
    static let edgePadding: CGFloat = 16      // 視窗邊距（4pt 節奏；原本 14）

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { monitor.contentHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in monitor.contentHeight = h }
                })
        }
        .frame(width: AppDelegate.panelWidth)
        .onExitCommand { monitor.onHide?() }   // Esc 隱藏面板（面板拿到 key 時）
        .onAppear { monitor.tick() }
    }

    /// 兩群：上面「看現在」（狀態 + 曲線 + 今日統計），下面「改設定」（風扇 / 提示音 / 套用）。
    /// 群組內 8、群組之間 16 —— 靠留白分群，不再加分隔線
    var content: some View {
        VStack(alignment: .leading, spacing: Neon.groupSpacing) {
            if let s = monitor.snapshot {
                VStack(alignment: .leading, spacing: Neon.stackSpacing) {
                    header(s)
                    tempCard(s)
                    sensorGrid
                    fanCard(s)
                    if s.pcoreMHz != nil { freqCard(s) }
                    timeAxis
                    statsRow(s)
                }
                VStack(alignment: .leading, spacing: Neon.stackSpacing) {
                    controls(s)
                    soundCard
                    applyBar
                }
                footer
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
                chipLabel(s.guardRunning ? L("guard執行中") : L("guard未執行"), s.guardRunning ? Color.secondary : Neon.amber,
                          symbol: s.guardRunning ? "checkmark.shield" : "exclamationmark.shield", onGlass: true)
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

    /// thermal pressure 原始值（powermetrics 英文）→ 介面用語。英文介面維持原字；對不上的值原樣顯示
    func pressureName(_ raw: String?) -> String {
        // 英文介面直接用 macOS 的原字（Nominal / Moderate…），不經「正常」→ Normal 這種二次翻譯
        guard L10n.language.hasPrefix("zh") else { return raw ?? "—" }
        switch raw {
        case "Nominal": return L("正常")
        case "Moderate": return L("中度")
        case "Heavy": return L("重度")
        case "Trapping": return L("嚴重")
        case "Sleeping": return L("休眠")
        case let r?: return r
        case nil: return "—"
        }
    }

    /// 一句話結論：全速 / 降頻中 / 溫度危險 / 沒有頻率資料
    func statusLine(_ s: Snapshot) -> some View {
        let (icon, text, color): (String, String, Color) = {
            if !s.guardRunning { return ("exclamationmark.triangle.fill", L("guard沒在執行，風扇由macOS控制"), Neon.amber) }
            if s.level == .critical { return ("flame.fill", L("溫度%.0f°C已達critical，hook會擋下工作", s.controlTemp), Neon.red) }
            if s.throttling { return ("tortoise.fill", L("降頻中（%@）· hook會讓工作等", pressureName(s.thermalPressure)), Neon.red) }
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
        .neonCard(padding: 8)
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
    var sensorGrid: some View {
        DisclosureGroup(isExpanded: Binding(get: { monitor.showSensors }, set: { monitor.showSensors = $0 })) {
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
                if monitor.showSensors {
                    Text(L("%ld個感測器", monitor.sensorTemps.count)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .neonCard(padding: 8)
    }

    func sensorGroup(_ name: String, prefix: String) -> some View {
        let items = monitor.sensorTemps.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
        let hi = items.map(\.value).max()
        let avg = items.isEmpty ? nil : items.map(\.value).reduce(0, +) / Double(items.count)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.primary).frame(width: 44, alignment: .leading)
                if let hi, let avg {
                    Text(L("最熱%.0f°", hi)).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(tempText(hi))
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
                if s.throttling { chipLabel(L("降頻（%@）", pressureName(s.thermalPressure)), Neon.red) }
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
            .neonCard(padding: 8)
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

    @ViewBuilder
    func controls(_ s: Snapshot) -> some View {
        let fmin = s.fans.first?.min ?? 1000
        let fmax = s.fans.first?.max ?? 4900
        VStack(alignment: .leading, spacing: 8) {
            // 標題列：模式 + 狀態
            HStack(spacing: 6) {
                Image(systemName: "fan").font(.caption).foregroundStyle(.secondary)
                Text(L("風扇控制")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !s.guardRunning {
                    Label(L("guard未執行"), systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Neon.amber)
                } else if monitor.fanDirty {
                    Text(L("未套用")).font(.caption2.weight(.medium)).foregroundStyle(Neon.amber)
                }
            }
            Picker(L("模式"), selection: Binding(get: { monitor.draft.mode }, set: { monitor.draft.mode = $0 })) {
                Text(L("曲線")).tag("curve")
                Text(L("固定")).tag("fixed")
                Text(L("自動")).tag("auto")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)   // 和下面的預設曲線 segmented、套用列同一尺寸（原本 regular 比卡片標題還重）

            switch monitor.draft.mode {
            case "fixed":
                curvePreview(s, fixed: monitor.draft.fixedRPM, fmin: fmin, fmax: fmax)
                HStack {
                    Slider(value: Binding(get: { monitor.draft.fixedRPM }, set: { monitor.draft.fixedRPM = ($0 / 50).rounded() * 50 }),
                           in: fmin...fmax)
                        .accessibilityLabel(L("固定轉速"))
                        .accessibilityValue(Text(verbatim: "\(Int(monitor.draft.fixedRPM)) RPM"))
                    Text(verbatim: "\(Int(monitor.draft.fixedRPM)) rpm").font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                }
            case "curve":
                curvePreview(s, fixed: nil, fmin: fmin, fmax: fmax)
                presetChips
                DisclosureGroup {
                    VStack(spacing: 4) {
                        ForEach(monitor.draft.curve.indices, id: \.self) { i in
                            HStack(spacing: 6) {
                                Stepper(value: Binding(get: { monitor.draft.curve[i].temp }, set: { monitor.draft.curve[i].temp = $0 }), in: 40...105, step: 1) {
                                    Text(verbatim: "\(Int(monitor.draft.curve[i].temp))°").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                                }
                                .controlSize(.regular)   // small 的上下箭頭各約 7pt 高，低於 macOS 可點範圍
                                .accessibilityLabel(L("第%ld點溫度", i + 1))
                                .accessibilityValue(L("%ld度", Int(monitor.draft.curve[i].temp)))
                                Slider(value: Binding(get: { monitor.draft.curve[i].rpm }, set: { monitor.draft.curve[i].rpm = ($0 / 50).rounded() * 50 }),
                                       in: fmin...fmax)
                                    .controlSize(.small)
                                    .accessibilityLabel(L("第%ld點轉速", i + 1))
                                    .accessibilityValue(Text(verbatim: "\(Int(monitor.draft.curve[i].rpm)) RPM"))
                                Text(verbatim: "\(Int(monitor.draft.curve[i].rpm))").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(currentPresetName.map { L("微調「%@」的點", $0) } ?? L("編輯自訂曲線的點")).font(.caption)
                }
            default:
                Text(L("風扇交回macOS自己管。M4 mini原廠策略很保守：CPU到100°C才加速，重載10–15分鐘後會降頻。"))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: Binding(get: { monitor.draft.includeGPU }, set: { monitor.draft.includeGPU = $0 })) {
                Text(L("GPU溫度也納入")).font(.caption).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox).controlSize(.small)
        }
        .neonCard()
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

    /// 提示音卡：熱 / 冷兩列，每列 = 開關（即時生效）+ ▶ 試聽 + 觸發門檻（走「套用」寫進 config）
    var soundCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").font(.caption).foregroundStyle(.secondary)
                Text(L("提示音")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if monitor.soundDirty { Text(L("未套用")).font(.caption2.weight(.medium)).foregroundStyle(Neon.amber) }
            }
            soundLine(L("過熱／降頻"), Neon.red, hot: true,
                      isOn: Binding(get: { monitor.hotSoundOn }, set: { monitor.hotSoundOn = $0 }),
                      threshold: Binding(get: { monitor.draftOverheatAbove }, set: { monitor.draftOverheatAbove = $0 }),
                      range: (monitor.draftCooldownBelow + 1)...105, prefix: "≥")
            soundLine(L("降溫回穩"), Neon.green, hot: false,
                      isOn: Binding(get: { monitor.coldSoundOn }, set: { monitor.coldSoundOn = $0 }),
                      threshold: Binding(get: { monitor.draftCooldownBelow }, set: { monitor.draftCooldownBelow = $0 }),
                      range: 40...(monitor.draftOverheatAbove - 1), prefix: "<")
            Text(L("CPU／GPU一降頻就算過熱，不看溫度。門檻獨立於風扇與hook的hot線。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .neonCard()
    }

    func soundLine(_ title: String, _ color: Color, hot: Bool, isOn: Binding<Bool>, threshold: Binding<Double>,
                   range: ClosedRange<Double>, prefix: String) -> some View {
        let file = monitor.soundPath(hot: hot)
        return HStack(spacing: 4) {
            Toggle(isOn: isOn) { Text(verbatim: title).font(.caption).foregroundStyle(isOn.wrappedValue ? color : .secondary) }
                .toggleStyle(.checkbox).controlSize(.small)
            Button { monitor.play(hot: hot) } label: {
                Image(systemName: "play.circle").font(.body).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())   // macOS 可點範圍至少 20pt
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("試聽「%@」提示音", title))
            .help(L("試聽：%@", file.map { ($0 as NSString).lastPathComponent } ?? L("系統音%@", hot ? Monitor.hotSound : Monitor.coldSound)))
            Spacer()
            Stepper(value: threshold, in: range, step: 1) {
                Text(verbatim: "\(prefix) \(Int(threshold.wrappedValue))°")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isOn.wrappedValue ? Color.primary : Color.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .controlSize(.regular)   // small 的上下箭頭各約 7pt 高，低於 macOS 可點範圍
            .accessibilityLabel(L("「%@」門檻", title))
            .accessibilityValue(L("%@%ld度", prefix, Int(threshold.wrappedValue)))
            .disabled(!isOn.wrappedValue)
        }
    }

    /// 全域套用列：風扇或提示音任一有改動才出現，一次寫回設定檔
    @ViewBuilder
    var applyBar: some View {
        if monitor.dirty || monitor.saveMessage != nil {
            HStack {
                // 套用列在卡片外（壓在玻璃上）：字用 vibrant 的 .primary / .secondary，狀態色只給 SF Symbol
                if let m = monitor.saveMessage {
                    Label { Text(verbatim: m).foregroundStyle(monitor.saveFailed ? Color.primary : Color.secondary) } icon: {
                        Image(systemName: monitor.saveFailed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .foregroundStyle(monitor.saveFailed ? Neon.red : Neon.green)
                    }
                    .font(.caption2).lineLimit(2)
                } else if monitor.dirty {
                    Label { Text(L("有未套用的變更")).foregroundStyle(.secondary) } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Neon.amber)
                    }
                    .font(.caption2).lineLimit(1)
                }
                Spacer()
                Button(L("捨棄")) { monitor.revert() }.disabled(!monitor.dirty).help(L("捨棄未套用的變更"))
                Button(L("套用")) { monitor.apply() }.disabled(!monitor.dirty).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.horizontal, 4)
        }
    }

    var footer: some View {
        // 文字按鈕前加 SF Symbol：一眼看得出是能按的動作，不是說明文字
        HStack(spacing: 12) {
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/cool42.log")) } label: { Label(L("記錄檔"), systemImage: "doc.text") }.help(L("打開%@", "/var/log/cool42.log"))
            Button { NSWorkspace.shared.selectFile(monitor.config.loadedFrom ?? "/etc/cool42/config.json", inFileViewerRootedAtPath: "") } label: {
                Label(L("設定檔"), systemImage: "folder")
            }.help(L("在Finder中顯示設定檔"))
            Spacer()
            Text(verbatim: "cool42 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).layoutPriority(-1)
            Button { monitor.relaunch() } label: { Label(L("重新啟動"), systemImage: "arrow.clockwise") }.help(L("重新啟動面板"))
            Button { NSApp.terminate(nil) } label: { Label(L("結束"), systemImage: "power") }.help(L("結束面板程式（guard不受影響）"))
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
