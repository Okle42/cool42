import AppKit
import Intents
import Cool42Core

// 專注模式：guard（root 常駐程式）拿不到，由面板在使用者 session 裡讀 INFocusStatusCenter，寫旗標檔給 guard（見 Cool42Core FocusFlag）。
//   只有設定裡有 focus 規則才讀；授權只在使用者按規則下方的「繼續⋯」時才請求（HIG：第一次用到才要、請求前的說明只放一顆「繼續」）
//   macOS 只給「有沒有開」，不給開的是哪一種專注模式
final class FocusWatcher {
    enum Auth: Equatable { case unavailable, notDetermined, denied, restricted, allowed }

    static let shared = FocusWatcher()

    /// 只有正式 .app、而且 Info.plist 有 NSFocusStatusUsageDescription 才碰 INFocusStatusCenter：
    /// swift run、離屏截圖沒有 app bundle 與用途字串，呼叫授權 API 會被 TCC 直接終止
    static var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.object(forInfoDictionaryKey: "NSFocusStatusUsageDescription") != nil
    }

    /// 讀授權狀態不會跳授權視窗
    var auth: Auth {
        guard Self.available else { return .unavailable }
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .restricted
        }
    }

    /// 使用者按了「繼續⋯」才呼叫：macOS 會問一次
    func request(_ done: @escaping (Auth) -> Void) {
        guard Self.available else { done(.unavailable); return }
        INFocusStatusCenter.default.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async { done(self?.auth ?? .unavailable) }
        }
    }

    private var lastWritten: (focused: Bool, time: Date)? = nil

    /// 每輪呼叫。needed = 設定裡有 focus 規則；已授權才讀，狀態變了或超過 60 秒才重寫旗標檔（guard 180 秒沒更新就當作不知道）
    func poll(needed: Bool) -> Bool? {
        guard needed, auth == .allowed, let f = INFocusStatusCenter.default.focusStatus.isFocused else { return nil }
        if lastWritten?.focused != f || Date().timeIntervalSince(lastWritten?.time ?? .distantPast) >= FocusFlag.refreshSeconds {
            if (try? FocusFlag(focused: f).write()) != nil { lastWritten = (f, Date()) }
        }
        return f
    }

    /// 系統設定 › 隱私權與安全性 › 專注模式（沒有這一頁的系統就開隱私權總頁）
    static func openSettings() {
        let urls = ["x-apple.systempreferences:com.apple.preference.security?Privacy_Focus",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }
}
