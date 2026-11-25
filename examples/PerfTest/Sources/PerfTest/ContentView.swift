import SwiftUI
import os

private let log = Logger(subsystem: "com.example.PerfTest", category: "bench")

struct ContentView: View {
    @State private var results: [BenchResult] = []
    @State private var running = false
    @State private var total = 0.0

    var body: some View {
        VStack(spacing: 12) {
            Text("PerfTest").font(.largeTitle.bold())
            Text("\(ProcessInfo.processInfo.activeProcessorCount) cores · median of \(benchRuns) runs").foregroundStyle(.secondary)
            List(results) { r in
                HStack {
                    Text(r.name)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(String(format: "%.0f ms", r.ms)).monospacedDigit().bold()
                        Text(String(format: "%.0f–%.0f", r.minMs, r.maxMs)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if !results.isEmpty { Text(String(format: "total of medians %.0f ms", total)).font(.title3.bold()) }
            Button(running ? "Running…" : "Run again") { run() }
                .buttonStyle(.borderedProminent).disabled(running)
        }
        .padding(.vertical)
        .onAppear { run() }
    }

    private func run() {
        running = true; results = []
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runBenchmarks()
            for b in r { log.notice("bench \(b.name, privacy: .public): \(b.ms, privacy: .public) ms") }
            let t = r.reduce(0) { $0 + $1.ms }
            log.notice("bench total: \(t, privacy: .public) ms")
            DispatchQueue.main.async { results = r; total = t; running = false }
        }
    }
}
