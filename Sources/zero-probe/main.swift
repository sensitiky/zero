import Foundation
import ZeroCore

// Drives a real provider CLI and prints the normalized AgentEvents, with permission requests
// answered from the terminal. No git, no persistence, no UI — this exists to catch the case where
// an adapter agrees with its own fixtures and both are wrong.
//
//   swift run zero-probe "list the files here"

@main
struct Probe {
    static func main() async {
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        guard !prompt.isEmpty else {
            FileHandle.standardError.write(Data("""
            zero-probe — drive a real provider CLI and print normalized events.

            usage: zero-probe <prompt>
                   zero-probe --check          only report provider availability

            Answers permission requests from the terminal, through the same PreToolUse hook the app
            uses. Runs in the current directory: use a scratch directory you do not mind touching.

            """.utf8))
            exit(2)
        }

        let registry = ProviderRegistry()
        let status = registry.status(of: .claude)
        print("provider: claude — \(status)")
        guard case .available(let version) = status else {
            print("unusable, stopping. Install or authenticate the CLI and retry.")
            exit(1)
        }
        print("version: \(version)")
        if prompt == "--check" { exit(0) }

        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sessionID = UUID().uuidString

        // The same broker the app uses, with the terminal standing in for the native UI.
        let socketsDirectory = PermissionBroker.defaultSocketsDirectory()
        let broker = PermissionBroker(socketsDirectory: socketsDirectory) { request in
            print("\n── permission ──────────────────────────────")
            print("tool: \(request.toolName)")
            print(request.detail)
            print("allow? [y/N] ", terminator: "")
            // `readLine` blocks, so it runs off the cooperative pool: blocking a concurrency thread
            // here would stall the very runtime that has to deliver the answer.
            let answer = await Task.detached {
                readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.value
            let allowed = answer == "y" || answer == "yes"
            print("→ \(allowed ? "allowed" : "denied")\n")
            // `.userAction` is the only origin available here, which is the point: a decision has
            // to come from a person, and the terminal is the person's stand-in.
            return .init(decision: allowed ? .allow : .deny, origin: .userAction)
        }

        let socketPath: String
        do {
            socketPath = try await broker.startSession(id: sessionID)
        } catch {
            print("could not open the permission socket: \(error)")
            exit(1)
        }

        let helper = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("zero-permission-hook")
        var extraArguments: [String] = []
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            extraArguments += [
                "--settings",
                HookSettings.json(helperPath: helper.path, socketPath: socketPath),
            ]
            print("permission hook: \(helper.lastPathComponent) via \(socketPath)\n")
        } else {
            print("warning: \(helper.path) not built — tool calls will not be gated\n")
        }

        let configuration: AgentProcess.Configuration
        do {
            configuration = try registry.configuration(
                for: .claude,
                workingDirectory: workingDirectory,
                extraArguments: extraArguments
            )
        } catch {
            print("could not build a launch configuration: \(error)")
            exit(1)
        }
        print("executable: \(configuration.executable.path)\n")
        let process = AgentProcess(configuration: configuration)

        var decoder = ClaudeCodeDecoder()
        var encoder = ClaudeCodeEncoder()

        do {
            try await process.start()
            for record in try encoder.encodePrompt(prompt) {
                try await process.send(record)
            }
        } catch {
            print("could not start the session: \(error)")
            await broker.stopAll()
            exit(1)
        }

        var unrecognized = 0
        for await output in process.output {
            switch output {
            case .record(let line):
                for event in decoder.decode(line: line) {
                    if case .unrecognized = event { unrecognized += 1 }
                    render(event)
                    // `claude --print --input-format stream-json` keeps reading stdin for further
                    // turns and does not exit on its own. The probe sends exactly one turn, so
                    // closing input at the turn boundary is what lets the process finish.
                    if case .turnEnded = event {
                        await process.closeInput()
                    }
                }
            case .diagnostic(let text):
                FileHandle.standardError.write(Data(text.utf8))
            case .streamFailure(let reason):
                print("stream failure: \(reason)")
            case .exited(let code, _):
                print("\n── exited \(code), \(unrecognized) unrecognized record(s) ──")
            }
        }

        await broker.stopAll()
        await process.terminate()
    }

    /// Prints one event. Unrecognized records are printed in full on purpose: they are the gaps
    /// between what the CLI emits and what the decoder understands, which is what this tool is for.
    static func render(_ event: AgentEvent) {
        switch event {
        case .textDelta(let text):
            print(text, terminator: "")
        case .thinkingDelta(let text):
            print("[thinking] \(text.prefix(200))")
        case .thinkingProgress(let tokens):
            FileHandle.standardError.write(Data("[thinking +\(tokens)]\n".utf8))
        case .toolCall(let call):
            print("[tool \(call.name) \(call.status)] \(call.input?.prefix(160) ?? "")")
            if let edit = call.edit { print("  edit: \(edit.path)") }
        case .plan(let items):
            print("[plan]")
            for item in items { print("  \(item.status) \(item.title)") }
        case .permissionRequested(let request):
            print("[permission requested in-band: \(request.toolName)]")
        case .usage(let usage):
            let cost = usage.costUSD.map { String(format: "$%.6f", $0) } ?? "unknown"
            print("""

            [usage] in=\(usage.inputTokens ?? 0) out=\(usage.outputTokens ?? 0) \
            cacheR=\(usage.cacheReadTokens ?? 0) cacheW=\(usage.cacheWriteTokens ?? 0) \
            thinking=\(usage.thinkingTokens ?? 0) cost=\(cost)
            """)
        case .sessionReady(let providerSessionID, let model):
            print("[session \(providerSessionID)\(model.map { " model=\($0)" } ?? "")]")
        case .rateLimit(let status, let resetsAt):
            let resets = resetsAt.map { " resets=\($0)" } ?? ""
            print("[rate limit: \(status)\(resets)]")
        case .turnStarted(let id):
            print("[turn \(id)]")
        case .turnEnded(let reason):
            print("[turn ended: \(reason)]")
        case .failed(let reason):
            print("[failed: \(reason)]")
        case .unrecognized(let raw):
            print("[unrecognized] \(String(decoding: raw, as: UTF8.self).prefix(240))")
        }
    }
}
