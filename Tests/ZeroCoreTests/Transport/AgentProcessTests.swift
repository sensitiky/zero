import Foundation
import Testing

@testable import ZeroCore

@Suite("AgentProcess", .serialized)
struct AgentProcessTests {
    private func configuration(script: String) -> AgentProcess.Configuration {
        AgentProcess.Configuration(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
    }

    /// Collects output until `predicate` is satisfied or the deadline passes.
    private func collect(
        _ process: AgentProcess,
        until predicate: @escaping @Sendable (AgentProcess.Output) -> Bool,
        seconds: TimeInterval = 5
    ) async -> [AgentProcess.Output] {
        var collected: [AgentProcess.Output] = []
        let deadline = Date().addingTimeInterval(seconds)
        for await item in process.output {
            collected.append(item)
            if predicate(item) || Date() > deadline { break }
        }
        return collected
    }

    private func text(_ output: AgentProcess.Output) -> String? {
        if case .record(let data) = output { return String(decoding: data, as: UTF8.self) }
        return nil
    }

    @Test("stdout lines arrive as framed records")
    func stdoutBecomesRecords() async throws {
        let process = AgentProcess(configuration: configuration(script: "echo first; echo second"))
        try await process.start()
        let output = await collect(process) { if case .exited = $0 { return true }; return false }
        let lines = output.compactMap { text($0) }
        #expect(lines == ["first", "second"])
        await process.terminate()
    }

    @Test("stdin stays open across writes so a turn is not a new process")
    func stdinPersistsAcrossWrites() async throws {
        // Echoes each line back, which only works if stdin is still open on the second write.
        let process = AgentProcess(configuration: configuration(script: "while read -r line; do echo \"got:$line\"; done"))
        try await process.start()
        try await process.send(Data("one".utf8))
        try await process.send(Data("two".utf8))
        await process.closeInput()

        let output = await collect(process) { if case .exited = $0 { return true }; return false }
        #expect(output.compactMap { text($0) } == ["got:one", "got:two"])
        await process.terminate()
    }

    @Test("interrupt delivers SIGINT to the child, not SIGTERM")
    func interruptDeliversSIGINT() async throws {
        // The child reports which signal it received, so this asserts the actual signal rather than
        // asserting that some method was called. SIGTERM here would mean a lost session, not a
        // cancelled turn.
        let script = """
        trap 'echo GOT_SIGINT; exit 0' INT
        trap 'echo GOT_SIGTERM; exit 0' TERM
        echo ready
        while true; do sleep 0.05; done
        """
        let process = AgentProcess(configuration: configuration(script: script))
        try await process.start()

        // Wait for the trap to be installed before signalling, or the signal races startup.
        var sawReady = false
        for await item in process.output where text(item) == "ready" {
            sawReady = true
            break
        }
        #expect(sawReady)

        await process.interrupt()
        let output = await collect(process) { if case .exited = $0 { return true }; return false }
        let lines = output.compactMap { text($0) }
        #expect(lines.contains("GOT_SIGINT"))
        #expect(!lines.contains("GOT_SIGTERM"))
        await process.terminate()
    }

    @Test("a child that dies reports its exit and keeps prior output")
    func deathReportsExitAndKeepsOutput() async throws {
        let process = AgentProcess(configuration: configuration(script: "echo before; exit 3"))
        try await process.start()
        let output = await collect(process) { if case .exited = $0 { return true }; return false }

        #expect(output.compactMap { text($0) } == ["before"])
        let exit = output.compactMap { item -> Int32? in
            if case .exited(let code, _) = item { return code }
            return nil
        }
        #expect(exit == [3])
        await process.terminate()
    }

    @Test("stderr arrives as a diagnostic, not as a record")
    func stderrIsDiagnostic() async throws {
        let process = AgentProcess(configuration: configuration(script: "echo oops 1>&2; echo fine"))
        try await process.start()
        let output = await collect(process) { if case .exited = $0 { return true }; return false }

        #expect(output.compactMap { text($0) } == ["fine"])
        let diagnostics = output.compactMap { item -> String? in
            if case .diagnostic(let message) = item { return message }
            return nil
        }
        #expect(diagnostics.joined().contains("oops"))
        await process.terminate()
    }

    @Test("sending before start throws instead of silently dropping the turn")
    func sendBeforeStartThrows() async throws {
        let process = AgentProcess(configuration: configuration(script: "cat"))
        await #expect(throws: AgentProcess.NotRunning.self) {
            try await process.send(Data("hello".utf8))
        }
    }

    @Test("writing to a process that already exited fails instead of crashing the app")
    func writeAfterExitFailsCleanly() async throws {
        // /bin/echo never reads stdin and exits almost immediately. Writing to its stdin pipe after
        // that used to deliver SIGPIPE, whose default disposition terminates the whole process — not
        // just this session. Regression: a provider CLI dying mid-write took every other session
        // down with it.
        let process = AgentProcess(
            configuration: AgentProcess.Configuration(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello"],
                environment: ["PATH": "/usr/bin:/bin"],
                workingDirectory: URL(fileURLWithPath: "/tmp")
            )
        )
        try await process.start()

        for await item in process.output {
            if case .exited = item { break }
        }

        await #expect(throws: (any Error).self) {
            try await process.send(Data("too late".utf8))
        }
        // Reaching this line at all is the assertion that matters: SIGPIPE did not take the process
        // down.
    }

}
