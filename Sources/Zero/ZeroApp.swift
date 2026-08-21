import SwiftUI
import ZeroCore

@main
struct ZeroApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { ZeroCommands(model: model) }
    }
}
