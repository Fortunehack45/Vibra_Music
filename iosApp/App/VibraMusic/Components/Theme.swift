import VibraMusicCore
import SwiftUI

// Ports ui/theme/Theme.kt. Android shipped SF Pro Display and hand-picked colours to look like
// Apple Music; on iOS the system font and semantic colours are that look already, so the palette
// only names the few values the app draws that iOS has no semantic colour for.

enum AppTheme {
    /// Apple Music's red, kept for the spots that want it whatever the theme (Replay's rank badge).
    static let accentRed = Color(red: 0xFA / 255, green: 0x2D / 255, blue: 0x48 / 255)

    /// The page gutter every shelf and row lines up on (Android's `PAGE_GUTTER`).
    static let gutter: CGFloat = 16
    /// Thumbnail corner shared by rows, the mini player and cards (Android's 8 dp).
    static let artCorner: CGFloat = 8
    /// The floating bars never run wider than this on an iPad or in landscape
    /// (Android's `FLOATING_BAR_MAX_WIDTH`).
    static let floatingBarMaxWidth: CGFloat = 640

    /// Heavy, tight typography — the backbone of the Apple Music look (Theme.kt's type scale).
    enum Typeface {
        static let display = Font.system(size: 34, weight: .heavy)
        static let headlineLarge = Font.system(size: 30, weight: .heavy)
        static let headline = Font.system(size: 22, weight: .bold)
        static let titleLarge = Font.system(size: 20, weight: .bold)
        static let title = Font.system(size: 16, weight: .semibold)
        static let body = Font.system(size: 16)
        static let bodySmall = Font.system(size: 14)
        static let label = Font.system(size: 12, weight: .semibold)
        static let labelSmall = Font.system(size: 11, weight: .semibold)
    }
}

extension ThemeMode {
    /// The colour scheme to force on the window: nil follows the system (Android's
    /// `isSystemInDarkTheme()` under `ThemeMode.SYSTEM`).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The UIKit style the same choice maps onto, for windows SwiftUI doesn't own (the sign-in
    /// web view, share sheets).
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}
