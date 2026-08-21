import Foundation
import Testing

@testable import ZeroCore

/// Compares flush policies, serialized so the numbers are not four benchmarks fighting for CPU.
///
/// This is the measurement that decides the persistence design: the earlier append benchmark
/// conflated "SwiftData is slow" with "we called save() on every single record".
/// Gated by a trait rather than an assertion: a benchmark that is not requested must be skipped,
/// not reported as a failure. An earlier version used `#require(shouldRun)` and turned every
/// ordinary `swift test` run red.
@Suite(
    "Benchmark — Flush policy",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ZERO_RUN_BENCHMARKS"] == "1")
)
@MainActor
struct FlushPolicyBenchmarkTests {
    private let count = 1_000

    private func makeStore() throws -> Store {
        // The no-argument initializer builds an in-memory container, which is what a benchmark
        // wants: it isolates append cost from disk behavior.
        try Store()
    }

    private func session(in store: Store) throws -> Session {
        try store.createSession(
            repository: nil, provider: "claude-code", model: "haiku",
            worktreePath: "/tmp/wt", branch: "zero/bench"
        )
    }

    private func report(_ label: String, _ latencies: [Double], total: Double) {
        let sorted = latencies.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))] }
        print("""

        === \(label) (\(count) appends) ===
        total:  \(String(format: "%.3f", total))s
        p50:    \(String(format: "%.4f", percentile(0.50) * 1000))ms
        p95:    \(String(format: "%.4f", percentile(0.95) * 1000))ms
        p99:    \(String(format: "%.4f", percentile(0.99) * 1000))ms
        """)
    }

    @Test("flush on every append")
    func flushEveryAppend() throws {
        let store = try makeStore()
        let target = try session(in: store)
        var latencies: [Double] = []
        let start = Date()
        for index in 0..<count {
            let began = Date()
            _ = try store.appendMessage(to: target, role: "assistant", content: "message \(index)")
            try store.flush()
            latencies.append(Date().timeIntervalSince(began))
        }
        report("flush per append", latencies, total: Date().timeIntervalSince(start))
    }

    @Test("flush once per 50 appends, the debounce shape")
    func flushDebounced() throws {
        let store = try makeStore()
        let target = try session(in: store)
        var latencies: [Double] = []
        let start = Date()
        for index in 0..<count {
            let began = Date()
            _ = try store.appendMessage(to: target, role: "assistant", content: "message \(index)")
            if index % 50 == 49 { try store.flush() }
            latencies.append(Date().timeIntervalSince(began))
        }
        try store.flush()
        report("flush every 50", latencies, total: Date().timeIntervalSince(start))
    }

}
