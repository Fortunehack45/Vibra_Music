import Foundation

// MARK: - Clock (Android: ui/player/LyricClock.kt)

/// Reconciles the frame-driven lyric clock with the player's slower position reports.
///
/// The player is sampled every 500 ms, while lyrics advance once per frame. Comparing a
/// fresh report directly with the already-advanced display clock mistakes delivery delay
/// for a seek and rewinds the words. Instead, compare it with where the previous *report*
/// should have reached in the elapsed wall-clock time. Ordinary polling and main-thread
/// delay stay monotonic; an actual seek is still a large discontinuity and resets at once.
///
/// Create one per track (Android keyed it on the track); between reports, advance the
/// displayed clock from the latest report plus the frame time elapsed since it arrived,
/// never backwards: `displayed = max(displayed, reported + (now - observedAt))`.
///
/// Only while ``isAdvancing``. A player says it is playing well before its clock moves (measured
/// on macOS: 350 to 1,100 ms on a first start, 180 ms after a seek), and carried forward over that
/// wait the lyrics ran ahead of the song by as much, then froze until it caught up.
public struct LyricClockReconciler: Sendable {
    /// Safely above one delayed 500 ms poll, but below a meaningful lyric seek.
    public static let seekDiscontinuityMs = 1_250

    private var lastReportedMs: Int
    private var lastObservedAtMs: Int
    private var wasPlaying: Bool
    /// The reports have moved since the last jump. A player already playing when this starts (lyrics
    /// opened mid-song) counts; one that starts or jumps later has to show it.
    private var hasMoved: Bool

    /// Whether the song is moving between reports, so that time passing means the position does.
    public var isAdvancing: Bool { wasPlaying && hasMoved }

    public init(initialReportedMs: Int, initialObservedAtMs: Int, initialPlaying: Bool) {
        lastReportedMs = initialReportedMs
        lastObservedAtMs = initialObservedAtMs
        wasPlaying = initialPlaying
        hasMoved = initialPlaying
    }

    /// The position the lyrics should show, given what they showed (`displayedMs`) and a new
    /// report from the player observed at `observedAtMs` (a monotonic clock, in ms).
    public mutating func reconcile(displayedMs: Int, reportedMs: Int, observedAtMs: Int, isPlaying: Bool) -> Int {
        let elapsedMs = max(observedAtMs - lastObservedAtMs, 0)
        let expectedMs = lastReportedMs + (isAdvancing ? elapsedMs : 0)
        let jumped = abs(reportedMs - expectedMs) > Self.seekDiscontinuityMs
        // Once playback stops there is no interpolation to protect. Settle on the
        // authoritative position immediately so pausing cannot leave a word ahead.
        let discontinuity = !isPlaying || jumped

        if jumped {
            hasMoved = false
        } else if isPlaying, reportedMs != lastReportedMs {
            hasMoved = true
        }
        lastReportedMs = reportedMs
        lastObservedAtMs = observedAtMs
        wasPlaying = isPlaying

        return discontinuity ? reportedMs : max(displayedMs, reportedMs)
    }
}

// MARK: - Focus (Android: ui/player/LyricFocus.kt, PlayerLyrics.scrollLead)

public enum LyricFocus {
    /// The rows to keep lit at `positionMs`: the latest line whose stamp has passed, plus
    /// every earlier line still being sung — overlapping vocals spanning more than two rows
    /// included. Only lines that state an end (or whose answering vocal does) can overlap;
    /// plain LRC advances without inventing one.
    public static func activeRows(_ lines: [LyricLine], positionMs: Int) -> [Int] {
        guard let latest = lines.lastIndex(where: { $0.timeMs <= positionMs }) else { return [] }
        return (0...latest).filter { index in
            let line = lines[index]
            return index == latest || (!line.isGap
                && (line.hasKnownEnd || line.background?.hasKnownEnd == true)
                && line.timeMs <= positionMs && positionMs < line.endMs)
        }
    }

    /// The line the cursor is on: the last one whose stamp has passed, or nil before the first.
    public static func currentIndex(_ lines: [LyricLine], positionMs: Int) -> Int? {
        lines.lastIndex { $0.timeMs <= positionMs }
    }

    /// How long before a line lands the panel starts moving to it — and how long the move
    /// takes. It is the run-up: the silence between the end of the current line and the next
    /// one's stamp, bounded to 350–500 ms because that silence is a held breath in one song
    /// and half a verse in another.
    public static func scrollLeadMs(_ lines: [LyricLine], positionMs: Int) -> Int {
        // Before the first line's own timestamp there is no current line to measure from.
        guard let current = currentIndex(lines, positionMs: positionMs), let next = lines.kGet(current + 1) else {
            return scrollLeadRange.lowerBound
        }
        return kClamp(next.timeMs - lines[current].endMs, scrollLeadRange.lowerBound, scrollLeadRange.upperBound)
    }

    public static let scrollLeadRange = 350...500
}

// MARK: - Offset (Android: ui/player/LyricsOffsetSheet.kt, PlayerLyrics.adjustedLyrics*)

/// Shifting every synced lyric against the playback clock. Positive values delay the
/// lyrics — +500 ms moves the highlight later — and negative values bring them forward.
public enum LyricsOffset {
    public static let minMs = -5_000
    public static let maxMs = 5_000
    public static var range: ClosedRange<Int> { minMs...maxMs }
    /// What the − and + buttons move by, and what the slider snaps to.
    public static let stepMs = 100

    public static func clamp(_ offsetMs: Int) -> Int { kClamp(offsetMs, minMs, maxMs) }

    /// The lyric clock for a playback position: the offset is subtracted, so a positive
    /// offset shows each line later. Never negative.
    public static func adjustedPosition(positionMs: Int, offsetMs: Int) -> Int {
        max(positionMs - offsetMs, 0)
    }

    /// Where to seek the player so that tapping a line lands on it with the offset applied.
    public static func seekTarget(lineTimeMs: Int, offsetMs: Int) -> Int {
        max(lineTimeMs + offsetMs, 0)
    }

    /// The − button: one step earlier, clamped.
    public static func decreased(_ offsetMs: Int) -> Int { clamp(offsetMs - stepMs) }
    /// The + button: one step later, clamped.
    public static func increased(_ offsetMs: Int) -> Int { clamp(offsetMs + stepMs) }

    public static func canDecrease(_ offsetMs: Int) -> Bool { offsetMs > minMs }
    public static func canIncrease(_ offsetMs: Int) -> Bool { offsetMs < maxMs }

    /// The slider position (0…1) for an offset.
    public static func fraction(forOffset offsetMs: Int) -> Float {
        Float(offsetMs - minMs) / Float(maxMs - minMs)
    }

    /// The offset for a slider position, snapped to `stepMs` (Kotlin's `roundToInt`, which
    /// rounds halves up).
    public static func offset(forFraction fraction: Float) -> Int {
        let raw = Float(minMs) + kClamp(fraction, 0, 1) * Float(maxMs - minMs)
        return Int((raw / Float(stepMs) + 0.5).rounded(.down)) * stepMs
    }

    /// "+0.5 s", "−1.2 s": the sheet's readout, with the sign always shown.
    public static func formatted(_ offsetMs: Int, locale: Locale = .current) -> String {
        String(format: "%+.1f s", locale: locale, Double(Float(offsetMs) / 1_000))
    }
}
