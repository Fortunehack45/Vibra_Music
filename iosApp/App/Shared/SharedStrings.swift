import Foundation

/// The app's strings, for code that also runs in the extensions.
///
/// The string catalog (`Localizable.xcstrings`, keyed by the Android resource names) is compiled
/// into the app bundle only. An extension lives inside the app bundle (`Vibra Music.app/PlugIns/…`),
/// and may read its container's resources, so lookups go to the app bundle from wherever they run
/// rather than shipping a second copy of every translation. In the app this is what `L10n` does.
enum SharedStrings {
    /// The containing app's bundle: `Bundle.main` in the app, two levels up from an `.appex`.
    static var appBundle: Bundle {
        let main = Bundle.main
        guard main.bundleURL.pathExtension == "appex" else { return main }
        let appURL = main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: appURL) ?? main
    }

    /// The in-app language key (`LanguageBundle.overrideKey`). The app keeps it in its own defaults;
    /// the app mirrors it into the App Group under the same key (``WidgetLanguageMirror``) so the
    /// widget, which can't read the app's defaults, speaks the language the app does.
    static let languageOverrideKey = "app_language_override"

    static var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

    /// The in-app language code, or nil to follow the system.
    static var languageOverride: String? {
        let defaults = isExtension ? UserDefaults(suiteName: SharedConstants.appGroup) : UserDefaults.standard
        return defaults?.string(forKey: languageOverrideKey)
    }

    /// The bundle lookups use: the app's in-app language when one is set, else the system's.
    static var bundle: Bundle {
        let app = appBundle
        if let code = languageOverride,
           let path = app.path(forResource: code, ofType: "lproj"),
           let localized = Bundle(path: path) {
            return localized
        }
        return app
    }

    static func tr(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: bundle, value: fallback, comment: "")
    }

    static var widgetNothingPlayed: String { tr("widget_nothing_played", "Nothing played yet") }
    static var widgetPlay: String { tr("widget_play", "Play") }
    static var widgetPause: String { tr("widget_pause", "Pause") }
    static var widgetNext: String { tr("widget_next", "Next") }
    static var widgetPrevious: String { tr("widget_previous", "Previous") }
    static var widgetArtwork: String { tr("widget_artwork", "Album art") }
    static var widgetOpenVibraMusic: String { tr("widget_open_vibramusic", "Open Vibra Music") }
    static var widgetSquareLabel: String { tr("widget_square_label", "Now playing 2×2") }
    static var widgetWideLabel: String { tr("widget_wide_label", "Now playing 4×2") }
    static var widgetPillLabel: String { tr("widget_pill_label", "Now playing 4×1") }
    static var widgetSquareDescription: String { tr("widget_square_description", "Album art with playback controls, in a square.") }
    static var widgetWideDescription: String { tr("widget_wide_description", "Album art with the track and playback controls, full width.") }
    static var widgetPillDescription: String { tr("widget_pill_description", "The track with Like, Shuffle and playback controls, in a single row.") }
    static var widgetPreviewTitle: String { tr("widget_preview_title", "Song title") }
    static var widgetPreviewArtist: String { tr("widget_preview_artist", "Artist") }
    static var like: String { tr("like", "Like") }
    static var removeFromLiked: String { tr("remove_from_liked", "Remove from liked") }
    static var shuffleOn: String { tr("shuffle_on", "Shuffle on") }
    static var shuffleOff: String { tr("shuffle_off", "Shuffle off") }
    static var appName: String { tr("app_name", "Vibra Music") }
}
