import Foundation

/// Code compiled into the app, the widget extension and the Share Extension.
enum SharedConstants {
    /// App Group shared by the app and its extensions (the now-playing snapshot, the share inbox).
    static let appGroup = "group.com.fortune.vibramusic"

    /// The app's own URL scheme (`CFBundleURLSchemes` in Vibra Music-Info.plist).
    static let urlScheme = "vibramusic"

    /// Opens the full player: the widget's tap target (Android's `PlayerDeepLink.EXTRA_OPEN_PLAYER`).
    static let openPlayerURL = URL(string: "vibramusic://player")!

    /// The class the app registers under this Objective-C name to serve the widget's buttons and
    /// Siri. Looked up at run time because the widget and Share Extension are compiled from the same
    /// Shared sources but don't contain it (see ``SystemIntentBridge``).
    static let intentHandlerClassName = "VibraMusicSystemIntentHandler"
}
