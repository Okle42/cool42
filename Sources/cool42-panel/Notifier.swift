import AppKit
import UserNotifications
import Cool42Core

// 通知：只在三個時刻發 —— 開始降頻、進入 critical、恢復正常。以「一段過熱」為單位（NotifyState）：
//   同一段裡每一類只發一次；穩定正常 2.5 分鐘才算恢復；恢復後 30 分鐘內又熱起來算同一段的延續，已發過的類別不再發；
//   這段真的發過警告才發「恢復正常」，而且恢復時把先前的「開始降頻／critical」從通知中心收掉，列表裡不會同時有互相矛盾的幾則
//   授權在「第一次真的要發」時才請求（不在啟動時要）；使用者拒絕或沒回覆就不再請求，面板顯示狀態與「打開通知設定」
//   面板提示音已經會響，所以通知本身不帶聲音，免得同一件事響兩次
//   不用 Time Sensitive（要另開 capability，而且 HIG 只給「現在就要處理」的事）：降頻、危險線用 .active，恢復正常用 .passive
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String, Hashable { case throttle, critical, recovered }
    enum Auth { case unavailable, unknown, notDetermined, allowed, denied }

    static let shared = Notifier()
    /// 請求過一次就記住：之後就算還是 notDetermined（使用者沒理那則授權橫幅）也不再自己跳
    static let askedKey = "notify.asked"

    /// 只有正式 .app 才能用通知中心：swift run、離屏截圖沒有 app bundle，UNUserNotificationCenter.current() 會直接當掉
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    private(set) var auth: Auth = .unknown
    var onAuthChange: ((Auth) -> Void)? = nil

    /// 啟動時呼叫：設 delegate、讀目前授權狀態（讀狀態不會跳授權視窗）
    func start() {
        guard Self.available else { setAuth(.unavailable); return }
        UNUserNotificationCenter.current().delegate = self
        refresh()
    }

    func refresh() {
        guard Self.available else { setAuth(.unavailable); return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            let a: Auth
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: a = .allowed
            case .denied: a = .denied
            case .notDetermined: a = .notDetermined
            @unknown default: a = .unknown
            }
            DispatchQueue.main.async { self?.setAuth(a) }
        }
    }

    private func setAuth(_ a: Auth) { auth = a; onAuthChange?(a) }

    /// 發一則通知（主執行緒呼叫）。要不要發由 NotifyState 決定；還沒授權就在這時才請求一次
    func post(_ kind: Kind, title: String, body: String) {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        if kind == .recovered {
            center.removeDeliveredNotifications(withIdentifiers: ["cool42." + Kind.throttle.rawValue, "cool42." + Kind.critical.rawValue])
        }
        center.getNotificationSettings { [weak self] s in
            guard let self else { return }
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.add(kind, title: title, body: body)
            case .notDetermined:
                // 使用者沒授權過：只問這一次
                guard !UserDefaults.standard.bool(forKey: Self.askedKey) else { self.refresh(); return }
                UserDefaults.standard.set(true, forKey: Self.askedKey)
                center.requestAuthorization(options: [.alert]) { ok, _ in
                    if ok { self.add(kind, title: title, body: body) }
                    self.refresh()
                }
            default:
                self.refresh()   // denied：不再請求
            }
        }
    }

    private func add(_ kind: Kind, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = nil
        c.threadIdentifier = "thermal"
        c.interruptionLevel = kind == .recovered ? .passive : .active
        c.relevanceScore = kind == .critical ? 1 : kind == .throttle ? 0.8 : 0.3
        // 同一類用固定 identifier：新的取代舊的，通知中心不會堆一串
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cool42." + kind.rawValue, content: c, trigger: nil))
    }

    /// 系統設定 › 通知 › cool42
    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.cool42.panel"
        if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") { NSWorkspace.shared.open(u) }
    }

    // 面板是 accessory app，沒有「在前景看畫面」的情境：照常顯示橫幅（有 delegate 卻不實作 willPresent，通知會被吞掉）
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    /// 點通知：打開面板
    var onOpen: (() -> Void)? = nil
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.onOpen?() }
        completionHandler()
    }
}

/// 通知的三個時刻（純邏輯，和提示音分開：提示音看 overheatAbove 門檻，通知只看降頻與 critical）。
/// 以「一段過熱」為單位，長時間算圖在 critical／降頻上下徘徊時一小時也只會有一兩則：
///   - 同一段裡每一類（降頻、critical）只發一次
///   - 不降頻、也退到 hot 以下，而且**連續** recoverAfter 秒都如此，這段才結束；這段發過警告才發「恢復正常」
///   - 結束後 relinkWithin 秒內又熱起來算同一段的延續：已發過的類別不再發（沒發過的，例如先只降頻、後來才到 critical，照發）
struct NotifyState {
    static let recoverAfter: TimeInterval = 150
    static let relinkWithin: TimeInterval = 1800

    private var wasThrottled: Bool? = nil
    private var wasCritical: Bool? = nil
    /// 目前是否在一段過熱裡
    private(set) var inEpisode = false
    /// 這段（含 30 分鐘內接續的前一段）已發過的類別
    private var alerted: Set<Notifier.Kind> = []
    /// 這一段本身有沒有發出過警告（決定要不要發「恢復正常」）
    private var deliveredThisEpisode = false
    private var calmSince: Date? = nil
    private var episodeEnd: Date? = nil

    /// 回傳這一輪該發的通知種類（第一輪只記狀態、不發）
    mutating func step(throttled: Bool, level: Level, now: Date = Date()) -> [Notifier.Kind] {
        let critical = level == .critical
        defer { wasThrottled = throttled; wasCritical = critical }
        // 第一輪只記狀態：啟動時已經在降頻不補發，之後也不發「恢復正常」（沒發過警告就沒有恢復可報）
        guard let wt = wasThrottled, let wc = wasCritical else { return [] }
        let normal = !throttled && level < .hot
        var out: [Notifier.Kind] = []
        func begin() {
            guard !inEpisode else { return }
            inEpisode = true; deliveredThisEpisode = false; calmSince = nil
            if let e = episodeEnd, now.timeIntervalSince(e) < Self.relinkWithin { return }   // 接續前一段：已發過的不再發
            alerted = []
        }
        if throttled && !wt {
            begin()
            if alerted.insert(.throttle).inserted { out.append(.throttle); deliveredThisEpisode = true }
        }
        if critical && !wc {
            begin()
            if alerted.insert(.critical).inserted { out.append(.critical); deliveredThisEpisode = true }
        }
        if inEpisode {
            if !normal { calmSince = nil }
            else if let c = calmSince {
                if now.timeIntervalSince(c) >= Self.recoverAfter {
                    if deliveredThisEpisode { out.append(.recovered) }
                    inEpisode = false; episodeEnd = now; calmSince = nil
                }
            } else { calmSince = now }
        }
        return out
    }
}
