import Foundation

/// The running app, for entry points SwiftUI doesn't reach: the widget's buttons, Siri, CarPlay and
/// a share handed over while the app was closed.
///
/// Any of those can be what launches the process, in the background with no window (Android's
/// widget binding the playback service after process death). Then there is no `AppModel` yet, so
/// one is built and started here — restoring last session's queue, which is what gives a widget's
/// play button something to resume. `AppModel.live()` registers itself as `AppModel.current`, and
/// the window, when it opens, uses that same instance (RootView).
@MainActor
enum SystemAppAccess {
    /// Tests put their own app here; nothing is ever built in the unit-test host otherwise.
    static var override: AppModel?

    static func model() -> AppModel? {
        if let override { return override }
        if let current = AppModel.current { return current }
        guard !RootView.isUnitTestHost else { return nil }
        let model = AppModel.live()
        model.start()
        return model
    }
}
