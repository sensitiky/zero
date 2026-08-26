import Testing

@testable import ZeroCore

@Suite("FileIcon")
struct FileIconTests {
    @Test("folder icon reflects expanded state")
    func folderReflectsExpanded() {
        #expect(FileIcon.folder(expanded: false) == "folder")
        #expect(FileIcon.folder(expanded: true) == "folder.fill")
    }

    @Test("a representative sample across the mapping table")
    func representativeSample() {
        #expect(FileIcon.symbol(forFileNamed: "App.swift") == "swift")
        #expect(FileIcon.symbol(forFileNamed: "index.ts") == "chevron.left.forwardslash.chevron.right")
        #expect(FileIcon.symbol(forFileNamed: "config.json") == "curlybraces")
        #expect(FileIcon.symbol(forFileNamed: "README.md") == "doc.text")
        #expect(FileIcon.symbol(forFileNamed: "logo.png") == "photo")
        #expect(FileIcon.symbol(forFileNamed: "spec.pdf") == "doc.richtext")
        #expect(FileIcon.symbol(forFileNamed: "Package.swift") == "doc.badge.gearshape")
        #expect(FileIcon.symbol(forFileNamed: "yarn.lock") == "doc.badge.gearshape")
    }

    @Test("an unmapped extension falls back to a generic document icon, never blank")
    func unmappedExtensionFallsBack() {
        #expect(FileIcon.symbol(forFileNamed: "mystery.xyz") == "doc")
        #expect(FileIcon.symbol(forFileNamed: "no-extension") == "doc")
    }
}
