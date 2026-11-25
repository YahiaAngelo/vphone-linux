// PerfTest's benchmarks: each runs `benchRuns` times and reports the median. The same file builds
// for iOS (the app) and natively on the host (host/build.sh), to compare the VM with bare metal.
import Foundation
import Dispatch

struct BenchResult: Identifiable {
    let id = UUID()
    let name: String
    let ms: Double      // median of `runs`
    let minMs: Double
    let maxMs: Double
    let check: Int
}

let benchRuns = 5

private struct Item: Codable { let id: Int; let name: String; let score: Double; let tags: [String] }
private final class Node { var value: Int; var next: Node?; init(_ v: Int, _ n: Node?) { value = v; next = n } }

private func time(_ name: String, _ body: () -> Int) -> BenchResult {
    var times: [Double] = []
    var check = 0
    for _ in 0..<benchRuns {
        let t0 = DispatchTime.now().uptimeNanoseconds
        check = body()
        let t1 = DispatchTime.now().uptimeNanoseconds
        times.append(Double(t1 - t0) / 1e6)
    }
    times.sort()
    return BenchResult(name: name, ms: times[times.count / 2], minMs: times.first!, maxMs: times.last!, check: check)
}

private func mandelRows(_ y0: Int, _ y1: Int, _ n: Int) -> Int {
    var inside = 0
    for y in y0..<y1 {
        for x in 0..<n {
            let cr = Double(x) * 3.0 / Double(n) - 2.0, ci = Double(y) * 3.0 / Double(n) - 1.5
            var zr = 0.0, zi = 0.0, i = 0
            while i < 200 && zr * zr + zi * zi < 4 { (zr, zi) = (zr * zr - zi * zi + cr, 2 * zr * zi + ci); i += 1 }
            if i == 200 { inside += 1 }
        }
    }
    return inside
}

func runBenchmarks() -> [BenchResult] {
    var rng = SystemRandomNumberGenerator()
    var out: [BenchResult] = []
    out.append(time("sieve 10M") {
        let n = 10_000_000
        var s = [Bool](repeating: true, count: n + 1); var c = 0
        for i in 2...n where s[i] { c += 1; var j = i * i; while j <= n { s[j] = false; j += i } }
        return c
    })
    out.append(time("sort 2M ints") {
        var a = (0..<2_000_000).map { _ in Int.random(in: 0..<1_000_000_000, using: &rng) }
        a.sort(); return a[1000]
    })
    out.append(time("dict 1M inserts") {
        var d = [Int: Int](); for i in 0..<1_000_000 { d[i &* 2654435761 % 10_000_019] = i }; return d.count
    })
    out.append(time("JSON 50k items") {
        let items = (0..<50_000).map { Item(id: $0, name: "item \($0)", score: Double($0) * 0.5, tags: ["a", "b", "\($0 % 7)"]) }
        let data = try! JSONEncoder().encode(items)
        return try! JSONDecoder().decode([Item].self, from: data).count + data.count % 1000
    })
    out.append(time("alloc 3M objects") {
        var head: Node? = nil
        for i in 0..<3_000_000 { head = Node(i, i % 1000 == 0 ? nil : head) }
        return head?.value ?? 0
    })
    out.append(time("strings 300k") {
        var total = 0
        for i in 0..<300_000 { let s = "value-\(i)-\(i * 7)"; total += s.split(separator: "-").count + s.uppercased().utf8.count }
        return total
    })
    out.append(time("mandelbrot 1 core") { mandelRows(0, 800, 800) })
    let cores = ProcessInfo.processInfo.activeProcessorCount
    out.append(time("mandelbrot \(cores) cores") {
        let chunks = cores * 4, n = 800
        // Each iteration writes its own slot only.
        nonisolated(unsafe) let counts = UnsafeMutableBufferPointer<Int>.allocate(capacity: chunks)
        counts.initialize(repeating: 0)
        defer { counts.deallocate() }
        DispatchQueue.concurrentPerform(iterations: chunks) { k in counts[k] = mandelRows(k * n / chunks, (k + 1) * n / chunks, n) }
        return counts.reduce(0, +)
    })
    return out
}
