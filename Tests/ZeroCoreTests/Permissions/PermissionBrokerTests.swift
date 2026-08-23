import Darwin
import Foundation
import Testing

@testable import ZeroCore

@Suite("PermissionBroker", .serialized)
struct PermissionBrokerTests {
    // MARK: - Helpers

    /// Short on purpose: `sun_path` is 104 bytes and the system temp directory alone eats half of
    /// it. A test that used `temporaryDirectory` here failed with `.pathTooLong`, which is the same
    /// wall the app would hit in Application Support.
    private func tempDirectory() -> URL {
        let url = URL(fileURLWithPath: "/tmp/zs-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The built helper binary.
    ///
    /// Located via `Bundle.module`, whose resource bundle sits in the products directory.
    /// `Bundle.main` points at swiftpm-testing-helper under the toolchain, not at our products.
    private var helperURL: URL {
        Bundle.module.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("zero-permission-hook")
    }

    /// A hook payload shaped the way Claude Code 2.1.237 actually sends it — snake_case, verified
    /// against a real capture.
    private func hookPayload(tool: String = "Write") -> Data {
        let payload: [String: Any] = [
            "session_id": UUID().uuidString,
            "cwd": "/tmp",
            "permission_mode": "acceptEdits",
            "hook_event_name": "PreToolUse",
            "tool_name": tool,
            "tool_input": ["file_path": "/tmp/danger.txt", "content": "boom"],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// Runs the real helper against `socketPath` and returns what it printed on stdout.
    private func runHelper(socketPath: String, stdin: Data) throws -> [String: Any] {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [socketPath]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        // The throwing variants on purpose: the helper exits before reading stdin on the immediate
        // deny paths, and `FileHandle.write(_:)` traps on a closed pipe instead of erroring.
        try? input.fileHandleForWriting.write(contentsOf: stdin)
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecoderError("helper printed no JSON: \(String(decoding: data, as: UTF8.self))")
        }
        return json
    }

    private func decision(from helperOutput: [String: Any]) -> String? {
        (helperOutput["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String
    }

    // MARK: - End to end, through the real helper binary

    @Test("the real helper carries an allow from the app back to stdout")
    func endToEndAllow() async throws {
        #expect(
            FileManager.default.isExecutableFile(atPath: helperURL.path),
            "zero-permission-hook is not built at \(helperURL.path)"
        )
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let broker = PermissionBroker(socketsDirectory: directory) { request in
            // The app would show UI here. Asserting the request survived the wire intact is the
            // point: a broker that answers correctly about the wrong tool is not safe.
            #expect(request.toolName == "Write")
            #expect(request.detail.contains("danger.txt"))
            return .init(decision: .allow, origin: .userAction)
        }
        let path = try await broker.startSession(id: "session-allow")

        let output = try runHelper(socketPath: path, stdin: hookPayload())
        #expect(decision(from: output) == "allow")
        #expect((output["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String == "PreToolUse")
        await broker.stopAll()
    }

    @Test("the real helper carries a deny back to stdout")
    func endToEndDeny() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let broker = PermissionBroker(socketsDirectory: directory) { _ in
            .init(decision: .deny, origin: .userAction)
        }
        let path = try await broker.startSession(id: "session-deny")

        #expect(decision(from: try runHelper(socketPath: path, stdin: hookPayload())) == "deny")
        await broker.stopAll()
    }

    // MARK: - Fail closed

    @Test("an app that never answers produces deny")
    func timeoutDenies() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let broker = PermissionBroker(socketsDirectory: directory, timeout: 0.2) { _ in
            try? await Task.sleep(for: .seconds(30))
            return .init(decision: .allow, origin: .userAction)
        }
        let path = try await broker.startSession(id: "session-timeout")

        #expect(decision(from: try runHelper(socketPath: path, stdin: hookPayload())) == "deny")
        await broker.stopAll()
    }

    @Test("an unreachable app produces deny")
    func unreachableDenies() throws {
        let missing = tempDirectory().appendingPathComponent("nobody-listening.sock").path
        #expect(decision(from: try runHelper(socketPath: missing, stdin: hookPayload())) == "deny")
    }

    @Test("a hook payload that is not JSON produces deny")
    func malformedStdinDenies() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = PermissionBroker(socketsDirectory: directory) { _ in
            .init(decision: .allow, origin: .userAction)
        }
        let path = try await broker.startSession(id: "session-malformed")

        let output = try runHelper(socketPath: path, stdin: Data("not json at all".utf8))
        #expect(decision(from: output) == "deny")
        await broker.stopAll()
    }

    @Test("a hook payload with no tool_name produces deny")
    func missingToolNameDenies() throws {
        let payload = try! JSONSerialization.data(withJSONObject: ["cwd": "/tmp"])
        let missing = tempDirectory().appendingPathComponent("unused.sock").path
        #expect(decision(from: try runHelper(socketPath: missing, stdin: payload)) == "deny")
    }

    @Test("a request naming a different session is denied without reaching the app")
    func sessionMismatchDenies() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let handlerRan = Mutex(false)
        let broker = PermissionBroker(socketsDirectory: directory) { _ in
            handlerRan.set(true)
            return .init(decision: .allow, origin: .userAction)
        }
        let path = try await broker.startSession(id: "session-real")

        // Bypass the helper: it derives the session from the socket name, so only a crafted client
        // can lie about it. That is exactly the client worth testing.
        let forged = HookRequest(
            toolName: "Bash",
            toolInput: "{}",
            requestID: "r1",
            sessionID: "some-other-session",
            cwd: "/tmp",
            permissionMode: "manual"
        )
        let fd = try #require(SocketIO.connect(path: path, timeout: 2))
        defer { Darwin.close(fd) }
        #expect(SocketIO.writeFrame(fd, try JSONEncoder().encode(forged)))
        let responseData = try #require(SocketIO.readFrame(fd))
        let response = try JSONDecoder().decode(HookResponse.self, from: responseData)

        #expect(response.hookSpecificOutput.permissionDecision == .deny)
        #expect(handlerRan.get() == false, "a forged session reached the app's UI")
        await broker.stopAll()
    }

    // MARK: - Socket hygiene

    @Test("the session socket is owner-only")
    func socketIsOwnerOnly() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = PermissionBroker(socketsDirectory: directory) { _ in
            .init(decision: .deny, origin: .userAction)
        }
        let path = try await broker.startSession(id: "session-mode")

        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
        await broker.stopAll()
    }

    @Test("stopping a session removes its socket")
    func stopRemovesSocket() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = PermissionBroker(socketsDirectory: directory) { _ in
            .init(decision: .deny, origin: .userAction)
        }
        let path = try await broker.startSession(id: "session-stop")
        #expect(FileManager.default.fileExists(atPath: path))
        await broker.stopSession(id: "session-stop")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: - The wire shape Claude Code actually reads

    @Test("hook output uses camelCase keys")
    func hookOutputIsCamelCase() throws {
        // Regression guard. An earlier revision emitted snake_case here. Claude Code ignores an
        // unrecognized response, so the tool call proceeds — the deny silently becomes an allow.
        let json = String(decoding: HookResponse(decision: .deny, reason: "x").stdoutPayload(), as: UTF8.self)
        #expect(json.contains("\"hookSpecificOutput\""))
        #expect(json.contains("\"hookEventName\""))
        #expect(json.contains("\"permissionDecision\""))
        #expect(json.contains("\"permissionDecisionReason\""))
        #expect(!json.contains("permission_decision"))
        #expect(!json.contains("hook_event_name"))
    }

    @Test("hook request parses the snake_case shape Claude Code sends")
    func hookRequestIsSnakeCase() throws {
        let wire = Data(#"{"tool_name":"Bash","tool_input":"{}","request_id":"r","session_id":"s","cwd":"/tmp","permission_mode":"manual"}"#.utf8)
        let request = try JSONDecoder().decode(HookRequest.self, from: wire)
        #expect(request.toolName == "Bash")
        #expect(request.sessionID == "s")
        #expect(request.permissionMode == "manual")
    }

    @Test("settings JSON installs a PreToolUse hook and quotes paths with spaces")
    func settingsJSON() throws {
        let json = HookSettings.json(
            helperPath: "/Applications/Zero.app/Contents/MacOS/zero permission hook",
            socketPath: "/tmp/a b/s.sock"
        )
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let hooks = try #require(parsed["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let command = try #require((preToolUse.first?["hooks"] as? [[String: String]])?.first?["command"])
        #expect(command.contains("'/Applications/Zero.app/Contents/MacOS/zero permission hook'"))
        #expect(command.contains("'/tmp/a b/s.sock'"))
    }

    @Test("askMatcher gates every configured tool including WebSearch; autoMatcher gates only the network ones")
    func matchersByMode() throws {
        for tool in ["Bash", "Write", "Edit", "NotebookEdit", "WebFetch", "WebSearch"] {
            #expect(HookSettings.askMatcher.range(of: tool) != nil)
        }
        for tool in ["Bash", "Write", "Edit", "NotebookEdit"] {
            #expect(HookSettings.autoMatcher.range(of: tool) == nil)
        }
        #expect(HookSettings.autoMatcher.range(of: "WebFetch") != nil)
        #expect(HookSettings.autoMatcher.range(of: "WebSearch") != nil)
    }

    // MARK: - Framing

    @Test("a frame split across reads reassembles")
    func framePartial() throws {
        let payload = Data(#"{"a":1}"#.utf8)
        let framed = SocketIO.encode(payload)
        #expect(SocketIO.decode(framed.prefix(framed.count - 1)) == nil)
        let decoded = try #require(SocketIO.decode(framed))
        #expect(decoded.payload == payload)
    }

    @Test("two frames in one buffer decode in order")
    func frameMultiple() throws {
        let first = Data(#"{"a":1}"#.utf8)
        let second = Data(#"{"b":2}"#.utf8)
        var buffer = SocketIO.encode(first)
        buffer.append(SocketIO.encode(second))

        let one = try #require(SocketIO.decode(buffer))
        #expect(one.payload == first)
        let two = try #require(SocketIO.decode(one.remaining))
        #expect(two.payload == second)
    }

    @Test("a frame claiming more than the cap is refused")
    func frameOversizeRefused() {
        var buffer = withUnsafeBytes(of: UInt32(SocketIO.maxPayloadBytes + 1).bigEndian) { Data($0) }
        buffer.append(Data(repeating: 0, count: 16))
        #expect(SocketIO.decode(buffer) == nil)
    }
}

/// Minimal lock box so a test can observe whether a `@Sendable` handler ran.
private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
