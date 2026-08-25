import Foundation

/// Remembers which project or session was selected, across a quit and relaunch.
///
/// `UserDefaults`, not a `Store` row: this is a single scalar UI preference with no relations and
/// no history of its own — a `@Model` for one value that never varies in shape would be a schema
/// for a preference, not a feature. See `docs/prds/006-persistent-projects-sessions/PRD.md`,
/// "Data model changes".
enum LastSelection {
    private static let kindKey = "lastSelection.kind"
    private static let idKey = "lastSelection.id"

    static func save(_ selection: AppModel.Selection?) {
        let defaults = UserDefaults.standard
        switch selection {
        case .project(let url):
            defaults.set("project", forKey: kindKey)
            defaults.set(url.path, forKey: idKey)
        case .session(let id):
            defaults.set("session", forKey: kindKey)
            defaults.set(id.uuidString, forKey: idKey)
        case nil:
            defaults.removeObject(forKey: kindKey)
            defaults.removeObject(forKey: idKey)
        }
    }

    /// The persisted selection, or nil if there wasn't one — the caller still has to check it
    /// resolves against what was actually restored (see `SessionCoordinator.restoreFromStore`);
    /// this type has no way to know what exists.
    static func load() -> AppModel.Selection? {
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: idKey) else { return nil }
        switch defaults.string(forKey: kindKey) {
        case "project":
            return .project(URL(fileURLWithPath: idString))
        case "session":
            return UUID(uuidString: idString).map(AppModel.Selection.session)
        default:
            return nil
        }
    }
}
