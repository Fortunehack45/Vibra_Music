import Foundation
import SwiftUI

/// The app's two colour schemes (`ui/theme/Theme.kt`): black-on-white or
/// white-on-black, Apple Music style, with the greys the untinted screens use.
///
/// Artwork-tinted pages start from these (``ArtworkPalette/untinted(_:)``) and
/// decide whether to derive a dark or light tint from ``isDark``.
public struct ThemeColorScheme: Hashable, Sendable {
    public var primary: ThemeColor
    public var onPrimary: ThemeColor
    public var background: ThemeColor
    public var onBackground: ThemeColor
    public var surface: ThemeColor
    public var onSurface: ThemeColor
    public var surfaceVariant: ThemeColor
    public var onSurfaceVariant: ThemeColor
    public var outline: ThemeColor

    public init(
        primary: ThemeColor,
        onPrimary: ThemeColor,
        background: ThemeColor,
        onBackground: ThemeColor,
        surface: ThemeColor,
        onSurface: ThemeColor,
        surfaceVariant: ThemeColor,
        onSurfaceVariant: ThemeColor,
        outline: ThemeColor
    ) {
        self.primary = primary
        self.onPrimary = onPrimary
        self.background = background
        self.onBackground = onBackground
        self.surface = surface
        self.onSurface = onSurface
        self.surfaceVariant = surfaceVariant
        self.onSurfaceVariant = onSurfaceVariant
        self.outline = outline
    }

    public static let dark = ThemeColorScheme(
        primary: .white,
        onPrimary: .black,
        background: .black,
        onBackground: .white,
        surface: ThemeColor(argb: 0xFF0D_0D0F),
        onSurface: .white,
        surfaceVariant: ThemeColor(argb: 0xFF1C_1C1E),
        onSurfaceVariant: ThemeColor(argb: 0xFF8E_8E93),
        outline: ThemeColor(argb: 0xFF2C_2C2E)
    )

    public static let light = ThemeColorScheme(
        primary: .black,
        onPrimary: .white,
        background: .white,
        onBackground: .black,
        surface: ThemeColor(argb: 0xFFF7_F7F9),
        onSurface: .black,
        surfaceVariant: ThemeColor(argb: 0xFFF2_F2F7),
        onSurfaceVariant: ThemeColor(argb: 0xFF6E_6E73),
        outline: ThemeColor(argb: 0xFFE5_E5EA)
    )

    public static func forDarkTheme(_ dark: Bool) -> ThemeColorScheme {
        dark ? .dark : .light
    }

    /// Whether this scheme is a dark one, told the way the artwork tint tells it
    /// on Android: the background's perceived luminance below one half.
    public var isDark: Bool {
        background.luminance < 0.5
    }

    /// The SwiftUI colour scheme this corresponds to.
    public var colorScheme: ColorScheme {
        isDark ? .dark : .light
    }

    /// Apple Music's signature red. No longer the primary accent, but kept for
    /// the spots (Replay's rank badge) that want that specific red regardless of theme.
    public static let accentRed = ThemeColor(argb: 0xFFFA_2D48)
}

/// The Theme setting: follow the system, or force light or dark.
///
/// Raw values are the names Android persists (`ThemeMode.valueOf`), so a
/// migrated or restored setting maps across unchanged. Android's default is dark.
public enum ThemeAppearance: String, CaseIterable, Hashable, Sendable {
    case system = "SYSTEM"
    case light = "LIGHT"
    case dark = "DARK"

    public static let defaultValue: ThemeAppearance = .dark

    /// Whether the app draws dark, given what the system is doing.
    public func isDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: systemIsDark
        case .light: false
        case .dark: true
        }
    }

    /// For `.preferredColorScheme(_:)`: nil follows the system.
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The type scale (`VibraMusicTypography`): heavy and tight, the backbone of the
/// Apple Music look.
///
/// Android bundles SF Pro Display to get this; on iOS it is simply the system
/// font, so each style carries only size, weight and tracking (points â‰ˆ sp).
public struct ThemeTextStyle: Hashable, Sendable {
    public var size: CGFloat
    public var weight: Font.Weight
    /// Letter spacing in points; negative tightens.
    public var tracking: CGFloat

    public init(size: CGFloat, weight: Font.Weight, tracking: CGFloat = 0) {
        self.size = size
        self.weight = weight
        self.tracking = tracking
    }

    public var font: Font {
        .system(size: size, weight: weight)
    }

    public static let displayLarge = ThemeTextStyle(size: 34, weight: .heavy, tracking: -0.8)
    public static let headlineLarge = ThemeTextStyle(size: 30, weight: .heavy, tracking: -0.7)
    public static let headlineMedium = ThemeTextStyle(size: 22, weight: .bold, tracking: -0.4)
    public static let titleLarge = ThemeTextStyle(size: 20, weight: .bold, tracking: -0.3)
    public static let titleMedium = ThemeTextStyle(size: 16, weight: .semibold, tracking: -0.2)
    public static let bodyLarge = ThemeTextStyle(size: 16, weight: .regular)
    public static let bodyMedium = ThemeTextStyle(size: 14, weight: .regular)
    public static let labelMedium = ThemeTextStyle(size: 12, weight: .semibold)
    public static let labelSmall = ThemeTextStyle(size: 11, weight: .semibold)
}
