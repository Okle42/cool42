import XCTest
@testable import Cool42Core

/// 安靜優先：接管去抖、預熱漸進、預熱學習、新設定鍵
final class QuietTests: XCTestCase {
    let rounds = TakeoverGate.requiredRounds(holdSeconds: 10, interval: 5)   // 預設 = 2 輪

    // MARK: 接管去抖

    func testHoldSecondsToRounds() {
        XCTAssertEqual(rounds, 2)
        XCTAssertEqual(TakeoverGate.requiredRounds(holdSeconds: 0, interval: 5), 0)
        XCTAssertEqual(TakeoverGate.requiredRounds(holdSeconds: 12, interval: 5), 3)   // 向上取整，不會比設定的短
    }

    /// log 裡最常見的那種：單輪 73°C 尖峰，下一輪就回 49°C —— 不接管
    func testSpikeDoesNotTakeOver() {
        var g = TakeoverGate()
        XCTAssertFalse(g.allow(temp: 73, threshold: 55, hotTemp: 95, throttling: false, requiredRounds: rounds))
        XCTAssertFalse(g.allow(temp: 49, threshold: 55, hotTemp: 95, throttling: false, requiredRounds: rounds))
        XCTAssertEqual(g.aboveRounds, 0)   // 一輪低就歸零
        XCTAssertFalse(g.allow(temp: 80, threshold: 55, hotTemp: 95, throttling: false, requiredRounds: rounds))
    }

    func testSustainedHeatTakesOver() {
        var g = TakeoverGate()
        XCTAssertFalse(g.allow(temp: 70, threshold: 55, hotTemp: 95, throttling: false, requiredRounds: rounds))
        XCTAssertTrue(g.allow(temp: 72, threshold: 55, hotTemp: 95, throttling: false, requiredRounds: rounds))
    }

    func testHotOrThrottlingTakesOverImmediately() {
        var g = TakeoverGate()
        XCTAssertTrue(g.allow(temp: 96, threshold: 55, hotTemp: 95, throttling: false, requiredRounds: rounds))
        var g2 = TakeoverGate()
        XCTAssertTrue(g2.allow(temp: 60, threshold: 55, hotTemp: 95, throttling: true, requiredRounds: rounds))
    }

    /// 等級遲滯仍在 hot（溫度剛掉到 93°C）也立刻接管
    func testLevelHotTakesOverImmediately() {
        var g = TakeoverGate()
        XCTAssertTrue(g.allow(temp: 93, threshold: 55, hotTemp: 95, levelHot: true, throttling: false, requiredRounds: rounds))
    }

    func testZeroHoldKeepsOldBehaviour() {
        var g = TakeoverGate()
        XCTAssertTrue(g.allow(temp: 56, threshold: 55, hotTemp: 95, throttling: false, requiredRounds: 0))
    }

    // MARK: 預熱漸進

    func testBoostStartsLowAndEscalatesOnTemperature() {
        let c = Config()
        XCTAssertEqual(BoostRamp.startRPM(c), 2000)
        let now = Date()
        XCTAssertFalse(BoostRamp.shouldEscalate(now: now, temp: 55, recent: [(now.addingTimeInterval(-5), 50)], escalateTemp: 70, escalateRise: 10))
        XCTAssertTrue(BoostRamp.shouldEscalate(now: now, temp: 70, recent: [(now.addingTimeInterval(-5), 69)], escalateTemp: 70, escalateRise: 10))
    }

    func testBoostEscalatesOnFastRise() {
        let now = Date()
        let recent: [(time: Date, temp: Double)] = [(now.addingTimeInterval(-10), 48), (now.addingTimeInterval(-5), 53)]
        XCTAssertTrue(BoostRamp.shouldEscalate(now: now, temp: 59, recent: recent, escalateTemp: 70, escalateRise: 10))
        XCTAssertFalse(BoostRamp.shouldEscalate(now: now, temp: 57, recent: recent, escalateTemp: 70, escalateRise: 10))
        // 超過 10 秒的舊低溫不算（緩升不加碼）
        let old: [(time: Date, temp: Double)] = [(now.addingTimeInterval(-20), 40), (now.addingTimeInterval(-5), 55)]
        XCTAssertFalse(BoostRamp.shouldEscalate(now: now, temp: 60, recent: old, escalateTemp: 70, escalateRise: 10))
        XCTAssertFalse(BoostRamp.shouldEscalate(now: now, temp: 60, recent: [], escalateTemp: 70, escalateRise: 10))
    }

    func testBoostStartRPMZeroOrAboveFullMeansNoRamp() {
        var c = Config(); c.boostStartRPM = 0
        XCTAssertEqual(BoostRamp.startRPM(c), c.boostRPM)
        c.boostStartRPM = 4000
        XCTAssertEqual(BoostRamp.startRPM(c), c.boostRPM)   // 夾在 boostRPM 以下
    }

    // MARK: 預熱學習

    func testLearnerPausesAfterThreeLightBoostsAndResumesAfter24h() {
        var l = BoostLearner()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(l.record("pytest", notHeavy: true, now: t0))
        XCTAssertFalse(l.record("pytest", notHeavy: true, now: t0))
        XCTAssertNil(l.pausedUntil("pytest", now: t0))
        XCTAssertTrue(l.record("pytest", notHeavy: true, now: t0))
        XCTAssertEqual(l.pausedUntil("pytest", now: t0.addingTimeInterval(60)), t0.addingTimeInterval(24 * 3600))
        XCTAssertNotNil(l.pausedUntil("pytest", now: t0.addingTimeInterval(24 * 3600 - 1)))
        // 24 小時後恢復，而且紀錄清空：恢復後要再連續 3 次才會又停
        let later = t0.addingTimeInterval(24 * 3600 + 1)
        XCTAssertNil(l.pausedUntil("pytest", now: later))
        XCTAssertEqual(l.expire(now: later), ["pytest"])
        XCTAssertNil(l.entries["pytest"]?.pausedUntil)
        XCTAssertFalse(l.record("pytest", notHeavy: true, now: later))
        XCTAssertNil(l.pausedUntil("pytest", now: later))
    }

    func testLearnerNeedsConsecutiveLightBoosts() {
        var l = BoostLearner()
        let t = Date()
        l.record("swift build", notHeavy: true, now: t)
        l.record("swift build", notHeavy: true, now: t)
        l.record("swift build", notHeavy: false, now: t)   // 中間一次真的重 → 連續中斷
        XCTAssertFalse(l.record("swift build", notHeavy: true, now: t))
        XCTAssertFalse(l.record("swift build", notHeavy: true, now: t))
        XCTAssertTrue(l.record("swift build", notHeavy: true, now: t))
        XCTAssertNil(l.pausedUntil("make", now: t))   // 關鍵字各自獨立
    }

    func testLearnerOnlyLearnsConfiguredKeywordsAndCapsSize() {
        let c = Config()
        XCTAssertEqual(BoostLearner.learnableKeyword("swift build", config: c), "swift build")
        XCTAssertEqual(BoostLearner.learnableKeyword("make", config: c), "make")   // 設定裡是 "make "（帶空白）
        XCTAssertNil(BoostLearner.learnableKeyword("rm -rf /", config: c))
        XCTAssertNil(BoostLearner.learnableKeyword(nil, config: c))
        var l = BoostLearner()
        for i in 0..<(BoostLearner.maxKeywords + 10) { l.record("k\(i)", notHeavy: true) }
        XCTAssertEqual(l.entries.count, BoostLearner.maxKeywords)
    }

    func testLearnerRoundTripsThroughFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cool42-learn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("boost-learn.json").path
        var l = BoostLearner()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<3 { l.record("ffmpeg", notHeavy: true, now: t) }
        l.save(path: path)
        let back = BoostLearner.load(path: path, expectOwner: getuid())
        XCTAssertEqual(back, l)
        XCTAssertNotNil(back.pausedUntil("ffmpeg", now: t))
        XCTAssertEqual(BoostLearner.load(path: path + ".missing"), BoostLearner())   // 沒檔案 = 空白狀態
        // 擁有者不是 root（guard 預設要求）→ 不信，退回空白
        if getuid() != 0 { XCTAssertEqual(BoostLearner.load(path: path), BoostLearner()) }
        // symlink 不跟
        let link = dir.appendingPathComponent("link.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        XCTAssertEqual(BoostLearner.load(path: link, expectOwner: getuid()), BoostLearner())
    }

    /// 暫停時間在遠未來（時鐘跳過、檔案被改）：夾掉，恢復預熱
    func testLearnerSanitizeClampsFarFuturePause() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var l = BoostLearner()
        l.entries["ffmpeg"] = .init(recent: [true], pausedUntil: now.addingTimeInterval(365 * 24 * 3600))
        l.entries["pytest"] = .init(recent: [], pausedUntil: now.addingTimeInterval(3600))   // 正常範圍內，不動
        XCTAssertEqual(l.sanitize(now: now), ["ffmpeg"])
        XCTAssertNil(l.pausedUntil("ffmpeg", now: now))
        XCTAssertNotNil(l.pausedUntil("pytest", now: now))
    }

    /// 學習速率上限：同一個關鍵字一小時最多記 maxRecordsPerHour 次，狂丟事件湊不出暫停
    func testLearnerRateLimit() {
        var l = BoostLearner()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<BoostLearner.maxRecordsPerHour { l.record("cmake", notHeavy: false, now: t) }
        // 這一小時額度已滿：再多的「不像重工作」都不算
        for _ in 0..<5 { XCTAssertFalse(l.record("cmake", notHeavy: true, now: t.addingTimeInterval(60))) }
        XCTAssertNil(l.pausedUntil("cmake", now: t.addingTimeInterval(120)))
        // 一小時後額度恢復
        let later = t.addingTimeInterval(3601)
        l.record("cmake", notHeavy: true, now: later); l.record("cmake", notHeavy: true, now: later)
        XCTAssertTrue(l.record("cmake", notHeavy: true, now: later))
    }

    // MARK: 設定鍵

    func testNewKeysDefaultWhenAbsent() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"mode":"curve"}"#.utf8))
        XCTAssertEqual(c.takeoverHoldSeconds, 10)
        XCTAssertEqual(c.boostStartRPM, 2000)
        XCTAssertEqual(c.boostEscalateTemp, 70)
        XCTAssertEqual(c.boostEscalateRise, 10)
        XCTAssertTrue(c.boostLearn)
    }

    func testNewKeysDecode() throws {
        let json = #"{"takeoverHoldSeconds":0,"boostStartRPM":0,"boostEscalateTemp":65,"boostEscalateRise":8,"boostLearn":false}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.takeoverHoldSeconds, 0)
        XCTAssertEqual(c.boostStartRPM, 0)
        XCTAssertEqual(c.boostEscalateTemp, 65)
        XCTAssertEqual(c.boostEscalateRise, 8)
        XCTAssertFalse(c.boostLearn)
    }

    func testNewKeysValidate() {
        for bad in [#"{"takeoverHoldSeconds":-1}"#, #"{"takeoverHoldSeconds":61}"#, #"{"boostStartRPM":-100}"#,
                    #"{"boostEscalateRise":0}"#, #"{"boostEscalateTemp":0}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(bad.utf8)), bad)
        }
    }

    func testExampleConfigHasNewKeys() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config.example.json")
        let d = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        for k in ["takeoverHoldSeconds", "boostStartRPM", "boostEscalateTemp", "boostEscalateRise", "boostLearn"] {
            XCTAssertNotNil(obj?[k], "config.example.json 缺 \(k)")
        }
        XCTAssertNoThrow(try JSONDecoder().decode(Config.self, from: d))
    }
}
