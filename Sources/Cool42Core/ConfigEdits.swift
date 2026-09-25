import Foundation

// 面板／設定視窗編輯設定檔的合併規則（面板與測試共用）。
//
// 設定視窗是「改完按套用」：編輯中那份 draft 可能放很久。這段時間裡設定檔也可能被別人改
// （手動編輯 config.json、`cool42` CLI、MCP cool42_set_fan、另一個面板）。
// 套用時如果整份 draft 寫回去，別人改的鍵會被悄悄蓋回舊值（例如 takeoverHoldSeconds、boostLearn）。
// 所以只把「使用者在面板上真的改過的欄位」（draft 和開始編輯時的 base 不同的那些）疊到最新的設定檔上，其他鍵照最新的。
extension Config {
    /// 面板會改的欄位
    public enum PanelField: String, CaseIterable {
        case mode, fixedRPM, includeGPU, curve, overheatAbove, cooldownBelow, maxRPM, profiles
    }

    /// draft 相對 base 改了哪些欄位
    public static func panelEdits(base: Config, draft: Config) -> Set<PanelField> {
        var out = Set<PanelField>()
        if draft.mode != base.mode { out.insert(.mode) }
        if draft.fixedRPM != base.fixedRPM { out.insert(.fixedRPM) }
        if draft.includeGPU != base.includeGPU { out.insert(.includeGPU) }
        if draft.curve.map({ [$0.temp, $0.rpm] }) != base.curve.map({ [$0.temp, $0.rpm] }) { out.insert(.curve) }
        if draft.overheatAbove != base.overheatAbove { out.insert(.overheatAbove) }
        if draft.cooldownBelow != base.cooldownBelow { out.insert(.cooldownBelow) }
        if draft.maxRPM != base.maxRPM { out.insert(.maxRPM) }
        if draft.profiles != base.profiles { out.insert(.profiles) }
        return out
    }

    /// 三方合併：把 draft 相對 base 改過的欄位疊到 latest（剛從磁碟讀的設定檔）上；其餘鍵一律照 latest。
    /// 回傳值的 loadedFrom 跟 latest 一樣（寫回同一個檔）
    public static func applyingPanelEdits(base: Config, draft: Config, onto latest: Config) -> Config {
        var out = latest
        for f in panelEdits(base: base, draft: draft) {
            switch f {
            case .mode: out.mode = draft.mode
            case .fixedRPM: out.fixedRPM = draft.fixedRPM
            case .includeGPU: out.includeGPU = draft.includeGPU
            case .curve: out.curve = draft.curve
            case .overheatAbove:
                var s = out.sounds ?? .init(); s.overheatAbove = draft.overheatAbove; out.sounds = s
            case .cooldownBelow:
                var s = out.sounds ?? .init(); s.cooldownBelow = draft.cooldownBelow; out.sounds = s
            case .maxRPM: out.maxRPM = draft.maxRPM
            case .profiles: out.profiles = draft.profiles
            }
        }
        return out
    }
}
