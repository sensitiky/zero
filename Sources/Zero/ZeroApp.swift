import SwiftUI
import ZeroCore

@main
struct ZeroApp: App {
    @State private var model = AppModel()
    @State private var coordinator: SessionCoordinator

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _coordinator = State(initialValue: SessionCoordinator(model: model))
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, coordinator: coordinator)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { ZeroCommands(model: model) }
    }
}
