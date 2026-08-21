import SwiftUI
import ZeroCore

/// The shell: sessions on the left, the active conversation in the middle, its accounting on the
/// right. Three panes because those are the three questions — which session, what is it saying, what
/// is it costing.
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationSplitView {
            SessionSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            HStack(spacing: 0) {
                ConversationPane(model: model)
                if model.inspectorVisible, model.selectedSession != nil {
                    Divider()
                    InspectorPane(model: model)
                        .frame(width: 260)
                }
            }
        }
        .zeroSurface(scheme)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.inspectorVisible.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Toggle the inspector")
            }
        }
    }
}

/// Placeholder shown when nothing is selected, and when there is nothing to select.
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
