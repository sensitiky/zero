import Foundation
import Testing

@testable import ZeroCore

@Suite("WorkspaceWatcher")
struct WorkspaceWatcherTests {
    @Test("a file created under root triggers the callback")
    func fileCreationTriggersCallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await confirmation(expectedCount: 1...) { fired in
            let watcher = WorkspaceWatcher(root: root, latency: 0.05) {
                fired()
            }
            let wrapped = try #require(watcher)

            // FSEvents needs a moment to arm before it reliably reports events made right after
            // stream start.
            try await Task.sleep(for: .milliseconds(200))
            try "hello".write(
                to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8
            )
            try await Task.sleep(for: .seconds(1))
            wrapped.stop()
        }
    }
}
