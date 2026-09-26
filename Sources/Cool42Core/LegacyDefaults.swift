import Foundation

/// 改名前（原名 cool42）的面板偏好：UserDefaults 網域是 bundle id，改名後從 com.cool42.panel 變成 com.cool42.panel，
/// 不搬的話面板開關、玻璃外觀、提示音、設定視窗上次分頁、今天時間軸⋯⋯全部回到預設。
/// 第一次啟動時把舊網域的值「只補不蓋」地抄過來一次（新網域已經有的鍵不動），做完記旗標，之後不再讀舊網域。
/// 舊網域本身不刪：留著可以回頭，scripts/migrate-from-cool42.sh 也會先 defaults export 備份一份。
/// 放在 Cool42Core 是為了能寫單元測試；面板在 main() 裡呼叫。必須在任何 UserDefaults 讀取之前呼叫（AppDelegate 的 stored property Monitor() 初始化時就會讀），所以放在 main() 最前面。
public enum LegacyDefaults {
    public static let legacyDomain = "com.cool42.panel"
    public static let migratedKey = "migration.fromLegacyDomain"

    /// 鍵名裡帶舊名的也跟著改：視窗位置是 AppKit 存的「NSWindow Frame cool42.panel」／「NSWindow Frame cool42.settings」，
    /// 新版 setFrameAutosaveName 用 cool42.panel／cool42.settings，不改名的話面板位置與高度會回到預設
    public static func newKey(_ k: String) -> String { k.replacingOccurrences(of: "cool42", with: "cool42") }

    @discardableResult
    public static func migrateOnce(into defaults: UserDefaults = .standard, domainProvider: (String) -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: $0) }) -> Int {
        guard !defaults.bool(forKey: migratedKey) else { return 0 }
        var copied = 0
        if let old = domainProvider(legacyDomain) {
            for (k, v) in old {
                let key = newKey(k)
                guard defaults.object(forKey: key) == nil else { continue }
                defaults.set(v, forKey: key)
                copied += 1
            }
        }
        defaults.set(true, forKey: migratedKey)
        return copied
    }
}
