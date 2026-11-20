import SwiftUI
import UIKit

// Ports MainActivity.kt's entry point and VibraMusicApplication.kt's process start.

@main
struct VibraMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// UIKit callbacks SwiftUI has no modifier for.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Finished background downloads wake the app here; the download queue takes them over. A wake
    /// that launched the process has no window and so no model yet, which ``SystemAppAccess`` builds.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            guard let model = SystemAppAccess.model() else {
                completionHandler()
                return
            }
            let done = UncheckedSendableBox(completionHandler)
            model.downloads.handleBackgroundEvents(identifier: identifier) { done.value() }
        }
    }
}

/// Carries a non-Sendable closure UIKit hands over across an isolation boundary it doesn't cross.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
