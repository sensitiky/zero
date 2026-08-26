import Foundation

/// A file's SF Symbol, by shape — never by hue.
///
/// Lives in `ZeroCore` rather than beside the view that renders it, same reasoning
/// `ComposerMetrics` already established: a pure `name → symbol` mapping is testable directly
/// here, and would only be testable through a SwiftUI view if it lived in `Zero`.
///
/// Zero's design system has exactly one accent color, used in exactly two views (`docs/DESIGN.md`,
/// enforced by `Scripts/lint-design-tokens.sh`); a file tree distinguishes types the way every
/// other surface in this app distinguishes anything, which is shape and weight, not color (see
/// `docs/prds/007-file-tree-sidebar/PRD.md` Non-goals).
public enum FileIcon {
    /// SF Symbol name for a folder.
    public static func folder(expanded: Bool) -> String {
        expanded ? "folder.fill" : "folder"
    }

    /// SF Symbol name for a file, by extension or, for a manifest/lockfile, by exact name. Falls
    /// back to a generic document icon — never blank — for anything not in this table.
    public static func symbol(forFileNamed name: String) -> String {
        if manifestNames.contains(name) { return "doc.badge.gearshape" }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "lock" { return "doc.badge.gearshape" }
        return extensionTable[ext] ?? "doc"
    }

    private static let manifestNames: Set<String> = ["Package.swift", "package.json"]

    private static let extensionTable: [String: String] = {
        var table: [String: String] = [:]
        table["swift"] = "swift"
        for ext in ["js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "java", "kt", "sh"] {
            table[ext] = "chevron.left.forwardslash.chevron.right"
        }
        for ext in ["json", "yml", "yaml", "xml", "toml"] {
            table[ext] = "curlybraces"
        }
        for ext in ["md", "txt", "html"] {
            table[ext] = "doc.text"
        }
        for ext in ["png", "jpg", "jpeg", "gif", "svg", "webp"] {
            table[ext] = "photo"
        }
        table["pdf"] = "doc.richtext"
        return table
    }()
}
