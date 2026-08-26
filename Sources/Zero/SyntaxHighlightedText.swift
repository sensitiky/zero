import SwiftUI
import ZeroCore

/// Renders one line as concatenated colored `Text` spans via `SyntaxHighlighter` — shared between
/// `FilePreviewView`'s plain preview and `DiffView`'s diff rows, so a code file looks the same
/// whether it's being read straight or being diffed. A file the highlighter doesn't recognize as
/// code renders as one plain span, unchanged from before either caller existed.
///
/// Layered on top of, not instead of, a diff row's own tint (`Theme.Diff.added`/`.removed`): the
/// tint is a whole-line background signal, the token color is per-character foreground — different
/// visual layers, which is why combining them doesn't read as noisy the way stacking two
/// foreground treatments would. The same pairing (background wash + foreground token color) is how
/// every mainstream diff-with-highlighting view already does this; it isn't a new idiom.
enum SyntaxHighlightedText {
    static func line(_ text: String, forFileNamed name: String, scheme: ColorScheme) -> Text {
        guard let commentStyle = SyntaxHighlighter.commentStyle(forFileNamed: name) else {
            return Text(text).foregroundStyle(Theme.foreground(scheme))
        }
        let tokens = SyntaxHighlighter.tokenize(text, commentStyle: commentStyle)
        return tokens.reduce(Text("")) { line, token in
            line + Text(token.text).foregroundStyle(color(for: token.kind, scheme: scheme))
        }
    }

    private static func color(for kind: SyntaxHighlighter.TokenKind, scheme: ColorScheme) -> Color {
        switch kind {
        case .plain: Theme.foreground(scheme)
        case .keyword: Theme.Syntax.keyword(scheme)
        case .string: Theme.Syntax.string(scheme)
        case .comment: Theme.secondary(scheme)
        case .number: Theme.Syntax.number(scheme)
        }
    }
}
