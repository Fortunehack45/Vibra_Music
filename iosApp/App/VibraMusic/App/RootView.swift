import VibraMusicCore
import SwiftUI

/// The window's root: builds the app once and hands it to every view through the environment.
///
/// In the unit-test host no app is built (tests construct what they exercise), so a test run
/// never starts the engine, restores a queue or talks to the network.
struct RootView: View {
    // `AppModel.current` first: a widget button, Siri or CarPlay may have started the app in the
    // background before any window existed (SystemAppAccess), and there must be one app, not two.
    @State private var model: AppModel? = RootView.isUnitTestHost ? nil : (AppModel.current ?? AppModel.live())

    /// XCTest injects its configuration into the host app's environment; UI tests don't (their
    /// runner is a separate process), so they get the real app.
    static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some View {
        if let model {
            AppShell(model: model)
        } else {
            Color(.systemBackground)
        }
    }
}

/// The running app: the tab shell with every environment value it reads, the theme and language,
/// deep links, and the scene lifecycle.
struct AppShell: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootTabView()
            .id(model.languageRevision)
            .environment(model)
            .environment(model.router)
            .environment(model.player)
            .environment(model.settings)
            .environment(model.likeState)
            .environment(model.searchHistory)
            // Theme.kt: System follows the device; Light and Dark force it on every screen,
            // presented sheets included.
            .preferredColorScheme(model.settings.themeMode.colorScheme)
            // The in-app language (LanguageBundle): number formats and right-to-left mirroring.
            .environment(\.locale, LanguageBundle.locale)
            .environment(\.layoutDirection, LanguageBundle.layoutDirection)
            .onOpenURL { url in model.open(url) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { model.open(url) }
            }
            .onChange(of: scenePhase) { _, phase in
                model.scenePhaseChanged(phase)
            }
            .task { model.start() }
    }
}
