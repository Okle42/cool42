import AppKit

// 選單列圖示：一律 template（黑＋透明，系統依選單列深淺與選取狀態上色），狀態靠「換形狀」不靠顏色（HIG The menu bar）。
//   等級 → 溫度計刻度往上走、critical 換三角形（Level.symbol）；hot 另在右下角加一個實心圓點（降頻時由烏龜取代）
//     （thermometer.medium／high 在 16pt 只差一小段刻度，只顯示圖示時分不出來）
//   降頻（pressure 非 Nominal、時脈降頻、GPU CLTM）→ 右上角多一隻烏龜（tortoise.fill），和面板裡的降頻圖示同一個；
//     ⚡ 在面板裡是「全速運作」，不拿來表示降頻
//   角標周圍挖一圈透明，選單列上兩個形狀才分得開
// 合成的圖快取起來：選單列每 3–5 秒更新一次，不必每次重畫
enum StatusIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(symbol: String, throttled: Bool, hotDot: Bool = false) -> NSImage? {
        let key = symbol + (throttled ? "+tortoise" : "") + (hotDot ? "+dot" : "")
        if let c = cache[key] { return c }
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        let badge = throttled ? NSImage(systemSymbolName: "tortoise.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) : nil
        // 降頻時只放烏龜：兩個角標擠在 16pt 裡會糊成一團（降頻本身比 hot 更值得看到）
        let dot = hotDot && !throttled ? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6, weight: .bold)) : nil
        guard badge != nil || dot != nil else {
            base.isTemplate = true
            cache[key] = base
            return base
        }
        // 畫布：本體靠左、角標貼右側，重疊 3pt；高度跟本體（選單列 SF Symbol 約 16–18pt 高）
        let overlap: CGFloat = 3
        let extra = max(badge?.size.width ?? 0, dot?.size.width ?? 0)
        let size = NSSize(width: ceil(base.size.width + extra - overlap),
                          height: ceil(max(base.size.height, badge?.size.height ?? 0)))
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: (rect.height - base.size.height) / 2, width: base.size.width, height: base.size.height))
            func stamp(_ b: NSImage, top: Bool) {
                let r = NSRect(x: rect.width - b.size.width, y: top ? rect.height - b.size.height : 0, width: b.size.width, height: b.size.height)
                // 挖空一圈（往八個方向各偏 1.2pt 用 destinationOut 擦掉）
                for (dx, dy) in [(-1.2, 0), (1.2, 0), (0, -1.2), (0, 1.2), (-0.9, -0.9), (0.9, 0.9), (-0.9, 0.9), (0.9, -0.9)] as [(CGFloat, CGFloat)] {
                    b.draw(in: r.offsetBy(dx: dx, dy: dy), from: .zero, operation: .destinationOut, fraction: 1)
                }
                b.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            }
            if let dot { stamp(dot, top: false) }
            if let badge { stamp(badge, top: true) }
            return true
        }
        img.isTemplate = true
        cache[key] = img
        return img
    }
}
