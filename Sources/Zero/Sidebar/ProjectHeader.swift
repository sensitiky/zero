import SwiftUI
import ZeroCore

/// A project in the sidebar: its name, and the one thing you do to it — start a session.
struct ProjectHeader: View {
    let project: AppModel.Project
    @Bindable var model: AppModel

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
