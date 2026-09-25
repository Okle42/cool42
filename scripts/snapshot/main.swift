import AppKit
import SwiftUI
import Cool42Core

// cool42 面板離屏截圖（開發用，由 scripts/render-panel.sh 組進暫存 package 編譯；不進正式產品）
//
//   cool42-snapshot SCENARIO.json OUT_PREFIX                   → OUT_PREFIX-light.png、OUT_PREFIX-dark.png（@2x）
//   cool42-snapshot A.json OUT_PREFIX --mix B.json --t 0.4     → A→B 之間的過場（數值線性內插、歷史曲線視窗往 B 滑）
//   選項：--only dark|light   只輸出一種外觀
//         --lang en          介面語言（預設跟系統）：用 -AppleLanguages 重新執行自己；*.lproj 要在執行檔旁邊（render-panel.sh 會複製）
//         --variant a,b,…    在情境上疊狀態，拿來檢查各種字串長度（都是示意、不是實機值）：
//                            fixed / auto（風扇模式）、custom（曲線微調過）、dirty（有未套用的變更）、
//                            applied / failed（套用後訊息）、guard-off、critical、gpu-throttle、nofreq、boost、
//                            clock-throttle（時脈降頻：pressure 仍 Nominal）、today（「今天」卡展開＋示意事件）、
//                            health（健康檢查卡展開）、health-bad（guard 沒跑且風扇卡手動 → 頂部紅燈）、
//                            notify-denied / notify-unasked（通知授權狀態）、handed-back（緊急交還原廠之後）、
//                            profiles（三條情境規則＋上限 3200，「夜間安靜」生效中）、profile-edit（展開第 2 條編輯）、
//                            cap-suspended（降頻中上限暫停）、focus-unasked（專注模式還沒授權 → 「繼續⋯」說明）
//   cool42-snapshot --onboarding OUT_PREFIX [--lang en]   → 首次啟動導覽三頁 OUT_PREFIX-{1,2,3}-{light,dark}.png
//   cool42-snapshot --menubar OUT_PREFIX [--lang en]      → 選單列圖示各狀態 OUT_PREFIX-{light,dark}.png
//
// 情境檔（scripts/snapshot/scenarios/*.json）：
//   snapshot   Snapshot 的 JSON（和 /var/run/cool42/state.json 同格式）
//   history    [HistoryPoint]（和 /var/run/cool42/history.json 同格式）；時間會整段平移到「現在往前」，面板 X 軸才看得到
//   sensors    { "Tp00": 45.1, … } 熱度格用的每個感測器溫度
//   boostRemaining  預熱剩幾秒（選填；boostUntil 依此換算成 now + 秒數）
//
// 不開視窗、不讀螢幕：NSHostingView 放進從不 orderFront 的 borderless NSWindow，再 cacheDisplay 成 bitmap，
// 所以不需要螢幕錄製 / 輔助使用權限。AppKit 橋接的控制項（segmented、checkbox、stepper、slider）也畫得出來。

struct Scenario: Decodable {
    var snapshot: Snapshot
    var history: [HistoryPoint]
    var sensors: [String: Double]
    var boostRemaining: Double?
    /// 受控情境的圖內浮水印（例如「受控情境 · 非實機紀錄」）：有值就畫在面板右上角，單獨拿出去用也看得出是示意
    var watermark: String?
}

func loadScenario(_ path: String) -> Scenario {
    guard let d = FileManager.default.contents(atPath: path) else { fatalError("讀不到 \(path)") }
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    do { return try dec.decode(Scenario.self, from: d) } catch { fatalError("\(path) 格式錯誤：\(error)") }
}

// --lang：語言要在程式一啟動、第一次查字串表之前就定下來，所以帶 -AppleLanguages 重新執行自己
if let i = CommandLine.arguments.firstIndex(of: "--lang"), i + 1 < CommandLine.arguments.count,
   !CommandLine.arguments.contains("-AppleLanguages"), let exe = Bundle.main.executableURL {
    let p = Process()
    p.executableURL = exe
    p.arguments = Array(CommandLine.arguments.dropFirst()) + ["-AppleLanguages", "(\(CommandLine.arguments[i + 1]))"]
    do { try p.run() } catch { fatalError("重新執行失敗：\(error)") }
    p.waitUntilExit()
    exit(p.terminationStatus)
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--live" { MainActor.assumeIsolated { runLive(outDir: args[2]) } }
if args.count >= 4, args[1] == "--terminal" { MainActor.assumeIsolated { renderTerminal(framesPath: args[2], outDir: args[3]) }; exit(0) }
if args.count >= 5, args[1] == "--hero" { MainActor.assumeIsolated { renderHero(panelPNG: args[2], lang: args[3], out: args[4]) }; exit(0) }
// --selftest：面板純邏輯的自我檢查（面板是 executableTarget，Cool42CoreTests 測不到）——通知三時刻狀態機、log parser；
// 另外把本機今天的 /var/log/cool42.log 解析結果印出來（唯讀）
if args.count >= 2, args[1] == "--selftest" { MainActor.assumeIsolated { exit(selfTest() ? 0 : 1) } }
if args.count >= 3, args[1] == "--onboarding" || args[1] == "--menubar" {
    if let want = opt("--lang"), !L10n.language.hasPrefix(want) {
        FileHandle.standardError.write("要 \(want) 卻選到 \(L10n.language)\n".data(using: .utf8)!); exit(3)
    }
    NSApplication.shared.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated {
        if args[1] == "--onboarding" { renderOnboarding(outPrefix: args[2]) } else { renderMenuBar(outPrefix: args[2]) }
    }
    exit(0)
}
guard args.count >= 3 else {
    FileHandle.standardError.write("用法：cool42-snapshot SCENARIO.json OUT_PREFIX [--mix B.json --t 0…1] [--only dark|light]\n".data(using: .utf8)!)
    exit(2)
}
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

let a = loadScenario(args[1])
let outPrefix = args[2]
let b = opt("--mix").map(loadScenario)
let t = min(max(Double(opt("--t") ?? "1") ?? 1, 0), 1)
let only = opt("--only")
let variants = Set((opt("--variant") ?? "").split(separator: ",").map(String.init))
let hasProfiles = !variants.isDisjoint(with: ["profiles", "profile-edit", "cap-suspended", "focus-unasked"])

// 要求的語言真的選到了才畫（lproj 沒複製到執行檔旁邊時會默默退回繁中，截出來的「英文版」其實是中文）
if let want = opt("--lang") {
    let got = L10n.language
    guard got.hasPrefix(want) else {
        FileHandle.standardError.write("要 \(want) 卻選到 \(got)（\(L10n.container.bundlePath) 有 \(L10n.container.localizations)）\n".data(using: .utf8)!)
        exit(3)
    }
}

func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
func lerpOpt(_ x: Double?, _ y: Double?) -> Double? {
    guard let x, let y else { return t < 0.5 ? x : y }
    return lerp(x, y)
}

/// 歷史曲線：沒有 --mix 就是 A 的歷史；有的話把 A、B 接成一條時間線，5 分鐘視窗從 A 的結尾往 B 的結尾滑
func historyNow() -> [HistoryPoint] {
    let now = Date().addingTimeInterval(-2)
    func rebase(_ h: [HistoryPoint], endingAt end: Date) -> [HistoryPoint] {
        guard let last = h.last?.time else { return [] }
        let dt = end.timeIntervalSince(last)
        return h.map { var p = $0; p.time = p.time.addingTimeInterval(dt); return p }
    }
    guard let b, let bFirst = b.history.first?.time, let bLast = b.history.last?.time else { return rebase(a.history, endingAt: now) }
    // A 的尾巴接在 B 的第一點前 5 秒
    let aLine = rebase(a.history, endingAt: bFirst.addingTimeInterval(-5))
    let line = aLine + b.history
    let end = (aLine.last?.time ?? bFirst).addingTimeInterval(bLast.timeIntervalSince(aLine.last?.time ?? bFirst) * t)
    let visible = line.filter { $0.time <= end && $0.time > end.addingTimeInterval(-History.keep) }
    let dt = now.timeIntervalSince(end)
    return visible.map { var p = $0; p.time = p.time.addingTimeInterval(dt); return p }
}

func snapshotNow() -> Snapshot {
    var s = a.snapshot
    s.time = Date()
    if let b {
        let y = b.snapshot
        s.cpuMax = lerp(a.snapshot.cpuMax, y.cpuMax)
        s.cpuAvg = lerp(a.snapshot.cpuAvg, y.cpuAvg)
        s.gpuMax = lerp(a.snapshot.gpuMax, y.gpuMax)
        s.controlTemp = lerp(a.snapshot.controlTemp, y.controlTemp)
        s.ssd = lerpOpt(a.snapshot.ssd, y.ssd)
        s.fans = zip(a.snapshot.fans, y.fans).map { f, g in
            var o = f; o.rpm = lerp(f.rpm, g.rpm); o.target = lerp(f.target, g.target); o.manual = t < 0.5 ? f.manual : g.manual; return o
        }
        s.gpuActive = lerpOpt(a.snapshot.gpuActive, y.gpuActive)
        s.pcoreMHz = t < 0.15 ? a.snapshot.pcoreMHz : lerpOpt(max(a.snapshot.pcoreMHz ?? 0, y.pcoreMHz ?? 0), y.pcoreMHz)
        s.ecoreMHz = lerpOpt(a.snapshot.ecoreMHz, y.ecoreMHz)
        if t >= 0.5 {
            s.level = y.level; s.thermalPressure = y.thermalPressure; s.topProcesses = y.topProcesses
            s.stats = y.stats; s.gpuThrottlePercent = y.gpuThrottlePercent; s.guardTargetRPM = y.guardTargetRPM
        }
    }
    let boost = t >= 0.5 ? (b?.boostRemaining ?? a.boostRemaining) : a.boostRemaining
    s.boostUntil = boost.map { Date().addingTimeInterval($0 + 0.5) }
    // --variant：示意狀態（檢查字串長度用）
    if variants.contains("guard-off") { s.guardRunning = false }
    if variants.contains("critical") { s.level = .critical; s.controlTemp = max(s.controlTemp, 102) }
    if variants.contains("gpu-throttle") { s.thermalPressure = "Nominal"; s.gpuThrottlePercent = 22 }
    if variants.contains("nofreq") { s.pcoreMHz = nil; s.thermalPressure = nil }
    if variants.contains("boost") { s.boostUntil = Date().addingTimeInterval(42.5) }
    if variants.contains("clock-throttle") {
        s.thermalPressure = "Nominal"; s.clockThrottled = true; s.gpuThrottlePercent = 0
        s.pcoreMHz = 3640; s.controlTemp = max(s.controlTemp, 101); s.level = .hot
    }
    if hasProfiles {
        s.profile = Monitor.template(.time).name; s.maxRPM = Monitor.template(.time).maxRPM
        s.maxRPMSuspended = variants.contains("cap-suspended")
        if variants.contains("cap-suspended") { s.clockThrottled = true; s.controlTemp = max(s.controlTemp, 101); s.level = .hot; s.pcoreMHz = 3640 }
    }
    if variants.contains("health-bad") {
        s.guardRunning = false
        if !s.fans.isEmpty { s.fans[0].manual = true; s.fans[0].target = 3000 }
    }
    return s
}

func sensorsNow() -> [String: Double] {
    guard let b else { return a.sensors }
    var out: [String: Double] = [:]
    for (k, v) in a.sensors { out[k] = lerp(v, b.sensors[k] ?? v) }
    return out
}

NSApplication.shared.setActivationPolicy(.prohibited)

let monitor = Monitor()
/// Monitor.init 會讀本機即時快照與 /etc 設定 —— 截圖一律改用預設設定與情境資料，每次渲染前重設一次
@MainActor func inject() {
    var cfg = Config()
    cfg.sounds = nil
    if variants.contains("fixed") { cfg.mode = "fixed" }
    if variants.contains("auto") { cfg.mode = "auto" }
    if variants.contains("custom") { cfg.curve[2].rpm += 150 }
    if hasProfiles { cfg.maxRPM = 3200; cfg.profiles = [Monitor.template(.apps), Monitor.template(.time), Monitor.template(.focus)] }
    monitor.config = cfg
    monitor.draft = cfg
    if variants.contains("dirty") { monitor.draft.fixedRPM += 500; monitor.draft.curve[1].rpm += 100; monitor.draftCooldownBelow -= 2 }
    monitor.saveMessage = nil
    monitor.saveFailed = false
    if variants.contains("applied") { monitor.saveMessage = L("已套用（%@）", "config.json") }
    if variants.contains("failed") {
        monitor.saveMessage = L("寫入失敗：%@", CocoaError(.fileWriteNoPermission).localizedDescription); monitor.saveFailed = true
    }
    monitor.showSensors = true          // didSet 會讀一次即時 SMC，下一行蓋掉
    monitor.sensorTemps = sensorsNow()
    monitor.snapshot = snapshotNow()
    monitor.history = historyNow()
    // 新手安心／一眼看懂的區塊：預設收合、通知已允許；variant 再疊狀態
    monitor.showToday = variants.contains("today")
    monitor.todayEvents = variants.contains("today") ? sampleToday() : []
    monitor.totalToday = monitor.todayEvents.count
    monitor.todayThrottles = monitor.todayEvents.filter { $0.kind == .throttleStart }.count
    monitor.todayBoosts = monitor.todayEvents.filter { $0.kind == .boost }.reduce(0) { $0 + ($1.boost?.count ?? 1) }
    // 情境卡、偏好卡預設收合；有情境示意、通知授權示意時展開
    monitor.showProfiles = hasProfiles
    monitor.showPrefs = variants.contains("prefs") || variants.contains("notify-denied") || variants.contains("notify-unasked")
    monitor.showHealth = variants.contains("health") || variants.contains("health-bad")
    monitor.health = Health.run(snapshot: monitor.snapshot, config: cfg)
    monitor.notifyOn = true
    monitor.notifyAuth = variants.contains("notify-denied") ? .denied : variants.contains("notify-unasked") ? .notDetermined : .allowed
    monitor.editingProfile = variants.contains("profile-edit") ? 1 : nil
    monitor.focusAuth = variants.contains("focus-unasked") ? .notDetermined : .allowed
    monitor.focusNow = false
    if variants.contains("handed-back") { monitor.config.mode = "auto"; monitor.draft.mode = "auto"; monitor.emergencyPrevMode = "curve" }
    else { monitor.emergencyPrevMode = nil }
}

/// 「今天」卡的示意事件：拿 guard 的真實 log 格式（Sources/cool42/Guard.swift）跑面板的 parser，順便驗 parser
func sampleToday() -> [DayEvent] {
    let d = Snapshot.Stats.today()
    let raw = [
        "\(d) 09:12:03 cool42 guard 啟動（Apple M4，1 顆風扇，每 5.0s，模式 curve，GPU 納入，控制中）",
        "\(d) 10:41:22 預熱 2000 rpm 到 \(d) 10:43:22：swift build",
        "\(d) 10:41:32 預熱加碼 3000 rpm：72°C（10 秒內 +14°C）",
        "\(d) 10:43:00 預熱 3000 rpm 到 \(d) 10:45:00：swift build",
        "\(d) 10:43:31 預熱提早結束：31 秒後仍只有 46°C，不像重工作",
        "\(d) 11:02:00 學到：pytest 不再預熱（連續 3 次預熱 30 秒後都不像重工作，暫停到 \(d) 23:59:00）",
        "\(d) 11:05:00 略過預熱：pytest 已學到不像重工作（\(d) 23:59:00 恢復）",
        "\(d) 11:07:10 略過預熱：pytest 已學到不像重工作（\(d) 23:59:00 恢復）",
        "\(d) 12:00:00 情境「剪片」生效：Final Cut Pro 在跑；曲線 performance",
        "\(d) 13:05:10 預熱 3000 rpm 到 \(d) 13:07:10：ffmpeg",
        "\(d) 13:06:40 等級 warm → hot（🟠 96°C 🌀3400rpm ⚡3.94GHz）",
        "\(d) 13:08:15 ⚠️ 熱降頻開始：時脈（pressure 仍 Nominal），P-core 3640 MHz，GPU CLTM 0%（🔴 101°C 🌀4900rpm ⚡3.64GHz 降頻(時脈)）",
        "\(d) 13:08:15 噪音上限 3200 rpm 暫停：降頻中，風扇不受上限限制（🔴 101°C 🌀4900rpm）",
        "\(d) 13:09:02 等級 hot → critical（🔴 108°C 🌀4900rpm ⚡3.60GHz）",
        "\(d) 13:10:30 等級 critical → warm（🟡 88°C 🌀4600rpm ⚡3.90GHz）",
        "\(d) 13:10:31 熱降頻結束：P-core 3936 MHz（🟡 88°C 🌀4600rpm ⚡3.94GHz）",
        "\(d) 13:12:00 噪音上限 3200 rpm 恢復：已低於 92°C 連續 6 輪、沒有降頻，照一般降速節奏降回上限（🟡 88°C 🌀4600rpm）",
        "\(d) 14:30:00 情境「剪片」結束，回到基本設定",
        "\(d) 15:20:00 設定已重載：模式 auto，曲線 60→1000 75→1800 85→2600 92→3600 97→4900",
    ].map { Substring($0) }
    var ev = DayLog.parse(raw)
    let f = DayLog.stamp
    ev.append(DayEvent(time: f.date(from: "\(d) 13:08:40")!, kind: .hookWait, text: L("AI指令等降頻結束才執行")))
    return ev.sorted { $0.time > $1.time }
}

/// 視窗本身的底（正式 app 由 NSPanel 畫圓角與背景，這裡照著畫）
struct Shot: View {
    let monitor: Monitor
    var watermark: String? = nil
    var body: some View {
        VStack(spacing: 0) {
            // 受控情境：浮水印獨立一列放在最上面（不蓋住面板內容），截圖單獨流出去也看得出是示意
            if let watermark { HStack { Spacer(); SimTag(text: watermark) }.padding(.top, 10).padding(.horizontal, 12) }
            PanelView(monitor: monitor).content
        }
            .background(Neon.panelBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Neon.hairline, lineWidth: 1))
    }
}

/// 受控情境膠囊：高對比（琥珀底、深色字），面板幀、終端機幀、單張截圖都用同一款、放右上角
struct SimTag: View {
    let text: String
    var size: CGFloat = 12
    var body: some View {
        Text(text).font(.system(size: size, weight: .bold)).foregroundStyle(Color(red: 0.12, green: 0.08, blue: 0.02))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color(red: 1, green: 0.74, blue: 0.30), in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
    }
}

@MainActor func render(_ appearance: NSAppearance.Name, to path: String) {
    inject()
    let host = NSHostingView(rootView: Shot(monitor: monitor, watermark: a.watermark))
    host.appearance = NSAppearance(named: appearance)
    let size = host.fittingSize
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: appearance)
    win.isOpaque = false
    win.backgroundColor = .clear
    win.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    // Charts 與橋接控制項在第一次 layout 後才定形：轉兩次 runloop 再重設資料（期間的 Timer tick 會讀即時快照）
    for _ in 0..<2 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        inject()
        host.layoutSubtreeIfNeeded()
    }
    let finalSize = host.fittingSize
    if finalSize != size { host.frame = NSRect(origin: .zero, size: finalSize); win.setContentSize(finalSize); host.layoutSubtreeIfNeeded() }
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale), pixelsHigh: Int(host.bounds.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("bitmap") }
    rep.size = host.bounds.size
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        host.cacheDisplay(in: host.bounds, to: rep)
    }
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try! png.write(to: URL(fileURLWithPath: path))
    print("\(path)  \(rep.pixelsWide)×\(rep.pixelsHigh)")
}

MainActor.assumeIsolated {
    if let title = opt("--stage") {
        // GIF 幀：面板上半截（深色）+ 右側說明
        renderStage(title: title, body: opt("--body") ?? "", tag: opt("--tag"), to: outPrefix + ".png")
    } else {
        if only != "light" { render(.darkAqua, to: outPrefix + "-dark.png") }
        if only != "dark" { render(.aqua, to: outPrefix + "-light.png") }
    }
}
exit(0)

// MARK: - 終端機畫面（GIF 用）

/// 終端機幀：每幀是一串行，每行一種樣式。文字由 frames 檔提供 —— 輸出字串要照 Sources/cool42/Hook.swift、main.swift 的真實格式
struct TermFrame: Decodable {
    struct Line: Decodable {
        var text: String
        var style: String?   // prompt | cmd | out | dim | note | ok | warn | hot | blank
    }
    var name: String
    var title: String?
    var lines: [Line]
    var footnote: String?
    var caption: String?
    /// 受控情境標示（右上角膠囊，和面板幀同款）
    var tag: String?
}

struct TerminalView: View {
    let frame: TermFrame
    let width: CGFloat
    let height: CGFloat
    static let bg = Color(red: 0.075, green: 0.08, blue: 0.10)

    func color(_ style: String?) -> Color {
        switch style {
        case "prompt": return Color(red: 0.85, green: 0.47, blue: 0.34)          // 使用者輸入
        case "cmd": return Color.white
        case "dim", "note": return Color.white.opacity(0.48)
        case "ok": return Color(red: 0.36, green: 0.95, blue: 0.55)
        case "warn": return Color(red: 1.00, green: 0.72, blue: 0.30)
        case "hot": return Color(red: 1.00, green: 0.42, blue: 0.46)
        default: return Color.white.opacity(0.86)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { c in
                        Circle().fill(c).frame(width: 12, height: 12)
                    }
                    Spacer()
                }
                Text(frame.title ?? "zsh").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.white.opacity(0.55))
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(Color.white.opacity(0.05))
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(frame.lines.enumerated()), id: \.offset) { _, l in
                    if l.style == "blank" {
                        Color.clear.frame(height: 6)
                    } else {
                        Text(l.text)
                            .font(.system(size: 14, weight: l.style == "cmd" || l.style == "prompt" ? .semibold : .regular, design: .monospaced))
                            .italic(l.style == "note")
                            .foregroundStyle(color(l.style))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let f = frame.footnote {
                    Text(f).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.38))
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .background(Self.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

/// 任何 SwiftUI view → @2x PNG（放進不顯示的視窗再 cacheDisplay，橋接控制項才畫得出來）
@MainActor func exportPNG<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name = .darkAqua, reinject: Bool = false, to path: String) {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.appearance = NSAppearance(named: appearance)
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: appearance); win.isOpaque = false; win.backgroundColor = .clear
    win.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    // 面板幀要在 runloop 轉過（Monitor 的 Timer 可能讀了即時快照）之後重設情境；終端機 / hero 沒有 Monitor，不必
    for _ in 0..<2 { RunLoop.current.run(until: Date().addingTimeInterval(0.15)); if reinject { inject() }; host.layoutSubtreeIfNeeded() }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("\(path)  \(rep.pixelsWide)×\(rep.pixelsHigh)")
}

/// GIF / 宣傳圖共用的底色與字（深色，和面板同一家族）
enum Stage {
    static let bg = LinearGradient(colors: [Color(red: 0.035, green: 0.04, blue: 0.065), Color(red: 0.07, green: 0.08, blue: 0.13)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
    static let size = CGSize(width: 880, height: 560)
}

struct StageCaption: View {
    let title: String, body_: String, tag: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let tag {
                Text(tag).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.72, blue: 0.30))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color(red: 1, green: 0.72, blue: 0.30).opacity(0.14), in: Capsule())
            }
            Text(title).font(.system(size: 28, weight: .bold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Text(body_).font(.system(size: 17)).foregroundStyle(Color.white.opacity(0.70)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("cool42 · by Okle42").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white.opacity(0.35))
        }
    }
}

/// 面板上半截：標題、狀態、溫度、熱度格、風扇 —— 高度裁在 528，下緣淡出
struct PanelCrop: View {
    let monitor: Monitor
    var height: CGFloat = 528
    var body: some View {
        Shot(monitor: monitor)
            .frame(height: height, alignment: .top)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .environment(\.colorScheme, .dark)
    }
}

@MainActor func renderStage(title: String, body: String, tag: String?, to path: String) {
    inject()
    let v = ZStack(alignment: .topLeading) {
        Stage.bg
        HStack(alignment: .top, spacing: 40) {
            PanelCrop(monitor: monitor).frame(width: 352)
            StageCaption(title: title, body_: body, tag: tag).padding(.top, 36).padding(.bottom, 8)
        }
        .padding(.leading, 28).padding(.trailing, 36).padding(.top, 16)
    }
    exportPNG(v, size: Stage.size, reinject: true, to: path)
}

/// README 用的 hero：左文案、右面板上半截
@MainActor func renderHero(panelPNG: String, lang: String, out: String) {
    guard let img = NSImage(contentsOfFile: panelPNG) else { fatalError("讀不到 \(panelPNG)") }
    let zh = lang != "en"
    // 三個數字出自 docs/perf-2026-09-25/（CPU＋GPU 滿載、同一台 Mac mini M4；原廠穩態只有 1 輪，限制寫在頁尾與該 README）：
    //   −7.4% ＝ 原廠自動 P-core 3,643.8 / 3936 MHz（run3 pm/04-auto-r2.txt 90 筆），pressure 79/79＋90/90 Nominal
    //   2,951 rpm ＝ 原廠自動取樣窗風扇（run3 results.csv 第 5 行）；4,900 是韌體上限，cool42 曲線同負載跑到 4,854–4,910
    //   3.94 GHz ＝ cool42 曲線兩輪 powermetrics 180/180 筆 3936 MHz（run4 pm/01、03）
    let stats: [(String, String)] = zh
        ? [("−7.4%", "原廠 P-core 時脈\nmacOS 仍回報 Nominal"), ("2,951 rpm", "原廠風扇停在這\n上限是 4,900"), ("3.94 GHz", "cool42 曲線同負載\n取樣窗全速（180/180 筆）")]
        : [("−7.4%", "stock P-core clock,\nstill reported Nominal"), ("2,951 rpm", "where stock parks the fan\n(max 4,900)"), ("3.94 GHz", "cool42 curve, same load,\n180/180 at full speed")]
    // 面板只取到風扇卡為止：風扇卡下緣在 535.5pt（352pt 寬時；中英文相同），裁在 536，
    // 下面再補 16pt 面板底色（和左右留白一樣寬），框的下緣就是收好的面板底邊，不會切到下一張卡
    let cropH: CGFloat = 536, tail: CGFloat = 16
    let panelBG = Color(red: 15 / 255, green: 18 / 255, blue: 28 / 255)   // 面板深色底（取樣自 panel-*-dark.png）
    let v = ZStack(alignment: .topLeading) {
        Stage.bg
        HStack(alignment: .center, spacing: 56) {
            VStack(alignment: .leading, spacing: 20) {
                Text(zh ? "cool42 · Apple Silicon 風扇守門員" : "cool42 · a fan guard for Apple Silicon")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(red: 0.16, green: 0.87, blue: 0.96))
                Text(zh ? "AI 寫程式時，\n自己看降頻排隊。" : "Your AI agent checks for\nthrottling before it builds.")
                    .font(.system(size: zh ? 52 : 48, weight: .bold)).foregroundStyle(.white).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                Text(zh ? "Claude Code 跑重指令前先問 cool42，真的降頻才等。\n這次實測原廠讓 P-core 掉 7.4%、風扇停在 2,951 rpm，\nmacOS 還回報「沒降頻」；\n所以 cool42 同時看熱壓力、GPU 限頻和 P-core 時脈。"
                        : "A Claude Code hook asks cool42 before every shell command\nand waits only when the Mac is really throttling. In this test stock\nmacOS let the P-cores drop 7.4% rather than spin the fan\npast ~2,950 rpm, and still reported Nominal — so cool42\nchecks the clock, too.")
                    .font(.system(size: 19)).foregroundStyle(Color.white.opacity(0.72)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 24) {
                    ForEach(stats, id: \.0) { v, k in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(v).font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Text(k).font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.66)).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 184, alignment: .leading)
                    }
                }
                .padding(.top, 8)
                Text(zh ? "同一台 Mac mini M4 · 2026-09-25 · CPU＋GPU 滿載 · 原廠穩態 n=1\n資料與限制：docs/perf-2026-09-25 · MIT · by Okle42"
                        : "One Mac mini M4 · Sep 25, 2026 · CPU+GPU load · stock steady state n=1\nData and caveats: docs/perf-2026-09-25 · MIT · by Okle42")
                    .font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.55)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 600, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    Image(nsImage: img).resizable().frame(width: 352, height: 352 * img.size.height / img.size.width)
                        .frame(height: cropH, alignment: .top).clipped()
                    panelBG.frame(width: 352, height: tail)
                }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                Text(zh ? "面板上半部 · 實機取樣（ffmpeg 4K 編碼）" : "Top of the panel · real capture (ffmpeg 4K encode)")
                    .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 88).frame(maxHeight: .infinity)
    }
    exportPNG(v, size: CGSize(width: 1280, height: 720), to: out)
}

@MainActor func renderTerminal(framesPath: String, outDir: String) {
    guard let d = FileManager.default.contents(atPath: framesPath),
          let frames = try? JSONDecoder().decode([TermFrame].self, from: d) else { fatalError("讀不到 \(framesPath)") }
    for f in frames {
        let v = ZStack(alignment: .topLeading) {
            Stage.bg
            VStack(alignment: .leading, spacing: 12) {
                Text(f.caption ?? "").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                TerminalView(frame: f, width: 824, height: 470)
            }
            .padding(.horizontal, 28).padding(.top, 18)
            if let tag = f.tag {
                HStack { Spacer(); SimTag(text: tag, size: 14) }.padding(.top, 70).padding(.trailing, 48)
            }
        }
        exportPNG(v, size: Stage.size, to: (outDir as NSString).appendingPathComponent(f.name + ".png"))
    }
}

// MARK: - 實機玻璃截圖（--live）

/// 離屏 cacheDisplay 畫不出 behind-window 的 Liquid Glass，所以這裡跑「真的」面板：
/// PanelApp.swift 的 AppDelegate 原封不動啟動（NSPanel ＋ applyBackground 的 NSGlassEffectView、即時 guard 資料），
/// 面板後面墊一個受控的背景視窗（模擬亮 / 暗 / 花俏桌布，不動使用者的桌布設定），
/// 依序切 外觀 × 背景，用 /usr/sbin/screencapture -R 截合成後的螢幕區域（含面板四角與陰影）。
/// 需要終端機已有「螢幕錄製」權限（scripts/snapshot/capture-glass.sh 會先 CGPreflightScreenCaptureAccess，沒有就不跑，不會跳視窗）。
/// 「增加對比」是系統全域設定，這裡不去切；改用 NSAppearance 的 accessibilityHighContrast* 外觀檢查面板自己的配色
/// （玻璃本身對「增加對比」的反應要真的打開系統設定才看得到）。
@MainActor func runLive(outDir: String) -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) { FileHandle.standardError.write("逾時\n".data(using: .utf8)!); exit(1) }
    let backdrops: [(String, [NSColor])] = [
        ("bright", [NSColor(srgbRed: 0.99, green: 0.98, blue: 0.93, alpha: 1), NSColor(srgbRed: 0.78, green: 0.89, blue: 1.00, alpha: 1)]),
        ("dark", [NSColor(srgbRed: 0.03, green: 0.03, blue: 0.05, alpha: 1), NSColor(srgbRed: 0.14, green: 0.11, blue: 0.24, alpha: 1)]),
        ("vivid", [NSColor(srgbRed: 1.00, green: 0.55, blue: 0.10, alpha: 1), NSColor(srgbRed: 0.85, green: 0.15, blue: 0.55, alpha: 1),
                   NSColor(srgbRed: 0.10, green: 0.65, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.95, green: 0.90, blue: 0.20, alpha: 1)]),
    ]
    var looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    if CommandLine.arguments.contains("--hc") { looks += [("light-hc", .accessibilityHighContrastAqua), ("dark-hc", .accessibilityHighContrastDarkAqua)] }
    var jobs: [(String, NSAppearance.Name, String, [NSColor])] = []
    for (ln, look) in looks { for (bn, cols) in backdrops { jobs.append((ln, look, bn, cols)) } }

    var backdrop: NSWindow? = nil
    func step(_ i: Int) {
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.title == "cool42" }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step(i) }; return
        }
        guard i < jobs.count else { exit(0) }
        let (ln, look, bn, cols) = jobs[i]
        let screen = panel.screen ?? NSScreen.main!
        let vf = screen.visibleFrame
        // 面板放左上角（不擋使用者右上角的真面板），高度由 autoHeight 跟內容
        // 高度收在可視範圍內（四角與陰影都要截得到），內容捲回最上面（標題列、狀態句是直接壓在玻璃上的字）
        var f = panel.frame
        f.size.height = min(f.height, vf.height - 100)
        f.origin = NSPoint(x: vf.minX + 60, y: vf.maxY - 40 - f.size.height)
        panel.setFrame(f, display: true)
        func scrollTop(_ v: NSView) {
            if let sv = v as? NSScrollView, let doc = sv.documentView {
                doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? 0 : max(0, doc.bounds.height - sv.contentView.bounds.height)))
            }
            v.subviews.forEach(scrollTop)
        }
        if let cv = panel.contentView { scrollTop(cv) }
        let area = f.insetBy(dx: -28, dy: -28)
        if backdrop == nil {
            let w = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            w.ignoresMouseEvents = true
            w.contentView = NSView()
            w.contentView?.wantsLayer = true
            backdrop = w
        }
        backdrop!.setFrame(area, display: true)
        let g = CAGradientLayer()
        g.colors = cols.map(\.cgColor)
        g.startPoint = CGPoint(x: 0, y: 1); g.endPoint = CGPoint(x: 1, y: 0)
        g.frame = CGRect(origin: .zero, size: area.size)
        backdrop!.contentView!.layer = g
        backdrop!.orderFront(nil)
        panel.orderFront(nil)
        NSApp.appearance = NSAppearance(named: look)
        // 等玻璃重新取樣、Charts 重畫
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            let sh = screen.frame.maxY   // screencapture 用左上原點
            let r = "\(Int(area.minX)),\(Int(sh - area.maxY)),\(Int(area.width)),\(Int(area.height))"
            let out = (outDir as NSString).appendingPathComponent("glass-\(ln)-\(bn).png")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R" + r, out]
            try? p.run(); p.waitUntilExit()
            print("\(out)  rect \(r)  panel \(Int(panel.frame.width))×\(Int(panel.frame.height))")
            step(i + 1)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { step(0) }
    app.run()
    exit(0)
}


// MARK: - 首次啟動導覽、選單列圖示

@MainActor func renderOnboarding(outPrefix: String) {
    for page in 0..<Onboarding.pageCount {
        for (name, look) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let v = OnboardingView(page: page).background(Color(nsColor: .windowBackgroundColor))
            let probe = NSHostingView(rootView: v)
            probe.appearance = NSAppearance(named: look)
            exportPNG(v, size: probe.fittingSize, appearance: look, to: "\(outPrefix)-\(page + 1)-\(name).png")
        }
    }
}

/// 選單列圖示：每個狀態一格（圖示＋溫度），最後一格是「只顯示圖示」；底色模擬淺 / 深選單列
@MainActor func renderMenuBar(outPrefix: String) {
    // (標籤, 符號, 降頻, hot 點, 溫度字)；溫度字和正式面板一樣補 figure space 到三位數寬
    let pad = { (t: Int) in " " + String(repeating: "\u{2007}", count: max(0, 3 - String(t).count)) + "\(t)°" }
    let states: [(String, String, Bool, Bool, String)] = [
        (L("正常"), Level.ok.symbol, false, false, pad(52)),
        (L("偏溫"), Level.warm.symbol, false, false, pad(84)),
        (L("過熱"), Level.hot.symbol, false, true, pad(96)),
        (L("危險"), Level.critical.symbol, false, false, pad(109)),
        (L("時脈"), Level.hot.symbol, true, true, pad(101)),
        (L("在選單列顯示溫度") + " ✕", Level.hot.symbol, true, true, ""),
        (L("在選單列顯示溫度") + " ✕", Level.warm.symbol, false, false, ""),
    ]
    struct Strip: View {
        let states: [(String, String, Bool, Bool, String)]
        var body: some View {
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, st in
                    VStack(spacing: 6) {
                        HStack(spacing: 0) {
                            if let img = StatusIcon.image(symbol: st.1, throttled: st.2, hotDot: st.3) {
                                Image(nsImage: img).renderingMode(.template).foregroundStyle(.primary)
                            }
                            if !st.4.isEmpty { Text(verbatim: st.4).font(Font(NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))) }
                        }
                        .padding(.horizontal, 6).frame(height: 24)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(verbatim: st.0).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(14)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    for (name, look) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        let v = Strip(states: states)
        let probe = NSHostingView(rootView: v)
        probe.appearance = NSAppearance(named: look)
        exportPNG(v, size: probe.fittingSize, appearance: look, to: "\(outPrefix)-\(name).png")
    }
}


@MainActor func selfTest() -> Bool {
    var ok = true
    func check(_ c: Bool, _ what: String) { print((c ? "✓ " : "✗ ") + what); if !c { ok = false } }
    // 通知狀態機（以一段過熱為單位；t 是秒數）
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ sec: Double) -> Date { t0.addingTimeInterval(sec) }
    var n = NotifyState()
    check(n.step(throttled: true, level: .hot, now: at(0)).isEmpty, "第一輪只記狀態、不發（啟動時已在降頻也不補發）")
    check(n.step(throttled: false, level: .ok, now: at(5)).isEmpty, "啟動時就在降頻：沒發過警告，恢復也不發")
    check(n.step(throttled: false, level: .warm, now: at(10)).isEmpty, "平常 warm 不發")
    check(n.step(throttled: true, level: .hot, now: at(20)) == [.throttle], "開始降頻發一次")
    check(n.step(throttled: true, level: .hot, now: at(25)).isEmpty, "持續降頻不重發")
    check(n.step(throttled: true, level: .critical, now: at(30)) == [.critical], "進 critical 發一次")
    check(n.step(throttled: false, level: .warm, now: at(40)).isEmpty, "剛退到 warm：還沒穩定 2.5 分鐘，不算恢復")
    check(n.step(throttled: true, level: .hot, now: at(60)).isEmpty, "同一段裡又降頻：不重發")
    check(n.step(throttled: false, level: .warm, now: at(70)).isEmpty, "又退下來：重新計時")
    check(n.step(throttled: false, level: .warm, now: at(70 + 150)) == [.recovered], "穩定正常 2.5 分鐘 → 恢復正常（這段發過警告）")
    check(n.step(throttled: false, level: .ok, now: at(300)).isEmpty, "恢復只發一次")
    check(n.step(throttled: true, level: .hot, now: at(600)).isEmpty, "恢復後 30 分鐘內又降頻：同一段的延續，不再發")
    check(n.step(throttled: false, level: .ok, now: at(610)).isEmpty && n.step(throttled: false, level: .ok, now: at(800)).isEmpty,
          "延續段沒發過警告：恢復也不發")
    check(n.step(throttled: true, level: .hot, now: at(800 + 1900)) == [.throttle], "上一段結束超過 30 分鐘：新的一段，照發")
    var m = NotifyState(); _ = m.step(throttled: false, level: .ok, now: at(0))
    check(m.step(throttled: true, level: .critical, now: at(5)) == [.throttle, .critical], "同一輪降頻＋critical 兩則都發")
    // log parser
    let ev = sampleToday()
    check(ev.count == 16, "示意 log 解析出 16 件（實得 \(ev.count)）")
    check(ev.contains { $0.kind == .throttleStart && $0.text.contains(L("時脈")) }, "時脈降頻寫成「時脈」，不是 pressure 的「正常」")
    check(ev.filter { $0.kind == .boost }.count == 2, "預熱 2 筆：swift build 加碼後被延長仍併成一筆，提早結束併進去")
    check(ev.contains { $0.kind == .boost && $0.boost?.rpm == 3000 && $0.boost?.count == 2 }, "預熱加碼後那一筆顯示 3000 rpm、×2")
    check(ev.contains { $0.kind == .boostSkip && $0.boost?.count == 2 }, "略過預熱併成一筆 ×2")
    check(ev.contains { $0.kind == .learn }, "學到：有記")
    check(ev.filter { $0.kind == .profile }.count == 2, "情境生效／結束各一筆")
    check(ev.filter { $0.kind == .cap }.count == 2, "噪音上限暫停／恢復各一筆")
    check(ev.contains { $0.kind == .boost && $0.boost?.early == 1 && $0.boost?.lastEarlySecs == 31 }, "提早結束併進同一筆（次數與秒數）")
    check(ev.contains { $0.kind == .mode }, "模式改成 auto 有記")
    check(!DayLog.parse(["garbage", "2026-09-25 12:00:00 🟢 70°C 🌀1000rpm → 交還自動"].map { Substring($0) }).contains { _ in true }, "高頻行與壞行不收")
    // 本機今天（唯讀）
    let real = DayLog.parse(DayLog.todayLines()).sorted { $0.time > $1.time }
    print("本機今天：\(real.count) 件")
    for e in real.prefix(20) { print("  \(PanelView.hm.string(from: e.time))  \(e.kind.rawValue)  \(e.text)") }
    return ok
}
