import CoreGraphics

/// 面板要不要搬到選單列圖示那台螢幕（純函式，座標都是 AppKit 螢幕座標：原點左下）。
/// 雙螢幕時 autosave 會把面板留在另一台（例如關著的電視），點圖示、開機自動開、點通知時看起來都像「沒開」。
public enum PanelPlacement {
    /// 圖示視窗的位置可不可信：剛啟動時 status item 還沒排進選單列，frame 會是 0 或不在螢幕上緣
    public static func anchorIsValid(button: CGRect, screen: CGRect) -> Bool {
        guard button.width > 0, button.height > 0 else { return false }
        guard screen.contains(CGPoint(x: button.midX, y: button.midY)) else { return false }
        return button.maxY >= screen.maxY - 2 && button.minX > screen.minX + 1
    }

    /// 面板中心已在圖示那台螢幕：回 nil（保留使用者在同一台拖過的位置）；
    /// 不在：回搬到圖示正下方的 frame（水平對齊圖示、貼可用區上緣，左右各留 12pt，高度不超過可用區）
    public static func relocated(panel: CGRect, anchorMidX: CGFloat, screen: CGRect, visible: CGRect) -> CGRect? {
        guard !screen.contains(CGPoint(x: panel.midX, y: panel.midY)) else { return nil }
        var f = panel
        f.size.height = min(f.height, visible.height - 16)
        f.origin.x = min(max(anchorMidX - f.width / 2, visible.minX + 12), visible.maxX - f.width - 12)
        f.origin.y = visible.maxY - f.height - 8
        return f
    }
}
