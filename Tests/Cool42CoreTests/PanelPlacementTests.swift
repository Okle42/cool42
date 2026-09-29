import XCTest
@testable import Cool42Core

/// 主螢幕 1920×1080 在 (0,0)、電視在左邊 (-1920,0)（實際出問題的雙螢幕配置）
final class PanelPlacementTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let mainVisible = CGRect(x: 0, y: 0, width: 1920, height: 1050)
    let tv = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let button = CGRect(x: 1373, y: 1056, width: 69, height: 24)

    /// 實際發生過：面板被記在電視右上角 (-352)，點主螢幕的圖示要搬過來、而不是關掉
    func testPanelOnOtherScreenMovesUnderIcon() {
        let panel = CGRect(x: -352, y: 328, width: 352, height: 722)
        let f = PanelPlacement.relocated(panel: panel, anchorMidX: button.midX, screen: main, visible: mainVisible)
        XCTAssertNotNil(f)
        XCTAssertTrue(main.contains(CGPoint(x: f!.midX, y: f!.midY)))
        XCTAssertEqual(f!.midX, button.midX, accuracy: 0.5)
        XCTAssertEqual(f!.maxY, mainVisible.maxY - 8, accuracy: 0.5)
    }

    func testPanelOnSameScreenStays() {
        let panel = CGRect(x: 200, y: 300, width: 352, height: 722)
        XCTAssertNil(PanelPlacement.relocated(panel: panel, anchorMidX: button.midX, screen: main, visible: mainVisible))
    }

    func testClampedToScreenEdges() {
        let panel = CGRect(x: -352, y: 328, width: 352, height: 722)
        let f = PanelPlacement.relocated(panel: panel, anchorMidX: 1915, screen: main, visible: mainVisible)!
        XCTAssertLessThanOrEqual(f.maxX, mainVisible.maxX - 12 + 0.5)
        let g = PanelPlacement.relocated(panel: panel, anchorMidX: 5, screen: main, visible: mainVisible)!
        XCTAssertGreaterThanOrEqual(g.minX, mainVisible.minX + 12 - 0.5)
    }

    func testTallPanelShrinksToVisibleHeight() {
        let panel = CGRect(x: -352, y: 0, width: 352, height: 2000)
        let f = PanelPlacement.relocated(panel: panel, anchorMidX: button.midX, screen: main, visible: mainVisible)!
        XCTAssertLessThanOrEqual(f.height, mainVisible.height - 16)
        XCTAssertGreaterThanOrEqual(f.minY, mainVisible.minY)
    }

    /// 剛啟動時圖示還沒定位：曾因此把面板搬到主螢幕左上角 (12, 38)
    func testAnchorValidity() {
        XCTAssertTrue(PanelPlacement.anchorIsValid(button: button, screen: main))
        XCTAssertFalse(PanelPlacement.anchorIsValid(button: .zero, screen: main))
        XCTAssertFalse(PanelPlacement.anchorIsValid(button: CGRect(x: 0, y: 0, width: 69, height: 24), screen: main))
        XCTAssertFalse(PanelPlacement.anchorIsValid(button: CGRect(x: 1373, y: 500, width: 69, height: 24), screen: main))
        XCTAssertTrue(PanelPlacement.anchorIsValid(button: CGRect(x: -683, y: 1056, width: 69, height: 24), screen: tv))
    }
}
