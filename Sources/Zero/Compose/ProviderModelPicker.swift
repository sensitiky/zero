import SwiftUI
import ZeroCore

/// One control, two levels: providers, and inside each one its models.
///
/// Nested rather than two separate pickers because the model list depends on the provider — two flat
/// pickers let you select a pair that cannot exist.
struct ProviderModelPicker: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: SessionCoordinator
    @ScaledMetric(relativeTo: .body) private var modelFieldWidth: CGFloat = 180

    var body: some View {
        Menu {
            ForEach(coordinator.availableProviders, id: \.descriptor.id) { entry in
                let available = coordinator.isAvailable(entry.descriptor.id)
                if entry.descriptor.knownModels.isEmpty {
                    // No verified model ids for this provider, so there is nothing honest to list.
                    Button(entry.descriptor.displayName) {
                        model.draftProvider = entry.descriptor.id
                        model.draftModel = ""
                    }
                    .disabled(!available)
                } else {
                    Menu(entry.descriptor.displayName) {
                        ForEach(entry.descriptor.knownModels, id: \.self) { name in
                            Button(name) {
                                model.draftProvider = entry.descriptor.id
                                model.draftModel = name
                            }
                        }
                    }
                    .disabled(!available)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                Text(label)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Agent and model: \(label)")

        if coordinator.descriptor(for: model.draftProvider)?.knownModels.isEmpty == true {
            // Free text where the ids are not known first-hand, rather than a menu of guesses.
            TextField("Model", text: $model.draftModel)
                .textFieldStyle(.roundedBorder)
                .frame(width: modelFieldWidth)
                .accessibilityLabel("Model name")
        }
    }

    private var label: String {
        let provider = coordinator.descriptor(for: model.draftProvider)?.displayName ?? model.draftProvider
        return model.draftModel.isEmpty ? provider : "\(provider) · \(model.draftModel)"
    }
}
