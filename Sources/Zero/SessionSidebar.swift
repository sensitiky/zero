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
                                    .foregroundStyle(
                                        Theme.foreground(scheme).opacity(Theme.secondaryOpacity)
                                    )
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
                .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Add a project, start a session in one, and search.
struct SidebarHeader: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var scheme

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
            }

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.foreground(scheme).opacity(Theme.secondaryOpacity))
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
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.foreground(scheme).opacity(0.06))
            )
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

struct ProjectHeader: View {
    let project: AppModel.Project
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            Text(project.name)
            Spacer(minLength: 4)
            Button {
                model.selection = .project(project.id)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New session in \(project.name)")
            .accessibilityLabel("New session in \(project.name)")
        }
        .accessibilityElement(children: .contain)
    }
}

/// One session: what it is called, and under it what it is doing.
struct SessionRow: View {
    let session: AppModel.SessionSnapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            StateDot(state: session.state, awaiting: session.pendingPermission != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1)
                if !session.summary.isEmpty {
                    // Dimmer, and never dimmer than 70%: below that it stops clearing WCAG AAA.
                    Text(session.summary)
                        .font(.caption)
                        .foregroundStyle(
                            Theme.foreground(scheme).opacity(Theme.secondaryOpacity)
                        )
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Spelled out for VoiceOver: a dot conveys nothing without it.
    private var accessibilityLabel: String {
        let status = session.pendingPermission != nil
            ? "waiting for your permission"
            : String(describing: session.state)
        return "\(session.title). \(session.summary). \(status)"
    }
}

struct StateDot: View {
    let state: SessionState
    let awaiting: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(Theme.foreground(scheme).opacity(awaiting ? 1 : opacity))
            .frame(width: 7, height: 7)
            // Shape, not just brightness: the palette is monochrome, so a ring is what separates
            // "needs you" from "busy" without relying on a colour difference.
            .overlay {
                if awaiting {
                    Circle()
                        .stroke(Theme.foreground(scheme), lineWidth: 1)
                        .frame(width: 13, height: 13)
                }
            }
            .frame(width: 14, height: 14)
    }

    private var opacity: Double {
        switch state {
        case .running, .waitingPermission: return 1
        case .idle: return 0.45
        case .finished: return 0.3
        case .error: return 0.75
        }
    }
}
