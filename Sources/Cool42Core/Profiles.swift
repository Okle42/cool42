import Foundation
import CSMC

// MARK: - 情境自動切換與噪音上限（純邏輯＋guard 取情境用的小工具；guard、面板、測試共用）

/// 一條情境規則：`when` 的條件全部成立才算符合（有寫的才看），依陣列順序第一條符合的生效，都不符合就用基本設定。
/// 動作：換成內建預設曲線（quiet / balanced / performance），和／或設轉速上限 maxRPM（取代基本設定的 maxRPM）。
///
///     {"name": "夜間安靜", "when": {"from": "23:00", "to": "07:00"}, "curve": "quiet", "maxRPM": 2200}
///     {"name": "剪片", "when": {"apps": ["Final Cut Pro", "ffmpeg"]}, "curve": "performance"}
///     {"name": "專注", "when": {"focus": true}, "maxRPM": 2000}
public struct Profile: Codable, Equatable {
    public struct When: Codable, Equatable {
        /// 時段（本地時間 HH:mm）。from > to 表示跨午夜，例如 23:00–07:00；區間含頭不含尾
        public var from: String? = nil
        public var to: String? = nil
        /// 任一個程序名稱在跑就成立（不分大小寫、可寫「Xcode.app」）
        public var apps: [String]? = nil
        /// 專注模式是否開啟（面板讀到後寫旗標檔給 guard；讀不到＝不成立）
        public var focus: Bool? = nil
        public init(from: String? = nil, to: String? = nil, apps: [String]? = nil, focus: Bool? = nil) {
            self.from = from; self.to = to; self.apps = apps; self.focus = focus
        }
    }
    public var name: String
    public var when: When
    /// 內建預設曲線 id：quiet / balanced / performance（也收「安靜／均衡／強力」）
    public var curve: String? = nil
    public var maxRPM: Double? = nil

    public init(name: String, when: When, curve: String? = nil, maxRPM: Double? = nil) {
        self.name = name; self.when = when; self.curve = curve; self.maxRPM = maxRPM
    }

    public static let maxCount = 16
    public static let maxNameLength = 40

    public var hasTime: Bool { when.from != nil || when.to != nil }
    public var hasApps: Bool { !(when.apps ?? []).isEmpty }
    public var hasFocus: Bool { when.focus != nil }

    public func validate() throws {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.count <= Profile.maxNameLength,
              !n.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Cool42Error.usage("profiles：name 要 1–\(Profile.maxNameLength) 字、不能有換行（收到「\(name)」）")
        }
        guard hasTime || hasApps || hasFocus else { throw Cool42Error.usage("profiles「\(name)」：when 至少要有一個條件（from/to、apps、focus）") }
        if hasTime {
            guard let f = when.from.flatMap(TimeOfDay.minutes), let t = when.to.flatMap(TimeOfDay.minutes) else {
                throw Cool42Error.usage("profiles「\(name)」：from / to 要成對、格式 HH:mm（例如 23:00）")
            }
            guard f != t else { throw Cool42Error.usage("profiles「\(name)」：from 與 to 不能相同") }
        }
        if let apps = when.apps {
            guard !apps.isEmpty, apps.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw Cool42Error.usage("profiles「\(name)」：apps 不能是空的或有空白名稱")
            }
        }
        guard curve != nil || maxRPM != nil else { throw Cool42Error.usage("profiles「\(name)」：至少要有 curve 或 maxRPM 其中一個動作") }
        if let c = curve, Config.presetCurve(c) == nil {
            throw Cool42Error.usage("profiles「\(name)」：curve 必須是 \(Config.presetIDs.joined(separator: "/"))，收到 \(c)")
        }
        if let m = maxRPM, !(m > 0) { throw Cool42Error.usage("profiles「\(name)」：maxRPM 必須大於 0") }
    }

    /// 這條規則現在符合嗎
    public func matches(_ ctx: ProfileContext) -> Bool {
        if hasTime {
            guard let f = when.from.flatMap(TimeOfDay.minutes), let t = when.to.flatMap(TimeOfDay.minutes),
                  TimeOfDay.contains(ctx.minuteOfDay, from: f, to: t) else { return false }
        }
        if let apps = when.apps, !apps.isEmpty {
            guard apps.contains(where: { ProcList.matches(rule: $0, running: ctx.runningApps) }) else { return false }
        }
        if let want = when.focus {
            guard let now = ctx.focus, now == want else { return false }   // 讀不到專注狀態＝不成立
        }
        return true
    }

    /// log 用的一句話（guard 的 log 是繁中）
    public var summary: String {
        var cond: [String] = []
        if let f = when.from, let t = when.to { cond.append("\(f)–\(t)") }
        if let a = when.apps, !a.isEmpty { cond.append(a.joined(separator: "/") + " 在跑") }
        if let fo = when.focus { cond.append(fo ? "專注模式開啟" : "專注模式關閉") }
        var act: [String] = []
        if let c = curve { act.append("曲線 \(Config.presetID(c) ?? c)") }
        if let m = maxRPM { act.append("上限 \(Int(m)) rpm") }
        return cond.joined(separator: "、") + "；" + act.joined(separator: "、")
    }
}

/// 規則評估要的外部狀態（guard 每輪組一次；測試直接建）
public struct ProfileContext {
    /// 本地時間 0–1439
    public var minuteOfDay: Int
    /// 在跑的程序名稱（小寫）
    public var runningApps: Set<String>
    /// 專注模式：nil = 不知道（面板沒在跑、沒授權、旗標過期）
    public var focus: Bool?

    public init(minuteOfDay: Int, runningApps: Set<String> = [], focus: Bool? = nil) {
        self.minuteOfDay = minuteOfDay; self.runningApps = runningApps; self.focus = focus
    }
    public init(now: Date, calendar: Calendar = .current, runningApps: Set<String> = [], focus: Bool? = nil) {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        self.init(minuteOfDay: (c.hour ?? 0) * 60 + (c.minute ?? 0), runningApps: runningApps, focus: focus)
    }

    /// guard 用：只有規則真的用到才列程序、讀專注旗標（沒有 apps 規則就完全不列舉程序）
    public static func live(for config: Config, now: Date = Date()) -> ProfileContext {
        let needApps = config.profiles.contains { $0.hasApps }
        let needFocus = config.profiles.contains { $0.hasFocus }
        // apps 規則只看目前登入主控台的使用者自己的程序；登入畫面（沒有主控台使用者）時 apps 規則一律不成立
        let apps: Set<String> = needApps ? (FocusFlag.consoleUser().map { ProcList.runningNames(owner: $0.uid) } ?? []) : []
        return ProfileContext(now: now, runningApps: apps,
                              focus: needFocus ? FocusFlag.readForConsoleUser(now: now) : nil)
    }
}

public enum Profiles {
    /// 依序第一條符合的規則；都不符合回 nil（用基本設定）
    public static func active(_ profiles: [Profile], _ ctx: ProfileContext) -> Profile? {
        profiles.first { $0.matches(ctx) }
    }
}

public enum TimeOfDay {
    /// "23:00" / "7:05" → 分鐘數；格式不對回 nil
    public static func minutes(_ s: String) -> Int? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 2, (1...2).contains(parts[0].count),
              let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
    public static func string(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60 % 24, minutes % 60) }

    /// [from, to)；from > to 是跨午夜
    public static func contains(_ minute: Int, from: Int, to: Int) -> Bool {
        from < to ? (minute >= from && minute < to) : (minute >= from || minute < to)
    }
}

// MARK: - 噪音上限

/// guard 所有目標轉速（曲線、固定、預熱）都夾在 maxRPM 以下；**安全例外**：hot（含等級遲滯）、critical 或降頻中忽略上限。
/// hot 就要立即全力散熱，不能被上限夾住（95–107°C 之間夾在低轉速正是最該避免的情況）。
/// 夾完之後 guard 仍會夾在韌體 F0Mn–F0Mx 之間，所以上限比最低轉速還低時以最低轉速為準
public enum RPMCap {
    public static func suspended(critical: Bool, hot: Bool, throttling: Bool) -> Bool { critical || hot || throttling }

    public static func clamp(_ rpm: Double, maxRPM: Double?, suspended: Bool) -> Double {
        guard let cap = maxRPM, !suspended else { return rpm }
        return min(rpm, cap)
    }

    public static func clamp(_ rpm: Double, maxRPM: Double?, critical: Bool, hot: Bool, throttling: Bool) -> Double {
        clamp(rpm, maxRPM: maxRPM, suspended: suspended(critical: critical, hot: hot, throttling: throttling))
    }
}

/// 上限暫停的閂鎖（有遲滯）：hot／critical／降頻任一成立就暫停；要控制溫度低於 hotTemp − levelHysteresis、
/// 而且**連續** releaseRounds 輪都沒有再觸發，才恢復上限。
/// 沒有遲滯的話，重載下會變成「上限 → 升溫降頻 → 暫停全速 → 頻率回來 → 45 秒降回上限 → 再降頻」的一分鐘循環
public struct CapLatch: Equatable {
    public private(set) var suspended = false
    public private(set) var calmRounds = 0
    public init() {}

    /// 每輪呼叫一次；trigger = hot／critical／降頻任一成立，temp 用原始控制溫度。回傳這輪是否暫停上限
    @discardableResult
    public mutating func update(trigger: Bool, temp: Double, releaseBelow: Double, releaseRounds: Int) -> Bool {
        if trigger { suspended = true; calmRounds = 0; return true }
        guard suspended else { calmRounds = 0; return false }
        calmRounds = temp < releaseBelow ? calmRounds + 1 : 0
        if calmRounds >= max(1, releaseRounds) { suspended = false; calmRounds = 0 }
        return suspended
    }

    /// 沒有設上限時歸零
    public mutating func reset() { suspended = false; calmRounds = 0 }
}

// MARK: - 預設曲線（面板的「安靜／均衡／強力」、情境規則的 curve 共用同一份）

extension Config {
    public static let presetIDs = ["quiet", "balanced", "performance"]
    public static let presetCurves: [String: [Point]] = [
        "quiet": [.init(temp: 65, rpm: 1000), .init(temp: 80, rpm: 1600), .init(temp: 90, rpm: 2400), .init(temp: 95, rpm: 3400), .init(temp: 99, rpm: 4900)],
        "balanced": Config().curve,   // A/B 實測：重載 87°C / 3150 rpm，不降頻
        "performance": [.init(temp: 55, rpm: 1000), .init(temp: 65, rpm: 1800), .init(temp: 75, rpm: 3000), .init(temp: 85, rpm: 4200), .init(temp: 90, rpm: 4900)],
    ]
    static let presetAliases = ["安靜": "quiet", "均衡": "balanced", "強力": "performance", "silent": "quiet", "perf": "performance"]

    /// 名稱正規化成 id（大小寫不拘；中文別名也收）；不認得回 nil
    public static func presetID(_ name: String) -> String? {
        let k = name.trimmingCharacters(in: .whitespaces)
        if presetCurves[k.lowercased()] != nil { return k.lowercased() }
        return presetAliases[k] ?? presetAliases[k.lowercased()]
    }
    public static func presetCurve(_ name: String) -> [Point]? { presetID(name).flatMap { presetCurves[$0] } }

    /// 套用情境規則後的有效設定：curve 換成預設曲線、maxRPM 取代基本設定的（規則沒寫就沿用基本設定）
    public func applying(_ p: Profile?) -> Config {
        guard let p else { return self }
        var c = self
        if let name = p.curve, let pts = Config.presetCurve(name) { c.curve = pts }
        if let m = p.maxRPM { c.maxRPM = m }
        return c
    }
}

// MARK: - 程序名稱（apps 規則）

public enum ProcList {
    /// 在跑的程序名稱（小寫）。proc_name 是 BSD 名稱，最長約 32 字元。
    /// owner 有給就只收那個 uid 的程序：root 看得到所有帳號的程序，別的本機帳號跑一個叫 zoom 的程序不該觸發你的規則
    public static func runningNames(owner: uid_t? = nil) -> Set<String> {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(cp_list_pids(&pids, Int32(pids.count)))
        guard count > 0 else { return [] }
        var out = Set<String>()
        var buf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(count) where pid > 0 {
            if let owner {
                var uid: uid_t = 0
                guard cp_uid(pid, &uid) == 0, uid == owner else { continue }
            }
            if cp_name(pid, &buf, Int32(buf.count)) == 0 { out.insert(String(cString: buf).lowercased()) }
        }
        return out
    }

    /// 規則名 vs 程序名：去頭尾空白、去「.app」、不分大小寫、完全相同；
    /// 程序名被截斷（≥ 15 字元且是規則名的開頭）也算
    public static func matches(rule: String, running: Set<String>) -> Bool {
        var r = rule.trimmingCharacters(in: .whitespaces).lowercased()
        if r.hasSuffix(".app") { r.removeLast(4) }
        guard !r.isEmpty else { return false }
        if running.contains(r) { return true }
        guard r.count > 15 else { return false }
        return running.contains { $0.count >= 15 && r.hasPrefix($0) }
    }
}

// MARK: - 專注模式旗標（面板 → guard）

/// guard 是 root 常駐程式，拿不到專注模式：Apple 唯一公開的 API（INFocusStatusCenter）要在使用者 session 的 app 裡、經使用者授權；
/// ~/Library/DoNotDisturb/DB 的檔案格式沒公開、排程開啟的專注模式也不一定記在裡面，不拿來猜。
/// 所以由面板讀、寫這個小檔到使用者自己的 ~/.config/cool42/focus.json，guard 讀「目前登入主控台的使用者」那份。
/// 這是使用者層的輸入：最多只能讓符合 focus 條件的規則生效（使用者自己設的曲線／上限），而且上限在 hot、critical、降頻時一律失效
public struct FocusFlag: Codable, Equatable {
    public var focused: Bool
    public var time: Date
    public init(focused: Bool, time: Date = Date()) { self.focused = focused; self.time = time }

    /// 面板至少每這麼多秒重寫一次；超過 staleAfter 沒更新（面板結束、當掉）就當作不知道
    public static let refreshSeconds: Double = 60
    public static let staleAfter: Double = 180
    public static let maxBytes = 1024

    public static func path(home: String) -> String { home + "/.config/cool42/focus.json" }

    /// 面板用（使用者權限、寫自己的家目錄）
    public func write(home: String = NSHomeDirectory()) throws {
        let p = FocusFlag.path(home: home)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: URL(fileURLWithPath: p), options: .atomic)
    }

    /// 讀旗標：不 follow symlink、不開 FIFO、只收小的普通檔；ownerUID 有給就要是那個使用者的檔；過期回 nil
    public static func read(path: String, ownerUID: uid_t? = nil, now: Date = Date()) -> Bool? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxBytes else { return nil }
        if let ownerUID, st.st_uid != ownerUID { return nil }
        var buf = [UInt8](repeating: 0, count: maxBytes)
        let n = Darwin.read(fd, &buf, maxBytes)
        guard n > 0 else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let f = try? dec.decode(FocusFlag.self, from: Data(buf.prefix(n))) else { return nil }
        let age = now.timeIntervalSince(f.time)
        guard age <= staleAfter, age >= -60 else { return nil }
        return f.focused
    }

    /// 目前登入主控台的使用者（/dev/console 的擁有者）；登入畫面（root）回 nil
    public static func consoleUser() -> (uid: uid_t, home: String)? {
        var st = stat()
        guard stat("/dev/console", &st) == 0, st.st_uid != 0, let pw = getpwuid(st.st_uid), let dir = pw.pointee.pw_dir else { return nil }
        return (st.st_uid, String(cString: dir))
    }

    public static func readForConsoleUser(now: Date = Date()) -> Bool? {
        guard let u = consoleUser() else { return nil }
        return read(path: path(home: u.home), ownerUID: u.uid, now: now)
    }
}
