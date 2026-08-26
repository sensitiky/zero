import Foundation
import Testing

@testable import ZeroCore

@Suite("PathContainment")
struct PathContainmentTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a path under root passes")
    func pathUnderRootPasses() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("a/b/c.txt")
        try FileManager.default.createDirectory(
            at: child.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "hi".write(to: child, atomically: true, encoding: .utf8)

        #expect(throws: Never.self) {
            try PathContainment.validate(child, isUnder: root)
        }
    }

    @Test("root itself passes")
    func rootItselfPasses() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self) {
            try PathContainment.validate(root, isUnder: root)
        }
    }

    @Test("a path outside root is rejected")
    func pathOutsideRootRejected() throws {
        let root = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        #expect(throws: PathContainmentError.self) {
            try PathContainment.validate(outside, isUnder: root)
        }
    }

    @Test("a sibling directory that merely shares a name prefix is rejected")
    func siblingPrefixNotConfusedWithChild() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("repo")
        let evil = base.appendingPathComponent("repo-evil/secret")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: evil.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        #expect(throws: PathContainmentError.self) {
            try PathContainment.validate(evil, isUnder: root)
        }
    }

    @Test("a symlink resolving outside root is rejected")
    func symlinkEscapeRejected() throws {
        let root = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: PathContainmentError.self) {
            try PathContainment.validate(link, isUnder: root)
        }
    }
}
