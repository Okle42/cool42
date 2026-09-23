import AppKit
import SwiftUI
import Cool42Core

// cool42 面板離屏截圖（開發用，由 scripts/render-panel.sh 組進暫存 package 編譯；不進正式產品）
//
//   cool42-snapshot SCENARIO.json OUT_PREFIX                   → OUT_PREFIX-light.png、OUT_PREFIX-dark.png（@2x）
//   cool42-snapshot A.json OUT_PREFIX --mix B.json --t 0.4     → A→B 之間的過場（數值線性內插、歷史曲線視窗往 B 滑）
//   選項：--only dark|light   只輸出一種外觀
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
}

func loadScenario(_ path: String) -> Scenario {
    guard let d = FileManager.default.contents(atPath: path) else { fatalError("讀不到 \(path)") }
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    do { return try dec.decode(Scenario.self, from: d) } catch { fatalError("\(path) 格式錯誤：\(error)") }
}

let args = CommandLine.arguments
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
    monitor.config = cfg
    monitor.draft = cfg
    monitor.saveMessage = nil
    monitor.showSensors = true          // didSet 會讀一次即時 SMC，下一行蓋掉
    monitor.sensorTemps = sensorsNow()
    monitor.snapshot = snapshotNow()
    monitor.history = historyNow()
}

/// 視窗本身的底（正式 app 由 NSPanel 畫圓角與背景，這裡照著畫）
struct Shot: View {
    let monitor: Monitor
    var body: some View {
        PanelView(monitor: monitor).content
            .background(Neon.panelBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Neon.hairline, lineWidth: 1))
    }
}

@MainActor func render(_ appearance: NSAppearance.Name, to path: String) {
    inject()
    let host = NSHostingView(rootView: Shot(monitor: monitor))
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
        ? [("95°C", "4 天最高控制溫度"), ("0 秒", "降頻"), ("0 次", "hook 讓 AI 等待")]
        : [("95°C", "peak control temp"), ("0 s", "throttled"), ("0×", "times the AI had to wait")]
    let v = ZStack(alignment: .topLeading) {
        Stage.bg
        HStack(alignment: .center, spacing: 56) {
            VStack(alignment: .leading, spacing: 20) {
                Text(zh ? "cool42 · Apple Silicon 風扇守門員" : "cool42 · a fan guard for Apple Silicon")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(red: 0.16, green: 0.87, blue: 0.96))
                Text(zh ? "AI 寫程式時，\n自己看溫度排隊。" : "Your AI agent checks\nthe heat before it builds.")
                    .font(.system(size: 52, weight: .bold)).foregroundStyle(.white).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                Text(zh ? "Claude Code 跑重指令前先問 cool42：沒降頻就全速放行，真的降頻才等。判斷看 thermal pressure，不看溫度。"
                        : "A Claude Code hook asks cool42 before every shell command. Not throttling means full speed — it only waits when the chip is actually throttling, judged by thermal pressure, not temperature.")
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
                Text(zh ? "Mac mini M4 實機 log · 2026-09-20 → 09-23（94 小時）· 0 外部依賴 · MIT · by Okle42"
                        : "Real guard logs from a Mac mini M4 · Sep 20–23, 2026 (94 h) · zero dependencies · MIT · by Okle42")
                    .font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.4))
            }
            .frame(width: 600, alignment: .leading)
            Image(nsImage: img).resizable().frame(width: 352, height: 352 * img.size.height / img.size.width)
                .frame(height: 640, alignment: .top).clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
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
        }
        exportPNG(v, size: Stage.size, to: (outDir as NSString).appendingPathComponent(f.name + ".png"))
    }
}
