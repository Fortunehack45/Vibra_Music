import Foundation
import SwiftUI

/// The language the UI is shown in.
///
/// iOS normally owns the per-app language (Settings › Vibra Music › Language), and that path
/// keeps working: with no override set, lookups go through the main bundle like any app.
/// Android lets people pick the language inside the app too, so an override is kept in
/// UserDefaults and lookups are redirected to that language's `.lproj` without a relaunch.
enum LanguageBundle {
    /// UserDefaults key holding the chosen localization identifier ("he", "zh-Hans"...); absent = follow the system.
    static let overrideKey = "app_language_override"

    /// Every localization the app ships, in the order the language picker lists them.
    static let supported = ["en", "de", "es", "fr", "he", "hi", "id", "it", "ja", "pl", "pt", "ru", "th", "tr", "vi", "zh-Hans"]

    static var override: String? {
        get { UserDefaults.standard.string(forKey: overrideKey) }
        set {
            if let newValue, supported.contains(newValue) {
                UserDefaults.standard.set(newValue, forKey: overrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: overrideKey)
            }
        }
    }

    /// Bundle that string lookups should use.
    static var current: Bundle {
        guard let code = override,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }

    /// Locale used for number formatting in localized strings.
    static var locale: Locale {
        override.map(Locale.init(identifier:)) ?? .current
    }

    /// Hebrew is the one right-to-left language shipped; SwiftUI mirrors the layout from this.
    static var layoutDirection: LayoutDirection {
        layoutDirection(override: override, preferred: Locale.preferredLanguages)
    }

    /// Judged on the language the strings actually come from (`AppLanguage.current`): a system
    /// language the app doesn't ship, such as Arabic, shows English text and must not mirror it.
    static func layoutDirection(override: String?, preferred: [String]) -> LayoutDirection {
        let code = AppLanguage.current(override: override, preferred: preferred).code
        return Locale.Language(identifier: code).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}
