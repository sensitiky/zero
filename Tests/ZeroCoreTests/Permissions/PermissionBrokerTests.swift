import Foundation
import Testing

@testable import ZeroCore

@Suite("PermissionBroker")
struct PermissionBrokerTests {
    // MARK: - Helpers

    /// Creates a temporary directory for socket files.
    func createTempSocketDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let socketDir = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
        return socketDir
    }

    /// Cleans up a temporary directory.
    func cleanupTempDir(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Tests

    @Test("request with allow decision returns allow hook response")
    func allowRequest() async throws {
        let socketDir = try createTempSocketDir()
        defer { cleanupTempDir(socketDir) }

        let sessionID = "test-session-allow"

        let broker = PermissionBroker(
            handler: { request, allow, deny in
                allow(PermissionOrigin.userAction)
            },
            socketsDirectory: socketDir,
            timeout: 2.0
        )

        try await broker.startSession(id: sessionID)

        let request = HookRequest(
            toolName: "Read",
            toolInput: #"{"path": "/tmp/test"}"#,
            requestID: "req-1",
            sessionID: sessionID,
            cwd: "/tmp",
            permissionMode: "permissionMode"
        )

        let response = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionBroker.Decision, Never>) in
            Task {
                await broker.processRequest(request) { decision in
                    continuation.resume(returning: decision)
                }
            }
        }

        #expect(response == .allow)

        await broker.stopSession(id: sessionID)
    }

    @Test("request with deny decision returns deny hook response")
    func denyRequest() async throws {
        let socketDir = try createTempSocketDir()
        defer { cleanupTempDir(socketDir) }

        let sessionID = "test-session-deny"

        let broker = PermissionBroker(
            handler: { request, allow, deny in
                deny(PermissionOrigin.userAction)
            },
            socketsDirectory: socketDir,
            timeout: 2.0
        )

        try await broker.startSession(id: sessionID)

        let request = HookRequest(
            toolName: "Write",
            toolInput: #"{"path": "/tmp/test"}"#,
            requestID: "req-2",
            sessionID: sessionID,
            cwd: "/tmp",
            permissionMode: "permissionMode"
        )

        let response = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionBroker.Decision, Never>) in
            Task {
                await broker.processRequest(request) { decision in
                    continuation.resume(returning: decision)
                }
            }
        }

        #expect(response == .deny)

        await broker.stopSession(id: sessionID)
    }

    @Test("timeout produces deny decision")
    func timeoutProducesDeny() async throws {
        let socketDir = try createTempSocketDir()
        defer { cleanupTempDir(socketDir) }

        let sessionID = "test-session-timeout"

        let broker = PermissionBroker(
            handler: { request, allow, deny in
                // Intentionally never call allow or deny - simulate forgotten dialog
            },
            socketsDirectory: socketDir,
            timeout: 0.1 // Very short timeout for testing
        )

        try await broker.startSession(id: sessionID)

        let request = HookRequest(
            toolName: "Read",
            toolInput: #"{"path": "/tmp/test"}"#,
            requestID: "req-3",
            sessionID: sessionID,
            cwd: "/tmp",
            permissionMode: "permissionMode"
        )

        let response = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionBroker.Decision, Never>) in
            Task {
                await broker.processRequest(request) { decision in
                    continuation.resume(returning: decision)
                }
            }
        }

        #expect(response == .deny)

        await broker.stopSession(id: sessionID)
    }

    @Test("session mismatch produces deny decision")
    func sessionMismatchProducesDeny() async throws {
        let socketDir = try createTempSocketDir()
        defer { cleanupTempDir(socketDir) }

        let sessionID = "test-session-real"
        let otherSessionID = "test-session-fake"

        let broker = PermissionBroker(
            handler: { request, allow, deny in
                allow(PermissionOrigin.userAction)
            },
            socketsDirectory: socketDir,
            timeout: 2.0
        )

        try await broker.startSession(id: sessionID)

        // Send a request for a different session
        let request = HookRequest(
            toolName: "Read",
            toolInput: #"{"path": "/tmp/test"}"#,
            requestID: "req-4",
            sessionID: otherSessionID, // Different session
            cwd: "/tmp",
            permissionMode: "permissionMode"
        )

        let response = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionBroker.Decision, Never>) in
            Task {
                await broker.processRequest(request) { decision in
                    continuation.resume(returning: decision)
                }
            }
        }

        // Should deny because the session doesn't match
        #expect(response == .deny)

        await broker.stopSession(id: sessionID)
    }

    @Test("socket is created with owner-only permissions")
    func socketPermissionsAreOwnerOnly() async throws {
        let socketDir = try createTempSocketDir()
        defer { cleanupTempDir(socketDir) }

        let sessionID = "test-session-perms"

        let broker = PermissionBroker(
            handler: { _, allow, _ in allow(PermissionOrigin.userAction) },
            socketsDirectory: socketDir,
            timeout: 2.0
        )

        try await broker.startSession(id: sessionID)

        let socketPath = socketDir.appendingPathComponent("\(sessionID).sock").path
        let attrs = try FileManager.default.attributesOfItem(atPath: socketPath)
        let permissions = attrs[.posixPermissions] as? NSNumber
        let mode = Int32(permissions?.int32Value ?? 0)

        // Socket should have permissions 0o600 (owner read/write, no group or other)
        let ownerOnly = (mode & 0o777) == 0o600
        #expect(ownerOnly, "Socket permissions should be 0o600, got \(String(mode, radix: 8))")

        // Note: don't call stopSession to keep the socket file for cleanup by defer
    }

    @Test("HookSettings produces valid JSON with PreToolUse hook")
    func hookSettingsProducesValidJSON() throws {
        let helperPath = "/usr/local/bin/zero-permission-hook"
        let settings = HookSettings(helperPath: helperPath)

        let json = try settings.settingsJSON()

        // Parse the JSON to verify structure
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = parsed["hooks"] as? [String: Any],
              let preTool = hooks["PreToolUse"] as? [String: Any],
              let command = preTool["command"] as? String
        else {
            Issue.record("Failed to parse hook settings JSON")
            return
        }

        #expect(command == helperPath)
    }

    @Test("hook request encodes and decodes correctly")
    func hookRequestCodec() throws {
        let original = HookRequest(
            toolName: "Write",
            toolInput: #"{"path": "/test"}"#,
            requestID: "req-123",
            sessionID: "sess-456",
            cwd: "/home/user",
            permissionMode: "permissionMode"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HookRequest.self, from: encoded)

        #expect(decoded.toolName == original.toolName)
        #expect(decoded.toolInput == original.toolInput)
        #expect(decoded.requestID == original.requestID)
        #expect(decoded.sessionID == original.sessionID)
        #expect(decoded.cwd == original.cwd)
        #expect(decoded.permissionMode == original.permissionMode)
    }

    @Test("hook response encodes correctly with allow decision")
    func hookResponseAllowCodec() throws {
        let response = HookResponse(
            hookSpecificOutput: HookResponse.HookOutput(
                permissionDecision: .allow,
                permissionDecisionReason: "User approved"
            )
        )

        let encoded = try JSONEncoder().encode(response)

        guard let json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let hookOutput = json["hookSpecificOutput"] as? [String: Any],
              let decision = hookOutput["permission_decision"] as? String
        else {
            Issue.record("Failed to verify hook response encoding")
            return
        }

        #expect(decision == "allow")
    }

    @Test("hook response encodes correctly with deny decision")
    func hookResponseDenyCodec() throws {
        let response = HookResponse(
            hookSpecificOutput: HookResponse.HookOutput(
                permissionDecision: .deny,
                permissionDecisionReason: "User denied"
            )
        )

        let encoded = try JSONEncoder().encode(response)

        guard let json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let hookOutput = json["hookSpecificOutput"] as? [String: Any],
              let decision = hookOutput["permission_decision"] as? String
        else {
            Issue.record("Failed to verify hook response encoding")
            return
        }

        #expect(decision == "deny")
    }

    @Test("socket frame encoding and decoding")
    func socketFrameCodec() {
        let message = Data(#"{"test": "message"}"#.utf8)
        let encoded = SocketFrame.encode(message)

        #expect(encoded.count == 4 + message.count)

        guard let (payload, remaining) = SocketFrame.decode(encoded) else {
            Issue.record("Failed to decode socket frame")
            return
        }

        #expect(payload == message)
        #expect(remaining.isEmpty)
    }

    @Test("socket frame handles partial data")
    func socketFramePartialData() {
        let message = Data(#"{"test": "message"}"#.utf8)
        let encoded = SocketFrame.encode(message)

        // Only send part of the frame
        let partial = encoded.prefix(2)
        let result = SocketFrame.decode(Data(partial))

        #expect(result == nil, "Should return nil for incomplete frame")
    }

    @Test("socket frame handles multiple messages")
    func socketFrameMultipleMessages() {
        let msg1 = Data(#"{"a": 1}"#.utf8)
        let msg2 = Data(#"{"b": 2}"#.utf8)

        let frame1 = SocketFrame.encode(msg1)
        let frame2 = SocketFrame.encode(msg2)
        var combined = frame1
        combined.append(frame2)

        guard let (payload1, remaining1) = SocketFrame.decode(combined) else {
            Issue.record("Failed to decode first frame")
            return
        }

        #expect(payload1 == msg1)

        guard let (payload2, remaining2) = SocketFrame.decode(remaining1) else {
            Issue.record("Failed to decode second frame")
            return
        }

        #expect(payload2 == msg2)
        #expect(remaining2.isEmpty)
    }

    @Test("permission origin is required for user action")
    func permissionOriginUserAction() async throws {
        let socketDir = try createTempSocketDir()
        defer { cleanupTempDir(socketDir) }

        let sessionID = "test-session-origin"

        let broker = PermissionBroker(
            handler: { request, allow, deny in
                // Use the userAction origin to allow
                allow(PermissionOrigin.userAction)
            },
            socketsDirectory: socketDir,
            timeout: 2.0
        )

        try await broker.startSession(id: sessionID)

        let request = HookRequest(
            toolName: "Read",
            toolInput: #"{"path": "/tmp/test"}"#,
            requestID: "req-origin-1",
            sessionID: sessionID,
            cwd: "/tmp",
            permissionMode: "permissionMode"
        )

        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionBroker.Decision, Never>) in
            Task {
                await broker.processRequest(request) { decision in
                    continuation.resume(returning: decision)
                }
            }
        }

        #expect(decision == .allow)

        await broker.stopSession(id: sessionID)
    }
}
