import Foundation
import Testing
import SwiftData
import os

@testable import ZeroCore

/// Benchmark suite for the measurement gate.
/// Run with: `ZERO_RUN_BENCHMARKS=1 swift test --filter AppendBenchmark`
///
/// This test measures whether SwiftData's append-heavy write pattern (messages arriving
/// one at a time during streaming) can sustain the performance needed for Zero's use case.
/// If p95 latency or memory grows unacceptably, this signals that SQLite is the right choice.
@Suite("Benchmark — Append-heavy write pattern")
@MainActor
struct AppendBenchmarkTests {
    private let shouldRun = ProcessInfo.processInfo.environment["ZERO_RUN_BENCHMARKS"] == "1"

    @Test("10k message appends measure latency and memory")
    func benchmarkMessageAppends() throws {
        guard shouldRun else {
            print("Skipping benchmark. Run with: ZERO_RUN_BENCHMARKS=1 swift test --filter AppendBenchmark")
            return
        }

        let store = try Store(modelContainer: nil)

        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test",
            branch: "zero/bench"
        )

        let messageCount = 10_000
        var latencies: [TimeInterval] = []
        latencies.reserveCapacity(messageCount)

        let startWall = Date()
        for i in 0..<messageCount {
            let iterStart = Date()
            _ = try store.appendMessage(
                to: session,
                role: i % 2 == 0 ? "user" : "assistant",
                content: "Message \(i)"
            )
            let iterEnd = Date()
            latencies.append(iterEnd.timeIntervalSince(iterStart))
        }
        let endWall = Date()

        let totalTime = endWall.timeIntervalSince(startWall)

        let sorted = latencies.sorted()
        let p50 = sorted[messageCount / 2]
        let p95 = sorted[Int(Double(messageCount) * 0.95)]
        let p99 = sorted[Int(Double(messageCount) * 0.99)]

        print("\n=== Message Append Benchmark ===")
        print("Total messages: \(messageCount)")
        print("Total wall time: \(String(format: "%.3f", totalTime))s")
        print("Median append latency (p50): \(String(format: "%.4f", p50 * 1000))ms")
        print("p95 latency: \(String(format: "%.4f", p95 * 1000))ms")
        print("p99 latency: \(String(format: "%.4f", p99 * 1000))ms")
        print("Mean latency: \(String(format: "%.4f", latencies.reduce(0, +) / Double(messageCount) * 1000))ms")

        // SwiftData should handle this comfortably for reasonable latencies
        // If p95 is > 100ms or total time > 60s on Apple Silicon, that's a warning
        #expect(totalTime < 300, "Total message append time should be reasonable (< 300s)")
        #expect(p95 < 0.1, "p95 append latency should be < 100ms")
    }

    @Test("10k usage record appends measure latency")
    func benchmarkUsageRecordAppends() throws {
        guard shouldRun else {
            return
        }

        let store = try Store(modelContainer: nil)

        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test",
            branch: "zero/bench"
        )

        let recordCount = 10_000
        var latencies: [TimeInterval] = []
        latencies.reserveCapacity(recordCount)

        let startWall = Date()
        for i in 0..<recordCount {
            let iterStart = Date()
            _ = try store.appendUsageRecord(
                to: session,
                model: "claude-opus",
                inputTokens: 100 + i,
                outputTokens: 50 + i / 2,
                cacheReadTokens: 10,
                cacheWriteTokens: 5,
                contextWindowUsed: 150,
                contextWindowTotal: 200_000
            )
            let iterEnd = Date()
            latencies.append(iterEnd.timeIntervalSince(iterStart))
        }
        let endWall = Date()

        let totalTime = endWall.timeIntervalSince(startWall)

        let sorted = latencies.sorted()
        let p50 = sorted[recordCount / 2]
        let p95 = sorted[Int(Double(recordCount) * 0.95)]
        let p99 = sorted[Int(Double(recordCount) * 0.99)]

        print("\n=== UsageRecord Append Benchmark ===")
        print("Total records: \(recordCount)")
        print("Total wall time: \(String(format: "%.3f", totalTime))s")
        print("Median append latency (p50): \(String(format: "%.4f", p50 * 1000))ms")
        print("p95 latency: \(String(format: "%.4f", p95 * 1000))ms")
        print("p99 latency: \(String(format: "%.4f", p99 * 1000))ms")
        print("Mean latency: \(String(format: "%.4f", latencies.reduce(0, +) / Double(recordCount) * 1000))ms")

        #expect(totalTime < 300, "Total usage record append time should be reasonable (< 300s)")
        #expect(p95 < 0.1, "p95 append latency should be < 100ms")
    }

    @Test("fetch session with 10k message history measures retrieval latency")
    func benchmarkSessionFetch() throws {
        guard shouldRun else {
            return
        }

        let store = try Store(modelContainer: nil)

        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test",
            branch: "zero/bench"
        )

        // Populate with messages
        let messageCount = 10_000
        for i in 0..<messageCount {
            _ = try store.appendMessage(
                to: session,
                role: i % 2 == 0 ? "user" : "assistant",
                content: "Message \(i)"
            )
        }

        // Measure fetch time
        let fetchStart = Date()
        let fetched = try store.fetchSession(id: session.id)
        let fetchEnd = Date()

        let fetchTime = fetchEnd.timeIntervalSince(fetchStart)

        print("\n=== Session Fetch Benchmark (10k messages) ===")
        print("Fetch time: \(String(format: "%.3f", fetchTime * 1000))ms")
        print("Messages in result: \(fetched?.messages.count ?? 0)")

        #expect(fetchTime < 5.0, "Fetching 10k message session should be quick (< 5s)")
        #expect(fetched?.messages.count == messageCount, "All messages should be fetched")
    }

    @Test("combined benchmark: messages + usage + fetch")
    func benchmarkCombined() throws {
        guard shouldRun else {
            return
        }

        let store = try Store(modelContainer: nil)

        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test",
            branch: "zero/bench"
        )

        let count = 5_000 // smaller for combined test

        print("\n=== Combined Benchmark ===")

        // Phase 1: append messages
        let msgStart = Date()
        for i in 0..<count {
            _ = try store.appendMessage(
                to: session,
                role: i % 2 == 0 ? "user" : "assistant",
                content: "Message \(i)"
            )
        }
        let msgTime = Date().timeIntervalSince(msgStart)
        print("Appended \(count) messages in \(String(format: "%.3f", msgTime))s")

        // Phase 2: append usage
        let usageStart = Date()
        for i in 0..<count {
            _ = try store.appendUsageRecord(
                to: session,
                model: "claude-opus",
                inputTokens: 100 + i,
                outputTokens: 50 + i / 2,
                cacheReadTokens: 10,
                cacheWriteTokens: 5,
                contextWindowUsed: 150,
                contextWindowTotal: 200_000
            )
        }
        let usageTime = Date().timeIntervalSince(usageStart)
        print("Appended \(count) usage records in \(String(format: "%.3f", usageTime))s")

        // Phase 3: fetch
        let fetchStart = Date()
        let fetched = try store.fetchSession(id: session.id)
        let fetchTime = Date().timeIntervalSince(fetchStart)
        print("Fetched session with \(fetched?.messages.count ?? 0) messages in \(String(format: "%.3f", fetchTime * 1000))ms")

        let totalTime = msgTime + usageTime + fetchTime
        print("Total combined time: \(String(format: "%.3f", totalTime))s")

        // Sanity check
        #expect(fetched?.messages.count == count)
        #expect(fetched?.usageRecords.count == count)
    }
}
