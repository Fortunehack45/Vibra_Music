import Foundation
import SwiftUI

/// Keeping the status bar legible over artwork, and deciding which glyph colour
/// every other surface uses.
///
/// Media-player convention: the full player always owns *light* status glyphs.
/// Rather than flipping the glyph colour per cover (which flickers through
/// artwork transitions), a black scrim is laid under the status bar whose
/// opacity follows how bright the top of the sleeve actually is.
public enum StatusBarContrast {
    // MARK: Luminance

    /// WCAG relative luminance of one packed ARGB pixel, in linear light.
    public static func relativeLuminance(argb: UInt32) -> Double {
        func linear(_ channel: Int) -> Double {
            let srgb = Double(Float(channel) / 255)
            return srgb <= 0.040_45 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(redOf(argb)) + 0.7152 * linear(greenOf(argb)) + 0.0722 * linear(blueOf(argb))
    }

    /// WCAG relative luminance averaged in linear light, never over gamma-encoded
    /// RGB — half black and half white is a mid grey (0.5) here, not the much
    /// darker sRGB midpoint. Zero for no pixels.
    public static func averageRelativeLuminance<Pixels: Collection>(_ pixels: Pixels) -> Double where Pixels.Element == UInt32 {
        guard !pixels.isEmpty else { return 0 }
        var sum = 0.0
        for pixel in pixels {
            sum += relativeLuminance(argb: pixel)
        }
        return sum / Double(pixels.count)
    }

    // MARK: Player scrim

    public static let minimumScrimAlpha = 0.16
    public static let maximumScrimAlpha = 0.65
    /// A modest floor while a player subview (lyrics, queue, output picker…)
    /// replaces the hero artwork with its artwork-derived backdrop.
    public static let subviewScrimMinimumAlpha = 0.40
    /// How many colour stops the top scrim gradient is drawn with.
    public static let scrimGradientSteps = 8

    /// Maps top-band artwork luminance to scrim opacity: subtle over a dark
    /// cover, strong enough over a light one to keep white glyphs legible.
    ///
    /// Out-of-range luminance is clamped, not extrapolated — a value above 1 is a
    /// rounding artefact, not a reason to darken past the ceiling. No luminance
    /// yet (artwork still loading) gets the subtle base.
    public static func topBandScrimAlpha(artworkLuminance: Double?) -> Double {
        let luminance = constrain(artworkLuminance ?? 0, 0, 1)
        return minimumScrimAlpha + (maximumScrimAlpha - minimumScrimAlpha) * luminance
    }

    /// The opacity of the player's top scrim, with the subview floor applied.
    public static func playerTopScrimAlpha(artworkLuminance: Double?, subviewOpen: Bool) -> Double {
        let alpha = topBandScrimAlpha(artworkLuminance: artworkLuminance)
        return subviewOpen ? max(alpha, subviewScrimMinimumAlpha) : alpha
    }

    /// The top scrim as evenly spaced stops, black fading with a `(1 - p)^1.5`
    /// falloff so it is densest right under the glyphs and gone by its foot.
    /// The view sizes it to the status-bar inset plus the player's top strip.
    public static func playerTopScrimStops(alpha: Double, steps: Int = scrimGradientSteps) -> [ThemeGradientStop] {
        let count = max(steps, 2)
        return (0..<count).map { index in
            let progress = Double(index) / Double(count - 1)
            let factor = Double(Float(pow(Double(1 - Float(progress)), 1.5)))
            return ThemeGradientStop(location: progress, color: ThemeColor.black.withAlpha(alpha * factor))
        }
    }

    // MARK: Glyph colour

    /// Which glyphs the status bar should draw for the app's current surface.
    ///
    /// Deciding this from the *system* appearance is the wrong input the moment
    /// the in-app theme disagrees with it: Light theme on a phone in dark mode
    /// left white icons on a white bar, invisible. The bar follows what the app
    /// is actually painting. The player owns light glyphs and paints its own
    /// contrast; Replay's page and stories are dark artwork either way.
    public static func glyphs(
        darkTheme: Bool,
        nowPlayingShown: Bool,
        replayShown: Bool,
        replayStoryShown: Bool
    ) -> StatusBarGlyphs {
        !darkTheme && !nowPlayingShown && !replayShown && !replayStoryShown ? .dark : .light
    }

    /// The full player's glyphs, regardless of cover — contrast comes from the scrim.
    public static let playerGlyphs: StatusBarGlyphs = .light
}

/// The colour of the status bar's glyphs.
///
/// Android's "light status bars" flag means *dark* glyphs (for a light bar);
/// this names the glyphs themselves to avoid that inversion.
public enum StatusBarGlyphs: Hashable, Sendable {
    /// Dark glyphs, for light content (UIKit `.darkContent`).
    case dark
    /// Light glyphs, for dark content (UIKit `.lightContent`).
    case light

    /// The colour scheme to hand SwiftUI (`.toolbarColorScheme(_:for:)` /
    /// `.preferredColorScheme`) so it draws these glyphs.
    public var colorScheme: ColorScheme {
        switch self {
        case .dark: .light
        case .light: .dark
        }
    }
}
