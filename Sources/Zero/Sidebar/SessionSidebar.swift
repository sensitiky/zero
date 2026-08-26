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
            // A custom binding, not `$model.selection` directly: selecting a restored session is
            // the one moment `SessionCoordinator` needs to hear about it, to lazily resume it if
            // it isn't already live (see `SessionCoordinator.openSession`, PRD FR-7).
            List(selection: Binding(
                get: { model.selection },
                set: { newValue in
                    model.selection = newValue
                    if case .session(let id) = newValue { Task { await coordinator.openSession(id) } }
                }
            )) {
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
                            let isSelected = model.selection == .session(session.id)
                            SessionRow(session: session, isSelected: isSelected)
                                .tag(AppModel.Selection.session(session.id))
                                .listRowBackground(selectionFill(isSelected))
                        }
                    } header: {
                        ProjectHeader(project: project, model: model)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// The fill under a selected row — ours, not AppKit's.
    ///
    /// Left to itself the list paints a selected row with the **system** accent colour: the user's
    /// choice in System Settings, not a value from docs/DESIGN.md, and in light mode a saturated
    /// blue that puts the row's own text at 4.6:1 and the accent dot at 1.2:1 in a palette whose
    /// whole argument is 16.74:1 and one hue. It also moves out from under the app the moment
    /// somebody picks pink.
    ///
    /// `.tint(_:)` does not reach it — measured, not assumed: tinting the list leaves the fill blue,
    /// because the sidebar style takes that colour from AppKit rather than from the environment. A
    /// `.listRowBackground` does, so the fill becomes the foreground token and the row inverts onto
    /// it (`Theme.rowForeground`). Supplying one is also why selection has to be passed down
    /// explicitly: it stops the platform reporting the row as prominent.
    ///
    /// It stays at full weight when the window is not focused, where AppKit would fade to grey. One
    /// row out of dozens says "this is the session you are in", and that is worth reading from
    /// across the desk.
    ///
    /// **Every row gets a background, not just the selected one.** A transparent one on the rest is
    /// what made the blue flash for a frame or two on click: AppKit highlights the row the instant
    /// the mouse goes down, while `model.selection` — and therefore this fill — only catches up on
    /// the next render, so for that gap the highlight had nothing over it. The unselected fill is
    /// the same colour the sidebar is painted with, so it is invisible except in the one job it
    /// does, which is being opaque.
    private func selectionFill(_ isSelected: Bool) -> some View {
        Theme.background(scheme).overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.inline, style: .continuous)
                    .fill(Theme.rowSelection(scheme))
            }
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
