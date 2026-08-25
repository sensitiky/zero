import SwiftUI
import ZeroCore

/// Add a project, start a session in one, and search.
struct SidebarHeader: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(BridgeController.self) private var bridge
    @State private var showingBridge = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    if let url = coordinator.chooseRepository() { model.addProject(url) }
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Add a project")
                .accessibilityLabel("Add a project")

                // Separate from the folder button on purpose: adding a repository and starting work
                // in one you already added are different intents, and one button doing both means
                // guessing which you meant.
                Menu {
                    if model.projects.isEmpty {
                        Text("No projects yet")
                    }
                    ForEach(model.projects) { project in
                        Button(project.name) { model.selection = .project(project.id) }
                    }
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.projects.isEmpty)
                .help("New session in…")
                .accessibilityLabel("New session in a project")

                Spacer(minLength: 0)

                // A popover, the pattern the usage ring already established, and for the same
                // reason: this is a switch and a code you glance at, not a column of the window and
                // not a settings window (DESIGN.md, "No second sidebar").
                Button {
                    showingBridge.toggle()
                } label: {
                    // The state is carried by the shape — a struck-through antenna when off — since
                    // the accent means one thing in this app and it is not this.
                    Image(
                        systemName: bridge.isListening
                            ? "antenna.radiowaves.left.and.right"
                            : "antenna.radiowaves.left.and.right.slash"
                    )
                }
                .buttonStyle(.borderless)
                .help(bridge.isListening ? "Bridge — listening" : "Bridge — off")
                .accessibilityLabel(
                    bridge.isListening ? "Bridge, listening. Open bridge panel."
                        : "Bridge, off. Open bridge panel."
                )
                .popover(isPresented: $showingBridge, arrowEdge: .bottom) {
                    // A popover is already a floating container, so it declares the floating level
                    // through its own background rather than nesting a second panel inside itself.
                    BridgePanel(bridge: bridge)
                        .presentationBackground(.thickMaterial)
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.secondary(scheme))
                TextField("Search sessions", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search session titles and summaries")
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.callout)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .zeroPanel(scheme, radius: Theme.Radius.inline, elevation: .raised, stroke: nil)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}
