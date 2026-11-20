import SwiftUI
import UIKit

// Ports ui/haptics/Haptics.kt.

/// What a touch *meant*, not what it should feel like (Android's `Haptic`). The shape of each
/// buzz lives here so no screen has to know what the motor can do.
enum Haptic: String, CaseIterable, Hashable {
    /// The lightest beat, for something that repeats under a finger (a drag crossing a boundary).
    case tick
    /// A plain press with no state behind it: More, Download, Menu.
    case tap
    /// A discrete choice landing: a tab, a filter pill, the end of a scrub.
    case select
    /// Switching something on — liking a song is the canonical one (a light lead-in rising into
    /// a firm beat).
    case toggleOn
    /// Switching it back off: the same pair mirrored.
    case toggleOff
    /// Forward through the queue: an accelerating triplet.
    case skipNext
    /// Backward: the triplet reversed.
    case skipPrevious
    /// Playback starting: swells into the beat that lands.
    case resume
    /// Playback stopping: lands first, then releases.
    case pause
    /// Something growing to fill the screen (the mini player opening Now Playing).
    case expand

    /// One beat of a pattern: its feel and its delay after the previous beat.
    struct Beat: Hashable {
        var style: UIImpactFeedbackGenerator.FeedbackStyle
        var intensity: CGFloat
        var delay: TimeInterval
    }

    /// The beats, all under 65 ms end to end as on Android: a haptic that outlasts the finger stops
    /// reading as a response to it.
    var beats: [Beat] {
        switch self {
        case .tick: return [Beat(style: .light, intensity: 0.4, delay: 0)]
        case .tap: return [Beat(style: .light, intensity: 0.8, delay: 0)]
        case .select: return [Beat(style: .medium, intensity: 0.7, delay: 0)]
        case .toggleOn: return [Beat(style: .light, intensity: 0.5, delay: 0), Beat(style: .light, intensity: 1, delay: 0.04)]
        case .toggleOff: return [Beat(style: .light, intensity: 1, delay: 0), Beat(style: .light, intensity: 0.5, delay: 0.04)]
        case .skipNext:
            return [Beat(style: .soft, intensity: 0.5, delay: 0), Beat(style: .soft, intensity: 0.7, delay: 0.03), Beat(style: .rigid, intensity: 0.8, delay: 0.02)]
        case .skipPrevious:
            return [Beat(style: .rigid, intensity: 0.8, delay: 0), Beat(style: .soft, intensity: 0.7, delay: 0.02), Beat(style: .soft, intensity: 0.5, delay: 0.03)]
        case .resume: return [Beat(style: .soft, intensity: 0.5, delay: 0), Beat(style: .medium, intensity: 0.9, delay: 0.04)]
        case .pause: return [Beat(style: .medium, intensity: 0.9, delay: 0), Beat(style: .soft, intensity: 0.4, delay: 0.04)]
        case .expand: return [Beat(style: .soft, intensity: 0.6, delay: 0), Beat(style: .soft, intensity: 0.8, delay: 0.05)]
        }
    }
}

/// Plays ``Haptic`` patterns.
///
/// `UIImpactFeedbackGenerator` is used rather than Core Haptics because it honours the system's
/// "System Haptics" switch by itself — the iOS counterpart of Android reading
/// `HAPTIC_FEEDBACK_ENABLED` — and does nothing on hardware without a Taptic Engine.
@MainActor
final class Haptics {
    static let shared = Haptics()

    /// Every pattern played, most recent last. For tests; capped so it can't grow unbounded.
    private(set) var played: [Haptic] = []
    /// Tests turn the motor off and read ``played``.
    var isMotorEnabled = true

    private var generators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]

    func play(_ haptic: Haptic) {
        played.append(haptic)
        if played.count > 32 { played.removeFirst(played.count - 32) }
        guard isMotorEnabled else { return }
        var at: TimeInterval = 0
        for beat in haptic.beats {
            at += beat.delay
            let generator = generator(for: beat.style)
            if at == 0 {
                generator.impactOccurred(intensity: beat.intensity)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    generator.impactOccurred(intensity: beat.intensity)
                }
            }
        }
    }

    private func generator(for style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let existing = generators[style] { return existing }
        let made = UIImpactFeedbackGenerator(style: style)
        made.prepare()
        generators[style] = made
        return made
    }
}
