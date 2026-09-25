import Foundation

// MARK: - 安靜優先：接管去抖、預熱漸進、預熱學習（純邏輯，guard 與測試共用）

/// 接管去抖。2026-09-20～25 的 log：一天交還自動 59～212 次，典型是單輪尖峰 73°C 接管 → 1340 rpm → 36 秒後 49°C 交還，
/// 風扇跟著「呼吸」。從交還自動的狀態重新接管，要控制溫度（**原始值**，不是 EMA）連續 N 輪都在接管門檻以上。
///
/// 為什麼用「連續 N 輪」而不是「30 秒視窗平均」：
/// - 單輪 90°C 的尖峰就能把 30 秒平均拉過 55°C，平均擋不住最常見的那種尖峰；連續條件一輪低就歸零
/// - 延遲固定、可預測（預設 10 秒 = 2 輪），真的重工作最多晚 10 秒；平均法在緩升負載下反而晚更久
/// - 用原始溫度：EMA 降溫係數 0.2，一輪 73°C 之後平滑值會在門檻以上停留 15～20 秒，用它等於沒去抖
///
/// 安全例外：溫度 ≥ hotTemp、等級仍在 hot 以上（遲滯中）或正在／可能在降頻，立刻接管，不等
public struct TakeoverGate {
    public private(set) var aboveRounds = 0
    public init() {}

    /// takeoverHoldSeconds 換算成輪數（向上取整；0 = 不去抖）
    public static func requiredRounds(holdSeconds: Double, interval: Double) -> Int {
        guard holdSeconds > 0, interval > 0 else { return 0 }
        return Int((holdSeconds / interval).rounded(.up))
    }

    /// 在「目前交還自動、曲線這輪想接管」時每輪呼叫一次；回 true = 現在接管
    /// levelHot = 上一輪的等級（含遲滯）≥ hot；throttling 在頻率資料過期時呼叫端應傳 true（不知道就當可能在降頻）
    public mutating func allow(temp: Double, threshold: Double, hotTemp: Double, levelHot: Bool = false, throttling: Bool, requiredRounds: Int) -> Bool {
        if requiredRounds <= 0 || temp >= hotTemp || levelHot || throttling { aboveRounds = 0; return true }
        guard temp >= threshold else { aboveRounds = 0; return false }
        aboveRounds += 1
        if aboveRounds >= requiredRounds { aboveRounds = 0; return true }
        return false
    }

    /// 已經接管、或曲線本來就不想接管時歸零
    public mutating func reset() { aboveRounds = 0 }
}

/// 預熱漸進：先用 boostStartRPM，溫度真的起來了才加碼到 boostRPM。
/// 09-20～25 的 log 按波次算 82% 的預熱 30 秒後仍只有 44–52°C（指令根本不重），那 30 秒一律轟 3000 rpm 是最吵、最沒必要的一段
public enum BoostRamp {
    /// 升溫速率的觀察窗（秒）：boostEscalateRise 是「這麼多秒內升幾度」
    public static let riseWindow: Double = 10

    /// 預熱起始轉速；boostStartRPM = 0 或 ≥ boostRPM 表示不漸進，直接 boostRPM
    public static func startRPM(_ c: Config) -> Double {
        c.boostStartRPM > 0 ? min(c.boostStartRPM, c.boostRPM) : c.boostRPM
    }

    /// 要不要加碼：控制溫度 ≥ escalateTemp，或與 riseWindow 秒內的最低溫相比升了 ≥ escalateRise。
    /// recent 是本輪之前的 (時間, 控制溫度) 樣本
    public static func shouldEscalate(now: Date, temp: Double, recent: [(time: Date, temp: Double)],
                                      escalateTemp: Double, escalateRise: Double) -> Bool {
        if temp >= escalateTemp { return true }
        let inWindow = recent.filter { now.timeIntervalSince($0.time) <= riseWindow + 0.5 }.map(\.temp)
        guard let low = inWindow.min() else { return false }
        return temp - low >= escalateRise
    }
}

/// 預熱學習：以 boostCommands 裡命中的關鍵字為單位，記最近幾次預熱是不是「不像重工作」（30 秒後溫度仍在曲線起點以下）。
/// 連續 streak 次都是 → 暫停替這個關鍵字預熱 pauseSeconds，時間到自動恢復。
/// 狀態由 root 的 guard 寫在 /var/db/cool42/（和 stats.json 同目錄、同樣 O_EXCL|O_NOFOLLOW 原子寫入）
public struct BoostLearner: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        /// 最近幾次預熱的結果，true = 不像重工作；舊到新
        public var recent: [Bool] = []
        public var pausedUntil: Date? = nil
        /// 最近一小時記過幾次（學習速率上限用；舊檔沒有這個鍵 = 空）
        public var recordedAt: [Date]? = nil
        public init(recent: [Bool] = [], pausedUntil: Date? = nil) { self.recent = recent; self.pausedUntil = pausedUntil }
    }
    public var entries: [String: Entry] = [:]
    public init() {}

    public static let streak = 3
    public static let pauseSeconds: Double = 24 * 3600
    public static let keepRecent = 5
    /// 事件備註是本機任何程式都能寫的，guard 只學 boostCommands 裡的關鍵字；再加一道上限，檔案不會無限長
    public static let maxKeywords = 64
    /// 每個關鍵字每小時最多記這麼多次結果：擋掉「閒置時狂丟事件，幾分鐘內就把關鍵字全學成不預熱」
    public static let maxRecordsPerHour = 6
    public static let maxFileBytes = 64 * 1024
    public static let path = "/var/db/cool42/boost-learn.json"

    /// 這個關鍵字目前是否暫停預熱；是的話回傳恢復時間
    public func pausedUntil(_ keyword: String, now: Date = Date()) -> Date? {
        guard let u = entries[keyword]?.pausedUntil, u > now else { return nil }
        return u
    }

    /// 清掉到期的暫停，回傳恢復預熱的關鍵字（guard 拿來記 log、存檔）
    public mutating func expire(now: Date = Date()) -> [String] {
        var resumed: [String] = []
        for (k, e) in entries {
            if let u = e.pausedUntil, u <= now { entries[k]?.pausedUntil = nil; resumed.append(k) }
        }
        return resumed.sorted()
    }

    /// 記一次預熱結果；回 true = 這次剛好湊滿 streak 次、開始暫停
    @discardableResult
    public mutating func record(_ keyword: String, notHeavy: Bool, now: Date = Date()) -> Bool {
        guard entries[keyword] != nil || entries.count < BoostLearner.maxKeywords else { return false }
        var e = entries[keyword] ?? Entry()
        if pausedUntil(keyword, now: now) != nil { return false }   // 暫停中不會有預熱，保險起見不動
        var times = (e.recordedAt ?? []).filter { now.timeIntervalSince($0) < 3600 && $0 <= now.addingTimeInterval(60) }
        guard times.count < BoostLearner.maxRecordsPerHour else { return false }   // 超過速率上限：這次不算
        times.append(now)
        e.recordedAt = times
        e.recent.append(notHeavy)
        if e.recent.count > BoostLearner.keepRecent { e.recent.removeFirst(e.recent.count - BoostLearner.keepRecent) }
        var paused = false
        if e.recent.count >= BoostLearner.streak, e.recent.suffix(BoostLearner.streak).allSatisfy({ $0 }) {
            e.pausedUntil = now.addingTimeInterval(BoostLearner.pauseSeconds)
            e.recent = []   // 恢復後重新累計，不會一恢復就因舊紀錄馬上又停
            paused = true
        }
        entries[keyword] = e
        return paused
    }

    /// 只學 config.boostCommands 裡的關鍵字（去頭尾空白比對）；其他備註（面板、手動丟的事件）不學
    public static func learnableKeyword(_ note: String?, config: Config) -> String? {
        guard let k = note?.trimmingCharacters(in: .whitespaces), !k.isEmpty,
              config.boostCommands.contains(where: { $0.trimmingCharacters(in: .whitespaces) == k }) else { return nil }
        return k
    }

    /// 讀狀態檔：不 follow symlink、只收 root 擁有的普通小檔（expectOwner 預設 0；測試傳自己的 uid）。
    /// 讀不到、不合規或 JSON 壞掉都退回空白狀態（最多就是重新學）
    public static func load(path: String = BoostLearner.path, expectOwner: uid_t? = 0) -> BoostLearner {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return BoostLearner() }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxFileBytes else { return BoostLearner() }
        if let expectOwner, st.st_uid != expectOwner { return BoostLearner() }
        var buf = [UInt8](repeating: 0, count: Int(st.st_size))
        let n = buf.isEmpty ? 0 : Darwin.read(fd, &buf, buf.count)
        guard n > 0 else { return BoostLearner() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(BoostLearner.self, from: Data(buf.prefix(n)))) ?? BoostLearner()
    }

    /// 暫停時間夾在 now + pauseSeconds 以內（系統時鐘往後跳過、或檔案被手動改過，就可能落在很遠的未來 = 永久不預熱）。
    /// 回傳被清掉的關鍵字，guard 拿來記 log
    @discardableResult
    public mutating func sanitize(now: Date = Date()) -> [String] {
        var cleared: [String] = []
        for (k, e) in entries {
            if let u = e.pausedUntil, u > now.addingTimeInterval(BoostLearner.pauseSeconds + 60) {
                entries[k]?.pausedUntil = nil; entries[k]?.recent = []; cleared.append(k)
            }
        }
        if entries.count > BoostLearner.maxKeywords {
            for k in entries.keys.sorted().dropFirst(BoostLearner.maxKeywords) { entries[k] = nil }
        }
        return cleared.sorted()
    }

    /// guard（root）用；和 Stats.persist 同樣的寫法：root 自己的真目錄、.tmp 以 O_EXCL|O_NOFOLLOW 建立再 rename
    public func save(path: String = BoostLearner.path) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        guard Snapshot.ensureDir((path as NSString).deletingLastPathComponent, mode: 0o755),
              let d = try? enc.encode(self) else { return }
        Snapshot.atomicWrite(d, to: path)
    }
}
