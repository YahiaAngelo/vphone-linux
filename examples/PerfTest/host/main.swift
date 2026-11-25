// The benchmarks natively on the host: host/build.sh, then ./perftest-host.
import Foundation
let r = runBenchmarks()
for b in r { print(b.name, Int(b.ms), "(\(Int(b.minMs))-\(Int(b.maxMs)))") }
print("total", Int(r.reduce(0) { $0 + $1.ms }))
