// gpu_burn：用 Metal compute 把 GPU 吃滿，給 perf_vs_temp.py 的 --gpu 負載用。
// 每個 thread 做一長串 FMA，一批做完立刻送下一批；SIGTERM/SIGINT 結束，SIGSTOP/SIGCONT 暫停與恢復（換檔降溫用）。
// 編譯：swiftc -O -o gpu_burn gpu_burn.swift -framework Metal
import Foundation
import Metal

let src = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float a = float(id) * 1e-6 + 1.0, b = 0.999991, c = 1e-7;
    for (uint i = 0; i < 4096; i++) {
        a = fma(a, b, c); b = fma(b, a, -c); c = fma(c, b, a) * 1e-3;
    }
    out[id] = a + b + c;
}
"""

guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else {
    FileHandle.standardError.write("gpu_burn：拿不到 Metal 裝置\n".data(using: .utf8)!)
    exit(1)
}
let lib = try dev.makeLibrary(source: src, options: nil)
let pso = try dev.makeComputePipelineState(function: lib.makeFunction(name: "burn")!)
let n = 1 << 20
let buf = dev.makeBuffer(length: n * MemoryLayout<Float>.size, options: .storageModePrivate)!
let tg = MTLSize(width: pso.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }
print("gpu_burn：\(dev.name)，每批 \(n) threads")
fflush(stdout)

while true {
    // 一次排四批，GPU 不會在 CPU 送單的空檔閒下來
    var last: MTLCommandBuffer?
    for _ in 0..<4 {
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { exit(1) }
        enc.setComputePipelineState(pso)
        enc.setBuffer(buf, offset: 0, index: 0)
        enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        last = cb
    }
    last?.waitUntilCompleted()
}
