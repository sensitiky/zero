import Foundation
import Testing
import SwiftData

@testable import ZeroCore

/// Short benchmark for quick measurements.
/// This is a reduced version for documentation purposes.
@Suite("Benchmark — Short run (1k items)")
@MainActor
struct BenchmarkShortTests {
    @Test("1k message appends measure latency")
    func benchmarkShortMessages() throws {
        let store = try Store(modelContainer: nil)

        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test",
            branch: "zero/bench"
        )

        let messageCount = 1_000
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

        print("\n=== Short Benchmark Results (1000 messages) ===")
        print("Total wall time: \(String(format: "%.3f", totalTime))s")
        print("p50 latency: \(String(format: "%.4f", p50 * 1000))ms")
        print("p95 latency: \(String(format: "%.4f", p95 * 1000))ms")
        print("p99 latency: \(String(format: "%.4f", p99 * 1000))ms")
        print("Throughput: \(Int(Double(messageCount) / totalTime)) messages/sec")
    }

    @Test("1k usage record appends measure latency")
    func benchmarkShortUsageRecords() throws {
        let store = try Store(modelContainer: nil)

        let session = try store.createSession(
            repository: nil,
            provider: "claude-code",
            model: "claude-opus",
            worktreePath: "/tmp/test",
            branch: "zero/bench"
        )

        let recordCount = 1_000
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

        print("\n=== Short Benchmark Results (1000 usage records) ===")
        print("Total wall time: \(String(format: "%.3f", totalTime))s")
        print("p50 latency: \(String(format: "%.4f", p50 * 1000))ms")
        print("p95 latency: \(String(format: "%.4f", p95 * 1000))ms")
        print("p99 latency: \(String(format: "%.4f", p99 * 1000))ms")
        print("Throughput: \(Int(Double(recordCount) / totalTime)) records/sec")
    }
}
