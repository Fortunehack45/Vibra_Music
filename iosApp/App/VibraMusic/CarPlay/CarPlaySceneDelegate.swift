import CarPlay
import UIKit

/// CarPlay entry point named in Info.plist's scene manifest (ports Android Auto's
/// MediaLibraryService connection in PlaybackService.kt).
///
/// A CarPlay audio app needs Apple's `com.apple.developer.carplay-audio` entitlement, requested at
/// developer.apple.com/contact/carplay; without it the scene never connects on a real car or the
/// CarPlay simulator. Nothing else changes when it is granted: add the key to Vibra Music.entitlements.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        MainActor.assumeIsolated {
            // The car can be what launched the app, with no phone window yet; SystemAppAccess
            // starts the app then, restoring the queue as a normal launch would.
            guard let model = SystemAppAccess.model() else { return }
            let coordinator = CarPlayCoordinator(library: CarLibrary(source: LiveCarLibrarySource(model: model)), player: model.player)
            self.coordinator = coordinator
            coordinator.connect(interfaceController)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        MainActor.assumeIsolated {
            coordinator?.disconnect()
            coordinator = nil
        }
    }
}
