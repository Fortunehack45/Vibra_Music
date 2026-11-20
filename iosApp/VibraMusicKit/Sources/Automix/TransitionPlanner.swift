/*
 * Ported from Orchard (https://github.com/SFG5453/Orchard), merging its
 * TransitionPlanner.kt and WsolaPlanner.kt into one file.
 *
 * Copyright (C) 2026 SFG545 (original Orchard implementation)
 * Copyright (C) 2026 Kushagra Singh (Vibra Music adaptation)
 *
 * Orchard's original source is licensed under the GNU Affero General Public
 * License, version 3 or later. Per AGPLv3 section 13, this file is combined
 * here into Vibra Music -- a work licensed under the GNU General Public
 * License, version 3 or later -- and remains itself governed by the AGPLv3
 * as part of that combination.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero
 * General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// Which crossfade behaviour the listener asked for: a fixed-length fade, or Automix.
public enum TransitionPlanMode: String, Sendable, Equatable {
    case standard
    case smart
}

/// The minimal facts about a queue item the planner needs, independent of the player's own item
/// type — kept separate so the planner stays pure and testable. Maps directly from Core's `Song`
/// (videoId, duration, title, artists, album, albumId).
public struct TransitionTrackInfo: Sendable, Equatable {
    public var id: String
    public var durationMs: Int64
    public var title: String
    public var artist: String
    public var album: String
    public var albumId: String

    public init(
        id: String,
        durationMs: Int64,
        title: String = "",
        artist: String = "",
        album: String = "",
        albumId: String = ""
    ) {
        self.id = id
        self.durationMs = durationMs
        self.title = title
        self.artist = artist
        self.album = album
        self.albumId = albumId
    }
}

/// How the renderer should execute a planned transition. ``TransitionAutomation`` turns each
/// style into concrete gain and filter curves.
public enum TransitionStyle: String, Sendable, Equatable, CaseIterable {
    /// A constant-power fade, unfiltered unless two vocals collide. The only style the bottom tier permits.
    case equalPower
    /// Album siblings played through: a near-instant handoff, not a mix.
    case gapless
    /// Beat-aligned blend with a bass swap, for matching or near-matching tempi.
    case djBlend
    /// Filtered handoff for tempi too far apart to blend flat.
    case djFilter
}

/// The planned transition for one pair of tracks, in outgoing-track timeline seconds.
///
/// A plan is produced on every tick; ``shouldStart`` is what says the playhead has actually
/// reached it. ``markerVisible`` is separate because the UI draws the upcoming transition before
/// it begins. When ``blocked`` is true nothing should happen at all and ``reason`` says why.
///
/// Executing it (Playback's job): start the fade at ``transitionStart``, run it for
/// ``fadeSeconds``, cue the incoming track to ``incomingCueTime`` instead of 0, play it at
/// ``incomingPlaybackRate`` (the tempo stretch; 1.0 is none), and ride ``automation`` for the
/// per-deck gains and filter cutoffs against fade progress.
public struct TransitionPlan: Sendable, Equatable {
    public static let defaultHandoffFraction = 0.5
    public static let defaultBedPosition = 0.5

    public var shouldStart: Bool
    public var markerVisible: Bool
    public var blocked: Bool
    public var reason: String
    public var transitionStart: Double
    public var transitionEnd: Double
    public var fadeSeconds: Double
    public var transitionStyle: TransitionStyle
    /// Where in the incoming track playback should be cued to when the transition opens.
    public var incomingCueTime: Double
    /// Where the incoming track's arrangement lands, on its own timeline.
    public var incomingHandoffTime: Double
    /// The tempo stretch applied to the incoming track for the blend. 1.0 is no stretch.
    public var incomingPlaybackRate: Double
    public var handoffStartSeconds: Double
    public var handoffDuration: Double
    public var pickupSeconds: Double
    public var transitionBeats: Int
    public var bassSwap: Bool
    public var handoffFraction: Double
    public var bedPosition: Double
    /// Where in the fade (0...1) the low end changes hands, on a shared-grid beat.
    public var bassSwapFraction: Double
    /// How far the outgoing low-pass ride travels, 0...1. Nonzero means "ride the filter instead
    /// of blending"; a beat-matched blend deliberately asks for none of it.
    public var filterSweep: Double
    /// How strongly the two tracks are expected to be singing over each other through this
    /// overlap, 0...1 — the vocal-clash avoidance input.
    ///
    /// Separate from ``filterSweep`` because it is a property of the *material*, not the style, and
    /// applies whatever the style: two tempo-matched vocals on the same grid is the case a blend
    /// handles worst. Zero whenever either track lacks a vocal mask.
    public var vocalOverlap: Double
    /// The tempi the overlap is built on, which are **not** the analyses' raw BPMs: the incoming
    /// one has been folded into the outgoing one's octave. Zero when the plan is not beat-matched.
    public var outgoingBPM: Double
    public var incomingBPM: Double
    /// Why the policy landed where it did, when it declined to be more ambitious.
    public var policyReasons: [String]

    public init(
        shouldStart: Bool = false,
        markerVisible: Bool = false,
        blocked: Bool = false,
        reason: String = "",
        transitionStart: Double = 0,
        transitionEnd: Double = 0,
        fadeSeconds: Double = 0,
        transitionStyle: TransitionStyle = .equalPower,
        incomingCueTime: Double = 0,
        incomingHandoffTime: Double = 0,
        incomingPlaybackRate: Double = 1,
        handoffStartSeconds: Double = 0,
        handoffDuration: Double = 0,
        pickupSeconds: Double = 0,
        transitionBeats: Int = 0,
        bassSwap: Bool = false,
        handoffFraction: Double = TransitionPlan.defaultHandoffFraction,
        bedPosition: Double = TransitionPlan.defaultBedPosition,
        bassSwapFraction: Double = 0.7,
        filterSweep: Double = 0,
        vocalOverlap: Double = 0,
        outgoingBPM: Double = 0,
        incomingBPM: Double = 0,
        policyReasons: [String] = []
    ) {
        self.shouldStart = shouldStart
        self.markerVisible = markerVisible
        self.blocked = blocked
        self.reason = reason
        self.transitionStart = transitionStart
        self.transitionEnd = transitionEnd
        self.fadeSeconds = fadeSeconds
        self.transitionStyle = transitionStyle
        self.incomingCueTime = incomingCueTime
        self.incomingHandoffTime = incomingHandoffTime
        self.incomingPlaybackRate = incomingPlaybackRate
        self.handoffStartSeconds = handoffStartSeconds
        self.handoffDuration = handoffDuration
        self.pickupSeconds = pickupSeconds
        self.transitionBeats = transitionBeats
        self.bassSwap = bassSwap
        self.handoffFraction = handoffFraction
        self.bedPosition = bedPosition
        self.bassSwapFraction = bassSwapFraction
        self.filterSweep = filterSweep
        self.vocalOverlap = vocalOverlap
        self.outgoingBPM = outgoingBPM
        self.incomingBPM = incomingBPM
        self.policyReasons = policyReasons
    }

    /// Convenience for an engine that schedules in milliseconds.
    public var fadeMs: Int64 { Int64((fadeSeconds * 1000).rounded()) }

    /// Whether executing this does something a plain crossfade could not — a filtering style, an
    /// incoming track cued into its arrangement, or a tempo stretch. What the scrubber's "mixing"
    /// highlight promises; an unanalysed pair cued at 0:00 fading equal-power is not one.
    public var isRealMix: Bool {
        transitionStyle == .djBlend || transitionStyle == .djFilter ||
            incomingCueTime > 0 || incomingPlaybackRate != 1
    }

    /// The span of the outgoing track the transition occupies, as fractions of `durationSeconds`,
    /// for drawing the marker on the scrubber. Nil when there is nothing to draw.
    public func markerWindow(durationSeconds: Double) -> (start: Double, end: Double)? {
        guard !blocked, markerVisible, durationSeconds > 0 else { return nil }
        return (
            (transitionStart / durationSeconds).coerced(0, 1),
            (transitionEnd / durationSeconds).coerced(0, 1)
        )
    }

    /// The gain and filter automation that renders this plan. See ``TransitionAutomation``.
    public var automation: TransitionAutomation { TransitionAutomation(plan: self) }
}

/// The outcome of planning one beat-matched transition.
///
/// ``refused(_:)`` is a routing decision, not an error: the caller falls back to the adaptive
/// overlap, which degrades further on its own.
public enum WsolaPlanResult: Sendable, Equatable {
    case refused(String)
    case planned(WsolaPlan)
}

/// A planned beat-matched phrase switch. All times are seconds on each track's own timeline.
public struct WsolaPlan: Sendable, Equatable {
    public var tier: TransitionTier
    public var beatConfidence: Double
    public var mixOutType: String
    public var vocalClash: Bool
    public var transitionStart: Double
    public var transitionEnd: Double
    public var overlapSeconds: Double
    public var beats: Int
    public var fadeBeats: Int
    public var handoffFraction: Double
    public var bedPosition: Double
    public var bassSwapFraction: Double
    public var filterSweep: Double
    public var outgoingBPM: Double
    public var incomingBPM: Double
    public var stretchRatio: Double
    public var incomingCueTime: Double
    public var incomingDropTime: Double
    public var incomingHandoffTime: Double
    public var incomingResumeTime: Double
}

/// Turns stored analysis into a concrete transition plan for one pair of tracks.
///
/// Nothing here touches PCM; the planner decides *where* a transition happens and *how*
/// ambitious it is. Playback executes the plan (see ``TransitionPlan``).
public enum TransitionPlanner {

    /// Four bars. Overlaps are counted in beats because that is what the ear hears; the seconds
    /// values are rails for tempi where four bars would be absurd. Eight to sixteen beats is the
    /// range the automatic-DJ literature reports for stable dance material, and less for dense pop.
    static let autoTransitionMaxBeats = 16.0
    static let autoMinSeconds = 4.0
    static let autoFastTrackMinSeconds = 6.0
    static let autoTransitionMaxSeconds = 12.0
    static let autoFallbackSeconds = 8.0

    /// Below this a track would spend too much of itself transitioning to be worth planning.
    static let minSmartDurationSeconds = 45.0

    /// Leave enough incoming material after a calibrated handoff to avoid landing in its outro.
    static let minIncomingClearanceSeconds = 5.0

    // The fade is bounded in beats because overlap length is musical: bounding it in seconds makes
    // a faster track get a longer mix, which is backwards. Four bars is the ceiling and one bar
    // the floor, the latter for tracks whose intro cannot cover more.
    static let minFadeBeats = 4
    static let maxFadeBeats = 16

    /// A ceiling on the whole overlap regardless of how long the incoming intro is.
    static let maxOverlapSeconds = 16.0

    /// Moving both decks by the same musical amount preserves the beat grid and overlap length
    /// while putting the incoming arrangement inside the blend instead of making it the finish
    /// line. Applied only to a content-end exit on the outgoing side.
    static let arrangementOverlapBeats = 8

    /// The prior for where the low end hands over, on a pairing with no useful structural change.
    static let defaultBassSwapFraction = 0.7

    /// Analysis may move the swap later than the prior, but never so late the outgoing low end
    /// survives almost to silence.
    static let maxBassSwapFraction = 0.85

    /// A normalized low-band step smaller than this is too weak to move the swap from its prior.
    static let minBassStructureScore = 0.25

    /// Capped in absolute seconds too, so a long overlap does not scale the hold up with it.
    static let bassSwapMaxSeconds = 6.0

    /// How far the outgoing track's low-pass sweep travels by the end of the overlap, as a
    /// fraction of a full ride. 1.0 is the whole way down to ``TransitionAutomation/filterFloorHz``.
    public static let filterSweep = 1.0

    /// The outgoing track must have this much audio before the overlap and the incoming this much after it.
    static let minClearanceSeconds = 5.0

    static let keyIndex: [String: Int] = [
        "C": 0, "C♯": 1, "D♭": 1, "D": 2, "D♯": 3, "E♭": 3,
        "E": 4, "F": 5, "F♯": 6, "G♭": 6, "G": 7, "G♯": 8,
        "A♭": 8, "A": 9, "A♯": 10, "B♭": 10, "B": 11,
    ]

    /// Anything matching this is spoken or already a performance; mixing it is never wanted.
    static let blockedText = try! NSRegularExpression(
        pattern: #"\b(podcast|episode|audiobook|live|concert|performance)\b"#,
        options: [.caseInsensitive]
    )

    // MARK: - Small helpers

    private static func blocked(_ reason: String, transitionStart: Double = 0, transitionEnd: Double = 0) -> TransitionPlan {
        TransitionPlan(blocked: true, reason: reason, transitionStart: transitionStart, transitionEnd: transitionEnd)
    }

    private static func trackDurationSeconds(_ track: TransitionTrackInfo?) -> Double {
        guard let track, track.durationMs > 0 else { return 0 }
        return Double(track.durationMs) / 1000
    }

    private static func itemText(_ track: TransitionTrackInfo?) -> String {
        guard let track else { return "" }
        return [track.title, track.artist, track.album]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
    }

    /// Gapless is for an album being played through, not for any two songs that happen to share
    /// an album. A playlist, a manual queue or a shuffle that lands two album siblings back to back
    /// is a mix, and gets mixed; the caller says which it is via `albumSequential`.
    private static func sameAlbum(_ left: TransitionTrackInfo?, _ right: TransitionTrackInfo?) -> Bool {
        guard let left, let right else { return false }
        if !left.albumId.isBlank && left.albumId == right.albumId { return true }
        return !left.album.isBlank && left.album == right.album && left.artist == right.artist
    }

    /// Folds `nextBPM` into the same octave as `currentBPM` and returns the ratio between them.
    static func normalizedTempoRatio(_ currentBPM: Double, _ nextBPM: Double) -> Double {
        if currentBPM <= 0 || nextBPM <= 0 { return 1 }
        var ratio = nextBPM / currentBPM
        while ratio > 1.5 { ratio /= 2 }
        while ratio < 0.67 { ratio *= 2 }
        return ratio
    }

    private static func splitKey(_ key: String) -> (index: Int?, mode: String?) {
        let parts = key.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
        return (parts.first.flatMap { keyIndex[$0] }, parts.count > 1 ? parts[1] : nil)
    }

    static func keyDistance(_ left: String, _ right: String) -> Int? {
        let (leftIndex, leftMode) = splitKey(left)
        let (rightIndex, rightMode) = splitKey(right)
        guard let leftIndex, let rightIndex else { return nil }
        let pitchDistance = min((leftIndex - rightIndex + 12) % 12, (rightIndex - leftIndex + 12) % 12)
        return pitchDistance + (leftMode != nil && rightMode != nil && leftMode != rightMode ? 1 : 0)
    }

    static func harmonicallyCompatible(_ left: String, _ right: String) -> Bool {
        let (leftIndex, leftMode) = splitKey(left)
        let (rightIndex, rightMode) = splitKey(right)
        guard let leftIndex, let rightIndex else { return false }
        let distance = min((leftIndex - rightIndex + 12) % 12, (rightIndex - leftIndex + 12) % 12)
        if let leftMode, let rightMode, leftMode != rightMode { return distance <= 1 }
        // A fifth is as close as a second here: it is the move every DJ makes.
        return distance <= 2 || distance == 5
    }

    /// A key the analyzer was not confident about is no key at all.
    static func trustedKey(_ analysis: TrackAnalysis) -> String {
        analysis.key.isBlank || analysis.keyConfidence < 0.25 ? "" : analysis.key
    }

    private static func nearestTimedValue(
        _ values: [Double],
        target: Double,
        tolerance: Double = .infinity,
        minimum: Double = 0
    ) -> Double? {
        values.filter { $0.isFinite && $0 >= minimum && abs($0 - target) <= tolerance }
            .min { abs($0 - target) < abs($1 - target) }
    }

    private static func timedValueNearOrBefore(
        _ values: [Double],
        target: Double,
        tolerance: Double = .infinity,
        minimum: Double = 0
    ) -> Double? {
        values.filter { $0.isFinite && $0 >= minimum && $0 <= target && target - $0 <= tolerance }.max()
    }

    private static func beatInterval(of analysis: TrackAnalysis) -> Double {
        let interval = analysis.beatInterval.orZero
        if interval > 0 { return interval }
        return analysis.bpm.orZero > 0 ? 60 / analysis.bpm : 0
    }

    /// Snaps a transition start onto the outgoing track's grid: a phrase boundary if one is near,
    /// a downbeat otherwise, and the raw target when neither is.
    private static func alignedTransitionStart(
        _ analysis: TrackAnalysis,
        target: Double,
        end: Double,
        preferEarlier: Bool,
        minimum: Double
    ) -> Double {
        let interval = beatInterval(of: analysis)
        let phraseTolerance = max(1, interval * 4)
        let downbeatTolerance = max(0.75, interval * 2)
        let phrase = preferEarlier
            ? timedValueNearOrBefore(analysis.phraseBoundaries, target: target, tolerance: phraseTolerance, minimum: minimum)
            : nearestTimedValue(analysis.phraseBoundaries, target: target, tolerance: phraseTolerance, minimum: minimum)
        let downbeat = preferEarlier
            ? timedValueNearOrBefore(analysis.downbeats, target: target, tolerance: downbeatTolerance, minimum: minimum)
            : nearestTimedValue(analysis.downbeats, target: target, tolerance: downbeatTolerance, minimum: minimum)
        return automixClamp(phrase ?? downbeat ?? target, minimum, end)
    }

    /// Where the incoming track's arrangement arrives: the point the outgoing track should be gone by.
    static func incomingCuePoint(_ analysis: TrackAnalysis) -> Double {
        if let best = TransitionPolicy.rankMixInCandidates(analysis).first { return best.time }

        let interval = beatInterval(of: analysis)
        let downbeats = analysis.downbeats

        let analyzedMixIn = analysis.mixInTime
        if analyzedMixIn.isFinite && analyzedMixIn > 0 {
            return nearestTimedValue(downbeats, target: analyzedMixIn, tolerance: max(0.5, interval * 2)) ?? analyzedMixIn
        }

        let pickup = max(
            0,
            analysis.introEndTime.orZero.nonZero
                ?? (analysis.audibleStartTime ?? analysis.pickupTime).orZero.nonZero
                ?? analysis.firstBeat.orZero
        )
        let duration = analysis.duration.orZero.nonZero ?? 300
        if pickup > 0 && pickup < duration - 10, let downbeat = downbeats.first(where: { $0 >= pickup }) {
            return downbeat
        }
        let phrases = analysis.phraseBoundaries
        if phrases.count > 1 && phrases[1] > 4 { return phrases[1] }
        if downbeats.count >= 8 { return downbeats[min(8, downbeats.count - 1)].orZero }
        return pickup
    }

    /// Where the incoming track first makes sound, so the fade is not cued into its lead-in silence.
    private static func incomingStartPoint(_ analysis: TrackAnalysis) -> Double {
        [analysis.audibleStartTime, analysis.pickupTime, analysis.firstBeat]
            .compactMap { $0 }
            .first { $0.isFinite && $0 >= 0 } ?? 0
    }

    // MARK: - Bass swap

    private static func averageLowEnergy(_ curve: [EnergySample], from: Double, until: Double) -> Double? {
        if until <= from { return nil }
        // Lower bound on time, as Kotlin's binarySearchBy lands on for a curve of distinct times.
        var low = 0
        var high = curve.count
        while low < high {
            let mid = (low + high) / 2
            if curve[mid].time < from { low = mid + 1 } else { high = mid }
        }
        var index = low
        var sum = 0.0
        var count = 0
        while index < curve.count && curve[index].time < until {
            let point = curve[index]
            index += 1
            if point.time.isFinite && point.energy.isFinite && point.energy >= 0 {
                sum += point.energy
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    private static func lowEnergyReference(_ curve: [EnergySample]) -> Double? {
        let energies = curve.map(\.energy).filter { $0.isFinite && $0 >= 0 }.sorted()
        guard let last = energies.last else { return nil }
        let upperDecile = energies[Int(Double(energies.count - 1) * 0.9)]
        let reference = max(upperDecile, last * 0.25)
        return reference > 1e-9 ? reference : nil
    }

    private static func lowEnergyResolution(_ curve: [EnergySample]) -> Double {
        guard curve.count > 1 else { return 0 }
        let gaps = zip(curve, curve.dropFirst())
            .map { $1.time - $0.time }
            .filter { $0.isFinite && $0 > 0 }
            .sorted()
        return gaps.isEmpty ? 0 : gaps[gaps.count / 2]
    }

    /// Change in low-band energy across one beat either side of `at`, normalized per track.
    private static func lowEnergyChange(
        _ curve: [EnergySample],
        reference: Double?,
        at: Double,
        windowSeconds: Double
    ) -> Double? {
        guard !curve.isEmpty, let reference, windowSeconds > 0 else { return nil }
        guard let before = averageLowEnergy(curve, from: at - windowSeconds, until: at),
              let after = averageLowEnergy(curve, from: at, until: at + windowSeconds) else { return nil }
        return (after / reference).coerced(0, 1.5) - (before / reference).coerced(0, 1.5)
    }

    /// Chooses one shared-grid beat for the low-end handoff.
    static func bassSwapFraction(
        _ analysis: TrackAnalysis,
        _ nextAnalysis: TrackAnalysis,
        transitionStart: Double,
        incomingCueTime: Double,
        outgoingBeatSeconds: Double,
        incomingBeatSeconds: Double,
        overlapSeconds: Double,
        overlapBeats: Int
    ) -> Double {
        if overlapSeconds <= 0 { return defaultBassSwapFraction }

        let latestFraction = min(maxBassSwapFraction, bassSwapMaxSeconds / overlapSeconds).coerced(0, 1)
        let prior = min(defaultBassSwapFraction, latestFraction)
        if overlapBeats < 2 { return prior }

        let beats = Double(overlapBeats)
        let earliestFraction = min(TransitionPlan.defaultHandoffFraction, latestFraction)
        let earliestBeat = Int((earliestFraction * beats - 1e-9).rounded(.up)).clamped(1, overlapBeats - 1)
        let latestBeat = Int((latestFraction * beats + 1e-9).rounded(.down)).clamped(earliestBeat, overlapBeats - 1)
        let candidates = Array(earliestBeat...latestBeat)
        let fallbackBeat = candidates.min { left, right in
            let leftDistance = abs(Double(left) / beats - prior)
            let rightDistance = abs(Double(right) / beats - prior)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return (left % 4 == 0 ? 0 : 1) < (right % 4 == 0 ? 0 : 1)
        }
        guard let fallbackBeat else { return prior }

        let outgoingReference = lowEnergyReference(analysis.lowEnergyCurve)
        let incomingReference = lowEnergyReference(nextAnalysis.lowEnergyCurve)
        let outgoingWindow = max(outgoingBeatSeconds, lowEnergyResolution(analysis.lowEnergyCurve) * 1.1)
        let incomingWindow = max(incomingBeatSeconds, lowEnergyResolution(nextAnalysis.lowEnergyCurve) * 1.1)

        let scored: [(beat: Int, score: Double)] = candidates.compactMap { beat in
            let outgoingAt = transitionStart + Double(beat) * outgoingBeatSeconds
            let incomingAt = incomingCueTime + Double(beat) * incomingBeatSeconds
            let incomingChange = lowEnergyChange(nextAnalysis.lowEnergyCurve, reference: incomingReference, at: incomingAt, windowSeconds: incomingWindow)
            let outgoingChange = lowEnergyChange(analysis.lowEnergyCurve, reference: outgoingReference, at: outgoingAt, windowSeconds: outgoingWindow)
            if incomingChange == nil && outgoingChange == nil { return nil }
            return (beat, (incomingChange ?? 0) - (outgoingChange ?? 0))
        }
        // Kotlin's maxWithOrNull keeps the first of equal maxima; so does Swift's max(by:).
        let strongest = scored.max { left, right in
            if left.score != right.score { return left.score < right.score }
            let leftBar = left.beat % 4 == 0 ? 1 : 0
            let rightBar = right.beat % 4 == 0 ? 1 : 0
            if leftBar != rightBar { return leftBar < rightBar }
            return -abs(Double(left.beat) / beats - prior) < -abs(Double(right.beat) / beats - prior)
        }

        let chosenBeat = strongest.flatMap { $0.score >= minBassStructureScore ? $0.beat : nil } ?? fallbackBeat
        return Double(chosenBeat) / beats
    }

    /// How vocal the planned overlap is on both sides at once, measured over the windows the plan
    /// actually blends. The incoming window is scaled by the playback rate rather than copied from
    /// the outgoing one, because a stretched track covers more of its own timeline per second.
    /// Answers zero for a degenerate span and for any track without a mask.
    private static func plannedVocalOverlap(
        _ analysis: TrackAnalysis,
        _ nextAnalysis: TrackAnalysis,
        transitionStart: Double,
        transitionEnd: Double,
        incomingCueTime: Double,
        incomingPlaybackRate: Double
    ) -> Double {
        let outgoingSpan = transitionEnd - transitionStart
        if outgoingSpan <= 0 || !outgoingSpan.isFinite { return 0 }
        let rate = incomingPlaybackRate.isFinite && incomingPlaybackRate > 0 ? incomingPlaybackRate : 1
        return TransitionPolicy.simultaneousVocalFraction(
            outgoing: analysis,
            incoming: nextAnalysis,
            outStart: transitionStart,
            outEnd: transitionEnd,
            inStart: incomingCueTime,
            rate: rate
        ) ?? 0
    }

    private static func nearestAtOrBefore(_ values: [Double], target: Double) -> Double? {
        values.filter { $0.isFinite && $0 >= 0 && $0 <= target }.max()
    }

    // MARK: - WSOLA-style beat-matched phrase switch

    /// Where the incoming track takes over: the best-ranked mix-in candidate, snapped to a downbeat.
    public static func incomingMixInPoint(_ analysis: TrackAnalysis) -> Double? {
        let beatSeconds = beatInterval(of: analysis)
        let tolerance = max(0.5, beatSeconds * 2)
        let target = [TransitionPolicy.rankMixInCandidates(analysis).first?.time, analysis.mixInTime]
            .compactMap { $0 }
            .first { $0.isFinite && $0 > 0 }
        guard let target else { return nil }
        return TransitionPolicy.nearestValue(analysis.downbeats, target: target, tolerance: tolerance) ?? target
    }

    /// Plans one beat-matched transition between `analysis` and `nextAnalysis`.
    public static func planWsolaTransition(
        _ analysis: TrackAnalysis,
        _ nextAnalysis: TrackAnalysis,
        duration: Double = 0,
        nextDuration: Double = 0
    ) -> WsolaPlanResult {
        let policy = TransitionPolicy.assessTier(analysis, nextAnalysis)
        if policy.tier != .beatmatched {
            return .refused(policy.reasons.first ?? "policy")
        }

        let outgoingBPM = analysis.bpm.orZero
        let incomingBPM = TransitionPolicy.alignTempoOctave(outgoingBPM: outgoingBPM, incomingBPM: nextAnalysis.bpm.orZero)
        let stretchRatio = outgoingBPM / incomingBPM

        let outgoingLength = max(duration.orZero, analysis.duration.orZero)
        let incomingLength = max(nextDuration.orZero, nextAnalysis.duration.orZero)
        if outgoingLength <= 0 || incomingLength <= 0 { return .refused("missing-duration") }

        let incomingBeatSeconds = 60 / incomingBPM
        let outgoingBeatSeconds = 60 / outgoingBPM

        guard let incomingDropTime = incomingMixInPoint(nextAnalysis),
              incomingDropTime.isFinite, incomingDropTime >= 0 else {
            return .refused("incoming-mix-in")
        }

        let contentEnd = analysis.contentEndTime.orZero.nonZero ?? outgoingLength
        let mixOutAnchor = TransitionPolicy.resolveMixOutAnchor(analysis, contentEnd: contentEnd, duration: outgoingLength)
        let unshiftedOverlapEnd = min(outgoingLength, mixOutAnchor.time)
        let outgoingArrangementOverlap = mixOutAnchor.type == "content_end"
            ? min(Double(arrangementOverlapBeats) * outgoingBeatSeconds, TransitionPolicy.maxDiscardedMusicSeconds)
            : 0
        let overlapEndTarget = max(minClearanceSeconds, unshiftedOverlapEnd - outgoingArrangementOverlap)

        let audibleStart = TransitionPolicy.audibleStart(of: nextAnalysis)
        let availableFadeBeats = max(0, incomingDropTime - audibleStart) / incomingBeatSeconds
        let cappedByOverlap = Int(((maxOverlapSeconds / incomingBeatSeconds).rounded(.down) / 4).rounded(.down)) * 4
        if cappedByOverlap < minFadeBeats { return .refused("overlap-too-long") }
        var fadeBeats = min(maxFadeBeats, cappedByOverlap, Int((availableFadeBeats / 4).rounded(.down)) * 4)
        if fadeBeats < minFadeBeats { fadeBeats = minFadeBeats }

        func clashOver(_ beats: Int) -> Bool {
            let outStart = overlapEndTarget - Double(beats) * outgoingBeatSeconds
            let inStart = max(audibleStart, incomingDropTime - Double(beats) * incomingBeatSeconds)
            let outVocal = TransitionPolicy.vocalActivity(analysis, from: outStart, to: overlapEndTarget)
            let inVocal = TransitionPolicy.vocalActivity(nextAnalysis, from: inStart, to: incomingDropTime)

            // Instant-by-instant first, because it is the question actually being asked. The
            // mean-based test below only fires when *both* windows average vocal across their
            // whole length, which a real clash routinely does not.
            let simultaneous = TransitionPolicy.simultaneousVocalFraction(
                outgoing: analysis,
                incoming: nextAnalysis,
                outStart: outStart,
                outEnd: overlapEndTarget,
                inStart: inStart,
                rate: outgoingBeatSeconds > 0 ? incomingBeatSeconds / outgoingBeatSeconds : 1
            )
            if let simultaneous, simultaneous > TransitionPolicy.vocalClashTolerance { return true }

            if TransitionPolicy.isVocalClash(outVocal, inVocal) { return true }

            if beats > 8, let outVocal, outVocal >= TransitionPolicy.vocalActiveThreshold {
                let deepVocal = TransitionPolicy.vocalActivity(
                    analysis,
                    from: outStart,
                    to: overlapEndTarget - 8 * outgoingBeatSeconds
                )
                if let deepVocal, deepVocal >= TransitionPolicy.vocalActiveThreshold { return true }
            }
            return false
        }
        var fadeVocalClash = clashOver(fadeBeats)
        while fadeVocalClash && fadeBeats > minFadeBeats {
            fadeBeats -= 4
            fadeVocalClash = clashOver(fadeBeats)
        }

        let coverableBeats = Int((max(0, incomingDropTime - audibleStart) / incomingBeatSeconds).rounded(.down))
        let overlapBeats = min(fadeBeats, coverableBeats)
        if overlapBeats < 1 { return .refused("incoming-no-intro") }

        let outgoingOverlapSeconds = Double(overlapBeats) * outgoingBeatSeconds
        let overlapSeconds = Double(overlapBeats) * incomingBeatSeconds

        let requestedIncomingHandoff = incomingDropTime + Double(arrangementOverlapBeats) * incomingBeatSeconds
        let maxIncomingHandoff = incomingLength - minClearanceSeconds
        if maxIncomingHandoff < incomingDropTime { return .refused("incoming-too-short") }
        let incomingHandoffTime = min(requestedIncomingHandoff, maxIncomingHandoff)
        let incomingCueTime = incomingHandoffTime - overlapSeconds
        if incomingCueTime < audibleStart - 0.05 { return .refused("incoming-no-runway") }

        let startTarget = overlapEndTarget - outgoingOverlapSeconds
        // Snapped to a downbeat only within a bar of the target. Android snaps to the latest
        // downbeat before it however far back that is, and downbeats exist only where the beat
        // model ran — the head and tail windows. A track whose tail window yielded no grid then
        // had its phrase switch moved back to the end of the *head* window: measured on a real
        // 6:12 song, a blend at 0:29 that cut five and a half minutes off it, which is exactly
        // what the discarded-music budget exists to forbid. Past a bar, the raw target stands,
        // as it already does when there is no downbeat at all.
        let transitionStart = nearestAtOrBefore(analysis.downbeats, target: startTarget)
            .flatMap { startTarget - $0 <= 4 * outgoingBeatSeconds ? $0 : nil }
            ?? startTarget
        if transitionStart < minClearanceSeconds { return .refused("outgoing-too-short") }
        let transitionEnd = transitionStart + outgoingOverlapSeconds
        if transitionEnd > outgoingLength + 0.05 { return .refused("outgoing-overlap-overruns") }

        let incomingResumeTime = incomingCueTime + overlapSeconds
        if incomingResumeTime + minClearanceSeconds > incomingLength { return .refused("incoming-too-short") }

        return .planned(WsolaPlan(
            tier: policy.tier,
            beatConfidence: policy.beatConfidence,
            mixOutType: mixOutAnchor.type,
            vocalClash: fadeVocalClash,
            transitionStart: transitionStart,
            transitionEnd: transitionEnd,
            overlapSeconds: overlapSeconds,
            beats: overlapBeats,
            fadeBeats: overlapBeats,
            handoffFraction: TransitionPlan.defaultHandoffFraction,
            bedPosition: TransitionPlan.defaultBedPosition,
            bassSwapFraction: bassSwapFraction(
                analysis,
                nextAnalysis,
                transitionStart: transitionStart,
                incomingCueTime: incomingCueTime,
                outgoingBeatSeconds: outgoingBeatSeconds,
                incomingBeatSeconds: incomingBeatSeconds,
                overlapSeconds: overlapSeconds,
                overlapBeats: overlapBeats
            ),
            filterSweep: filterSweep,
            outgoingBPM: outgoingBPM,
            incomingBPM: incomingBPM,
            stretchRatio: stretchRatio,
            incomingCueTime: incomingCueTime,
            incomingDropTime: incomingDropTime,
            incomingHandoffTime: incomingHandoffTime,
            incomingResumeTime: incomingResumeTime
        ))
    }

    /// The most ambitious move available: run the incoming track's instrumental intro underneath
    /// the outgoing one and close on its drop. Nil is a routing decision: the caller falls back to
    /// the adaptive overlap.
    private static func phraseSwitch(
        _ analysis: TrackAnalysis,
        _ nextAnalysis: TrackAnalysis,
        length: Double,
        nextLength: Double
    ) -> TransitionPlan? {
        if !harmonicallyCompatible(trustedKey(analysis), trustedKey(nextAnalysis)) { return nil }

        guard case let .planned(planned) = planWsolaTransition(
            analysis,
            nextAnalysis,
            duration: length,
            nextDuration: nextLength
        ) else { return nil }

        let overlap = planned.transitionEnd - planned.transitionStart
        return TransitionPlan(
            markerVisible: true,
            transitionStart: planned.transitionStart,
            transitionEnd: planned.transitionEnd,
            fadeSeconds: overlap,
            transitionStyle: .djBlend,
            incomingCueTime: planned.incomingCueTime,
            incomingHandoffTime: planned.incomingHandoffTime,
            incomingPlaybackRate: roundedTo4(planned.stretchRatio),
            handoffStartSeconds: 0,
            handoffDuration: overlap,
            pickupSeconds: TransitionPolicy.audibleStart(of: nextAnalysis),
            transitionBeats: planned.beats,
            bassSwap: true,
            handoffFraction: planned.handoffFraction,
            bedPosition: planned.bedPosition,
            bassSwapFraction: planned.bassSwapFraction,
            // Deliberately not `planned.filterSweep`. A phrase switch is the one case where both
            // decks are genuinely on the same grid, and the move there is to hand the low end
            // over on a beat, not to hide the outgoing track behind a filter. The renderer reads
            // a nonzero sweep as "ride the filter instead", so this says zero.
            filterSweep: 0,
            // The separation this style *does* need, and the one it cannot get from alignment:
            // two tracks on a shared grid are the worst case for overlapping voices. The renderer
            // uses this to deepen the entry high-pass and the exit low-pass.
            vocalOverlap: plannedVocalOverlap(
                analysis,
                nextAnalysis,
                transitionStart: planned.transitionStart,
                transitionEnd: planned.transitionEnd,
                incomingCueTime: planned.incomingCueTime,
                incomingPlaybackRate: planned.stretchRatio
            ),
            outgoingBPM: planned.outgoingBPM,
            incomingBPM: planned.incomingBPM
        )
    }

    private struct Overlap {
        var overlap: Double
        var transitionBeats: Int
        var incomingPlaybackRate: Double
    }

    /// How long a mix should run when the tracks are related but not phrase-switchable.
    private static func adaptiveOverlap(_ analysis: TrackAnalysis, _ nextAnalysis: TrackAnalysis) -> Overlap {
        let currentBPM = analysis.bpm.orZero
        let nextBPM = nextAnalysis.bpm.orZero
        if currentBPM <= 0 || nextBPM <= 0 {
            return Overlap(overlap: autoFallbackSeconds, transitionBeats: 0, incomingPlaybackRate: 1)
        }

        let ratio = normalizedTempoRatio(currentBPM, nextBPM)
        let distance = keyDistance(trustedKey(analysis), trustedKey(nextAnalysis))
        let vocalConflict = analysis.vocalProbability >= 0.62 && nextAnalysis.vocalProbability >= 0.62
        let transitionBeats = !vocalConflict && (abs(1 - ratio) > 0.07 || (distance.map { $0 > 4 } ?? false)) ? 16 : 8
        let beatSeconds = 60 / currentBPM
        let minimumOverlap = currentBPM >= 140 ? autoFastTrackMinSeconds : autoMinSeconds

        return Overlap(
            overlap: automixClamp(Double(transitionBeats) * beatSeconds, minimumOverlap, autoTransitionMaxSeconds),
            transitionBeats: transitionBeats,
            incomingPlaybackRate: (0.9...1.1).contains(ratio) ? roundedTo4(automixClamp(1 / ratio, 0.9, 1.1)) : 1
        )
    }

    private static func standardTransition(
        length: Double,
        playbackTime: Double,
        fadeSeconds: Double,
        minFadeSeconds: Double,
        reason: String = "standard"
    ) -> TransitionPlan {
        let fade = automixClamp(fadeSeconds, minFadeSeconds, 12)
        let transitionStart = max(0, length - fade)
        let started = playbackTime >= transitionStart
        return TransitionPlan(
            shouldStart: started,
            markerVisible: true,
            reason: started ? reason : "before-\(reason)-window",
            transitionStart: transitionStart,
            transitionEnd: length,
            fadeSeconds: fade,
            transitionStyle: .equalPower
        )
    }

    /// A stale analysis paired with the wrong track is worse than no analysis at all.
    private static func analysisReady(_ analysis: TrackAnalysis, for track: TransitionTrackInfo?) -> Bool {
        if analysis.status.isBlank { return true }
        if analysis.status != TrackAnalysis.statusReady { return false }
        guard let trackId = track?.id, !trackId.isBlank else { return true }
        return analysis.trackId.isBlank || analysis.trackId == trackId
    }

    private static func roundedTo4(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }

    /// Plans the transition out of `currentTrack` and into `nextTrack`.
    ///
    /// Called on every playback tick; the returned plan describes the transition whether or not it
    /// has started yet.
    ///
    /// - Parameters:
    ///   - albumSequential: true only when this is an album genuinely being played through in
    ///     order, which is the sole case that earns a gapless handoff instead of a mix.
    ///   - currentTime: the outgoing track's playhead, in seconds.
    ///   - fadeSeconds: the fallback fade, used before analysis lands or when the evidence
    ///     supports nothing beyond a plain crossfade.
    public static func plan(
        analysis: TrackAnalysis = TrackAnalysis(),
        nextAnalysis: TrackAnalysis = TrackAnalysis(),
        currentTrack: TransitionTrackInfo? = nil,
        nextTrack: TransitionTrackInfo? = nil,
        currentTime: Double = 0,
        duration: Double = 0,
        fadeSeconds: Double = 6,
        minFadeSeconds: Double = 1,
        mode: TransitionPlanMode = .standard,
        albumSequential: Bool = false
    ) -> TransitionPlan {
        let length = max(duration.orZero, trackDurationSeconds(currentTrack))
        let playbackTime = max(0, currentTime.orZero)
        if length <= 0 { return blocked("no-duration") }

        let standardFade = automixClamp(fadeSeconds, minFadeSeconds, 12)
        if mode != .smart {
            return standardTransition(length: length, playbackTime: playbackTime, fadeSeconds: standardFade, minFadeSeconds: minFadeSeconds)
        }

        if length < minSmartDurationSeconds {
            return blocked("short-duration-guard", transitionStart: length, transitionEnd: length)
        }

        let analyzedContentEnd = analysis.contentEndTime.orZero.nonZero ?? length
        let finalMixAnchor = analyzedContentEnd > 0 && analyzedContentEnd <= length ? analyzedContentEnd : length
        let mixOutAnchor = TransitionPolicy.resolveMixOutAnchor(analysis, contentEnd: finalMixAnchor, duration: length)
        let hasInteriorMixOut = mixOutAnchor.time < finalMixAnchor - 1

        if albumSequential && sameAlbum(currentTrack, nextTrack) && !hasInteriorMixOut {
            let transitionStart = max(0, length - 0.45)
            let started = playbackTime >= transitionStart
            return TransitionPlan(
                shouldStart: started,
                markerVisible: true,
                reason: started ? "same-album-gapless" : "before-gapless-window",
                transitionStart: transitionStart,
                transitionEnd: length,
                fadeSeconds: 0.12,
                transitionStyle: .gapless
            )
        }

        let text = "\(itemText(currentTrack)) \(itemText(nextTrack))"
        if blockedText.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return blocked("blocked-speech-or-live")
        }

        if !analysisReady(analysis, for: currentTrack) || !analysisReady(nextAnalysis, for: nextTrack) {
            return standardTransition(
                length: length,
                playbackTime: playbackTime,
                fadeSeconds: standardFade,
                minFadeSeconds: minFadeSeconds,
                reason: "smart-analysis-fallback"
            )
        }

        let preferredMixAnchor = min(length, mixOutAnchor.time)
        let mixAnchor = playbackTime >= preferredMixAnchor - 0.05 && preferredMixAnchor < finalMixAnchor - 1
            ? finalMixAnchor
            : preferredMixAnchor

        let policy = TransitionPolicy.assessTier(analysis, nextAnalysis)
        if policy.tier == .plainCrossfade {
            let transitionStart = max(0, mixAnchor - standardFade)
            let started = playbackTime >= transitionStart
            return TransitionPlan(
                shouldStart: started,
                markerVisible: true,
                reason: started ? "smart-plain-crossfade" : "before-plain-crossfade-window",
                transitionStart: transitionStart,
                transitionEnd: mixAnchor,
                fadeSeconds: mixAnchor - transitionStart,
                transitionStyle: .equalPower,
                incomingCueTime: incomingStartPoint(nextAnalysis),
                policyReasons: policy.reasons
            )
        }

        let nextLength = max(nextAnalysis.duration.orZero, trackDurationSeconds(nextTrack))

        if var plan = phraseSwitch(analysis, nextAnalysis, length: length, nextLength: nextLength),
           playbackTime < plan.transitionEnd {
            let started = playbackTime >= plan.transitionStart
            plan.shouldStart = started
            plan.policyReasons = policy.reasons
            plan.reason = started ? "smart-phrase-switch" : "before-phrase-switch"
            return plan
        }

        let adaptive = adaptiveOverlap(analysis, nextAnalysis)
        let overlap = adaptive.overlap
        let transitionBeats = adaptive.transitionBeats
        let incomingPlaybackRate = adaptive.incomingPlaybackRate
        let currentBPM = analysis.bpm.orZero
        let nextBPM = nextAnalysis.bpm.orZero
        let handoffBPM = currentBPM > 0 ? currentBPM : nextBPM
        let sameBeatBlend = currentBPM > 0 && nextBPM > 0 &&
            abs(1 - normalizedTempoRatio(currentBPM, nextBPM)) <= 0.05 &&
            (analysis.beatConfidence.orZero >= 0.2 || nextAnalysis.beatConfidence.orZero >= 0.2)
        let outgoingArrangementOverlap = sameBeatBlend && mixOutAnchor.type == "content_end"
            ? min(Double(arrangementOverlapBeats) * 60 / currentBPM, TransitionPolicy.maxDiscardedMusicSeconds)
            : 0
        let mixEnd = max(0, mixAnchor - outgoingArrangementOverlap)
        let maximumOverlap = min(
            handoffBPM > 0 ? (autoTransitionMaxBeats * 60) / handoffBPM : autoTransitionMaxSeconds,
            autoTransitionMaxSeconds,
            mixEnd * 0.4,
            nextLength > 0 ? nextLength * 0.4 : autoTransitionMaxSeconds
        )
        let handoffBeats = sameBeatBlend ? 8.0 : 4.0
        let beatSeconds = handoffBPM > 0 ? 60 / handoffBPM : 0.5
        let handoffSeconds = handoffBPM > 0
            ? automixClamp((handoffBeats * 60) / handoffBPM, 2, sameBeatBlend ? 6 : 5)
            : 4
        let analyzedPickup = nextAnalysis.audibleStartTime ?? nextAnalysis.pickupTime
        let pickupSeconds: Double
        if let analyzedPickup, analyzedPickup.isFinite, analyzedPickup >= 0 {
            pickupSeconds = analyzedPickup
        } else {
            pickupSeconds = 0
        }
        let incomingDropTime = incomingCuePoint(nextAnalysis)
        let alignedIncomingBPM = TransitionPolicy.alignTempoOctave(outgoingBPM: currentBPM, incomingBPM: nextBPM)
        let requestedIncomingHandoff = sameBeatBlend && alignedIncomingBPM > 0
            ? incomingDropTime + Double(arrangementOverlapBeats) * 60 / alignedIncomingBPM
            : incomingDropTime
        let maxIncomingHandoff = nextLength - minIncomingClearanceSeconds
        let incomingHandoffTime = maxIncomingHandoff >= incomingDropTime
            ? min(requestedIncomingHandoff, maxIncomingHandoff)
            : incomingDropTime
        let rawIncomingCueTime = incomingStartPoint(nextAnalysis)
        let analyzedIncomingHandoff = nextAnalysis.mixInTime
        let hasIncomingPreroll = analyzedIncomingHandoff.isFinite && analyzedIncomingHandoff > rawIncomingCueTime + 0.5
        let incomingCueTime = hasIncomingPreroll ? rawIncomingCueTime : incomingHandoffTime
        let introPreroll = max(
            0,
            (hasIncomingPreroll ? incomingHandoffTime - incomingCueTime : 0) / max(0.8, incomingPlaybackRate)
        )

        let finalIncomingCueTime: Double
        let transitionStart: Double

        if sameBeatBlend && beatSeconds > 0 {
            let introDropTime = incomingHandoffTime / max(0.8, incomingPlaybackRate)
            let totalOverlap = automixClamp(introDropTime, min(12, maximumOverlap), maximumOverlap)
            let targetStart = max(0, mixEnd - totalOverlap)
            let earliestTransitionStart = max(0, mixEnd - maximumOverlap)
            transitionStart = alignedTransitionStart(
                analysis,
                target: targetStart,
                end: mixEnd - 0.05,
                preferEarlier: true,
                minimum: earliestTransitionStart
            )
            finalIncomingCueTime = max(0, incomingHandoffTime - (mixEnd - transitionStart) * incomingPlaybackRate)
        } else {
            let desiredOverlap = max(overlap, introPreroll + handoffSeconds * 0.42)
            let actualOverlap = automixClamp(desiredOverlap, min(handoffSeconds, maximumOverlap), maximumOverlap)
            let targetStart = max(0, mixEnd - actualOverlap)
            let earliestTransitionStart = max(0, mixEnd - maximumOverlap)
            transitionStart = alignedTransitionStart(
                analysis,
                target: targetStart,
                end: mixEnd - 0.05,
                preferEarlier: desiredOverlap > overlap + 0.5,
                minimum: earliestTransitionStart
            )
            finalIncomingCueTime = hasIncomingPreroll
                ? max(0, incomingHandoffTime - (mixEnd - transitionStart) * incomingPlaybackRate)
                : incomingCueTime
        }

        let alignedOverlap = mixEnd - transitionStart
        let hasBassContent = !analysis.lowEnergyCurve.isEmpty || !nextAnalysis.lowEnergyCurve.isEmpty
        let started = playbackTime >= transitionStart
        return TransitionPlan(
            shouldStart: started,
            markerVisible: true,
            reason: started ? "smart-duration" : "before-smart-duration",
            transitionStart: transitionStart,
            transitionEnd: mixEnd,
            fadeSeconds: alignedOverlap,
            transitionStyle: sameBeatBlend ? .djBlend : .djFilter,
            incomingCueTime: finalIncomingCueTime,
            incomingHandoffTime: incomingHandoffTime,
            incomingPlaybackRate: incomingPlaybackRate,
            handoffStartSeconds: 0,
            handoffDuration: alignedOverlap,
            pickupSeconds: pickupSeconds,
            transitionBeats: transitionBeats,
            bassSwap: sameBeatBlend || hasBassContent,
            // The two styles are alternatives, not a scale: a matched pair hands the low end over
            // on a beat and otherwise stays open, while an unmatched pair has no shared grid and
            // instead pulls the outgoing track behind a closing low-pass. Zero on the blend branch
            // so the renderer doesn't do both at once.
            filterSweep: sameBeatBlend ? 0 : filterSweep,
            vocalOverlap: plannedVocalOverlap(
                analysis,
                nextAnalysis,
                transitionStart: transitionStart,
                transitionEnd: mixEnd,
                incomingCueTime: finalIncomingCueTime,
                incomingPlaybackRate: incomingPlaybackRate
            ),
            policyReasons: policy.reasons
        )
    }
}

extension String {
    /// Kotlin's `isBlank`: empty or whitespace only.
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}

extension Int {
    /// Kotlin's `coerceIn` for integers.
    func clamped(_ lower: Int, _ upper: Int) -> Int { Swift.max(lower, Swift.min(upper, self)) }
}
