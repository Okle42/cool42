import AppKit
import SwiftUI
import Cool42Core

// 「情境與噪音上限」卡：目前生效的情境、噪音上限滑桿（附取捨說明）、情境規則的新增／刪除／編輯。
// 改動走 draft，和風扇、提示音同一條「套用」寫回設定檔；guard 熱重載後每輪依序評估規則（Cool42Core/Profiles.swift）

enum RuleKind { case time, apps, focus }

extension Monitor {
    /// 新規則的起始內容（名稱用目前語言；存進設定檔後就是使用者的字，guard 的 log 也照寫）
    static func template(_ k: RuleKind) -> Profile {
        switch k {
        case .time: return Profile(name: L("夜間安靜"), when: .init(from: "23:00", to: "07:00"), curve: "quiet", maxRPM: 2200)
        case .apps: return Profile(name: L("重工作App"), when: .init(apps: ["Xcode", "Blender", "ffmpeg"]), curve: "performance")
        case .focus: return Profile(name: L("專注模式"), when: .init(focus: true), maxRPM: 2400)
        }
    }

    func addProfile(_ k: RuleKind) {
        guard draft.profiles.count < Profile.maxCount else { return }
        var p = Self.template(k)
        // 名稱不重複：「夜間安靜」已經有了就叫「夜間安靜 2」
        let names = Set(draft.profiles.map(\.name))
        if names.contains(p.name) { p.name = (2...).lazy.map { "\(p.name) \($0)" }.first { !names.contains($0) }! }
        draft.profiles.append(p)
        editingProfile = draft.profiles.count - 1
        saveMessage = nil
    }

    func removeProfile(_ i: Int) {
        guard draft.profiles.indices.contains(i) else { return }
        draft.profiles.remove(at: i)
        editingProfile = nil
    }

    func moveProfileUp(_ i: Int) {
        guard i > 0, draft.profiles.indices.contains(i) else { return }
        draft.profiles.swapAt(i, i - 1)
        editingProfile = i - 1
    }

    /// 刪除中途 SwiftUI 可能拿舊索引來讀：一律檢查範圍
    func ruleBinding<T>(_ i: Int, _ kp: WritableKeyPath<Profile, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.draft.profiles.indices.contains(i) ? self.draft.profiles[i][keyPath: kp] : fallback },
                set: { if self.draft.profiles.indices.contains(i) { self.draft.profiles[i][keyPath: kp] = $0 } })
    }

    /// 面板端先擋掉 guard 會拒絕的規則（Profile.validate 的訊息是繁中、給 log 看的）
    static func problem(_ p: Profile, in all: [Profile] = []) -> String? {
        let n = p.name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return L("要有名稱") }
        if p.name.count > Profile.maxNameLength { return L("名稱太長") }
        // 名稱是 guard 回報「哪條生效」的依據：重名的話兩條都會顯示生效中
        if all.filter({ $0.name.trimmingCharacters(in: .whitespaces) == n }).count > 1 { return L("和另一條規則同名") }
        if let a = p.when.apps, a.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return L("至少填一個App名稱") }
        if p.hasTime, p.when.from == p.when.to { return L("開始與結束時間不能相同") }
        if p.curve == nil && p.maxRPM == nil { return L("選一條曲線或設轉速上限") }
        return nil
    }
    var firstProfileProblem: (String, String)? {
        for p in draft.profiles { if let m = Self.problem(p, in: draft.profiles) { return (p.name.isEmpty ? L("未命名") : p.name, m) } }
        return nil
    }

    /// "23:00" → 跟系統地區的時間格式（英文介面 11:00 PM，和 DatePicker 顯示的一樣）
    static func timeText(_ hhmm: String?) -> String {
        guard let m = hhmm.flatMap(TimeOfDay.minutes),
              let d = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) else { return hhmm ?? "" }
        return PanelView.hm.string(from: d)
    }

    /// 一行摘要：條件 · 動作
    static func summary(_ p: Profile) -> String {
        var parts: [String] = []
        if p.when.from != nil, p.when.to != nil { parts.append(timeText(p.when.from) + "–" + timeText(p.when.to)) }
        if let a = p.when.apps?.filter({ !$0.isEmpty }), !a.isEmpty { parts.append(a.joined(separator: ", ")) }
        if let fo = p.when.focus { parts.append(fo ? L("專注模式開啟時") : L("專注模式關閉時")) }
        if let c = p.curve { parts.append(presetName(c)) }
        if let m = p.maxRPM { parts.append(L("上限%ld rpm", Int(m))) }
        return parts.joined(separator: " · ")
    }
}

extension PanelView {
    /// 預設收合：標題列就是結論（目前哪個情境生效），展開才看上限與規則
    func profilesCard(_ s: Snapshot) -> some View {
        let fmin = s.fans.first?.min ?? 1000
        let fmax = s.fans.first?.max ?? 4900
        return DisclosureGroup(isExpanded: Binding(get: { monitor.showProfiles }, set: { monitor.showProfiles = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                activeProfileLine(s)
                capSection(fmin: fmin, fmax: fmax)
                Divider().padding(.vertical, 2)
                rulesSection(fmin: fmin, fmax: fmax)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "switch.2").font(.caption).foregroundStyle(.secondary)
                Text(L("情境與噪音上限")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if monitor.profileDirty {
                    Text(L("未套用")).font(.caption2.weight(.medium)).foregroundStyle(Neon.amber)
                } else {
                    Text(verbatim: profileHeadline(s)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .neonCard(padding: 8)
    }

    /// 收合時標題列右側的一句話
    func profileHeadline(_ s: Snapshot) -> String {
        guard s.guardRunning else { return L("guard沒在跑") }
        if monitor.config.mode == "auto" { return L("macOS控制中，暫不作用") }
        if let name = s.profile { return L("「%@」生效中", name) }
        if let m = s.maxRPM { return L("上限%ld rpm", Int(m)) }
        return monitor.config.profiles.isEmpty ? L("沒有規則") : L("基本設定")
    }

    /// 目前生效的情境（guard 寫在快照裡）；上限因降頻／高溫暫停時另起一行。
    /// 交還原廠（mode auto）時 guard 不控風扇，情境與上限都不作用；固定模式不套曲線
    @ViewBuilder
    func activeProfileLine(_ s: Snapshot) -> some View {
        if !s.guardRunning {
            Label(L("guard沒在跑，情境不會切換"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(Neon.amber)
        } else if monitor.config.mode == "auto" {
            Label {
                Text(L("風扇由macOS原廠控制中，情境與上限暫不作用")).font(.caption).fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if let name = s.profile {
                    let rule = monitor.config.profiles.first { $0.name == name }
                    Label {
                        Text(verbatim: L("「%@」生效中", name) + (rule.map { " · " + Monitor.summary($0) } ?? ""))
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Neon.green) }
                    if monitor.config.mode == "fixed", rule?.curve != nil {
                        Text(L("固定模式不套曲線，只有上限會作用")).font(.caption2).foregroundStyle(.secondary).padding(.leading, 22)
                    }
                } else {
                    Label {
                        Text(monitor.config.profiles.isEmpty ? L("沒有情境規則，用基本設定") : L("沒有符合的情境，用基本設定")).font(.caption)
                    } icon: { Image(systemName: "circle.dashed").foregroundStyle(.secondary) }
                }
                if s.maxRPMSuspended == true {
                    Label {
                        Text(L("溫度高或降頻中：暫時不限轉速")).font(.caption2)
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Neon.amber) }
                } else if let m = s.maxRPM, s.profile == nil || monitor.config.profiles.first(where: { $0.name == s.profile })?.maxRPM == nil {
                    // 情境本身寫了上限時摘要已經講了，不重複
                    Text(L("目前最高%ld rpm", Int(m))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).padding(.leading, 22)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// 基本設定的噪音上限：勾選才限，滑桿 100 rpm 一格；下面是取捨說明（只講實測過的數字，不給換算）
    func capSection(fmin: Double, fmax: Double) -> some View {
        let on = monitor.draft.maxRPM != nil
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { on }, set: { monitor.draft.maxRPM = $0 ? min(max(3000, fmin), fmax) : nil })) {
                Text(L("基本上限（沒有情境符合時）")).font(.caption)
            }
            .toggleStyle(.checkbox).controlSize(.small)
            if let cap = monitor.draft.maxRPM {
                HStack {
                    Slider(value: Binding(get: { cap }, set: { monitor.draft.maxRPM = ($0 / 100).rounded() * 100 }), in: fmin...fmax)
                        .controlSize(.small)
                        .accessibilityLabel(L("最高轉速"))
                        .accessibilityValue(Text(verbatim: "\(Int(cap)) RPM"))
                    Text(verbatim: "\(Int(cap)) rpm").font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                }
            }
            Text(L("上限越低越安靜，也越可能降頻。本機M4 Mac mini實測（2026-09）：原廠讓風扇停在約2,950 rpm時，P-core慢了7.4%。溫度到hot、critical或降頻時，cool42會暫時忽略上限，降溫後才恢復。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 規則清單：依序第一條符合的生效。每列可展開編輯、刪除；「新增規則」選時段／App／專注模式
    func rulesSection(fmin: Double, fmax: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("情境規則")).font(.caption.weight(.medium))
                Text(L("由上往下，第一條符合的生效")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    Button { monitor.addProfile(.time) } label: { Label(L("時段"), systemImage: "clock") }
                    Button { monitor.addProfile(.apps) } label: { Label(L("App在跑時"), systemImage: "app.badge") }
                    Button { monitor.addProfile(.focus) } label: { Label(L("專注模式開啟時"), systemImage: "moon") }
                } label: {
                    Label(L("新增"), systemImage: "plus")
                }
                .menuStyle(.button).controlSize(.small).fixedSize()
                .disabled(monitor.draft.profiles.count >= Profile.maxCount)
                .help(L("新增一條情境規則（最多%ld條）", Profile.maxCount))
            }
            if monitor.draft.profiles.isEmpty {
                Text(L("例如：23:00–07:00換安靜曲線、Xcode在跑時換強力曲線。")).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(monitor.draft.profiles.enumerated()), id: \.offset) { i, p in
                ruleRow(i, p, fmin: fmin, fmax: fmax)
            }
        }
    }

    func ruleSymbol(_ p: Profile) -> String { p.when.apps != nil ? "app.badge" : p.hasFocus ? "moon" : "clock" }

    func ruleRow(_ i: Int, _ p: Profile, fmin: Double, fmax: Double) -> some View {
        let expanded = monitor.editingProfile == i
        // 交還原廠（auto）時 guard 不控風扇，規則不算生效
        let active = !monitor.profileDirty && monitor.snapshot?.profile == p.name && monitor.snapshot?.guardRunning == true
            && monitor.config.mode != "auto"
        let problem = Monitor.problem(p, in: monitor.draft.profiles)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button { monitor.editingProfile = expanded ? nil : i } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                        Image(systemName: ruleSymbol(p)).font(.caption).foregroundStyle(active ? Neon.green : .secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(verbatim: p.name.isEmpty ? L("未命名") : p.name).font(.caption.weight(.semibold)).lineLimit(1)
                                if active { Text(L("生效中")).font(.caption2.weight(.medium)).foregroundStyle(Neon.green) }
                            }
                            Text(verbatim: Monitor.summary(p)).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            if let problem {
                                Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Neon.amber) }
                                    .font(.caption2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("規則%ld：%@，%@", i + 1, p.name, Monitor.summary(p)))
                .accessibilityHint(expanded ? L("收起編輯") : L("展開編輯"))
            }
            if expanded { ruleEditor(i, p, fmin: fmin, fmax: fmax).padding(.leading, 16) }
            if p.hasFocus && !expanded { focusAccessNote.padding(.leading, 32) }
        }
    }

    func ruleEditor(_ i: Int, _ p: Profile, fmin: Double, fmax: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("名稱")).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                TextField(L("名稱"), text: monitor.ruleBinding(i, \.name, fallback: ""))
                    .textFieldStyle(.roundedBorder).controlSize(.small).font(.caption).labelsHidden()
            }
            if p.hasTime {
                HStack(spacing: 6) {
                    Text(L("時段")).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    DatePicker(L("開始時間"), selection: timeBinding(i, from: true), displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.stepperField).controlSize(.small)
                    Text(verbatim: "–").foregroundStyle(.secondary)
                    DatePicker(L("結束時間"), selection: timeBinding(i, from: false), displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.stepperField).controlSize(.small)
                    Spacer(minLength: 0)
                }
                if let f = p.when.from.flatMap(TimeOfDay.minutes), let t = p.when.to.flatMap(TimeOfDay.minutes), f > t {
                    Text(L("跨午夜：到隔天%@", Monitor.timeText(p.when.to))).font(.caption2).foregroundStyle(.secondary).padding(.leading, 50)
                }
            }
            if p.hasApps || p.when.apps != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("App")).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    AppsField(apps: monitor.ruleBinding(i, \.when.apps, fallback: nil))
                }
                Text(L("任一個在跑就符合，只看你自己帳號的程式。填程序名稱（例如Visual Studio Code是Code），用逗號分開，不分大小寫；不確定就從右邊選單挑。")).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 50)
            }
            if p.hasFocus {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("條件")).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    Text(L("專注模式開啟時")).font(.caption)
                    Spacer(minLength: 0)
                }
                focusAccessNote.padding(.leading, 50)
            }
            HStack(spacing: 6) {
                Text(L("曲線")).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                Picker(L("曲線"), selection: monitor.ruleBinding(i, \.curve, fallback: nil)) {
                    Text(L("不換")).tag(String?.none)
                    ForEach(Config.presetIDs, id: \.self) { id in Text(verbatim: Monitor.presetName(id)).tag(Optional(id)) }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
            }
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { p.maxRPM != nil },
                                     set: { monitor.ruleBinding(i, \.maxRPM, fallback: nil).wrappedValue = $0 ? min(max(2400, fmin), fmax) : nil })) {
                    Text(L("上限")).font(.caption).foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox).controlSize(.small).frame(width: 60, alignment: .leading)
                if let m = p.maxRPM {
                    Slider(value: Binding(get: { m }, set: { monitor.ruleBinding(i, \.maxRPM, fallback: nil).wrappedValue = ($0 / 100).rounded() * 100 }),
                           in: fmin...fmax)
                        .controlSize(.small)
                        .accessibilityLabel(L("「%@」的最高轉速", p.name))
                        .accessibilityValue(Text(verbatim: "\(Int(m)) RPM"))
                    Text(verbatim: "\(Int(m)) rpm").font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                } else {
                    Text(L("沿用平常的上限")).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                if i > 0 {
                    Button { monitor.moveProfileUp(i) } label: { Label(L("上移"), systemImage: "arrow.up") }
                        .help(L("排前面的規則優先"))
                }
                Button { monitor.removeProfile(i) } label: { Label(L("刪除規則"), systemImage: "trash") }
                    .help(L("刪除這條規則（按「套用」才會寫入）"))
            }
            .controlSize(.small)
        }
    }

    /// "HH:mm" ↔ 今天的那個時刻（DatePicker 只顯示時分）
    func timeBinding(_ i: Int, from: Bool) -> Binding<Date> {
        let kp: WritableKeyPath<Profile, String?> = from ? \.when.from : \.when.to
        let b = monitor.ruleBinding(i, kp, fallback: nil)
        return Binding(get: {
            let m = b.wrappedValue.flatMap(TimeOfDay.minutes) ?? 0
            return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            b.wrappedValue = TimeOfDay.string((c.hour ?? 0) * 60 + (c.minute ?? 0))
        })
    }

    /// 專注模式規則下方：讀得到才安靜；需要授權時先說明，按「繼續⋯」macOS 才會問（HIG：請求前的說明只放一顆按鈕、不用「允許」）
    @ViewBuilder
    var focusAccessNote: some View {
        switch monitor.focusAuth {
        case .allowed:
            if let f = monitor.focusNow {
                Text(f ? L("專注模式：開啟中") : L("專注模式：關閉")).font(.caption2).foregroundStyle(.secondary)
            } else if monitor.profileDirty {
                Text(L("按「套用」後開始讀取專注模式。")).font(.caption2).foregroundStyle(.secondary)
            }
        case .notDetermined:
            VStack(alignment: .leading, spacing: 4) {
                Text(L("這條規則要知道專注模式有沒有開。cool42只會讀「開或關」，不會知道是哪一種。"))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("繼續⋯")) { monitor.requestFocusAccess() }.controlSize(.small)
                    .help(L("macOS會問你要不要讓cool42讀取專注模式"))
            }
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 4) {
                Text(L("讀不到專注模式，這條規則不會生效。")).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("打開隱私權設定")) { FocusWatcher.openSettings() }.controlSize(.small)
            }
        case .unavailable:
            Text(L("從cool42 Panel.app執行時才讀得到專注模式；讀不到時這條規則不會生效。")).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// App 名稱輸入：自己留一份文字（打到一半的逗號、空白不會被正規化吃掉），每次改動才解析回陣列。
/// 右邊的選單列出執行中的 App，選了填入它的**執行檔名**（guard 比對的是程序名稱：Visual Studio Code 是 Code、DaVinci Resolve 是 Resolve）
struct AppsField: View {
    @Binding var apps: [String]?
    @State private var text = ""
    @State private var loaded = false
    var body: some View {
        HStack(spacing: 4) {
            TextField(L("例如Xcode, Blender, ffmpeg"), text: $text)
                .textFieldStyle(.roundedBorder).controlSize(.small).font(.caption).labelsHidden()
                .onAppear { if !loaded { text = (apps ?? []).joined(separator: ", "); loaded = true } }
                .onChange(of: text) { _, t in
                    apps = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
                .accessibilityLabel(L("App名稱"))
            Menu {
                let running = Self.runningApps()
                if running.isEmpty { Text(L("沒有執行中的App")) }
                ForEach(running, id: \.exec) { a in
                    Button(a.exec == a.name ? a.name : L("%@（%@）", a.name, a.exec)) { add(a.exec) }
                }
            } label: { Image(systemName: "list.bullet") }
                .menuStyle(.button).menuIndicator(.hidden).controlSize(.small).fixedSize()
                .help(L("從執行中的App挑選"))
                .accessibilityLabel(L("從執行中的App挑選"))
        }
    }

    private func add(_ exec: String) {
        var list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !list.contains(where: { $0.caseInsensitiveCompare(exec) == .orderedSame }) else { return }
        list.append(exec)
        text = list.joined(separator: ", ")
    }

    /// 一般 App（有 Dock 圖示的）：顯示名稱＋執行檔名，依名稱排序
    static func runningApps() -> [(name: String, exec: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a -> (String, String)? in
                guard let exec = a.executableURL?.lastPathComponent, seen.insert(exec.lowercased()).inserted else { return nil }
                return (a.localizedName ?? exec, exec)
            }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
}
