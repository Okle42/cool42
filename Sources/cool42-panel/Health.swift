import AppKit
import SwiftUI
import Cool42Core

// 健康檢查：cool42 doctor 的面板版（同樣的檢查項目，面板自己做、不需要 root、不開終端機）。
//   紅燈 = cool42 現在沒在保護這台 Mac（guard 沒跑、設定檔壞、風扇卡在手動…），面板頂部會多一條提示
//   黃燈 = 功能少一塊但不危險（沒裝 hook、沒有頻率資料、log 不輪替）
// 面板開著時每 30 秒重做一次；只讀檔案與行程清單，不寫任何東西

struct HealthItem: Identifiable, Equatable {
    enum Severity: Int, Comparable { case ok, warn, bad; static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue } }
    var id: String { name }
    var name: String
    var detail: String
    var severity: Severity
    /// 紅燈的處理順序（小的先）：頂部提示只顯示第一項，所以最急、最能動手的排前面
    var priority: Int = 50
    static let pFanStuck = 0, pMacsFan = 1, pGuard = 2, pConfig = 3, pSensor = 4

    var symbol: String {
        switch severity {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch severity {
        case .ok: return Neon.green
        case .warn: return Neon.amber
        case .bad: return Neon.red
        }
    }
}

enum Health {
    static let daemonPlist = "/Library/LaunchDaemons/com.cool42.guard.plist"
    static let logRotation = "/etc/newsyslog.d/cool42.conf"

    static func run(snapshot s: Snapshot?, config: Config) -> [HealthItem] {
        var out: [HealthItem] = []
        func add(_ name: String, _ detail: String, _ sev: HealthItem.Severity, priority: Int = 50) {
            out.append(HealthItem(name: name, detail: detail, severity: sev, priority: priority))
        }
        let fm = FileManager.default

        // 1. 設定檔
        do {
            let c = try Config.loadOrError(path: nil)
            add(L("設定檔"), c.loadedFrom.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L("沒有設定檔，使用預設值"), .ok)
        } catch {
            add(L("設定檔"), L("解析失敗，guard沿用舊設定：%@", error.localizedDescription), .bad, priority: HealthItem.pConfig)
        }

        // 2. guard（快照夠新＝在跑）
        let plist = fm.fileExists(atPath: daemonPlist)
        // 風扇停在手動時不能說「由macOS控制」：那是卡在上次的轉速
        let stuck = s.flatMap { s in s.guardRunning ? nil : s.fans.first.flatMap { $0.manual ? $0.target : nil } }
        if let s, s.guardRunning {
            add("guard", L("執行中，模式「%@」", modeDisplayName(s.guardMode ?? config.mode)), .ok)
        } else if !plist {
            add("guard", L("沒有安裝：執行install.sh"), .bad, priority: HealthItem.pGuard)
        } else if let rpm = stuck {
            add("guard", L("沒在執行，風扇停在手動%.0f rpm，hook也看不到降頻", rpm), .bad, priority: HealthItem.pGuard)
        } else {
            add("guard", L("沒在執行，風扇由macOS控制，hook也看不到降頻"), .bad, priority: HealthItem.pGuard)
        }
        add(L("開機自動啟動"), plist ? daemonPlist : L("找不到%@", daemonPlist), plist ? .ok : .bad)

        // 3. 風扇控制權：guard 沒跑卻停在手動 = 風扇卡在上次的轉速
        if let rpm = stuck {
            add(L("風扇"), L("停在手動%.0f rpm但guard沒在跑；在終端機執行sudo cool42 fan auto交還", rpm), .bad, priority: HealthItem.pFanStuck)
        } else if let s, s.fans.isEmpty {
            add(L("風扇"), L("讀不到風扇"), .bad, priority: HealthItem.pFanStuck)
        }

        // 4. 感測器
        if let s {
            add(L("溫度感測器"), s.sensorOK ? ((s.cpuKeys ?? []).isEmpty ? L("讀取正常") : L("%ld個CPU感測器", (s.cpuKeys ?? []).count)) : L("讀取不完整，guard暫停降速"), s.sensorOK ? .ok : .bad, priority: HealthItem.pSensor)
        }

        // 5. 衝突程式
        let mfc = NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "").lowercased().contains("macsfancontrol") || $0.localizedName == "Macs Fan Control"
        }
        if mfc { add("Macs Fan Control", L("正在執行，會和cool42互搶風扇；請先結束它"), .bad, priority: HealthItem.pMacsFan) }

        // 6. 頻率（powermetrics）：沒有也能用溫度判斷，但看不到時脈降頻
        if let s, s.guardRunning {
            add(L("CPU頻率"), s.pcoreMHz != nil ? L("有（可判斷時脈降頻）") : L("沒有頻率資料：只能用溫度判斷"), s.pcoreMHz != nil ? .ok : .warn)
        }

        // 7. 事件目錄（hook 預熱、統計用）
        if let s, s.guardRunning, !fm.isWritableFile(atPath: Event.dir) {
            add(L("事件目錄"), L("%@不可寫，預熱與AI等待統計會失效", Event.dir), .warn)
        }

        // 8. Claude Code hook（選用功能）
        let hook = hookInstalled()
        add("Claude Code hook", hook ? L("已安裝") : L("沒有安裝：AI不會先看降頻（scripts/install-hook.py）"), hook ? .ok : .warn)

        // 9. log 輪替
        if !fm.fileExists(atPath: logRotation) { add(L("記錄檔輪替"), L("沒有%@，記錄檔會一直長大", logRotation), .warn) }

        // 自訂模糊度用的是 SkyLight 私有函式：macOS 更新拿掉時要第一時間知道。只有使用者真的在用（模糊背景關、模糊度 > 0）才亮紅燈
        let usingCustomBlur = !GlassStyle.blur && GlassStyle.blurRadius > 0
        if let n = WindowBlur.symbolName {
            add(L("自訂模糊度"), L("可用（%@）", n), .ok)
        } else {
            add(L("自訂模糊度"),
                usingCustomBlur ? L("這版 macOS 找不到系統的模糊函式，面板已改用 Apple 玻璃（模糊度固定）；請回報 issue")
                                : L("這版 macOS 找不到系統的模糊函式，模糊度滑桿停用；Apple 玻璃不受影響"),
                usingCustomBlur ? .bad : .warn)
        }
        return out
    }

    static func hookInstalled() -> Bool {
        let p = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        guard let d = FileManager.default.contents(atPath: p),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any], let pre = hooks["PreToolUse"] as? [[String: Any]] else { return false }
        return pre.contains { e in (e["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains("cool42 hook") } }
    }
}

// MARK: - 畫面

extension PanelView {
    /// 紅燈，照處理順序排（風扇卡手動 > Macs Fan Control > guard > 設定檔 > 感測器）
    var badHealth: [HealthItem] { monitor.health.filter { $0.severity == .bad }.sorted { $0.priority < $1.priority } }

    /// 標題列下方的紅燈提示：只有紅燈才出現；按「查看」打開設定視窗的「關於與檢查」分頁
    @ViewBuilder
    var healthBanner: some View {
        if let first = badHealth.first {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Neon.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(badHealth.count > 1 ? L("健康檢查有%ld項要處理", badHealth.count) : L("健康檢查有1項要處理"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                    Text(verbatim: L("%@：%@", first.name, first.detail)).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button(L("查看⋯")) { monitor.refreshHealth(force: true); monitor.onShowSettings?(.about) }.controlSize(.small)
                    .help(L("打開設定視窗的健康檢查"))
            }
            .padding(8)
            // 警示是內容，不是玻璃：淡紅底＋紅色圖示，文字仍用系統色
            .background(Neon.red.opacity(0.14), in: RoundedRectangle(cornerRadius: Neon.plotRadius, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }

    /// 健康檢查清單（設定視窗「關於與檢查」分頁）
    var healthList: some View {
        let items = monitor.health
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { it in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: it.symbol).foregroundStyle(it.color).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: it.name).font(.body.weight(.medium))
                        Text(verbatim: it.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    var healthSummary: String {
        let bad = monitor.health.filter { $0.severity == .bad }.count, warn = monitor.health.filter { $0.severity == .warn }.count
        return bad > 0 ? L("%ld項要處理", bad) : warn > 0 ? L("正常 · %ld項提醒", warn) : L("全部正常")
    }
}
