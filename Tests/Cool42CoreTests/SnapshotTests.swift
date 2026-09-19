import XCTest
@testable import Cool42Core

final class SnapshotTests: XCTestCase {
    /// v0.1 guard 寫的快照（沒有 controlTemp / sensorOK / stats / 頻率）也要讀得懂
    func testDecodeLegacySnapshot() throws {
        let legacy = #"{"cpuAvg":43.7,"cpuMax":75.4,"fans":[{"index":0,"manual":true,"max":4900,"min":1000,"rpm":1000,"target":1000}],"gpuMax":39.4,"guardMode":"curve","guardRunning":true,"guardTargetRPM":1625,"level":"ok","ssd":30.4,"time":"2026-09-15T20:16:54Z"}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(Snapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(s.cpuMax, 75.4)
        XCTAssertEqual(s.controlTemp, 75.4)     // 缺 controlTemp → 用 cpuMax
        XCTAssertTrue(s.sensorOK)
        XCTAssertNil(s.pcoreMHz)
        XCTAssertNil(s.stats)
        XCTAssertFalse(s.throttling)
        XCTAssertEqual(s.fans.first?.max, 4900)
    }

    func testRoundTrip() throws {
        var s = Snapshot(time: Date(timeIntervalSince1970: 1_700_000_000), cpuMax: 88, cpuAvg: 60, gpuMax: 50, ssd: 33,
                         fans: [.init(index: 0, rpm: 3000, target: 3000, min: 1000, max: 4900, manual: true)],
                         level: .warm, guardRunning: true, guardTargetRPM: 3000)
        s.controlTemp = 88; s.pcoreMHz = 3936; s.ecoreMHz = 2808; s.thermalPressure = "Moderate"
        var st = Snapshot.Stats(date: "2026-09-16"); st.throttleSeconds = 15; s.stats = st
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Snapshot.self, from: try enc.encode(s))
        XCTAssertEqual(back.pcoreMHz, 3936)
        XCTAssertTrue(back.throttling)
        XCTAssertEqual(back.stats?.throttleSeconds, 15)
        XCTAssertTrue(back.short.contains("⚡3.94GHz"))
        XCTAssertTrue(back.short.contains("降頻(Moderate)"))
    }

    func testFreqReaderParse() {
        let lines = [
            "E-Cluster HW active frequency: 0 MHz",
            "P-Cluster HW active frequency: 3936 MHz",
            "CPU Power: 21522 mW",
            "**** Thermal pressure ****",
            "Current pressure level: Nominal",
            "P-Cluster HW active frequency: 4130 MHz",
        ]
        let r = FreqReader.parse(lines: lines)
        XCTAssertEqual(r.p, 4130)      // 取最後一次
        XCTAssertEqual(r.e, 0)
        XCTAssertEqual(r.pressure, "Nominal")
        let empty = FreqReader.parse(lines: ["nothing here"])
        XCTAssertNil(empty.p); XCTAssertNil(empty.pressure)
    }

    // MARK: canReuse —— 快取毒化那隻 bug
    // 症狀：M4 上 SMC 明明有 18 個 Tg0* 感測器、config 也寫了 gpuPrefixes:["Tg"]、includeGPU:true，
    // 但 doctor 一直報「GPU 感測器 0 個」，controlTemp 恆等於 cpuMax —— 把關溫度完全看不到 GPU。
    // 差別只在走不走快取：`chip`（forceRescan）掃得到 18 個，`doctor`（吃快照）是 0 個。

    private func cfg(includeGPU: Bool = true) -> Config {
        var c = Config()
        c.cpuPrefixes = ["Tp", "Te"]
        c.gpuPrefixes = ["Tg"]
        c.includeGPU = includeGPU
        return c
    }

    func testCanReuseAcceptsMatchingKeys() {
        XCTAssertTrue(Snapshot.canReuse(cpuKeys: ["Tp01", "Te04"], gpuKeys: ["Tg0C", "Tg0D"], config: cfg()))
    }

    /// 核心回歸：includeGPU 開著卻拿到空 GPU 清單 —— 不可採用，必須重掃。
    /// 以前這裡回 true，空清單就被 guard 原樣寫回快照，一路自我延續下去。
    func testCanReuseRejectsEmptyGPUKeysWhenGPUIncluded() {
        XCTAssertFalse(Snapshot.canReuse(cpuKeys: ["Tp01", "Te04"], gpuKeys: [], config: cfg()))
    }

    /// 反面：沒要納入 GPU 時，空清單是合法的，不該白白多掃 1375 個 key
    func testCanReuseAcceptsEmptyGPUKeysWhenGPUExcluded() {
        XCTAssertTrue(Snapshot.canReuse(cpuKeys: ["Tp01"], gpuKeys: [], config: cfg(includeGPU: false)))
    }

    /// 前綴設定改過（或快照來自別台機器）就不能採用 —— CPU 與 GPU 都要驗
    func testCanReuseRejectsPrefixMismatch() {
        XCTAssertFalse(Snapshot.canReuse(cpuKeys: ["TC0P"], gpuKeys: ["Tg0C"], config: cfg()),
                       "CPU 前綴對不上")
        XCTAssertFalse(Snapshot.canReuse(cpuKeys: ["Tp01"], gpuKeys: ["TG0C"], config: cfg()),
                       "GPU 前綴對不上（大小寫有差）")
    }

    func testCanReuseRejectsEmptyCPUKeys() {
        XCTAssertFalse(Snapshot.canReuse(cpuKeys: [], gpuKeys: ["Tg0C"], config: cfg()))
    }

    /// gpuKeys 為 nil（舊版快照沒這個欄位）代表「沒掃過」，take() 不該把它當成空陣列採用
    func testLegacySnapshotHasNilGPUKeys() throws {
        let legacy = #"{"cpuAvg":43.7,"cpuMax":75.4,"fans":[],"gpuMax":39.4,"guardRunning":true,"level":"ok","time":"2026-09-15T20:16:54Z"}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(Snapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(s.gpuKeys, "沒掃過 ≠ 掃過但沒有；nil 必須保持 nil 才能觸發重掃")
        XCTAssertNil(s.cpuKeys)
    }

    func testEventPostSkipsWhenDirMissing() {
        // 事件目錄不存在（guard 沒跑）時 post 應該靜靜回 false，不能炸
        if !FileManager.default.fileExists(atPath: Event.dir) {
            XCTAssertFalse(Event(kind: .boost, rpm: 3000, seconds: 120).post())
        }
    }
}

final class PlausibleTempTests: XCTestCase {
    func testRejectsBogusReadings() {
        XCTAssertFalse(SMC.plausibleTemp(0))
        XCTAssertFalse(SMC.plausibleTemp(1))      // 實際看過 GPU 讀到 1°C
        XCTAssertFalse(SMC.plausibleTemp(-3))
        XCTAssertFalse(SMC.plausibleTemp(200))
        XCTAssertTrue(SMC.plausibleTemp(10.5))
        XCTAssertTrue(SMC.plausibleTemp(105))
    }
}
