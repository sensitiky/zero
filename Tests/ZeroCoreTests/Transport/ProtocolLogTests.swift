import Foundation
import Testing

@testable import ZeroCore

@Suite("ProtocolLog")
struct ProtocolLogTests {
    private let tempDir = FileManager.default.temporaryDirectory

    @Test("disabled by default — nothing written")
    func disabledByDefault() async throws {
        let logPath = tempDir.appendingPathComponent("test-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logPath) }

        let log = ProtocolLog(logURL: logPath)

        // Logging is disabled by default.
        await log.logInbound(Data(#"{"type":"test"}"#.utf8))
        await log.logOutbound(Data(#"{"type":"test"}"#.utf8))

        // Wait a bit for any background writes to complete.
        try await Task.sleep(for: .milliseconds(100))

        // File should not exist.
        #expect(!FileManager.default.fileExists(atPath: logPath.path))
    }

    @Test("enabled logging records inbound and outbound in order")
    func enabledLoggingRecordsInOrder() async throws {
        let logPath = tempDir.appendingPathComponent("test-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logPath) }

        let log = ProtocolLog(logURL: logPath)
        await log.enable()

        let record1 = Data(#"{"id":1}"#.utf8)
        let record2 = Data(#"{"id":2}"#.utf8)

        await log.logOutbound(record1)
        await log.logInbound(record2)

        // Wait for background writes.
        try await Task.sleep(for: .milliseconds(100))

        let contents = try String(contentsOf: logPath, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)

        // Should have two records.
        #expect(lines.count == 2)

        // First should be outbound, second inbound.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let firstData = lines[0].data(using: .utf8),
           let first = try? decoder.decode(ProtocolLog.Record.self, from: firstData)
        {
            #expect(first.direction == .outbound)
        }

        if let secondData = lines[1].data(using: .utf8),
           let second = try? decoder.decode(ProtocolLog.Record.self, from: secondData)
        {
            #expect(second.direction == .inbound)
        }
    }

    @Test("API keys are redacted")
    func apiKeysAreRedacted() async throws {
        let logPath = tempDir.appendingPathComponent("test-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logPath) }

        let log = ProtocolLog(logURL: logPath)
        await log.enable()

        let recordWithSecret = Data(#"{"api_key":"sk-1234567890abcdef"}"#.utf8)
        await log.logInbound(recordWithSecret)

        // Wait for background writes.
        try await Task.sleep(for: .milliseconds(100))

        let contents = try String(contentsOf: logPath, encoding: .utf8)
        #expect(!contents.contains("sk-1234567890abcdef"))
        #expect(contents.contains("<redacted>"))
    }

    @Test("bearer tokens are redacted")
    func bearerTokensAreRedacted() async throws {
        let logPath = tempDir.appendingPathComponent("test-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logPath) }

        let log = ProtocolLog(logURL: logPath)
        await log.enable()

        let recordWithSecret = Data(#"{"Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ"}"#.utf8)
        await log.logInbound(recordWithSecret)

        // Wait for background writes.
        try await Task.sleep(for: .milliseconds(100))

        let contents = try String(contentsOf: logPath, encoding: .utf8)
        #expect(!contents.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        #expect(contents.contains("<redacted>"))
    }

    @Test("OAuth tokens are redacted")
    func oauthTokensAreRedacted() async throws {
        let logPath = tempDir.appendingPathComponent("test-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logPath) }

        let log = ProtocolLog(logURL: logPath)
        await log.enable()

        let recordWithSecret = Data(#"{"access_token":"ya29.a0AfH6SMBx1234567890"}"#.utf8)
        await log.logInbound(recordWithSecret)

        // Wait for background writes.
        try await Task.sleep(for: .milliseconds(100))

        let contents = try String(contentsOf: logPath, encoding: .utf8)
        #expect(!contents.contains("ya29.a0AfH6SMBx1234567890"))
        #expect(contents.contains("<redacted>"))
    }

    @Test("size bound is enforced")
    func sizeBoundEnforced() async throws {
        let logPath = tempDir.appendingPathComponent("test-\(UUID()).log")
        defer {
            try? FileManager.default.removeItem(at: logPath)
            try? FileManager.default.removeItem(at: logPath.appendingPathExtension("1"))
        }

        // Very small max size for testing to force rotation.
        let log = ProtocolLog(logURL: logPath, maxSizeBytes: 400)
        await log.enable()

        // Write records until rotation happens.
        for i in 0..<30 {
            let record = Data(#"{"id":\#(i)}"#.utf8)
            await log.logInbound(record)
        }

        // Wait for background writes to complete and rotation to occur.
        try await Task.sleep(for: .milliseconds(1000))

        // Check that rotation happened: backup file exists.
        let backupPath = logPath.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: backupPath.path))
    }

    @Test("records with refresh_token are redacted")
    func refreshTokensAreRedacted() async throws {
        let logPath = tempDir.appendingPathComponent("test-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logPath) }

        let log = ProtocolLog(logURL: logPath)
        await log.enable()

        let recordWithSecret = Data(#"{"refresh_token":"1//refresh_token_value_here"}"#.utf8)
        await log.logInbound(recordWithSecret)

        // Wait for background writes.
        try await Task.sleep(for: .milliseconds(100))

        let contents = try String(contentsOf: logPath, encoding: .utf8)
        #expect(!contents.contains("1//refresh_token_value_here"))
        #expect(contents.contains("<redacted>"))
    }

    @Test("non-JSON data is handled gracefully")
    func nonJsonDataHandledGracefully() async throws {
        let logPath = tempDir.appendingPathComponent("test-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logPath) }

        let log = ProtocolLog(logURL: logPath)
        await log.enable()

        // Log some binary data that is not valid JSON.
        let binaryData = Data([0xFF, 0xFE, 0xFD, 0xFC])
        await log.logInbound(binaryData)

        // Wait for background writes.
        try await Task.sleep(for: .milliseconds(100))

        // A vacuous #expect(true) stood here. "Handled gracefully" has to mean something: the
        // record must survive rather than be silently dropped because the redactor could not
        // parse it as JSON.
        let written = try #require(try? Data(contentsOf: logPath))
        #expect(!written.isEmpty)
    }

    @Test("disabled logging does not write even after being enabled then disabled")
    func disablingStopsWrites() async throws {
        let logPath = tempDir.appendingPathComponent("test-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logPath) }

        let log = ProtocolLog(logURL: logPath)
        await log.enable()

        let record1 = Data(#"{"id":1}"#.utf8)
        await log.logInbound(record1)

        // Wait for background write.
        try await Task.sleep(for: .milliseconds(100))

        // Disable logging.
        await log.disable()

        // Try to write more; should be ignored.
        let record2 = Data(#"{"id":2}"#.utf8)
        await log.logInbound(record2)

        // Wait a bit.
        try await Task.sleep(for: .milliseconds(100))

        let contents = try String(contentsOf: logPath, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)

        // Should have only one record.
        #expect(lines.count == 1)
    }

    @Test("redactor catches multiple secret patterns in one record")
    func redactorCatchesMultipleSecrets() async throws {
        let logPath = tempDir.appendingPathComponent("test-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logPath) }

        let log = ProtocolLog(logURL: logPath)
        await log.enable()

        let recordWithMultipleSecrets = Data(
            #"{"api_key":"sk-secret1","access_token":"token123","Authorization":"Bearer jwt-token-here"}"#.utf8
        )
        await log.logInbound(recordWithMultipleSecrets)

        // Wait for background writes.
        try await Task.sleep(for: .milliseconds(100))

        let contents = try String(contentsOf: logPath, encoding: .utf8)
        #expect(!contents.contains("sk-secret1"))
        #expect(!contents.contains("token123"))
        #expect(!contents.contains("jwt-token-here"))
    }
}
