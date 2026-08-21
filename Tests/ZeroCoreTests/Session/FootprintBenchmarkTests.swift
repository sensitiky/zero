import Darwin
import Foundation
import Testing

@testable import ZeroCore

/// Measures Zero's own footprint under concurrent sessions.
///
/// The provider processes stand in as `cat` over a captured fixture. That is the honest shape for
/// this NFR: it is about how much memory *Zero* costs to run five sessions — decoding, persisting and
/// holding five transcripts — not about how much the agent CLIs cost, which is their own budget and
/// not something the app can change.
@Suite(
    "Benchmark — Footprint",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ZERO_RUN_BENCHMARKS"] == "1")
)
@MainActor
struct FootprintBenchmarkTests {
    private func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    @Test("five concurrent sessions stay inside the memory budget")
    func fiveSessionsFootprint() async throws {
        let fixture = try #require(
            Bundle.module.url(
                forResource: "text-turn",
                withExtension: "ndjson",
                subdirectory: "Fixtures/claude-code"
            )
        )
        // A stream long enough to be a stream: one turn's worth of records is not a load test.
        let repeated = FileManager.default.temporaryDirectory
            .appendingPathComponent("zero-footprint-\(UUID().uuidString).ndjson")
        let oneTurn = try String(contentsOf: fixture, encoding: .utf8)
        try String(repeating: oneTurn, count: 200).write(to: repeated, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: repeated) }

        let before = residentBytes()
        let store = try Store()
        var runtimes: [SessionRuntime] = []

        for index in 0..<5 {
            let repo = URL(fileURLWithPath: "/tmp/zf-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["init", "-q", repo.path]
            try git.run()
            git.waitUntilExit()

            let session = try store.createSession(
                repository: nil, provider: "claude", model: "claude-haiku-4-5",
                worktreePath: repo.path, branch: "zero/footprint-\(index)"
            )
            let runtime = SessionRuntime(
                sessionID: session.id,
                process: AgentProcess(
                    configuration: AgentProcess.Configuration(
                        executable: URL(fileURLWithPath: "/bin/cat"),
                        arguments: [repeated.path],
                        environment: ["PATH": "/usr/bin:/bin"],
                        workingDirectory: repo
                    )
                ),
                store: store,
                gitService: try GitService(repositoryPath: repo),
                decoder: ClaudeCodeDecoder(),
                encoder: ClaudeCodeEncoder(),
                providerRegistry: ProviderRegistry()
            )
            runtimes.append(runtime)
            try await runtime.start()
        }

        for runtime in runtimes {
            for await _ in runtime.transcript {}
            await runtime.waitUntilFinished()
        }

        let after = residentBytes()
        let mb = { (bytes: Int64) in Double(bytes) / 1_048_576 }
        print("""

        === Footprint: 5 concurrent sessions ===
        before: \(String(format: "%.1f", mb(before))) MB
        after:  \(String(format: "%.1f", mb(after))) MB
        delta:  \(String(format: "%.1f", mb(after - before))) MB
        """)

        // The NFR is about the whole app; this measures the library's share of it, which is the part
        // this test can honestly speak to. The window's own cost is measured separately.
        #expect(mb(after) < 400, "five sessions cost \(String(format: "%.1f", mb(after))) MB resident")

        for runtime in runtimes { await runtime.waitUntilFinished() }
    }
}
