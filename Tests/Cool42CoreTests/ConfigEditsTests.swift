import XCTest
@testable import Cool42Core

/// 設定視窗「改完按套用」期間，設定檔被別處改過：套用只寫使用者改過的欄位，不把別人改的鍵蓋回舊值
final class ConfigEditsTests: XCTestCase {
    func testExternalChangeSurvivesApply() {
        let base = Config()
        var draft = base
        draft.curve[0].rpm = 1200                 // 設定視窗裡拖了一個曲線點，還沒套用
        var latest = base
        latest.takeoverHoldSeconds = 25           // 這段時間手動改了 config.json
        latest.boostLearn = false                 // MCP／CLI 改的
        latest.maxRPM = 3000
        let out = Config.applyingPanelEdits(base: base, draft: draft, onto: latest)
        XCTAssertEqual(out.takeoverHoldSeconds, 25, "外部改的 takeoverHoldSeconds 不能被舊 draft 蓋回")
        XCTAssertFalse(out.boostLearn)
        XCTAssertEqual(out.maxRPM, 3000, "draft 沒動 maxRPM：照設定檔最新值")
        XCTAssertEqual(out.curve[0].rpm, 1200, "使用者改的曲線點要寫進去")
    }

    func testOnlyEditedSoundThresholdIsWritten() {
        var base = Config()
        base.sounds = .init(overheat: "~/a.mp3", overheatAbove: 95, cooldown: nil, cooldownBelow: 85)
        var draft = base
        draft.sounds?.overheatAbove = 98
        var latest = base
        latest.sounds?.cooldownBelow = 80          // 別處改了另一個門檻
        latest.sounds?.cooldown = "~/b.mp3"
        let out = Config.applyingPanelEdits(base: base, draft: draft, onto: latest)
        XCTAssertEqual(out.overheatAbove, 98)
        XCTAssertEqual(out.cooldownBelow, 80)
        XCTAssertEqual(out.sounds?.overheat, "~/a.mp3")
        XCTAssertEqual(out.sounds?.cooldown, "~/b.mp3", "音檔路徑不是面板編輯的欄位，照最新")
    }

    func testNoEditsMeansLatestUnchanged() throws {
        var latest = Config()
        latest.hotTemp = 98
        latest.mode = "auto"
        let base = Config()
        let out = Config.applyingPanelEdits(base: base, draft: base, onto: latest)
        XCTAssertTrue(Config.panelEdits(base: base, draft: base).isEmpty)
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        XCTAssertEqual(try enc.encode(out), try enc.encode(latest))
    }

    func testEditsDetectsProfilesAndMode() {
        let base = Config()
        var draft = base
        draft.mode = "fixed"
        draft.profiles = [Profile(name: "夜間", when: .init(from: "23:00", to: "07:00"), curve: "quiet")]
        XCTAssertEqual(Config.panelEdits(base: base, draft: draft), [.mode, .profiles])
    }
}
