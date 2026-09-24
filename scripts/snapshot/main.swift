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
//                            applied / failed（套用後訊息）、guard-off、critical、gpu-throttle、nofreq、boost
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
    let stats: [(String, String)] = zh
        ? [("95°C", "4 天最高控制溫度"), ("0 秒", "熱壓力非 Nominal"), ("0 次", "hook 讓 AI 等待")]
        : [("95°C", "peak control temp"), ("0 s", "non-Nominal pressure"), ("0×", "times the AI had to wait")]
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
                Text(zh ? "Claude Code 跑重指令前先問 cool42。\nmacOS 回報 Nominal 就全速放行，回報降頻才等。\n判斷看 thermal pressure，不看溫度。"
                        : "A Claude Code hook asks cool42 before every shell command.\nNominal thermal pressure means full speed; it waits only\nwhen macOS reports throttling — pressure, not temperature.")
                    .font(.system(size: 19)).foregroundStyle(Color.white.opacity(0.72)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 32) {
                    ForEach(stats, id: \.0) { v, k in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(v).font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                            Text(k).font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.6))
                        }
                    }
                }
                .padding(.top, 8)
                Text(zh ? "Mac mini M4 實機 log · 2026-09-20 → 09-23（94 小時，macOS 27）· MIT · by Okle42"
                        : "Mac mini M4 guard logs · Sep 20–23, 2026 (94 h, macOS 27) · MIT · by Okle42")
                    .font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.4))
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
                    .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.45))
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
