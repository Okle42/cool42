import Foundation
import SwiftUI
import Cool42Core

// 面板「今天」時間軸：今天發生過的降頻、過熱、預熱、AI 等待／擋下，一件一行（時間＋一句話），最多 20 筆、新的在上。
// 資料來源：
//   /var/log/cool42.log（guard 寫、644 全機可讀）—— 降頻開始／結束、等級進入 hot／critical、預熱（加碼、提早結束、學到／略過／恢復）、
//   情境生效／結束、噪音上限暫停／恢復、guard 啟動／結束、警告
//   hook 等待／擋下不寫 log（guard 只累計在今日統計），所以由面板自己盯 stats.hookWaits／hookDenies 的增量記下時間
//   （面板沒開的時段看不到這兩種；統計列的「AI等待／擋下」仍是準的）
// 只在面板開著、log 有變動時才重讀（最多每 15 秒一次），只讀檔尾 1 MB

struct DayEvent: Identifiable, Equatable {
    enum Kind: String { case throttleStart, throttleEnd, hot, critical, criticalEnd, boost, boostSkip, learn, profile, cap, hookWait, hookDeny, guardStart, guardStop, mode, warning }
    var time: Date
    var kind: Kind
    var text: String
    /// 預熱／略過預熱專用：同一個關鍵字 10 分鐘內連續的併成一行（一天 100 多次預熱，不併會把 20 筆擠滿）。
    /// 併的 key 只看關鍵字、不看轉速：預熱先 2000、加碼到 3000 後被延長的仍是同一波。time 是最後一次（排序用），first 是第一次
    var boost: Boost? = nil
    struct Boost: Equatable {
        var rpm: Int, note: String, count = 1, early = 0, lastEarlySecs: Int? = nil, first: Date, last: Date, skipped = false
        var text: String {
            if skipped {
                let head = L("略過預熱 · %@（已學到不像重工作）", note)
                return count > 1 ? L("%@ ×%ld · %@", head, count, DayEvent.range(first, last)) : head
            }
            let head = note.isEmpty ? L("預熱%ld rpm", rpm) : L("預熱%ld rpm · %@", rpm, note)
            if count > 1 {
                let r = DayEvent.range(first, last)
                return early > 0 ? L("%@ ×%ld，%ld次提早收 · %@", head, count, early, r) : L("%@ ×%ld · %@", head, count, r)
            }
            if let s = lastEarlySecs { return L("%@ · %ld秒後提早收", head, s) }
            return head
        }
    }
    /// 「10:41–14:02」：時間跟系統的 12／24 小時制
    static func range(_ a: Date, _ b: Date) -> String {
        let f = PanelView.hm
        let x = f.string(from: a), y = f.string(from: b)
        return x == y ? x : x + "–" + y
    }
    var id: String { "\(Int(time.timeIntervalSince1970))-\(kind.rawValue)-\(text.hashValue)" }

    var symbol: String {
        switch kind {
        case .throttleStart: return "tortoise.fill"
        case .throttleEnd, .criticalEnd: return "checkmark.circle.fill"
        case .hot: return "thermometer.high"
        case .critical: return "flame.fill"
        case .boost: return "wind"
        case .boostSkip: return "forward.fill"
        case .learn: return "lightbulb"
        case .profile: return "switch.2"
        case .cap: return "speaker.wave.1"
        case .hookWait: return "hourglass"
        case .hookDeny: return "hand.raised.fill"
        case .guardStart, .guardStop: return "power"
        case .mode: return "slider.horizontal.3"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
    var color: Color {
        switch kind {
        case .throttleStart, .critical, .hookDeny: return Neon.red
        case .throttleEnd, .criticalEnd: return Neon.green
        case .hot, .hookWait, .warning: return Neon.amber
        case .boost: return Neon.cyan
        case .boostSkip, .learn, .profile, .cap, .guardStart, .guardStop, .mode: return .secondary
        }
    }
}

enum DayLog {
    static let path = "/var/log/cool42.log"
    static let maxShown = 20
    static let tailBytes: UInt64 = 1 << 20

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// 讀 log 檔尾，只留今天的行
    static func todayLines(path: String = path, day: String = Snapshot.Stats.today()) -> [Substring] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        let start = end > tailBytes ? end - tailBytes : 0
        try? h.seek(toOffset: start)
        guard let d = try? h.readToEnd(), let s = String(data: d, encoding: .utf8) ?? String(data: d.dropFirst(4), encoding: .utf8) else { return [] }
        let prefix = day + " "
        return s.split(separator: "\n").filter { $0.hasPrefix(prefix) }
    }

    private static func firstInt(_ s: Substring, after marker: String) -> Int? {
        guard let r = s.range(of: marker) else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
    /// 「78°C」這種：找第一個「數字°C」
    private static func celsius(_ s: Substring) -> Int? {
        guard let r = s.range(of: "°C") else { return nil }
        let before = s[..<r.lowerBound]
        let digits = before.reversed().prefix { $0.isNumber }
        return Int(String(digits.reversed()))
    }

    /// log 行 → 事件（純函式，文字依目前介面語言組好）。等級 ok↔warm、每輪轉速、交還自動這類高頻行不收
    static func parse(_ lines: [Substring]) -> [DayEvent] {
        var out: [DayEvent] = []
        var lastMode: String? = nil
        for line in lines {
            guard line.count > 20, let t = stamp.date(from: String(line.prefix(19))) else { continue }
            let m = line.dropFirst(20)
            if m.hasPrefix(GuardLogPattern.throttleStart) {
                var reasons: [String] = []
                if m.contains(GuardLogPattern.clock) { reasons.append(L("時脈")) }
                else if let r = m.range(of: "pressure ") {
                    let p = String(m[r.upperBound...].prefix { $0.isLetter })
                    if p != "Nominal" && !p.isEmpty { reasons.append(pressureDisplayName(p)) }
                }
                if let g = firstInt(m, after: "GPU CLTM "), g > 5 { reasons.append(L("GPU限頻%ld%%", g)) }
                out.append(DayEvent(time: t, kind: .throttleStart,
                                    text: reasons.isEmpty ? L("開始降頻") : L("開始降頻（%@）", reasons.joined(separator: " · "))))
            } else if m.hasPrefix(GuardLogPattern.throttleEnd) {
                let mhz = firstInt(m, after: "P-core ") ?? 0
                out.append(DayEvent(time: t, kind: .throttleEnd, text: mhz >= 100 ? L("降頻結束 · P-core回到%.2f GHz", Double(mhz) / 1000) : L("降頻結束")))
            } else if m.hasPrefix(GuardLogPattern.levelChange) {
                // 等級 hot → critical（🔴 101°C …）
                let parts = m.dropFirst(GuardLogPattern.levelChange.count).split(separator: " ", maxSplits: 3)
                guard parts.count >= 3 else { continue }
                let from = String(parts[0]), to = String(parts[2].prefix { $0.isLetter })
                let c = celsius(m) ?? 0
                if to == "critical" { out.append(DayEvent(time: t, kind: .critical, text: L("%ld°C，進入危險線，hook會擋下工作", c))) }
                else if to == "hot" && from != "critical" { out.append(DayEvent(time: t, kind: .hot, text: L("%ld°C，進入過熱", c))) }
                else if from == "critical" { out.append(DayEvent(time: t, kind: .criticalEnd, text: L("%ld°C，離開危險線", c))) }
            } else if m.hasPrefix(GuardLogPattern.boostEarlyEnd) {
                // 接到最近一筆預熱上，不另開一行
                if let i = out.lastIndex(where: { $0.kind == .boost }), var b = out[i].boost, let secs = firstInt(m, after: GuardLogPattern.colon) {
                    b.early += 1; b.lastEarlySecs = secs
                    out[i].boost = b; out[i].text = b.text
                }
            } else if m.hasPrefix(GuardLogPattern.boostEscalate) {
                // 「預熱加碼 3000 rpm：72°C…」→ 最近一筆預熱改成加碼後的轉速
                if let i = out.lastIndex(where: { $0.kind == .boost }), var b = out[i].boost, let rpm = firstInt(m, after: GuardLogPattern.boostEscalate + " ") {
                    b.rpm = max(b.rpm, rpm)
                    out[i].boost = b; out[i].text = b.text
                }
            } else if m.hasPrefix(GuardLogPattern.boostSkip) {
                let note = between(m, GuardLogPattern.colon, GuardLogPattern.skipEnd) ?? ""
                if let i = out.lastIndex(where: { $0.kind == .boostSkip }), var b = out[i].boost, b.note == note, t.timeIntervalSince(b.last) < 600 {
                    b.count += 1; b.last = t
                    out[i].boost = b; out[i].text = b.text; out[i].time = t
                } else {
                    let b = DayEvent.Boost(rpm: 0, note: note, first: t, last: t, skipped: true)
                    out.append(DayEvent(time: t, kind: .boostSkip, text: b.text, boost: b))
                }
            } else if m.hasPrefix(GuardLogPattern.boostLearned) {
                let k = between(m, GuardLogPattern.boostLearned, GuardLogPattern.learnedEnd) ?? ""
                out.append(DayEvent(time: t, kind: .learn, text: L("學到：%@連續3次都不像重工作，24小時內不預熱", k)))
            } else if m.hasPrefix(GuardLogPattern.boostResume) {
                let ks = between(m, GuardLogPattern.colon, GuardLogPattern.paren) ?? ""
                out.append(DayEvent(time: t, kind: .learn, text: L("恢復預熱：%@", ks.replacingOccurrences(of: GuardLogPattern.listSep, with: L("、")))))
            } else if m.hasPrefix(GuardLogPattern.boostLearnWarn) {
                out.append(DayEvent(time: t, kind: .warning, text: L("預熱學習的暫停時間異常，已清掉")))
            } else if m.hasPrefix(GuardLogPattern.boost) {
                let rpm = firstInt(m, after: GuardLogPattern.boost) ?? 0
                let note = m.range(of: GuardLogPattern.colon, options: .backwards).map { String(m[$0.upperBound...]) } ?? ""
                // 同關鍵字、距上一次不到 10 分鐘 → 併進去（不看轉速：加碼後被延長的也是同一波）
                if let i = out.lastIndex(where: { $0.kind == .boost }), var b = out[i].boost,
                   b.note == note, t.timeIntervalSince(b.last) < 600 {
                    b.count += 1; b.last = t; b.rpm = max(b.rpm, rpm)
                    out[i].boost = b; out[i].text = b.text; out[i].time = t
                } else {
                    let b = DayEvent.Boost(rpm: rpm, note: note, first: t, last: t)
                    out.append(DayEvent(time: t, kind: .boost, text: b.text, boost: b))
                }
            } else if m.hasPrefix(GuardLogPattern.profile) {
                let name = between(m, GuardLogPattern.profile, GuardLogPattern.profileEnd) ?? ""
                if m.contains(GuardLogPattern.profileOn) {
                    out.append(DayEvent(time: t, kind: .profile, text: L("情境「%@」生效", name)))
                } else if m.contains(GuardLogPattern.profileOff) {
                    out.append(DayEvent(time: t, kind: .profile, text: L("情境「%@」結束，回到基本設定", name)))
                }
            } else if m.hasPrefix(GuardLogPattern.cap) {
                let rpm = firstInt(m, after: GuardLogPattern.cap) ?? 0
                if m.contains(" rpm " + GuardLogPattern.capPause) {
                    out.append(DayEvent(time: t, kind: .cap, text: L("噪音上限%ld rpm暫停：溫度高或降頻，風扇不受限", rpm)))
                } else if m.contains(" rpm " + GuardLogPattern.capResume) {
                    out.append(DayEvent(time: t, kind: .cap, text: L("噪音上限%ld rpm恢復", rpm)))
                }
            } else if m.hasPrefix(GuardLogPattern.configKeysGone) {
                out.append(DayEvent(time: t, kind: .warning, text: L("設定檔裡的上限或情境規則不見了（舊版面板按了套用？）")))
            } else if m.hasPrefix(GuardLogPattern.guardStart) {
                out.append(DayEvent(time: t, kind: .guardStart, text: L("guard啟動")))
            } else if m.hasPrefix(GuardLogPattern.guardStop) {
                out.append(DayEvent(time: t, kind: .guardStop, text: L("guard結束")))
            } else if m.hasPrefix(GuardLogPattern.reload) {
                // 只記模式真的換了的那幾次（改曲線點、音檔不算）
                let mode = firstWord(m, after: GuardLogPattern.mode)
                if let mode, mode != (lastMode ?? "curve") {
                    out.append(DayEvent(time: t, kind: .mode, text: L("風扇模式改成「%@」", modeDisplayName(mode))))
                }
                lastMode = mode ?? lastMode
            } else if m.hasPrefix(GuardLogPattern.sensorFault) {
                out.append(DayEvent(time: t, kind: .warning, text: L("感測器讀取不完整")))
            } else if m.hasPrefix(GuardLogPattern.configFail) {
                out.append(DayEvent(time: t, kind: .warning, text: L("設定檔解析失敗，guard保留舊設定")))
            } else if m.hasPrefix(GuardLogPattern.watchdog) {
                out.append(DayEvent(time: t, kind: .warning, text: L("guard卡住，已自動重啟")))
            } else if m.hasPrefix(GuardLogPattern.macsFanControl) {
                out.append(DayEvent(time: t, kind: .warning, text: L("Macs Fan Control在執行，會互搶風扇")))
            }
        }
        return out
    }

    /// a 與 b 之間的字（去頭尾空白）
    private static func between(_ s: Substring, _ a: String, _ b: String) -> String? {
        guard let r = s.range(of: a) else { return nil }
        let rest = s[r.upperBound...]
        let end = rest.range(of: b)?.lowerBound ?? rest.endIndex
        let v = rest[..<end].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    private static func firstWord(_ s: Substring, after marker: String) -> String? {
        guard let r = s.range(of: marker) else { return nil }
        let w = s[r.upperBound...].prefix { $0.isLetter }
        return w.isEmpty ? nil : String(w)
    }
}

/// 風扇模式 → 介面用語（和控制卡的 segmented 同一組字）
func modeDisplayName(_ mode: String) -> String {
    switch mode {
    case "curve": return L("曲線")
    case "fixed": return L("固定")
    case "auto": return L("自動")
    default: return mode
    }
}

/// thermal pressure 原始值（powermetrics 英文）→ 介面用語。英文介面維持 macOS 原字；對不上的值原樣顯示
func pressureDisplayName(_ raw: String?) -> String {
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

extension Snapshot {
    /// 為什麼算降頻（一個詞）：pressure 非 Nominal 用 pressure；pressure 仍 Nominal 但 guard 判定時脈降頻就寫「時脈」；
    /// 只有 GPU 被 CLTM 限制時寫 GPU。以前一律寫 pressure 的中文，時脈降頻時會出現「降頻中（正常）」
    var throttleReason: String {
        if let p = thermalPressure, p != "Nominal" { return pressureDisplayName(p) }
        if clockThrottled == true { return L("時脈") }
        if gpuThrottling { return L("GPU限頻%ld%%", Int((gpuThrottlePercent ?? 0).rounded())) }
        return pressureDisplayName(thermalPressure)
    }
}

/// hook 等待／擋下的時間點：guard 不寫 log，面板看今日統計的增量記下來（存 UserDefaults，只留今天）
struct HookMarks {
    static let key = "timeline.hookMarks"
    private var base: (date: String, waits: Int, denies: Int)? = nil

    /// 每輪呼叫；有新增就記一筆（同一輪多次合併成一筆，n 次）
    mutating func observe(_ st: Snapshot.Stats?, now: Date = Date()) {
        guard let st else { return }
        defer { base = (st.date, st.hookWaits, st.hookDenies) }
        guard let b = base, b.date == st.date else { return }
        let dw = st.hookWaits - b.waits, dd = st.hookDenies - b.denies
        guard dw > 0 || dd > 0 else { return }
        var marks = Self.load().filter { Calendar.current.isDateInToday(Date(timeIntervalSince1970: $0.t)) }
        if dw > 0 { marks.append(.init(t: now.timeIntervalSince1970, k: "wait", n: dw)) }
        if dd > 0 { marks.append(.init(t: now.timeIntervalSince1970, k: "deny", n: dd)) }
        Self.save(Array(marks.suffix(200)))
    }

    struct Mark: Codable { var t: Double; var k: String; var n: Int }
    static func load() -> [Mark] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Mark].self, from: d)) ?? []
    }
    static func save(_ m: [Mark]) {
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func todayEvents() -> [DayEvent] {
        load().filter { Calendar.current.isDateInToday(Date(timeIntervalSince1970: $0.t)) }.map { m in
            let t = Date(timeIntervalSince1970: m.t)
            if m.k == "deny" { return DayEvent(time: t, kind: .hookDeny, text: m.n > 1 ? L("AI指令被擋下（%ld次）", m.n) : L("AI指令被擋下")) }
            return DayEvent(time: t, kind: .hookWait, text: m.n > 1 ? L("AI指令等降頻結束才執行（%ld次）", m.n) : L("AI指令等降頻結束才執行"))
        }
    }
}

// MARK: - 畫面

extension PanelView {
    /// 「今天」卡：收合時標題列就有摘要（幾次降頻、幾次預熱），展開才列事件
    var todayCard: some View {
        let ev = monitor.todayEvents
        // 次數從完整清單算（todayEvents 可能只列 20 件），預熱次數是併起來的每一行的 count 加總
        let throttles = monitor.todayThrottles
        let boosts = monitor.todayBoosts
        return DisclosureGroup(isExpanded: Binding(get: { monitor.showToday }, set: { monitor.showToday = $0 })) {
            VStack(alignment: .leading, spacing: 5) {
                if ev.isEmpty {
                    Text(L("今天還沒有降頻、過熱或預熱。")).font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(ev) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: Self.hm.string(from: e.time)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: Self.hmWidth, alignment: .leading)
                            Image(systemName: e.symbol).font(.caption2).foregroundStyle(e.color).frame(width: 14)
                            Text(verbatim: e.text).font(.caption2).foregroundStyle(.primary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if monitor.totalToday > ev.count {
                        Text(L("只列%ld件（降頻、過熱優先），完整內容看記錄檔。", DayLog.maxShown)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle").font(.caption).foregroundStyle(.secondary)
                Text(L("今天")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(verbatim: todaySummary(throttles: throttles, boosts: boosts, total: max(ev.count, monitor.totalToday)))
                    .font(.caption2.monospacedDigit()).foregroundStyle(throttles > 0 ? Neon.red : Color.secondary).lineLimit(1)
            }
        }
        .neonCard(padding: 8)
    }

    func todaySummary(throttles: Int, boosts: Int, total: Int) -> String {
        if total == 0 { return L("沒有事件") }
        if throttles > 0 { return L("降頻%ld次 · 共%ld件", throttles, total) }
        if boosts > 0 { return L("預熱%ld次 · 共%ld件", boosts, total) }
        return L("共%ld件", total)
    }

    /// 時:分，跟系統地區的 12／24 小時制（英文介面顯示 11:00 PM、繁中顯示 23:00）
    static let hm: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("jmm"); return f }()
    /// 時間欄寬：12 小時制多了 AM／PM（英文 a、繁中「上午／晚上」是 B）
    static var hmWidth: CGFloat { hm.dateFormat.contains(where: { "aBb".contains($0) }) ? 58 : 36 }
}
