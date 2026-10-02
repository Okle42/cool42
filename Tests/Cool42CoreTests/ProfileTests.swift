import XCTest
@testable import Cool42Core

final class ProfileTests: XCTestCase {
    func ctx(_ hhmm: String, apps: Set<String> = [], focus: Bool? = nil) -> ProfileContext {
        ProfileContext(minuteOfDay: TimeOfDay.minutes(hhmm)!, runningApps: apps, focus: focus)
    }
    let night = Profile(name: "夜間安靜", when: .init(from: "23:00", to: "07:00"), curve: "quiet", maxRPM: 2200)

    // MARK: 時段

    func testTimeParsing() {
        XCTAssertEqual(TimeOfDay.minutes("23:00"), 23 * 60)
        XCTAssertEqual(TimeOfDay.minutes("7:05"), 7 * 60 + 5)
        XCTAssertEqual(TimeOfDay.minutes(" 00:00 "), 0)
        for bad in ["24:00", "7", "07:5", "07:60", "ab:cd", "", "7:00:00", "-1:00"] { XCTAssertNil(TimeOfDay.minutes(bad), bad) }
        XCTAssertEqual(TimeOfDay.string(7 * 60 + 5), "07:05")
    }

    func testCrossMidnightRange() {
        XCTAssertTrue(night.matches(ctx("23:00")))    // 含頭
        XCTAssertTrue(night.matches(ctx("23:59")))
        XCTAssertTrue(night.matches(ctx("00:00")))
        XCTAssertTrue(night.matches(ctx("06:59")))
        XCTAssertFalse(night.matches(ctx("07:00")))   // 不含尾
        XCTAssertFalse(night.matches(ctx("12:00")))
        XCTAssertFalse(night.matches(ctx("22:59")))
    }

    func testSameDayRange() {
        let lunch = Profile(name: "午休", when: .init(from: "12:00", to: "13:30"), maxRPM: 1800)
        XCTAssertFalse(lunch.matches(ctx("11:59")))
        XCTAssertTrue(lunch.matches(ctx("12:00")))
        XCTAssertTrue(lunch.matches(ctx("13:29")))
        XCTAssertFalse(lunch.matches(ctx("13:30")))
        XCTAssertFalse(lunch.matches(ctx("23:00")))
    }

    func testContextFromDateUsesLocalCalendar() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let d = ISO8601DateFormatter().date(from: "2026-09-25T15:30:00Z")!   // 台北 23:30
        XCTAssertEqual(ProfileContext(now: d, calendar: cal).minuteOfDay, 23 * 60 + 30)
        XCTAssertTrue(night.matches(ProfileContext(now: d, calendar: cal)))
    }

    // MARK: App

    func testAppRuleMatchesProcessNames() {
        let heavy = Profile(name: "重工作", when: .init(apps: ["Xcode", "Blender.app", "FFmpeg"]), curve: "performance")
        XCTAssertTrue(heavy.matches(ctx("12:00", apps: ["xcode", "finder"])))
        XCTAssertTrue(heavy.matches(ctx("12:00", apps: ["blender"])))       // 規則寫 .app 也行
        XCTAssertTrue(heavy.matches(ctx("12:00", apps: ["ffmpeg"])))        // 不分大小寫
        XCTAssertFalse(heavy.matches(ctx("12:00", apps: ["finder", "xcodebuild"])))   // 完全相同才算，xcodebuild ≠ Xcode
        XCTAssertFalse(heavy.matches(ctx("12:00")))
    }

    func testAppRuleTruncatedProcessName() {
        XCTAssertTrue(ProcList.matches(rule: "DaVinci Resolve Studio", running: ["davinci resolve"]))   // 被截成 15 字
        XCTAssertFalse(ProcList.matches(rule: "Blender", running: ["blend"]))                          // 短名不做前綴比對
        XCTAssertFalse(ProcList.matches(rule: "  ", running: [""]))
    }

    func testRunningNamesSeesThisProcess() {
        let names = ProcList.runningNames()
        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.allSatisfy { $0 == $0.lowercased() })
    }

    // MARK: 專注模式

    func testFocusRule() {
        let focus = Profile(name: "專注", when: .init(focus: true), maxRPM: 2000)
        XCTAssertTrue(focus.matches(ctx("12:00", focus: true)))
        XCTAssertFalse(focus.matches(ctx("12:00", focus: false)))
        XCTAssertFalse(focus.matches(ctx("12:00", focus: nil)))   // 讀不到＝不成立
    }

    func testConditionsAreANDed() {
        let nightXcode = Profile(name: "夜間編譯", when: .init(from: "23:00", to: "07:00", apps: ["Xcode"]), maxRPM: 2600)
        XCTAssertTrue(nightXcode.matches(ctx("01:00", apps: ["xcode"])))
        XCTAssertFalse(nightXcode.matches(ctx("01:00")))
        XCTAssertFalse(nightXcode.matches(ctx("12:00", apps: ["xcode"])))
    }

    // MARK: 順序與套用

    func testFirstMatchWins() {
        let heavy = Profile(name: "重工作", when: .init(apps: ["ffmpeg"]), curve: "performance")
        let rules = [heavy, night]
        XCTAssertEqual(Profiles.active(rules, ctx("01:00", apps: ["ffmpeg"]))?.name, "重工作")   // 兩條都符合 → 前面的
        XCTAssertEqual(Profiles.active(rules, ctx("01:00"))?.name, "夜間安靜")
        XCTAssertNil(Profiles.active(rules, ctx("12:00")))                                    // 都不符合 → 基本設定
        XCTAssertEqual(Profiles.active([night, heavy], ctx("01:00", apps: ["ffmpeg"]))?.name, "夜間安靜")   // 換順序結果就換
    }

    func testApplyingProfile() {
        var base = Config(); base.maxRPM = 3000
        XCTAssertEqual(base.applying(nil).curve.map(\.rpm), base.curve.map(\.rpm))
        let c = base.applying(night)
        XCTAssertEqual(c.curve.map(\.rpm), Config.presetCurves["quiet"]!.map(\.rpm))
        XCTAssertEqual(c.maxRPM, 2200)                          // 規則的上限取代基本設定
        let onlyCurve = base.applying(Profile(name: "x", when: .init(focus: true), curve: "強力"))
        XCTAssertEqual(onlyCurve.maxRPM, 3000)                  // 規則沒寫上限 → 沿用基本設定
        XCTAssertEqual(onlyCurve.curve.map(\.rpm), Config.presetCurves["performance"]!.map(\.rpm))
        XCTAssertEqual(c.mode, base.mode)                       // 情境不改模式（緊急交還原廠 = auto 不受影響）
    }

    func testPresetNames() {
        XCTAssertEqual(Config.presetID("Quiet"), "quiet")
        XCTAssertEqual(Config.presetID("均衡"), "balanced")
        XCTAssertEqual(Config.presetID("強力"), "performance")
        XCTAssertNil(Config.presetID("turbo"))
        XCTAssertEqual(Config.presetCurves["balanced"]!.map(\.rpm), Config().curve.map(\.rpm))
    }

    // MARK: 噪音上限

    func testRPMCapClampAndSafetyExceptions() {
        XCTAssertEqual(RPMCap.clamp(4000, maxRPM: 2500, critical: false, hot: false, throttling: false), 2500)
        XCTAssertEqual(RPMCap.clamp(1800, maxRPM: 2500, critical: false, hot: false, throttling: false), 1800)
        XCTAssertEqual(RPMCap.clamp(4000, maxRPM: nil, critical: false, hot: false, throttling: false), 4000)
        XCTAssertEqual(RPMCap.clamp(4900, maxRPM: 2500, critical: true, hot: false, throttling: false), 4900)    // critical 忽略上限
        XCTAssertEqual(RPMCap.clamp(4900, maxRPM: 2500, critical: false, hot: false, throttling: true), 4900)    // 降頻忽略上限
        XCTAssertTrue(RPMCap.suspended(critical: false, hot: false, throttling: true))
        XCTAssertFalse(RPMCap.suspended(critical: false, hot: false, throttling: false))
    }

    /// hot（95°C 以上、或等級遲滯仍在 hot）就要全力散熱：上限不作用
    func testRPMCapIgnoredWhenHot() {
        XCTAssertEqual(RPMCap.clamp(4900, maxRPM: 2200, critical: false, hot: true, throttling: false), 4900)
        XCTAssertTrue(RPMCap.suspended(critical: false, hot: true, throttling: false))
        XCTAssertEqual(RPMCap.clamp(4900, maxRPM: 2200, suspended: true), 4900)
        XCTAssertEqual(RPMCap.clamp(4900, maxRPM: 2200, suspended: false), 2200)
    }

    /// 閂鎖：觸發就暫停；降到門檻以下且連續 N 輪沒再觸發才恢復，中間任何一輪再觸發（降頻）就重算
    func testCapLatchHysteresis() {
        var l = CapLatch()
        let below = 92.0   // hotTemp 95 − levelHysteresis 3
        XCTAssertFalse(l.update(trigger: false, temp: 80, releaseBelow: below, releaseRounds: 3))
        XCTAssertTrue(l.update(trigger: true, temp: 104, releaseBelow: below, releaseRounds: 3))
        // 頻率恢復、不再觸發，但溫度還在 93°C（門檻以上）：維持暫停
        XCTAssertTrue(l.update(trigger: false, temp: 93, releaseBelow: below, releaseRounds: 3))
        XCTAssertEqual(l.calmRounds, 0)
        XCTAssertTrue(l.update(trigger: false, temp: 90, releaseBelow: below, releaseRounds: 3))
        XCTAssertTrue(l.update(trigger: false, temp: 89, releaseBelow: below, releaseRounds: 3))
        // 第 3 輪前又降頻：重算
        XCTAssertTrue(l.update(trigger: true, temp: 91, releaseBelow: below, releaseRounds: 3))
        XCTAssertTrue(l.update(trigger: false, temp: 88, releaseBelow: below, releaseRounds: 3))
        XCTAssertTrue(l.update(trigger: false, temp: 88, releaseBelow: below, releaseRounds: 3))
        XCTAssertFalse(l.update(trigger: false, temp: 88, releaseBelow: below, releaseRounds: 3))   // 連續 3 輪 → 恢復
        l.reset()
        XCTAssertFalse(l.suspended)
    }

    func testDuplicateProfileNamesRejected() {
        let json = #"{"profiles":[{"name":"夜間","when":{"from":"23:00","to":"07:00"},"maxRPM":2000},{"name":"夜間 ","when":{"focus":true},"maxRPM":2400}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(json.utf8)))
    }

    // MARK: 設定檔

    func testOldConfigWithoutNewKeys() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"mode":"curve","boostRPM":3000}"#.utf8))
        XCTAssertNil(c.maxRPM)
        XCTAssertTrue(c.profiles.isEmpty)
        XCTAssertNil(Profiles.active(c.profiles, ctx("01:00", apps: ["xcode"], focus: true)))
        XCTAssertEqual(c.applying(nil).curve.map(\.rpm), Config().curve.map(\.rpm))
    }

    func testDecodeProfilesAndRoundTrip() throws {
        let json = #"""
        {"maxRPM": 3200, "profiles": [
          {"name": "夜間安靜", "when": {"from": "23:00", "to": "07:00"}, "curve": "quiet", "maxRPM": 2200},
          {"name": "重工作", "when": {"apps": ["Xcode", "Blender", "ffmpeg"]}, "curve": "performance"},
          {"name": "專注", "when": {"focus": true}, "maxRPM": 2000}
        ]}
        """#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.maxRPM, 3200)
        XCTAssertEqual(c.profiles.map(\.name), ["夜間安靜", "重工作", "專注"])
        XCTAssertEqual(c.profiles[1].when.apps ?? [], ["Xcode", "Blender", "ffmpeg"])
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))   // 面板存檔再讀回
        XCTAssertEqual(back.profiles, c.profiles)
        XCTAssertEqual(back.maxRPM, 3200)
        // 沒有 maxRPM 的設定存檔後也不會多出這個鍵
        let plain = String(data: try JSONEncoder().encode(Config()), encoding: .utf8)!
        XCTAssertFalse(plain.contains("maxRPM"))
    }

    func testValidateRejectsBadProfiles() {
        let bad = [
            #"{"maxRPM": 0}"#,
            #"{"maxRPM": -100}"#,
            #"{"profiles": [{"name": "x", "when": {}, "maxRPM": 2000}]}"#,                                  // 沒有條件
            #"{"profiles": [{"name": "x", "when": {"from": "23:00"}, "maxRPM": 2000}]}"#,                   // from/to 不成對
            #"{"profiles": [{"name": "x", "when": {"from": "25:00", "to": "07:00"}, "maxRPM": 2000}]}"#,    // 時間格式
            #"{"profiles": [{"name": "x", "when": {"from": "07:00", "to": "07:00"}, "maxRPM": 2000}]}"#,    // 同一時間
            #"{"profiles": [{"name": "x", "when": {"apps": []}, "maxRPM": 2000}]}"#,
            #"{"profiles": [{"name": "x", "when": {"focus": true}}]}"#,                                     // 沒有動作
            #"{"profiles": [{"name": "x", "when": {"focus": true}, "curve": "turbo"}]}"#,
            #"{"profiles": [{"name": "", "when": {"focus": true}, "maxRPM": 2000}]}"#,
            #"{"profiles": [{"name": "a\nb", "when": {"focus": true}, "maxRPM": 2000}]}"#,                  // 名稱會進 log，不能換行
            #"{"profiles": [{"name": "x", "when": {"focus": true}, "maxRPM": 0}]}"#,
            #"{"profiles": [{"when": {"focus": true}, "maxRPM": 2000}]}"#,                                 // 缺 name
        ]
        for j in bad { XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(j.utf8)), j) }
        let many = (0...Profile.maxCount).map { #"{"name":"r\#($0)","when":{"focus":true},"maxRPM":2000}"# }.joined(separator: ",")
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(#"{"profiles":[\#(many)]}"#.utf8)))
    }

    /// 範例設定會被 install 複製成新安裝的 /etc/cool42/config.json：鍵要在（使用者看得到可以設），但預設不啟用任何情境、不限轉速
    func testExampleConfigHasNewKeysButKeepsOldBehavior() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config.example.json")
        let d = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        XCTAssertNotNil(obj?["maxRPM"], "config.example.json 缺 maxRPM")
        XCTAssertNotNil(obj?["profiles"], "config.example.json 缺 profiles")
        let c = try JSONDecoder().decode(Config.self, from: d)
        XCTAssertNil(c.maxRPM)
        XCTAssertTrue(c.profiles.isEmpty)
    }

    /// README 裡給的情境範例要真的解得開（文件不能寫出 guard 拒絕載入的設定）
    func testReadmeProfileExampleDecodes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["README.md", "README.zh-TW.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            guard let start = text.range(of: "<!-- profiles-example -->"), let fence = text.range(of: "```json\n", range: start.upperBound..<text.endIndex),
                  let end = text.range(of: "\n```", range: fence.upperBound..<text.endIndex) else { return XCTFail("\(name) 找不到 profiles-example 區塊") }
            let c = try JSONDecoder().decode(Config.self, from: Data(text[fence.upperBound..<end.lowerBound].utf8))
            XCTAssertEqual(c.profiles.count, 3, name)
            XCTAssertNotNil(c.maxRPM, name)
        }
    }

    // MARK: 專注旗標

    func testFocusFlagReadWriteAndStale() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cool42-focus-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let p = FocusFlag.path(home: home)
        XCTAssertNil(FocusFlag.read(path: p))                                   // 沒有檔 → 不知道
        let t = Date()
        try FocusFlag(focused: true, time: t).write(home: home)
        XCTAssertEqual(FocusFlag.read(path: p, ownerUID: getuid(), now: t), true)
        XCTAssertNil(FocusFlag.read(path: p, ownerUID: getuid() &+ 1, now: t))  // 不是那個使用者的檔
        XCTAssertNil(FocusFlag.read(path: p, now: t.addingTimeInterval(FocusFlag.staleAfter + 1)))   // 面板沒在更新 → 過期
        try FocusFlag(focused: false, time: t).write(home: home)
        XCTAssertEqual(FocusFlag.read(path: p, now: t), false)
    }

    func testFocusFlagRefusesSymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cool42-focus-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FocusFlag(focused: true).write(home: dir)
        let real = FocusFlag.path(home: dir)
        let link = dir + "/link.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        XCTAssertEqual(FocusFlag.read(path: real), true)
        XCTAssertNil(FocusFlag.read(path: link))
    }
}
