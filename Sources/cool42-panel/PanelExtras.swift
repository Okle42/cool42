import AppKit
import SwiftUI
import Cool42Core

// 「新手安心」的兩塊（在設定視窗裡用）：
//   emergencyRow  風扇控制分頁最下面的「緊急交還原廠」／「恢復」
//   notifyStatus  通知授權狀態（只有發不出去時才講話）

extension PanelView {
    /// 緊急交還原廠：確認後只把設定檔的 mode 改成 auto（guard 熱重載、風扇交還 SMC），不需要密碼。
    /// 交還後同一列換成「恢復」按鈕，回到交還前的模式
    @ViewBuilder
    var emergencyRow: some View {
        let isAuto = monitor.config.mode == "auto"
        let guardUp = monitor.snapshot?.guardRunning ?? false
        HStack(spacing: 6) {
            if !guardUp {
                // guard 沒跑時改設定檔沒人讀：風扇若卡在手動，只能用 root 交還（面板不要 root，所以給指令）
                Text(L("guard沒在跑：交還請在終端機執行sudo cool42 fan auto")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("sudo cool42 fan auto", forType: .string)
                } label: { Label(L("拷貝指令"), systemImage: "doc.on.doc") }
                    .help(L("拷貝「sudo cool42 fan auto」，貼到終端機執行"))
            } else if isAuto, let prev = monitor.emergencyPrevMode {
                Image(systemName: "arrow.uturn.backward.circle.fill").font(.body).foregroundStyle(Neon.amber)
                Text(L("已交還原廠控制")).font(.body).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button(L("恢復「%@」", modeDisplayName(prev))) { monitor.emergencyRestore() }
                    .help(L("把風扇模式改回交還前的「%@」", modeDisplayName(prev)))
            } else if isAuto {
                Image(systemName: "checkmark.circle").font(.body).foregroundStyle(.secondary)
                Text(L("風扇目前由macOS原廠控制")).font(.body).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Text(L("風扇怪怪的？")).font(.body).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button { confirmEmergency() } label: {
                    Label(L("緊急交還原廠⋯"), systemImage: "arrow.uturn.backward.circle")
                }
                .help(L("幾秒內把風扇交回macOS自己管，不需要密碼；之後可以恢復"))
            }
        }
    }

    /// 確認對話框：掛在面板上的 sheet（面板不見了就退回獨立 alert）。預設鈕是「取消」以外的主要動作「交還原廠」——
    /// 這個動作是往安全的方向（原廠行為），不是破壞性動作
    func confirmEmergency() { Self.confirmEmergency(monitor: monitor) }

    /// 選單列右鍵選單也用同一個流程
    static func confirmEmergency(monitor: Monitor) {
        let a = NSAlert()
        a.messageText = L("要把風扇交還macOS原廠控制嗎？")
        a.informativeText = L("cool42會停止調整風扇，改由macOS自己管；guard照常監看溫度與降頻，hook也照常運作。之後可以按「恢復」回到「%@」。",
                              modeDisplayName(monitor.config.mode))
        a.addButton(withTitle: L("交還原廠"))
        a.addButton(withTitle: L("取消"))
        let run = { (r: NSApplication.ModalResponse) in if r == .alertFirstButtonReturn { monitor.emergencyAuto() } }
        if let w = monitor.panelWindow, w.isVisible {
            a.beginSheetModal(for: w, completionHandler: run)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            run(a.runModal())
        }
    }

    /// 通知授權狀態：只有「不會發出去」的情況才講話，並給直接按鈕（HIG：給按鈕，不要描述設定路徑）
    @ViewBuilder
    var notifyStatus: some View {
        switch monitor.notifyAuth {
        case .denied:
            // 字與按鈕上下排：英文按鈕字較長，並排會被截斷
            VStack(alignment: .leading, spacing: 4) {
                Text(L("通知已在系統設定中關閉。")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("打開通知設定")) { Notifier.openSettings() }
            }
            
        case .notDetermined where UserDefaults.standard.bool(forKey: Notifier.askedKey):
            // 字與按鈕上下排：英文按鈕字較長，並排會被截斷
            VStack(alignment: .leading, spacing: 4) {
                Text(L("還沒允許通知。")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("打開通知設定")) { Notifier.openSettings() }
            }
            
        case .notDetermined:
            Text(L("第一次要發通知時，macOS會問你要不要允許。")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unavailable:
            Text(L("從cool42 Panel.app執行時才會發通知。")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .allowed, .unknown:
            EmptyView()
        }
    }
}
