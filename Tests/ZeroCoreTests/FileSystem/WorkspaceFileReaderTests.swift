import Foundation
import Testing

@testable import ZeroCore

@Suite("WorkspaceFileReader")
struct WorkspaceFileReaderTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a small UTF-8 file round-trips as text")
    func textFileRoundTrips() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hello.txt")
        try "Hello, 世界".write(to: file, atomically: true, encoding: .utf8)

        #expect(try WorkspaceFileReader.read(file, root: root) == .text("Hello, 世界"))
    }

    @Test("invalid UTF-8 bytes come back as binary")
    func invalidUTF8IsBinary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("data.bin")
        let bytes = Data([0xFF, 0xFE, 0x00, 0x01, 0x02])
        try bytes.write(to: file)

        guard case .binary(let count) = try WorkspaceFileReader.read(file, root: root) else {
            Issue.record("expected .binary")
            return
        }
        #expect(count == bytes.count)
    }

    @Test("a file over the size ceiling comes back tooLarge without reading its bytes")
    func oversizedFileIsTooLarge() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("huge.txt")
        // Sparse-ish: seek past the ceiling and write one byte, rather than materializing 1 MB+
        // of test data — the boundary check is on the reported file size, not on content.
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(WorkspaceFileReader.sizeCeiling + 1))
        handle.write(Data([0x41]))
        try handle.close()

        let content = try WorkspaceFileReader.read(file, root: root)
        guard case .tooLarge(let bytes) = content else {
            Issue.record("expected .tooLarge, got \(content)")
            return
        }
        #expect(bytes > WorkspaceFileReader.sizeCeiling)
    }

    @Test("a file at exactly the ceiling is still read")
    func fileAtCeilingIsRead() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("exact.txt")
        try Data(repeating: 0x41, count: WorkspaceFileReader.sizeCeiling).write(to: file)

        guard case .text(let text) = try WorkspaceFileReader.read(file, root: root) else {
            Issue.record("expected .text")
            return
        }
        #expect(text.utf8.count == WorkspaceFileReader.sizeCeiling)
    }

    @Test("a path outside root throws")
    func pathOutsideRootThrows() throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let file = outside.appendingPathComponent("secret.txt")
        try "secret".write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: PathContainmentError.self) {
            _ = try WorkspaceFileReader.read(file, root: root)
        }
    }
}
