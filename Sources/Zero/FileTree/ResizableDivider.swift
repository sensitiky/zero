import AppKit
import SwiftUI

/// A vertical divider that resizes whatever's beside it — the plain `Divider()` this replaces had
/// no way to drag, and `HStack` gets no free column-resize the way `NavigationSplitView` gives its
/// own columns (the reason that wasn't used for this panel — see `docs/prds/007-file-tree-sidebar/PLAN.md`).
struct ResizableDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        Divider()
            // The visible line stays hairline-thin; the draggable/hoverable area is wider than
            // that so the handle is actually findable with a mouse.
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = widthAtDragStart ?? width
                        widthAtDragStart = start
                        // The panel sits trailing; dragging the handle left grows it.
                        let proposed = start - value.translation.width
                        width = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
            .onDisappear { NSCursor.pop() }
    }
}
