import SwiftUI
import ZeroCore

@main
struct ZeroApp: App {
    @State private var model = AppModel()
    @State private var coordinator: SessionCoordinator
    /// Off at launch, always (FR-2). Owned here because it outlives any one view, and reached
    /// through the environment because exactly one view needs it.
    @State private var bridge: BridgeController

    init() {
        let model = AppModel()
        if PreviewData.isEnabled {
            // ZERO_PREVIEW=1, set via LSEnvironment in the preview bundle's Info.plist — never seen
            // by a normal launch. Seeds the sidebar, transcript, tool cells, diff, plan and the
            // permission card with data built through the real Transcript API, so every panel can be
            // looked at without a real agent or repository.
            PreviewData.seed(into: model)
        }
        let coordinator = SessionCoordinator(model: model)
        // Before the first frame, not deferred to `.onAppear` — that would race the sidebar's
        // first render showing empty (PRD FR-4/FR-6). Skipped under preview data: it already
        // seeded `model` directly, and restoring here would overwrite that with whatever (likely
        // nothing) happens to be in the real on-disk store on this machine.
        if !PreviewData.isEnabled { coordinator.restoreFromStore() }
        let bridge = BridgeController(model: model, coordinator: coordinator)
        if PreviewData.isEnabled { PreviewData.seed(into: bridge) }
        _model = State(initialValue: model)
        _coordinator = State(initialValue: coordinator)
        _bridge = State(initialValue: bridge)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, coordinator: coordinator)
                .frame(minWidth: 900, minHeight: 560)
                .environment(bridge)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { ZeroCommands(model: model, coordinator: coordinator) }
    }
}
