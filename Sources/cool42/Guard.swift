import Foundation
import Cool42Core

// MARK: - guard

/// guard 的 log：root 時自己 append 到 /var/log/cool42.log（帶時間戳；newsyslog 輪替後自然寫到新檔），否則走 stderr
// （放在 enum 裡用 static：main.swift 的頂層 let 是依序初始化的，runGuard 被呼叫時它們還沒建好）
enum GuardLog {
    static let path = "/var/log/cool42.log"
    static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
}
func guardLog(_ m: String, toFile: Bool) {
    let line = "\(GuardLog.stamp.string(from: Date())) \(m)\n"
    if toFile, let d = line.data(using: .utf8) {
        if !FileManager.default.fileExists(atPath: GuardLog.path) {
            FileManager.default.createFile(atPath: GuardLog.path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        if let fh = FileHandle(forWritingAtPath: GuardLog.path) {
            fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
            return
        }
    }
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

/// 常駐控制迴圈（需 root 才能寫 SMC）。config 檔改動會自動重載（面板改模式/曲線即時生效）
func runGuard(config initial: Config, dryRun: Bool, interval: Double) throws {
    let isRoot = getuid() == 0
    if !isRoot && !dryRun {
        throw Cool42Error.usage("guard 需要 root 才能寫風扇（sudo cool42 guard），或加 --dry-run 只觀察")
    }
    func log(_ m: String) { guardLog(m, toFile: isRoot && !dryRun) }
    if macsFanControlRunning() {
        log("⚠️ Macs Fan Control 正在執行，兩者會互搶風扇控制；建議先退出它。")
    }
    let fanCount = SMC.fanCount
    guard fanCount > 0 else { throw Cool42Error.smc("找不到風扇（FNum=0）") }

    // baseConfig = 設定檔原樣；config = 套用目前情境規則後的有效設定（每輪重算，其餘程式碼一律用 config）
    var baseConfig = initial
    var config = initial
    var configMtime = Config.mtime(baseConfig.loadedFrom)
    // 執行期目錄（快照、歷史、事件）：必須是 root 自己的真目錄，不然一個 symlink 就能讓 root 覆寫任意檔
    guard Event.prepareDir() else {
        throw Cool42Error.usage("\(Snapshot.runDir) 不是 root 擁有的目錄（被換成 symlink 或別人的？），拒絕啟動。移除它再重啟 guard")
    }
    // 硬體頻率與 thermal pressure：root 才讀得到（powermetrics）
    let freq = FreqReader(interval: interval)
    let gpuStats = GPUStats()
    let procTop = ProcTop()
    if FreqReader.available { freq.ensureRunning() } else { log("powermetrics 不可用（非 root 或找不到），不顯示頻率") }

    // 終止訊號：SIGTERM（launchd 停止 / 重啟）保持目前轉速不交還 —— 重啟接管只要幾秒，交還自動反而讓高負載下 30 秒衝到 100°C；
    // SIGINT（Ctrl-C）/ SIGHUP 才交還自動。uninstall.sh 會明確 `cool42 fan auto`
    var stopping = false
    var keepFansOnExit = false
    let restore = {
        if !dryRun { for i in 0..<fanCount { try? SMC.setFanAuto(i) } }
    }
    defer { freq.stop() }
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { stopping = true; keepFansOnExit = (sig == SIGTERM) }
        src.resume()
        _ = Unmanaged.passRetained(src as AnyObject)
    }

    let boostGraceSeconds = 30.0 // 預熱至少撐這麼久才判斷要不要提早收
    var lastTarget: Double = -1
    var forceWrite = false       // 設定重載後這輪不管 deadband 一定寫
    var auto = true              // 目前是否交還 SMC 自動
    var smoothed: Double? = nil  // 控制溫度 EMA（升溫快、降溫慢）
    var lastLevel: Level? = nil
    var wasThrottling = false
    var clockThrottled = false   // 時脈降頻（無聲降頻）狀態，進出有遲滯
    let chip = chipName()
    var lastFreqError: String? = nil
    var coolRounds = 0           // 連續幾輪目標低於現在（降速前的等待計數）
    var faultStreak = 0          // 連續感測器故障輪數
    var boostUntil: Date? = nil
    var boostRPM: Double = 0
    var boostStart: Date? = nil  // 這一波預熱從何時開始（判斷「預熱了 30 秒溫度還沒起來」用）
    var levelCoolRounds = 0      // 等級連續幾輪該降（降級前的等待計數，和風扇降速同一個 rampDownHoldRounds）
    // 安靜優先：接管去抖、預熱漸進、預熱學習（純邏輯在 Cool42Core/Quiet.swift）
    var takeover = TakeoverGate()
    var boostEscalated = false   // 這一波預熱是否已從 boostStartRPM 加碼到 boostRPM
    // 這一波預熱「開頭那個事件」的關鍵字（學習用）。只記開波的那一個、而且只收主控台使用者自己丟的事件：
    // 事件目錄任何本機帳號都能丟，延長事件也算進來的話，一波內把 17 個關鍵字各丟一次就能把它們全學成不預熱
    var boostKeyword: String? = nil
    var recentTemps: [(time: Date, temp: Double)] = []   // 最近幾輪的原始控制溫度（判斷升溫速率）
    let persistLearner = isRoot && !dryRun
    var learner = BoostLearner.load(expectOwner: persistLearner ? 0 : nil)
    for k in learner.sanitize() {
        log("⚠️ 預熱學習：\(k) 的暫停時間超過 \(Int(BoostLearner.pauseSeconds / 3600)) 小時（系統時鐘跳過或檔案被改過），已清掉、恢復預熱")
    }
    var activeProfile: Profile? = nil   // 目前生效的情境規則
    var capLatch = CapLatch()           // 噪音上限的暫停閂鎖（hot／critical／降頻進入，降溫且連續幾輪沒降頻才恢復）
    var capSuspended = false            // 上一輪的暫停狀態（只拿來記 log）
    var capSnap = false                 // 剛進情境／剛改設定：風扇高於上限時直接往上限降（暫停剛結束不算，照一般降速節奏）
    /// 一波預熱結束時記結果；湊滿連續 3 次不像重工作就 log「學到」並存檔
    func finishBoost(notHeavy: Bool) {
        defer { boostKeyword = nil }
        guard config.boostLearn, let k = boostKeyword else { return }
        if learner.record(k, notHeavy: notHeavy) {
            let until = learner.pausedUntil(k).map { GuardLog.stamp.string(from: $0) } ?? "?"
            log("學到：\(k) 不再預熱（連續 \(BoostLearner.streak) 次預熱 \(Int(boostGraceSeconds)) 秒後都不像重工作，暫停到 \(until)）")
        }
        if persistLearner { learner.save() }
    }
    // 今日統計：guard 重啟時從舊快照接續，快照不在（/tmp 重開機被清）就從 /var/db 的落地檔接（都要同一天才算）
    var stats = [Snapshot.load()?.stats, Snapshot.Stats.loadPersisted()].compactMap { $0 }.first { $0.date == Snapshot.Stats.today() }
        ?? Snapshot.Stats(date: Snapshot.Stats.today())
    var statsPersistRound = 0
    var history = History.load().filter { Date().timeIntervalSince($0.time) < History.keep }

    // Watchdog：主迴圈卡在 kernel 呼叫（SMC mach_msg 不回、被餓死…）連 SIGTERM 都收不到；
    // 另一條 thread 看心跳，超過 6 個週期沒動就自殺讓 launchd（KeepAlive）重啟
    let heartbeat = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    heartbeat.pointee = Date().timeIntervalSince1970
    let watchdogLimit = max(30, interval * 6)
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 5)
            let age = Date().timeIntervalSince1970 - heartbeat.pointee
            if age > watchdogLimit {
                guardLog("⚠️ watchdog：主迴圈 \(Int(age)) 秒沒心跳（卡在 SMC 或被餓死），自殺讓 launchd 重啟", toFile: isRoot && !dryRun)
                _exit(3)
            }
        }
    }

    log("cool42 guard 啟動（\(chipName())，\(fanCount) 顆風扇，每 \(interval)s，模式 \(config.mode)，GPU \(config.includeGPU ? "納入" : "不納入")，\(dryRun ? "dry-run" : "控制中")）")

    while !stopping {
        heartbeat.pointee = Date().timeIntervalSince1970
        // 設定檔熱重載：解析失敗（含面板寫到一半）就保留舊設定，下一輪再試
        if let m = Config.mtime(baseConfig.loadedFrom), m != configMtime {
            do {
                let old = baseConfig
                baseConfig = try Config.loadOrError(path: baseConfig.loadedFrom)
                config = baseConfig.applying(activeProfile)
                capSnap = true
                // 舊版面板不認得 maxRPM / profiles，按「套用」會把它們整段刪掉；刻意移除的話這行可以忽略
                if (old.maxRPM != nil && baseConfig.maxRPM == nil) || (!old.profiles.isEmpty && baseConfig.profiles.isEmpty) {
                    log("⚠️ 設定檔裡的 \([old.maxRPM != nil && baseConfig.maxRPM == nil ? "maxRPM" : nil, !old.profiles.isEmpty && baseConfig.profiles.isEmpty ? "profiles" : nil].compactMap { $0 }.joined(separator: "、")) 不見了：如果不是你刻意移除，可能是還沒重建的舊版面板按了「套用」（面板要和 guard 一起更新）")
                }
                configMtime = m
                forceWrite = true
                log("設定已重載：模式 \(baseConfig.mode)，曲線 \(baseConfig.curve.map { "\(Int($0.temp))→\(Int($0.rpm))" }.joined(separator: " "))"
                    + (baseConfig.maxRPM.map { "，上限 \(Int($0)) rpm" } ?? "") + (baseConfig.profiles.isEmpty ? "" : "，情境規則 \(baseConfig.profiles.count) 條"))
            } catch {
                log("⚠️ 設定檔解析失敗，保留舊設定：\(error)")
            }
        }

        // 情境自動切換：依序第一條符合的規則生效，都不符合用基本設定。apps 規則才列程序、focus 規則才讀面板寫的旗標
        let nowProfile = Profiles.active(baseConfig.profiles, ProfileContext.live(for: baseConfig))
        if nowProfile != activeProfile {
            if let p = nowProfile { log("情境「\(p.name)」生效：\(p.summary)") }
            else if let old = activeProfile { log("情境「\(old.name)」結束，回到基本設定") }
            activeProfile = nowProfile
            capSnap = true
        }
        config = baseConfig.applying(activeProfile)

        // 收 hook / 面板丟過來的事件。事件目錄任何本機程式都能丟，所以事件只表達「要預熱」，
        // 轉速與秒數一律用 root 自己讀的 config，不信事件檔裡的值（否則丟 rpm 99999 / seconds 1e9 就能讓風扇永遠轟）
        let events = Event.drain()
        let consoleUID = events.isEmpty ? nil : FocusFlag.consoleUser()?.uid
        if Event.lastDropped > 0 { log("⚠️ 事件目錄有 \(Event.lastDropped) 個不合規檔案（symlink / 太大 / 不是事件 JSON），已丟棄") }
        for e in events {
            switch e.kind {
            case .boost:
                // 只學主控台使用者自己丟的事件（hook 是以使用者身分跑的）；別的本機帳號丟的照樣預熱，但不拿來學
                let fromConsoleUser = e.ownerUID != nil && e.ownerUID == consoleUID
                let keyword = config.boostLearn ? BoostLearner.learnableKeyword(e.note, config: config) : nil
                if let k = keyword, let paused = learner.pausedUntil(k) {
                    log("略過預熱：\(k) 已學到不像重工作（\(GuardLog.stamp.string(from: paused)) 恢復）")
                    continue
                }
                let until = min(e.time, Date()).addingTimeInterval(config.boostSeconds)
                if boostUntil == nil {
                    // 新的一波：先用 boostStartRPM，溫度真的起來才加碼（已經加碼的波被延長時不降回去）
                    boostStart = Date()
                    boostRPM = BoostRamp.startRPM(config)
                    boostEscalated = boostRPM >= config.boostRPM
                    boostKeyword = fromConsoleUser ? keyword : nil   // 只記開波的那一個；延長事件不算
                }
                if boostUntil == nil || until > boostUntil! { boostUntil = until }
                if boostEscalated { boostRPM = config.boostRPM }
                stats.boosts += 1
                log("預熱 \(Int(boostRPM)) rpm 到 \(GuardLog.stamp.string(from: boostUntil!))：\(e.note ?? "")")
            case .hookWait: stats.hookWaits += 1
            case .hookDeny: stats.hookDenies += 1
            }
        }
        if let b = boostUntil, b <= Date() {
            // 撐完整段沒被提早收掉 = 像重工作
            boostUntil = nil; boostRPM = 0; boostStart = nil; boostEscalated = false
            finishBoost(notHeavy: false)
        }
        // 暫停 24 小時到期的關鍵字恢復預熱
        let resumed = learner.expire()
        if !resumed.isEmpty {
            log("恢復預熱：\(resumed.joined(separator: "、"))（暫停 \(Int(BoostLearner.pauseSeconds / 3600)) 小時已到）")
            if persistLearner { learner.save() }
        }

        var s = Snapshot.take(config: config)
        if let g = gpuStats.sample() { s.gpuActive = g.active; s.gpuMHz = g.mhz; s.gpuThrottlePercent = gpuStats.cltmPercent }
        let top = procTop.sample(); if !top.isEmpty { s.topProcesses = top }

        // 跨日歸零
        if stats.date != Snapshot.Stats.today() {
            log("今日統計結算：最高 \(Int(stats.maxTemp))°C，hot \(Int(stats.hotSeconds))s，critical \(Int(stats.criticalSeconds))s，hook 等待 \(stats.hookWaits) 次、擋下 \(stats.hookDenies) 次，預熱 \(stats.boosts) 次，降頻 \(Int(stats.throttleSeconds))s")
            stats = Snapshot.Stats(date: Snapshot.Stats.today())
        }

        if !s.sensorOK {
            // 感測器讀不完整：這輪的溫度不可信，不動風扇；連續 6 輪（30 秒）就交還 SMC 自己管
            faultStreak += 1; stats.sensorFaults += 1
            if faultStreak == 1 || faultStreak % 12 == 0 { log("⚠️ 感測器讀取不完整（連續 \(faultStreak) 輪），保持目前風扇目標") }
            if faultStreak >= 6 && !auto { restore(); auto = true; lastTarget = -1; log("⚠️ 感測器持續故障，風扇交還自動") }
        } else {
            faultStreak = 0
            let t = s.controlTemp
            if let prev = smoothed {
                // 到 hot 以上就不平滑了，尖峰要立刻反應（閒段 → 重載一輪可以 +20°C）
                smoothed = t >= config.hotTemp ? max(t, prev) : prev + (t - prev) * (t > prev ? config.smoothingUp : config.smoothingDown)
            } else { smoothed = t }
            let fmin = s.fans.first?.min ?? 0
            let fmax = s.fans.first?.max ?? 5000
            let curveMin = config.curve.map(\.temp).min() ?? 0
            // 「不像重工作」與學習用基本設定的曲線起點：不隨情境漂移（quiet 起點 65°C，同一條指令在夜間會更容易被判輕）。
            // 接管／交還門檻則跟著情境的曲線走（README 有寫）
            let learnCurveMin = baseConfig.curve.map(\.temp).min() ?? curveMin
            let now = Date()
            defer {
                recentTemps.append((now, s.controlTemp))
                recentTemps.removeAll { now.timeIntervalSince($0.time) > BoostRamp.riseWindow + interval }
            }

            // 決定目標：nil = 交還自動
            var desired: Double? = nil
            switch config.mode {
            case "auto":
                desired = nil
            case "fixed":
                desired = config.fixedRPM
            default: // curve；低於曲線最低點 5°C 以上就交還自動讓 SMC 省電
                desired = smoothed! < curveMin - 5 ? nil : config.rpm(for: smoothed!)
            }
            // 接管去抖：交還自動中、曲線想接管時，要原始控制溫度連續 takeoverHoldSeconds 都在門檻以上；
            // hot 或降頻立刻接管。預熱與設定剛重載（forceWrite）不等 —— 那是明確要求
            let boostingNow = boostUntil.map { $0 > Date() } ?? false
            if auto, desired != nil, config.mode == "curve", !boostingNow, !forceWrite {
                // 頻率資料過期（powermetrics 停了或還沒第一筆）時 wasThrottling 是舊值：不知道就當可能在降頻，立刻接管
                let freqUnknown = FreqReader.available && !freq.fresh
                let ok = takeover.allow(temp: s.controlTemp, threshold: curveMin - 5, hotTemp: config.hotTemp,
                                        levelHot: (lastLevel ?? .ok) >= .hot,
                                        throttling: wasThrottling || s.gpuThrottling || freqUnknown,
                                        requiredRounds: TakeoverGate.requiredRounds(holdSeconds: config.takeoverHoldSeconds, interval: interval))
                if !ok { desired = nil }
            } else {
                takeover.reset()
            }
            // 預熱了 30 秒控制溫度還在曲線起點以下，表示這條指令根本不重（幾秒就跑完的 pytest、被關鍵字撞到的 sed…），
            // 不必再轟滿 120 秒；真的重的指令 30 秒內早就過 60°C，曲線會接手
            if let b = boostUntil, b > Date(), let st = boostStart, Date().timeIntervalSince(st) >= boostGraceSeconds, smoothed! < learnCurveMin {
                log("預熱提早結束：\(Int(Date().timeIntervalSince(st))) 秒後仍只有 \(Int(s.controlTemp))°C，不像重工作")
                boostUntil = nil; boostRPM = 0; boostStart = nil; boostEscalated = false
                finishBoost(notHeavy: true)
            }
            // 預熱漸進：溫度到 boostEscalateTemp 或 10 秒內升 boostEscalateRise 度，才從 boostStartRPM 加碼到 boostRPM
            if let b = boostUntil, b > Date(), !boostEscalated, config.mode != "auto",
               BoostRamp.shouldEscalate(now: now, temp: s.controlTemp, recent: recentTemps,
                                        escalateTemp: config.boostEscalateTemp, escalateRise: config.boostEscalateRise) {
                boostEscalated = true; boostRPM = config.boostRPM
                let low = recentTemps.filter { now.timeIntervalSince($0.time) <= BoostRamp.riseWindow + 0.5 }.map(\.temp).min() ?? s.controlTemp
                log("預熱加碼 \(Int(boostRPM)) rpm：\(Int(s.controlTemp))°C（\(Int(BoostRamp.riseWindow)) 秒內 +\(Int(max(0, s.controlTemp - low)))°C）")
            }
            // 預熱：重指令剛開始、溫度還沒上來時先把風扇拉起來；auto 模式尊重使用者，不預熱
            if let b = boostUntil, b > Date(), config.mode != "auto" {
                desired = max(desired ?? 0, boostRPM)
            }
            // 噪音上限：所有目標（曲線、固定、預熱）夾在 maxRPM 以下；hot、critical 或降頻中忽略上限（安全例外）。
            // 暫停是閂鎖：進入條件任一成立就暫停，要降到 hotTemp − levelHysteresis 以下且連續 rampDownHoldRounds 輪沒再觸發才恢復
            let capCritical = s.controlTemp >= config.criticalTemp || lastLevel == .critical
            let capHot = s.controlTemp >= config.hotTemp || (lastLevel ?? .ok) >= .hot
            let capThrottling = wasThrottling || s.gpuThrottling
            let suspendNow: Bool
            if config.maxRPM != nil {
                suspendNow = capLatch.update(trigger: RPMCap.suspended(critical: capCritical, hot: capHot, throttling: capThrottling),
                                             temp: s.controlTemp, releaseBelow: config.hotTemp - config.levelHysteresis,
                                             releaseRounds: config.rampDownHoldRounds)
            } else {
                capLatch.reset(); suspendNow = false
            }
            if suspendNow != capSuspended {
                if suspendNow {
                    capSnap = false
                    log("噪音上限 \(Int(config.maxRPM ?? 0)) rpm 暫停：\(capCritical ? "溫度到 critical" : capThrottling ? "降頻中" : "溫度到 hot")，風扇不受上限限制（\(s.short)）")
                } else if config.maxRPM != nil {
                    log("噪音上限 \(Int(config.maxRPM ?? 0)) rpm 恢復：已低於 \(Int(config.hotTemp - config.levelHysteresis))°C 連續 \(config.rampDownHoldRounds) 輪、沒有降頻，照一般降速節奏降回上限（\(s.short)）")
                }
                capSuspended = suspendNow
            }
            desired = desired.map { RPMCap.clamp($0, maxRPM: config.maxRPM, suspended: suspendNow) }
            // 任何來源的目標都夾在韌體回報的 F0Mn–F0Mx 之間，永遠不會超轉（上限比 F0Mn 還低時以 F0Mn 為準）
            var target = desired.map { min(max($0, fmin), fmax) }
            // 降速（含交還自動）要「連續 N 輪都偏冷」才開始，短暫鬆一下不理；一旦要升速就立刻歸零
            // （面板剛切到 auto 模式那輪 forceWrite 為 true：使用者要的是立刻交還，不等）
            if lastTarget >= 0, !forceWrite, target == nil || target! < lastTarget - config.deadband {
                coolRounds += 1
                if coolRounds <= config.rampDownHoldRounds { target = lastTarget }
            } else {
                coolRounds = 0
            }
            // 剛進入情境或剛改設定、風扇還高於上限：不等上面「連續 N 輪偏冷」，直接往上限降，仍受下面 maxRampDown 限制。
            // 上限暫停剛結束時不用這條（capSnap 在暫停時清掉），照一般 coolRounds 等待再降，避免重載下一分鐘一次的呼吸
            if capSnap, !suspendNow, let t = target, let cap = config.maxRPM {
                if t > max(cap, fmin) { target = max(cap, fmin) } else { capSnap = false }
            } else if config.maxRPM == nil || target == nil {
                capSnap = false
            }
            // 斜率限制：降速每輪最多 maxRampDown，升速每輪最多 maxRampUp（預熱與剛接管時不限，該快就快）
            if let t = target, lastTarget >= 0 {
                if config.maxRampDown > 0, t < lastTarget - config.maxRampDown { target = lastTarget - config.maxRampDown }
                let boosting = boostUntil.map { $0 > Date() } ?? false
                let urgent = s.controlTemp >= config.hotTemp   // 已經 hot 就別慢慢升
                if config.maxRampUp > 0, !boosting, !urgent, t > lastTarget + config.maxRampUp { target = lastTarget + config.maxRampUp }
            }

            if let target {
                if abs(target - lastTarget) >= config.deadband || auto || forceWrite {
                    if !dryRun { for i in 0..<fanCount { try SMC.setFan(i, rpm: target) } }
                    lastTarget = target; auto = false; forceWrite = false
                    log("\(s.short) → 目標 \(Int(target)) rpm")
                }
            } else if !auto {
                restore(); auto = true; lastTarget = -1; forceWrite = false
                log("\(s.short) → 交還自動")
            }
        }

        // 等級加遲滯（升級立即、降級要低於門檻 3°C 且連續 rampDownHoldRounds 輪都如此），快照、統計、log 都用這個。
        // 單核尖峰 5 秒內 50↔80°C 來回，只靠 3°C 遲滯一天會寫幾百條 ok↔warm；升級仍是立即，安全不打折
        let rawLevel = config.level(for: s.controlTemp, previous: lastLevel)
        if let last = lastLevel, rawLevel < last {
            levelCoolRounds += 1
            s.level = levelCoolRounds > config.rampDownHoldRounds ? rawLevel : last
        } else {
            levelCoolRounds = 0
            s.level = rawLevel
        }
        // 統計
        switch s.level {
        case .warm: stats.warmSeconds += interval
        case .hot: stats.hotSeconds += interval
        case .critical: stats.criticalSeconds += interval
        case .ok: break
        }
        stats.maxTemp = max(stats.maxTemp, s.controlTemp)
        freq.ensureRunning()
        if let e = freq.lastError, e != lastFreqError { log("⚠️ \(e)"); lastFreqError = e }
        if freq.fresh {
            s.pcoreMHz = freq.pcoreMHz; s.ecoreMHz = freq.ecoreMHz; s.thermalPressure = freq.pressure
            // 無聲降頻：高溫且 P-core 掉到全核滿載頻率以下（pressure 可能仍 Nominal）。
            // 進：≥ clockThrottleTemp 且 < full×ratio；出：頻率回到 full×(ratio+0.02) 以上，或溫度低於門檻 − levelHysteresis
            if let full = config.clockFullLoadMHz ?? Config.fullLoadMHz(chip: chip), let p = freq.pcoreMHz, p >= 100 {
                if clockThrottled {
                    if p >= full * (config.clockThrottleRatio + 0.02) || s.controlTemp < config.clockThrottleTemp - config.levelHysteresis {
                        clockThrottled = false
                    }
                } else if s.controlTemp >= config.clockThrottleTemp && p < full * config.clockThrottleRatio {
                    clockThrottled = true
                }
            } else {
                clockThrottled = false
            }
            s.clockThrottled = clockThrottled
            let throttlingNow = s.throttling || s.gpuThrottling
            if throttlingNow {
                stats.throttleSeconds += interval
                if !wasThrottling { log("⚠️ 熱降頻開始：\(clockThrottled && !(freq.pressure.map { $0 != "Nominal" } ?? false) ? "時脈（pressure 仍 Nominal）" : "pressure \(freq.pressure ?? "?")")，P-core \(Int(freq.pcoreMHz ?? 0)) MHz，GPU CLTM \(Int(s.gpuThrottlePercent ?? 0))%（\(s.short)）") }
            } else if wasThrottling {
                log("熱降頻結束：P-core \(Int(freq.pcoreMHz ?? 0)) MHz（\(s.short)）")
            }
            wasThrottling = throttlingNow
        }
        if s.level != lastLevel, let last = lastLevel {
            log("等級 \(last.rawValue) → \(s.level.rawValue)（\(s.short)）")
        }
        lastLevel = s.level

        s.guardRunning = true
        s.guardMode = config.mode
        s.guardTargetRPM = auto ? nil : lastTarget
        s.boostUntil = boostUntil
        s.profile = activeProfile?.name
        s.maxRPM = config.maxRPM
        s.maxRPMSuspended = config.maxRPM != nil ? capSuspended : nil
        s.stats = stats
        s.save()
        statsPersistRound += 1
        if isRoot && !dryRun && statsPersistRound % 12 == 0 { stats.persist() }

        history.append(HistoryPoint(time: s.time, cpu: s.cpuMax, gpu: s.gpuMax, rpm: s.fans.first?.rpm ?? 0, target: auto ? nil : lastTarget, pMHz: s.pcoreMHz, gpuActive: s.gpuActive))
        history.removeAll { Date().timeIntervalSince($0.time) > History.keep }
        History.save(history)

        if dryRun { stderr("\(s.short) → \(auto ? "auto" : "\(Int(lastTarget)) rpm")") }
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
    if keepFansOnExit && !auto {
        log("cool42 guard 結束（SIGTERM），風扇維持 \(Int(lastTarget)) rpm 等 launchd 重啟接管；要交還自動請 `sudo cool42 fan auto`")
    } else {
        restore()
        log("cool42 guard 結束，風扇已交還自動")
    }
    var s = Snapshot.take(config: config); s.guardRunning = false; s.stats = stats; s.save()
    if isRoot && !dryRun { stats.persist() }
}
