import SwiftUI
import ZeroCore

@main
struct ZeroApp: App {
    @State private var model = AppModel()
    @State private var coordinator: SessionCoordinator

    init() {
        let model = AppModel()
        if PreviewData.isEnabled {
            // ZERO_PREVIEW=1, set via LSEnvironment in the preview bundle's Info.plist — never seen
            // by a normal launch. Seeds the sidebar, transcript, tool cells, diff, plan and the
            // permission card with data built through the real Transcript API, so every panel can be
            // looked at without a real agent or repository.
            PreviewData.seed(into: model)
        }
        _model = State(initialValue: model)
        _coordinator = State(initialValue: SessionCoordinator(model: model))
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, coordinator: coordinator)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { ZeroCommands(model: model, coordinator: coordinator) }
    }
}
