import Foundation
import Observation
import SwiftUI
import ZeroCore

/// What the UI observes.
///
/// Deliberately thin: it owns no protocol knowledge and no subprocess. Sessions live in
/// `SessionRuntime` actors off the main actor, and this type holds only the `Sendable` snapshots the
/// views render — the NFR forbidding I/O and parsing on the main actor is only meetable if the
/// observable layer never touches either.
@MainActor
@Observable
final class AppModel {
    /// A repository the user has opened. Its path is its identity — two entries for the same
    /// checkout would split one project's sessions across two groups.
    struct Project: Identifiable, Hashable, Sendable {
        let id: URL
        var name: String

        init(url: URL) {
            self.id = url
            self.name = url.lastPathComponent
        }
    }

    /// What the sidebar has selected. A project and a session are different destinations: a project
    /// opens the "what should be built" state, a session opens its transcript.
    enum Selection: Hashable, Sendable {
        case project(URL)
        case session(UUID)
    }

    /// A session as the UI sees it. No model objects, no actors, nothing that must be awaited.
    struct SessionSnapshot: Identifiable, Sendable {
        let id: UUID
        let projectID: URL
        var title: String
        var provider: String
        var model: String
        var branch: String
        var workspace: SessionRuntime.Workspace
        var state: SessionState
        /// The conversation. Assembly lives in `ZeroCore.Transcript`, where it can be tested.
        var transcript = Transcript()
        /// The opening request, so a session that has not replied yet still says what it is for.
        var initialPrompt: String

        var events: [Transcript.Entry] { transcript.entries }
        var usage: Usage { transcript.usage }
        var pendingPermission: PermissionRequest? { transcript.pendingPermission }

        /// The dim second line: what this session is doing, falling back to what it was asked.
        var summary: String {
            transcript.summary.isEmpty ? Transcript.condensed(initialPrompt) : transcript.summary
        }
    }

    var projects: [Project] = []
    var sessions: [SessionSnapshot] = []
    var selection: Selection?
    var inspectorVisible = true
    var composerText = ""
    /// Filters the sidebar by session title and summary only.
    ///
    /// Deliberately not a full-text search over transcripts: those are long, and a search that
    /// matches every session because the word appears in some tool output is a search that tells you
    /// nothing. Searching the transcript is a different feature with a different UI.
    var searchText = ""
    /// What the next session in a project will use, remembered between sessions.
    var draftProvider = ProviderDescriptor.claude.id
    var draftModel = ProviderDescriptor.claude.knownModels.first ?? ""
    /// Defaults to the checkout you are already in, because continuing your current work is the
    /// ordinary case and an isolated worktree is the deliberate one.
    var draftWorkspace: SessionRuntime.Workspace = .currentCheckout

    var selectedSessionID: UUID? {
        if case .session(let id) = selection { return id }
        return nil
    }

    var selectedProjectID: URL? {
        switch selection {
        case .project(let url): return url
        case .session(let id): return sessions.first { $0.id == id }?.projectID
        case nil: return nil
        }
    }

    var selectedSession: SessionSnapshot? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var selectedProject: Project? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    /// Sessions of a project, newest first, filtered by the search field.
    func sessions(in project: Project) -> [SessionSnapshot] {
        let all = sessions.filter { $0.projectID == project.id }
        guard !searchText.isEmpty else { return all }
        let needle = searchText.lowercased()
        return all.filter {
            $0.title.lowercased().contains(needle) || $0.summary.lowercased().contains(needle)
        }
    }

    /// Projects worth showing. While searching, a project with no matching session is hidden rather
    /// than shown empty — an empty group is noise in a list you are filtering.
    var visibleProjects: [Project] {
        guard !searchText.isEmpty else { return projects }
        return projects.filter { !sessions(in: $0).isEmpty }
    }

    /// Sessions waiting on the user, for the sidebar's badge.
    var sessionsAwaitingUser: [SessionSnapshot] {
        sessions.filter { $0.pendingPermission != nil }
    }

    static func condensed(_ text: String, limit: Int = 90) -> String {
        Transcript.condensed(text, limit: limit)
    }

    func addProject(_ url: URL) {
        let project = Project(url: url)
        guard !projects.contains(where: { $0.id == project.id }) else {
            selection = .project(project.id)
            return
        }
        projects.append(project)
        selection = .project(project.id)
    }

    // MARK: - Mutation

    /// Records what the user just sent, so it appears in the transcript at the moment they send it
    /// rather than never.
    func appendUserMessage(_ text: String, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].transcript.appendUserMessage(text)
        sessions[index].state = .running
    }

    func apply(_ event: AgentEvent, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let state = sessions[index].transcript.apply(event) {
            sessions[index].state = state
        }
    }

    func resolvePermission(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].transcript.resolvePermission()
        sessions[index].state = .running
    }

}
