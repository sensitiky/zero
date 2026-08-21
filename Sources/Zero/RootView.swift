import SwiftUI
import ZeroCore

/// The shell: projects and their sessions on the left, the active conversation in the middle, its
/// accounting on the right.
struct RootView: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationSplitView {
            SessionSidebar(model: model, coordinator: coordinator)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            HStack(spacing: 0) {
                ConversationPane(model: model, coordinator: coordinator)
                if model.inspectorVisible, model.selectedSession != nil {
                    Divider()
                    InspectorPane(model: model)
                        .frame(width: 260)
                }
            }
        }
        .zeroSurface(scheme)
        .onAppear { StartupClock.reportFirstFrame() }
        .alert(
            "Something went wrong",
            isPresented: .init(
                get: { coordinator.lastError != nil },
                set: { if !$0 { coordinator.lastError = nil } }
            )
        ) {
            Button("OK") { coordinator.lastError = nil }
        } message: {
            // Shown verbatim: a provider that will not start says why, and paraphrasing that into
            // "an error occurred" throws away the only thing that helps.
            Text(coordinator.lastError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.inspectorVisible.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                // Disabled rather than hidden when there is no session. It used to render always and
                // do nothing without one, which reads as a broken button next to the working sidebar
                // toggle — and there were two things that looked like sidebar controls.
                .disabled(model.selectedSession == nil)
                .help(model.selectedSession == nil ? "Select a session first" : "Toggle the inspector")
            }
        }
    }
}

/// Shown when nothing is selected.
struct EmptyStatePane: View {
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title3.weight(.medium))
            Text(detail)
                .font(.callout)
                .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zeroSurface(scheme)
    }
}
