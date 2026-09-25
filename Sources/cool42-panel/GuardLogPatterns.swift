// l10n:ignore-file
// guard 寫進 /var/log/cool42.log 的固定字首（格式由 Sources/cool42/Guard.swift 的 log(...) 決定，兩邊要一起改）。
// 這些是「比對 log 用的協定字串」，不是介面文字，所以不走 L()；scripts/check-l10n.py 看到上面的標記就不把這裡的中文
// 當成漏包 L() 的介面字串。面板上顯示的句子都在 Timeline.swift 用 L() 組，別把介面字串放進這個檔
enum GuardLogPattern {
    static let throttleStart = "⚠️ 熱降頻開始"
    static let throttleEnd = "熱降頻結束"
    static let levelChange = "等級 "
    static let boostEarlyEnd = "預熱提早結束"
    static let boostEscalate = "預熱加碼"
    static let boostSkip = "略過預熱"
    static let boostResume = "恢復預熱"
    static let boostLearned = "學到："
    static let boostLearnWarn = "⚠️ 預熱學習"
    static let boost = "預熱 "
    static let profile = "情境「"
    static let profileOn = "」生效"
    static let profileOff = "」結束"
    static let profileEnd = "」"
    static let cap = "噪音上限 "
    static let capPause = "暫停"
    static let capResume = "恢復"
    static let guardStart = "cool42 guard 啟動"
    static let guardStop = "cool42 guard 結束"
    static let reload = "設定已重載"
    static let mode = "模式 "
    static let sensorFault = "⚠️ 感測器"
    static let configFail = "⚠️ 設定檔解析失敗"
    static let configKeysGone = "⚠️ 設定檔裡的"
    static let watchdog = "⚠️ watchdog"
    static let macsFanControl = "⚠️ Macs Fan Control"
    /// 熱降頻開始的原因：「時脈（pressure 仍 Nominal）」
    static let clock = "時脈"
    /// 全形冒號：「預熱 3000 rpm 到 …：swift build」「預熱提早結束：30 秒後…」
    static let colon = "："
    /// 「學到：swift build 不再預熱（…」的關鍵字結尾
    static let learnedEnd = " 不再預熱"
    /// 「略過預熱：swift build 已學到…」的關鍵字結尾
    static let skipEnd = " 已學到"
    /// 「恢復預熱：a、b（暫停 24 小時已到）」
    static let listSep = "、"
    static let paren = "（"
}
