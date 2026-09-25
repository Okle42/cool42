import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Cool42Core

// 設定視窗（⌘,、選單列右鍵「設定⋯」、面板頁尾「設定⋯」）。
// 這個 app 是 NSApplication＋NSPanel（不是 SwiftUI App），沒有 Settings scene 可用，
// 所以用 NSTabViewController 的 .toolbar 分頁（系統設定視窗那種上方圖示分頁）＋每頁一個 SwiftUI grouped Form：
//   視窗標題跟著分頁變、記住上次的分頁、不能縮放（最小化／放大鈕變暗）、大小跟著分頁內容。
// 會寫設定檔（/etc/cool42/config.json，guard 熱重載）的欄位沿用面板原本的 draft →「套用」流程：
//   刻意偏離 HIG「改了就生效」—— 設定檔給 root 常駐的 guard 讀，拖滑桿時每一格都寫檔會讓風扇跟著抖，
//   曲線點也要整組驗證過才寫（guard 會拒絕壞設定，面板卻以為生效了）。只存在面板本機的偏好（選單列、通知、提示音開關）即時生效。
//   例外：「模式」跟面板上的一樣按了就寫（同一個控制項兩個地方行為不同，使用者會以為生效了）。
// 有未套用的變更時：關視窗先問「套用／取消／捨棄變更」，面板頁尾也有一行提示；
// 套用是三方合併（Config.applyingPanelEdits）：只寫使用者改過的欄位，編輯期間別處改的鍵保留。

enum SettingsTab: String, CaseIterable {
    case fan, profiles, sounds, display, about
    var title: String {
        switch self {
        case .fan: return L("風扇控制")
        case .profiles: return L("情境與噪音上限")
        case .sounds: return L("提示音")
        case .display: return L("通知與顯示")
        case .about: return L("關於與檢查")
        }
    }
    var symbol: String {
        switch self {
        case .fan: return "fan"
        case .profiles: return "switch.2"
        case .sounds: return "speaker.wave.2"
        case .display: return "bell.badge"
        case .about: return "stethoscope"
        }
    }
    static let key = "settings.tab"
    static var last: SettingsTab { UserDefaults.standard.string(forKey: key).flatMap(SettingsTab.init(rawValue:)) ?? .fan }
}

/// 分頁切換時：視窗標題換成分頁名稱、記住這一頁
final class SettingsTabController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let id = tabViewItem?.identifier as? String, let t = SettingsTab(rawValue: id) else { return }
        view.window?.title = t.title
        UserDefaults.standard.set(id, forKey: SettingsTab.key)
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    let monitor: Monitor
    private(set) var window: NSWindow?
    private var tabs: SettingsTabController?

    init(monitor: Monitor) { self.monitor = monitor }

    func show(tab: SettingsTab?) {
        monitor.reloadConfig()   // 有未套用的編輯時會疊到最新的設定檔上，不會丟
        monitor.refreshHealth(force: true)
        let w = window ?? build()
        let t = tab ?? SettingsTab.last
        if let i = SettingsTab.allCases.firstIndex(of: t) { tabs?.selectedTabViewItemIndex = i }
        w.title = t.title
        // LSUIElement app：不先 activate，視窗會被壓在別的 app 後面
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSWindow {
        let tc = SettingsTabController()
        tc.tabStyle = .toolbar
        tc.transitionOptions = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : [.crossfade, .allowUserInteraction]
        for t in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsPage(tab: t, monitor: monitor))
            host.sizingOptions = [.preferredContentSize]   // 視窗大小跟著分頁內容
            host.title = t.title   // NSTabViewController 會把選中分頁的 title 傳給視窗；沒設的話視窗標題變「未命名」
            let item = NSTabViewItem(viewController: host)
            item.identifier = t.rawValue
            item.label = t.title
            item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
            tc.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tc)
        w.styleMask = [.titled, .closable]          // 不可縮放、不可最小化（HIG：設定視窗的這兩顆鈕變暗）
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("cool42.settings")
        if !w.setFrameUsingName("cool42.settings") { w.center() }
        tabs = tc
        window = w
        return w
    }

    /// 有未套用的變更就先問（HIG 的「要儲存變更嗎」那一種）：套用（預設）／取消（Esc）／捨棄變更
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard monitor.dirty else { return true }
        let a = NSAlert()
        a.messageText = L("要套用設定的變更嗎？")
        a.informativeText = L("還沒套用的變更不會寫入設定檔，guard看不到。")
        a.addButton(withTitle: L("套用"))
        a.addButton(withTitle: L("取消")).keyEquivalent = "\u{1b}"
        a.addButton(withTitle: L("捨棄變更"))
        a.beginSheetModal(for: sender) { [weak self] r in
            guard let self else { return }
            switch r {
            case .alertFirstButtonReturn:
                self.monitor.apply()
                if !self.monitor.saveFailed { sender.close() }   // 寫入失敗就留著視窗，錯誤在「套用」列看得到
            case .alertThirdButtonReturn:
                self.monitor.revert()
                sender.close()
            default: break
            }
        }
        return false
    }
}

// MARK: - 分頁內容

/// 設定視窗寬固定 560，高度跟著分頁內容（量 Form 的內容高度）：
/// 超過螢幕可用高度 − 96 才停在上限、由 Form 自己捲（1080p 上曲線模式的風扇頁不用捲）
struct SettingsPage: View {
    let tab: SettingsTab
    var monitor: Monitor
    static let width: CGFloat = 560
    /// Form 內容量到的高度（含上下內距）；0＝還沒量到
    @State private var natural: CGFloat = 0

    var hasApplyBar: Bool { tab == .fan || tab == .profiles || tab == .sounds }

    var body: some View {
        let p = PanelView(monitor: monitor)
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .fan: FanSettings(monitor: monitor, panel: p)
                case .profiles: ProfileSettings(monitor: monitor, panel: p)
                case .sounds: SoundSettings(monitor: monitor)
                case .display: DisplaySettings(monitor: monitor, panel: p)
                case .about: AboutSettings(monitor: monitor, panel: p)
                }
            }
            .formStyle(.grouped)
            .modifier(MeasureFormHeight(height: $natural))
            .frame(height: natural > 0 ? min(natural, formCap) : Self.fallbackHeight(tab))
            if hasApplyBar { SettingsApplyBar(monitor: monitor) }
        }
        .frame(width: Self.width)
    }

    /// Form 最多多高：螢幕可用高度 − 96（視窗上下各留 48）− 標題列＋分頁列 − 「套用」列
    var formCap: CGFloat {
        let vf = NSScreen.main?.visibleFrame.height ?? 900
        return max(320, vf - 96 - 74 - (hasApplyBar ? 52 : 0))
    }

    /// 量不到內容高度（macOS 14 沒有 onScrollGeometryChange）時的估計值
    static func fallbackHeight(_ t: SettingsTab) -> CGFloat {
        switch t {
        case .fan: return 700
        case .profiles: return 420
        case .sounds: return 400
        case .display: return 300
        case .about: return 600
        }
    }
}

/// grouped Form 本身是一個捲動區：讀它的內容高度（macOS 15+），視窗才能剛好包住內容
struct MeasureFormHeight: ViewModifier {
    @Binding var height: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self, of: { g in
                (g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom).rounded(.up)
            }) { _, h in if h > 0, abs(h - height) > 0.5 { height = h } }
        } else {
            content
        }
    }
}

/// 「套用」列：寫設定檔的分頁共用（draft 是同一份，改了哪一頁都看得到有沒有未套用的變更）
struct SettingsApplyBar: View {
    var monitor: Monitor
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if let m = monitor.saveMessage {
                    Label { Text(verbatim: m).foregroundStyle(monitor.saveFailed ? Color.primary : Color.secondary) } icon: {
                        Image(systemName: monitor.saveFailed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .foregroundStyle(monitor.saveFailed ? Neon.red : Neon.green)
                    }
                    .lineLimit(2)
                } else if monitor.dirty {
                    Label { Text(L("有未套用的變更")) } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Neon.amber)
                    }
                } else {
                    Text(L("按「套用」後寫入設定檔，guard幾秒內生效。")).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(L("捨棄變更")) { monitor.revert() }.disabled(!monitor.dirty)
                Button(L("套用")) { monitor.apply() }.disabled(!monitor.dirty)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}

struct FanSettings: View {
    var monitor: Monitor
    let panel: PanelView

    var body: some View {
        let s = monitor.snapshot
        let fmin = s?.fans.first?.min ?? 1000
        let fmax = s?.fans.first?.max ?? 4900
        Form {
            Section {
                // 模式和面板上的一樣：按了就寫設定檔（不走「套用」），同一個控制項兩個地方行為一致
                Picker(L("模式"), selection: Binding(get: { monitor.config.mode }, set: { monitor.setModeNow($0) })) {
                    Text(L("曲線")).tag("curve")
                    Text(L("固定")).tag("fixed")
                    Text(L("自動")).tag("auto")
                }
                .pickerStyle(.segmented)
                Toggle(L("GPU溫度也納入"), isOn: Binding(get: { monitor.draft.includeGPU }, set: { monitor.draft.includeGPU = $0 }))
                    .toggleStyle(.switch).controlSize(.mini)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsFooter(modeFooter)
                    SettingsFooter(L("模式按了就生效；曲線與轉速按「套用」才寫入。"))
                }
            }
            switch monitor.config.mode {
            case "curve":
                Section(L("曲線")) {
                    Picker(L("預設曲線"), selection: Binding<String?>(
                        get: { panel.currentPresetName },
                        set: { name in if let pts = Monitor.presets.first(where: { $0.0 == name })?.1 { monitor.draft.curve = pts } })) {
                        ForEach(Monitor.presets, id: \.0) { name, _ in Text(verbatim: name).tag(Optional(name)) }
                        if panel.currentPresetName == nil { Text(L("自訂")).tag(String?.none) }
                    }
                    .pickerStyle(.segmented)
                    if let s { panel.curvePreview(s, fixed: nil, fmin: fmin, fmax: fmax).frame(height: 130) }
                    ForEach(monitor.draft.curve.indices, id: \.self) { i in curvePointRow(i, fmin: fmin, fmax: fmax) }
                }
            case "fixed":
                Section(L("固定轉速")) {
                    if let s { panel.curvePreview(s, fixed: monitor.draft.fixedRPM, fmin: fmin, fmax: fmax).frame(height: 130) }
                    LabeledContent(L("轉速")) {
                        HStack {
                            Slider(value: Binding(get: { monitor.draft.fixedRPM }, set: { monitor.draft.fixedRPM = ($0 / 50).rounded() * 50 }), in: fmin...fmax)
                                .labelsHidden()
                                .accessibilityLabel(L("固定轉速"))
                                .accessibilityValue(Text(verbatim: "\(Int(monitor.draft.fixedRPM)) RPM"))
                            Text(verbatim: "\(Int(monitor.draft.fixedRPM)) rpm").monospacedDigit().frame(width: 76, alignment: .trailing)
                        }
                    }
                }
            default:
                EmptyView()
            }
            Section {
                panel.emergencyRow
            } header: {
                Text(L("緊急交還"))
            }
        }
    }

    var modeFooter: String {
        switch monitor.config.mode {
        case "fixed": return L("風扇一直停在同一個轉速，不看溫度。")
        case "auto": return L("風扇交回macOS自己管。M4 mini原廠策略很保守：CPU到100°C才加速，重載10–15分鐘後會降頻。")
        default: return L("照溫度曲線提早把風扇轉起來。點與點之間線性內插；溫度到hot、critical或降頻時不受噪音上限限制。")
        }
    }

    func curvePointRow(_ i: Int, fmin: Double, fmax: Double) -> some View {
        LabeledContent(L("第%ld點", i + 1)) {
            HStack(spacing: 10) {
                Text(verbatim: "\(Int(monitor.draft.curve[i].temp))°C").monospacedDigit().frame(width: 44, alignment: .trailing)
                Stepper("", value: Binding(get: { monitor.draft.curve[i].temp }, set: { monitor.draft.curve[i].temp = $0 }), in: 40...105, step: 1)
                    .labelsHidden()
                    .accessibilityLabel(L("第%ld點溫度", i + 1))
                    .accessibilityValue(L("%ld度", Int(monitor.draft.curve[i].temp)))
                Slider(value: Binding(get: { monitor.draft.curve[i].rpm }, set: { monitor.draft.curve[i].rpm = ($0 / 50).rounded() * 50 }), in: fmin...fmax)
                    .labelsHidden()
                    .frame(width: 200)
                    .accessibilityLabel(L("第%ld點轉速", i + 1))
                    .accessibilityValue(Text(verbatim: "\(Int(monitor.draft.curve[i].rpm)) RPM"))
                Text(verbatim: "\(Int(monitor.draft.curve[i].rpm)) rpm").monospacedDigit().frame(width: 76, alignment: .trailing)
            }
        }
    }
}

struct ProfileSettings: View {
    var monitor: Monitor
    let panel: PanelView
    var body: some View {
        let fmin = monitor.snapshot?.fans.first?.min ?? 1000
        let fmax = monitor.snapshot?.fans.first?.max ?? 4900
        Form {
            if let s = monitor.snapshot {
                Section { panel.activeProfileLine(s) }
            }
            Section(L("噪音上限")) { panel.capSection(fmin: fmin, fmax: fmax) }
            Section { panel.rulesSection(fmin: fmin, fmax: fmax) }
        }
    }
}

struct SoundSettings: View {
    var monitor: Monitor
    var body: some View {
        Form {
            soundSection(L("過熱／降頻"), hot: true,
                         isOn: Binding(get: { monitor.hotSoundOn }, set: { monitor.hotSoundOn = $0 }),
                         threshold: Binding(get: { monitor.draftOverheatAbove }, set: { monitor.draftOverheatAbove = $0 }),
                         range: (monitor.draftCooldownBelow + 1)...105, prefix: "≥", thresholdLabel: L("溫度到達"))
            soundSection(L("降溫回穩"), hot: false,
                         isOn: Binding(get: { monitor.coldSoundOn }, set: { monitor.coldSoundOn = $0 }),
                         threshold: Binding(get: { monitor.draftCooldownBelow }, set: { monitor.draftCooldownBelow = $0 }),
                         range: 40...(monitor.draftOverheatAbove - 1), prefix: "<", thresholdLabel: L("溫度降到"),
                         footer: L("CPU／GPU一降頻就算過熱，不看溫度。門檻獨立於風扇與hook的hot線；開關立即生效，門檻按「套用」才寫入。"))
        }
    }

    func soundSection(_ title: String, hot: Bool, isOn: Binding<Bool>, threshold: Binding<Double>,
                      range: ClosedRange<Double>, prefix: String, thresholdLabel: String, footer: String? = nil) -> some View {
        let file = monitor.soundPath(hot: hot)
        return Section {
            Toggle(L("播放提示音"), isOn: isOn).toggleStyle(.switch).controlSize(.mini)
            LabeledContent(thresholdLabel) {
                HStack(spacing: 6) {
                    Text(verbatim: "\(prefix) \(Int(threshold.wrappedValue))°C").monospacedDigit()
                    Stepper("", value: threshold, in: range, step: 1).labelsHidden()
                        .accessibilityLabel(L("「%@」門檻", title))
                        .accessibilityValue(L("%@%ld度", prefix, Int(threshold.wrappedValue)))
                }
            }
            .disabled(!isOn.wrappedValue)
            LabeledContent(L("聲音")) {
                HStack(spacing: 8) {
                    // 檔名本身就是選檔按鈕（像 Finder 的路徑選擇器）：點了開檔案選擇視窗換音檔
                    Button { chooseSound(hot: hot, title: title) } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: file.map { ($0 as NSString).lastPathComponent } ?? L("系統音%@", hot ? Monitor.hotSound : Monitor.coldSound))
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(file ?? L("點一下選擇其他音檔"))
                    .accessibilityLabel(L("「%@」提示音檔案", title))
                    .accessibilityHint(L("點一下選擇其他音檔"))
                    .contextMenu {
                        Button(L("選擇其他音檔⋯")) { chooseSound(hot: hot, title: title) }
                        if let file {
                            Button(L("在 Finder 中顯示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                        }
                        if monitor.hasCustomSound(hot: hot) {
                            Divider()
                            Button(L("還原成內建音效")) { monitor.setSoundFileNow(hot: hot, path: nil) }
                        }
                    }
                    Button(L("試聽")) { monitor.play(hot: hot) }
                        .accessibilityLabel(L("試聽「%@」提示音", title))
                }
            }
        } header: { Text(verbatim: title) } footer: {
            if let footer { SettingsFooter(footer) }
        }
    }
}

extension SoundSettings {
    /// NSOpenPanel 選音檔；選好直接寫設定並試聽一次，讓使用者馬上知道換成什麼聲音
    func chooseSound(hot: Bool, title: String) {
        let p = NSOpenPanel()
        p.title = L("選擇「%@」提示音", title)
        p.prompt = L("選擇")
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        if let cur = monitor.soundPath(hot: hot) {
            p.directoryURL = URL(fileURLWithPath: cur).deletingLastPathComponent()
        }
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        monitor.setSoundFileNow(hot: hot, path: url.path)
        monitor.play(hot: hot)
    }
}

/// 面板外觀的本地狀態（UserDefaults；SwiftUI 需要一個可觀察的來源才會跟著重畫）
@Observable final class PanelLook {
    var appearance = GlassStyle.appearance
    var transparency = GlassStyle.transparency
    var blur = GlassStyle.blur
    var blurRadius = GlassStyle.blurRadius
}

struct DisplaySettings: View {
    var monitor: Monitor
    let panel: PanelView
    @State private var look = PanelLook()
    var body: some View {
        Form {
            Section {
                Toggle(L("在選單列顯示溫度"), isOn: Binding(get: { monitor.showTempInMenuBar }, set: { monitor.showTempInMenuBar = $0 }))
                    .toggleStyle(.switch).controlSize(.mini)
            } header: { Text(L("選單列")) } footer: {
                SettingsFooter(L("關掉就只顯示圖示：溫度計刻度分正常／偏溫，過熱時右下角多一個點，危險換成三角形，降頻時改成右上角一隻烏龜"))
            }
            Section {
                Picker(L("外觀"), selection: Binding(get: { look.appearance }, set: { look.appearance = $0; GlassStyle.appearance = $0 })) {
                    Text(L("跟隨系統")).tag("system")
                    Text(L("淺色")).tag("light")
                    Text(L("深色")).tag("dark")
                }
                .pickerStyle(.segmented)
                Toggle(L("模糊背景"), isOn: Binding(get: { look.blur }, set: { look.blur = $0; GlassStyle.blur = $0 }))
                    .toggleStyle(.switch).controlSize(.mini)
                if !look.blur {
                    LabeledContent(L("模糊度")) {
                        HStack(spacing: 8) {
                            Image(systemName: "circle.grid.3x3").imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true)
                            Slider(value: Binding(get: { look.blurRadius }, set: { look.blurRadius = $0; GlassStyle.blurRadius = $0 }),
                                   in: 0...GlassStyle.maxBlurRadius, step: 1)
                                .frame(width: 180)
                                .accessibilityLabel(L("背景模糊度"))
                                .accessibilityValue(Text(verbatim: "\(Int(look.blurRadius))"))
                            Image(systemName: "aqi.medium").imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                    }
                    .disabled(!WindowBlur.available)
                }
                LabeledContent(L("透明度")) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill").imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true)
                        Slider(value: Binding(get: { look.transparency }, set: { look.transparency = $0; GlassStyle.transparency = $0 }), in: 0...1)
                            .frame(width: 180)
                            .accessibilityLabel(L("面板透明度"))
                            .accessibilityValue(Text(verbatim: "\(Int(look.transparency * 100))%"))
                        Image(systemName: "circle.dashed").imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
                if abs(look.transparency - GlassStyle.defaultTransparency) > 0.001 {
                    Button(L("還原預設透明度")) { look.transparency = GlassStyle.defaultTransparency; GlassStyle.transparency = GlassStyle.defaultTransparency }
                }
            } header: { Text(L("面板外觀")) } footer: {
                SettingsFooter(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                    ? L("系統的「減少透明度」開著，面板用實色底，透明度設定暫時不作用")
                    : look.blur
                        ? L("模糊背景開著是 Apple 的玻璃材質：背景一定會被模糊，透明度只調深淺，看不到後面的東西。要看得到桌布與後面的視窗，把「模糊背景」關掉")
                        : WindowBlur.available
                            ? L("模糊背景關著：模糊度 0 是完全不模糊的真透明，往右越模糊；透明度調疊層濃淡。背景越花字越難讀，可以把模糊度調高一點")
                            : L("這台 macOS 不支援自訂模糊度，面板維持不模糊的真透明；透明度調疊層濃淡"))
            }
            Section {
                Toggle(L("降頻、過熱與恢復正常時發通知"), isOn: Binding(get: { monitor.notifyOn }, set: { monitor.notifyOn = $0 }))
                    .toggleStyle(.switch).controlSize(.mini)
                if monitor.notifyOn { panel.notifyStatus }
            } header: { Text(L("通知")) } footer: {
                SettingsFooter(L("只在開始降頻、溫度到critical、恢復正常三個時刻發；同一段過熱每一類只發一次，穩定正常2.5分鐘才算恢復"))
            }
        }
    }
}

struct AboutSettings: View {
    var monitor: Monitor
    let panel: PanelView
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "fan.fill").font(.system(size: 28)).foregroundStyle(Neon.cyan).frame(width: 40).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "cool42").font(.title3.weight(.semibold))
                        Text(L("Apple Silicon風扇守門員 · 版本%@", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("cool42是做什麼的？")) { monitor.onShowOnboarding?() }
                }
            }
            Section {
                panel.healthList
                HStack(spacing: 8) {
                    Button { monitor.refreshHealth(force: true) } label: { Label(L("重新檢查"), systemImage: "arrow.clockwise") }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("cool42 doctor", forType: .string)
                    } label: { Label(L("拷貝完整檢查指令"), systemImage: "doc.on.doc") }
                        .help(L("拷貝「cool42 doctor」，貼到終端機執行"))
                    Spacer()
                }
            } header: {
                HStack {
                    Text(L("健康檢查"))
                    Spacer()
                    Text(verbatim: panel.healthSummary).foregroundStyle(.secondary)
                }
            }
            Section(L("檔案與程式")) {
                LabeledContent(L("設定檔")) {
                    Button(L("在Finder中顯示")) {
                        NSWorkspace.shared.selectFile(monitor.config.loadedFrom ?? "/etc/cool42/config.json", inFileViewerRootedAtPath: "")
                    }
                }
                LabeledContent(L("記錄檔")) {
                    Button(L("打開")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/cool42.log")) }
                }
                LabeledContent(L("面板程式")) {
                    HStack {
                        Button(L("重新啟動")) { monitor.relaunch() }
                        Button(L("結束")) { NSApp.terminate(nil) }.help(L("結束面板程式（guard不受影響）"))
                    }
                }
            }
        }
    }
}

/// 分組下方的說明字：靠左（多行時不要置中）、次要色
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text).font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
