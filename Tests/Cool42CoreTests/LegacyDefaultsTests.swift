import XCTest
@testable import Cool42Core

final class LegacyDefaultsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "cool42.tests.legacy.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        // removePersistentDomain 只清空內容，~/Library/Preferences 裡的空 plist 還在，每跑一次測試多一個網域
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite!).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    func testCopiesMissingKeysOnceAndKeepsNewValues() {
        defaults.set("dark", forKey: "glass.appearance")   // 新網域已經有的值不能被舊值蓋掉
        let old: [String: Any] = ["glass.appearance": "light", "sound.hot": false, "panel.open": true]
        var asked: [String] = []
        let n = LegacyDefaults.migrateOnce(into: defaults) { asked.append($0); return old }
        XCTAssertEqual(asked, [LegacyDefaults.legacyDomain])
        XCTAssertEqual(n, 2)
        XCTAssertEqual(defaults.string(forKey: "glass.appearance"), "dark")
        XCTAssertEqual(defaults.object(forKey: "sound.hot") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "panel.open") as? Bool, true)
        XCTAssertTrue(defaults.bool(forKey: LegacyDefaults.migratedKey))
        // 第二次不再讀舊網域
        let again = LegacyDefaults.migrateOnce(into: defaults) { _ in XCTFail("不該再讀舊網域"); return old }
        XCTAssertEqual(again, 0)
    }

    func testRenamesWindowFrameKeys() {
        let old: [String: Any] = ["NSWindow Frame cool42.panel": "1 2 336 719 0 0 1920 1080 ", "sensors.show": true]
        XCTAssertEqual(LegacyDefaults.migrateOnce(into: defaults) { _ in old }, 2)
        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame cool42.panel"), "1 2 336 719 0 0 1920 1080 ")
        XCTAssertNil(defaults.object(forKey: "NSWindow Frame cool42.panel"))
        XCTAssertEqual(defaults.object(forKey: "sensors.show") as? Bool, true)
    }

    func testNoLegacyDomainStillMarksDone() {
        XCTAssertEqual(LegacyDefaults.migrateOnce(into: defaults) { _ in nil }, 0)
        XCTAssertTrue(defaults.bool(forKey: LegacyDefaults.migratedKey))
    }
}
