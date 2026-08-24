import SwiftUI
import ZeroCore

/// Projects, each with its sessions under it.
///
/// Grouped rather than one flat list: sessions belong to a repository, and a single scroll of every
/// session ever started stops being navigable at about a dozen. The group is the unit you think in.
struct SessionSidebar: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(model: model, coordinator: coordinator)
            Divider()
            content
        }
        .zeroSurface(scheme)
    }

    @ViewBuilder
    private var content: some View {
        if model.projects.isEmpty {
            emptyState(
                "No projects",
                "Add a repository to start. Each session gets its own git worktree inside it."
            )
        } else if model.visibleProjects.isEmpty {
            emptyState("No matches", "Nothing matches “\(model.searchText)”.")
        } else {
            List(selection: $model.selection) {
                ForEach(model.visibleProjects) { project in
                    Section {
                        let sessions = model.sessions(in: project)
                        if sessions.isEmpty {
                            Button {
                                model.selection = .project(project.id)
                            } label: {
                                Text("Start a session")
                                    .font(.callout)
                                    .foregroundStyle(Theme.secondary(scheme))
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(sessions) { session in
                            SessionRow(session: session)
                                .tag(AppModel.Selection.session(session.id))
                        }
                    } header: {
                        ProjectHeader(project: project, model: model)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary(scheme))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
