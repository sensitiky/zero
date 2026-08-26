import Foundation

/// Reads one file's content, bounded to a workspace root.
public enum WorkspaceFileReader {
    /// The bar `docs/prds/007-file-tree-sidebar/PRD.md`'s FR-9 set — roughly what GitHub's own
    /// blob view draws the same line at, and conservative given this app's own history with
    /// large-text rendering cost (`004-composer-input-lag`).
    public static let sizeCeiling = 1_048_576 // 1 MB

    public enum Content: Sendable, Equatable {
        case text(String)
        case binary(bytes: Int)
        case tooLarge(bytes: Int)
    }

    /// - parameter root: The workspace root `file` must resolve under (`PathContainment`) — the
    ///   same boundary `WorkspaceTree` enforces for listing, enforced again here because a caller
    ///   holding a `WorkspaceEntry.url` from an earlier listing is not proof the entry — or what
    ///   it now points to — hasn't changed since.
    /// - throws: `PathContainmentError` if `file` falls outside `root`, or a `FileManager`/`Data`
    ///   error if reading fails outright (the file vanished, permissions changed).
    public static func read(_ file: URL, root: URL) throws -> Content {
        try PathContainment.validate(file, isUnder: root)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? Int) ?? 0
        guard size <= sizeCeiling else { return .tooLarge(bytes: size) }

        let data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8) else {
            return .binary(bytes: data.count)
        }
        return .text(text)
    }
}
