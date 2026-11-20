/*
 * Ported from Orchard (https://github.com/SFG5453/Orchard).
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

/// The confidence-aware transition policy.
///
/// Analysis happens ahead of playback (see ``TrackAnalyzer``), and the runtime only decides how
/// ambitious a transition the stored evidence can support. Ambition degrades in explicit tiers as
/// certainty falls (see ``TransitionTier``) rather than letting one engine quietly do beat math on
/// junk data.
///
/// Every judgement here is made from stored analysis fields and their confidences; nothing in
/// this file touches PCM. A caseless enum rather than free functions so the app, which imports
/// every module, does not collect a dozen generic top-level names.
public enum TransitionPolicy {

    /// Below this the analyzer's beat grid is treated as a guess, and no renderer may stretch or
    /// phase-align against it. Catalog tempo lookups merge in with `beatConfidence` 0, so a
    /// metadata BPM alone can never authorize beat-matching.
    public static let minBeatmatchConfidence = 0.55

    /// Below this on both tracks, even the DJ-assisted crossfade (beat-quantized anchors, EQ
    /// handoff) is off the table and the mix degrades to a plain fade.
    public static let minDJConfidence = 0.2

    /// One octave either side of a typical dance tempo; outside this the analysis is noise.
    public static let minBPM = 40.0
    public static let maxBPM = 220.0

    /// How far a tempo pairing may drift from unity and still be considered transparent to stretch.
    public static let maxStretchDeviation = 0.04

    /// A vocal-activity mask value at or above this counts as singing. A fallback analyzer that
    /// emits a flat 0.5 mask never trips vocal logic; only a real mask can.
    public static let vocalActiveThreshold = 0.6

    /// How much of the outgoing track's remaining *music* a transition may skip by ending before
    /// its content does. A transition is allowed to leave a short tail unplayed; it is not allowed
    /// to cut the song short.
    public static let maxDiscardedMusicSeconds = 12.0

    /// How much simultaneous vocal a transition may carry before it counts as a clash worth
    /// reshaping the overlap for.
    ///
    /// Not zero. A mask is a model's estimate sampled on a coarse grid, and both edges of a vocal
    /// phrase are soft, so demanding literal zero would refuse overlaps that sound clean and spend
    /// the fade budget chasing a rounding error. A twentieth of the window is roughly one
    /// energy-curve sample either side of a boundary.
    public static let vocalClashTolerance = 0.05

    /// Fraction of a track's own loud-end reference below which a sample counts as silence rather
    /// than music, so a genuine gap costs nothing against the budget.
    static let audibleEnergyFraction = 0.1

    /// How much each candidate type is trusted as an entry point before scoring. Drops are where
    /// an arrangement arrives, so they dominate; a pickup is just "the file starts making sound"
    /// and a phrase boundary is only a grid line.
    static let mixInTypeWeight: [String: Double] = [
        "main_drop": 0.5,
        "intro_drop": 0.4,
        "pickup": 0.15,
        "phrase": 0.1,
    ]

    /// Mirrors the analyzer's own scoring of mix-out candidates, used when an analysis carries the
    /// scalar fields but not the candidate list.
    static let mixOutTypeScore: [String: Double] = [
        "energy_cliff": 0.95,
        "interior_mix_out": 0.95,
        "outro_start": 0.9,
        "content_end": 0.75,
    ]

    /// Halves or doubles `incomingBPM` until it is as close as possible to `outgoingBPM`, the way a
    /// DJ counts a 63 BPM track against a 126 BPM one.
    public static func alignTempoOctave(outgoingBPM: Double, incomingBPM: Double) -> Double {
        if outgoingBPM <= 0 || incomingBPM <= 0 { return incomingBPM }
        var aligned = incomingBPM
        while aligned / outgoingBPM > 1.5 { aligned /= 2 }
        while aligned / outgoingBPM < 0.67 { aligned *= 2 }
        return aligned
    }

    /// Mean vocal activity over `start...end` on a track's own timeline, or nil when the analysis
    /// carries no usable mask there. The mask is indexed against ``TrackAnalysis/energyCurve`` times.
    public static func vocalActivity(_ analysis: TrackAnalysis, from start: Double, to end: Double) -> Double? {
        let mask = analysis.vocalActivityMask
        let curve = analysis.energyCurve
        if mask.isEmpty || mask.count != curve.count || end <= start { return nil }
        var sum = 0.0
        var count = 0
        for index in mask.indices {
            let time = curve[index].time
            if !time.isFinite || time < start || time > end { continue }
            let value = mask[index]
            if !value.isFinite { continue }
            sum += value
            count += 1
        }
        return count > 0 ? sum / Double(count) : nil
    }

    /// Both windows measurably singing at once. Nil means "no evidence", which never blocks;
    /// absence of a mask is not absence of a vocal, but acting on it would punish every track a
    /// fallback analyzer handled.
    public static func isVocalClash(_ outgoingActivity: Double?, _ incomingActivity: Double?) -> Bool {
        guard let outgoing = outgoingActivity, let incoming = incomingActivity else { return false }
        return outgoing >= vocalActiveThreshold && incoming >= vocalActiveThreshold
    }

    /// How strongly two windows sing over each other: 0 for nothing worth acting on, 1 for two
    /// fully vocal passages landing on one another.
    ///
    /// ``isVocalClash(_:_:)``'s graded counterpart. A boolean is the right shape for a routing
    /// decision, the wrong shape for the renderer, which has to decide *how hard* to pull the two
    /// voices apart. Governed by the quieter of the two, because a clash needs both sides. Nil on
    /// either side is no evidence and answers zero.
    public static func vocalOverlapAmount(_ outgoingActivity: Double?, _ incomingActivity: Double?) -> Double {
        guard let outgoing = outgoingActivity, let incoming = incomingActivity else { return 0 }
        let both = min(outgoing, incoming)
        if both <= vocalActiveThreshold { return 0 }
        return ((both - vocalActiveThreshold) / (1.0 - vocalActiveThreshold)).coerced(0, 1)
    }

    /// The fraction of a planned overlap where **both** tracks are singing at the same instant,
    /// or nil when either side has no mask.
    ///
    /// A mean over the window is the wrong statistic for a clash: twelve seconds holding three of
    /// vocal and nine of instrumental averages well under the threshold while the listener plainly
    /// hears two voices for those three seconds. So this goes instant by instant. The outgoing
    /// track's own energy-curve samples are the clock; each is mapped onto the incoming timeline
    /// through `rate`, because a stretched incoming track covers proportionally more of its own
    /// timeline in the same wall-clock second. Unmeasured regions sit at the analyzer's neutral
    /// 0.5, below the threshold, so they count as "not singing" rather than as evidence.
    ///
    /// Both curves are time-ascending, so the incoming index only ever moves forward.
    public static func simultaneousVocalFraction(
        outgoing: TrackAnalysis,
        incoming: TrackAnalysis,
        outStart: Double,
        outEnd: Double,
        inStart: Double,
        rate: Double
    ) -> Double? {
        let outMask = outgoing.vocalActivityMask
        let outCurve = outgoing.energyCurve
        let inMask = incoming.vocalActivityMask
        let inCurve = incoming.energyCurve
        if outMask.isEmpty || outMask.count != outCurve.count { return nil }
        if inMask.isEmpty || inMask.count != inCurve.count { return nil }
        if outEnd <= outStart { return nil }
        let step = rate.isFinite && rate > 0 ? rate : 1.0

        var inIndex = 0
        var both = 0
        var total = 0
        for index in outMask.indices {
            let time = outCurve[index].time
            if !time.isFinite || time < outStart { continue }
            if time > outEnd { break }
            total += 1
            if outMask[index] < vocalActiveThreshold { continue }
            let target = inStart + (time - outStart) * step
            while inIndex + 1 < inCurve.count && inCurve[inIndex + 1].time <= target { inIndex += 1 }
            if inMask[inIndex] >= vocalActiveThreshold { both += 1 }
        }
        return total > 0 ? Double(both) / Double(total) : nil
    }

    /// Seconds of audible music in `start...end` on a track's own timeline, judged against the
    /// track's own loud-end reference so the measure is independent of how the analyzer scales
    /// energy. Returns nil when there is no usable curve.
    public static func audibleSeconds(_ analysis: TrackAnalysis, from start: Double, to end: Double) -> Double? {
        let curve = analysis.energyCurve
        if curve.count < 2 || end <= start { return nil }
        let energies = curve.map(\.energy).filter { $0.isFinite && $0 >= 0 }.sorted()
        if energies.isEmpty { return nil }
        let reference = energies[Int((Double(energies.count - 1) * 0.85).rounded(.down))].orZero
        if reference <= 0 { return 0 }
        let threshold = reference * audibleEnergyFraction
        guard let first = curve.first?.time, let last = curve.last?.time,
              first.isFinite, last.isFinite, last > first else { return nil }
        let sampleSeconds = (last - first) / Double(curve.count - 1)
        var audible = 0.0
        for point in curve {
            if !point.time.isFinite || point.time < start || point.time > end { continue }
            if point.energy >= threshold { audible += sampleSeconds }
        }
        return audible
    }

    /// The earliest point the analysis claims the track makes sound.
    ///
    /// ``TrackAnalysis/firstBeat`` is not optional the way the other two are, and the analyzer uses
    /// 0.0 as its "nothing was measured" fallback. Counting that zero as a real audible start pins
    /// this to 0 for any track without a beat grid, which silently overrides a measured
    /// `audibleStartTime` and tells the planner the whole head of the track is intro it can fade
    /// across.
    public static func audibleStart(of analysis: TrackAnalysis) -> Double {
        let firstBeat: Double? = analysis.firstBeat.isFinite && analysis.firstBeat > 0 ? analysis.firstBeat : nil
        let candidates = [analysis.audibleStartTime, analysis.pickupTime, firstBeat]
            .compactMap { $0 }
            .filter { $0.isFinite && $0 >= 0 }
        return candidates.min() ?? 0
    }

    /// The value in `values` closest to `target` within `tolerance`, or nil when none qualifies.
    static func nearestValue(_ values: [Double], target: Double, tolerance: Double) -> Double? {
        values.filter { $0.isFinite && abs($0 - target) <= tolerance }
            .min { abs($0 - target) < abs($1 - target) }
    }

    /// Ranks a track's analyzed mix-in candidates as entry points for a transition, best first.
    ///
    /// Selection is a scoring problem, not a type lookup: the analyzer's own score, the candidate
    /// type, downbeat alignment, whether there is any intro before the point to bed under the
    /// outgoing track, and how vocal that intro is all move a candidate up or down.
    public static func rankMixInCandidates(_ analysis: TrackAnalysis) -> [RankedMixCandidate] {
        let candidates = analysis.mixInCandidates.filter { $0.time.isFinite && $0.time >= 0 }
        if candidates.isEmpty { return [] }
        let beatSeconds: Double = {
            let interval = analysis.beatInterval.orZero
            if interval > 0 { return interval }
            return analysis.bpm.orZero > 0 ? 60 / analysis.bpm : 0.5
        }()
        let audibleStart = audibleStart(of: analysis)
        let ranked = candidates.map { candidate -> RankedMixCandidate in
            var rankScore = candidate.score.orZero + (mixInTypeWeight[candidate.type] ?? 0)
            if nearestValue(analysis.downbeats, target: candidate.time, tolerance: beatSeconds / 2) != nil {
                rankScore += 0.1
            }
            // A cold open: nothing before the point to play underneath the outgoing track, so
            // entering here means starting the blend on the arrangement.
            if candidate.time - audibleStart < beatSeconds * 4 { rankScore -= 0.2 }
            // Prefer entries whose run-up is instrumental; an intro that already sings will sing
            // over the outgoing track for the whole pre-roll.
            if let vocal = vocalActivity(
                analysis,
                from: max(audibleStart, candidate.time - beatSeconds * 16),
                to: candidate.time
            ) {
                rankScore += (0.5 - vocal) * 0.4
            }
            return RankedMixCandidate(
                time: candidate.time,
                score: candidate.score.orZero,
                type: candidate.type,
                rankScore: rankScore
            )
        }
        return ranked.stableSorted { $0.rankScore > $1.rankScore }
    }

    /// Falls back to the scalar mix-out fields when the analysis carries no candidate list.
    static func mixOutCandidates(of analysis: TrackAnalysis, contentEnd: Double) -> [MixCandidate] {
        let supplied = analysis.mixOutCandidates.filter { $0.time.isFinite && $0.time > 0 }
        var candidates = supplied.map { MixCandidate(time: $0.time, score: $0.score.orZero, type: $0.type) }
        if supplied.isEmpty {
            let mixOut = analysis.mixOutTime.orZero
            let outroStart = analysis.outroStartTime.orZero
            if mixOut > 0 && mixOut < contentEnd - 1 {
                candidates.append(MixCandidate(time: mixOut, score: 0.95, type: "energy_cliff"))
            }
            if outroStart > 0 && outroStart < contentEnd - 1 {
                candidates.append(MixCandidate(time: outroStart, score: 0.9, type: "outro_start"))
            }
        }
        // Vocals describe how the overlap should be shaped, not where the outgoing song stops.
        // Only structural and energy candidates choose the exit. The transition always has
        // somewhere to end: where the content does.
        if !candidates.contains(where: { abs($0.time - contentEnd) < 0.05 }) {
            candidates.append(MixCandidate(time: contentEnd, score: 0.75, type: "content_end"))
        }
        return candidates
    }

    /// Resolves the content end from the analysis and the caller's overrides, in priority order.
    static func resolveContentEnd(_ analysis: TrackAnalysis, contentEnd: Double, duration: Double) -> Double {
        contentEnd.orZero.nonZero
            ?? analysis.contentEndTime.orZero.nonZero
            ?? duration.orZero.nonZero
            ?? analysis.duration.orZero
    }

    /// Ranks a track's analyzed mix-out candidates as places for a transition to end, best first.
    ///
    /// Candidates that would skip more than ``maxDiscardedMusicSeconds`` of remaining music are
    /// dropped outright: how confidently the analyzer marked a boundary is no argument for cutting
    /// a song short, and both an outro marker and a mid-track silence gap will happily do exactly
    /// that. Silence is free, so a genuine interior gap still wins the anchor it deserves.
    public static func rankMixOutCandidates(
        _ analysis: TrackAnalysis,
        contentEnd: Double = 0,
        duration: Double = 0
    ) -> [RankedMixCandidate] {
        let end = resolveContentEnd(analysis, contentEnd: contentEnd, duration: duration)
        if end <= 0 { return [] }
        return mixOutCandidates(of: analysis, contentEnd: end)
            .map { candidate -> RankedMixCandidate in
                let measured = audibleSeconds(analysis, from: candidate.time, to: end)
                // With no energy curve there is no way to tell skipped music from skipped
                // silence, so the raw gap is charged in full and the budget errs toward playing
                // the track.
                return RankedMixCandidate(
                    time: candidate.time,
                    score: candidate.score,
                    type: candidate.type,
                    rankScore: candidate.score + (mixOutTypeScore[candidate.type] ?? 0),
                    discardedMusicSeconds: measured ?? max(0, end - candidate.time),
                    measured: measured != nil
                )
            }
            .filter { $0.discardedMusicSeconds <= maxDiscardedMusicSeconds }
            .stableSorted { left, right in
                if left.rankScore != right.rankScore { return left.rankScore > right.rankScore }
                return left.time > right.time
            }
    }

    /// Where the outgoing track's transition ends: the best-ranked mix-out candidate that stays
    /// inside the discarded-music budget, or the end of content when none does.
    public static func resolveMixOutAnchor(
        _ analysis: TrackAnalysis,
        contentEnd: Double = 0,
        duration: Double = 0
    ) -> MixOutAnchor {
        let end = resolveContentEnd(analysis, contentEnd: contentEnd, duration: duration)
        let best = rankMixOutCandidates(analysis, contentEnd: end, duration: duration).first
        return MixOutAnchor(
            time: best?.time ?? end,
            type: best?.type ?? "content_end",
            discardedMusicSeconds: best?.discardedMusicSeconds ?? 0
        )
    }

    /// Decides how ambitious a transition the stored analysis supports.
    ///
    /// Reasons are ordered most-disqualifying first so callers can surface `reasons.first` as the
    /// routing verdict: `outgoing-tempo`, `incoming-tempo`, `beat-confidence`, `tempo-distance`.
    public static func assessTier(_ analysis: TrackAnalysis, _ nextAnalysis: TrackAnalysis) -> TransitionPolicyVerdict {
        let outgoingBPM = analysis.bpm.orZero
        let incomingBPM = nextAnalysis.bpm.orZero
        let outgoingConfidence = analysis.beatConfidence.orZero
        let incomingConfidence = nextAnalysis.beatConfidence.orZero
        let floorConfidence = min(outgoingConfidence, incomingConfidence)
        var reasons: [String] = []

        if outgoingBPM < minBPM || outgoingBPM > maxBPM { reasons.append("outgoing-tempo") }
        if incomingBPM < minBPM || incomingBPM > maxBPM { reasons.append("incoming-tempo") }
        if !reasons.isEmpty {
            return TransitionPolicyVerdict(tier: .plainCrossfade, reasons: reasons, beatConfidence: floorConfidence)
        }

        if outgoingConfidence < minDJConfidence && incomingConfidence < minDJConfidence {
            return TransitionPolicyVerdict(tier: .plainCrossfade, reasons: ["beat-confidence"], beatConfidence: floorConfidence)
        }

        let stretchRatio = outgoingBPM / alignTempoOctave(outgoingBPM: outgoingBPM, incomingBPM: incomingBPM)
        if abs(stretchRatio - 1) > maxStretchDeviation { reasons.append("tempo-distance") }
        if outgoingConfidence < minBeatmatchConfidence || incomingConfidence < minBeatmatchConfidence {
            reasons.append("beat-confidence")
        }

        return TransitionPolicyVerdict(
            tier: reasons.isEmpty ? .beatmatched : .djAssisted,
            reasons: reasons,
            beatConfidence: floorConfidence
        )
    }
}

// MARK: - Numeric helpers shared by the policy and the planner

extension Double {
    /// Non-finite guard, matching the desktop planner's coercion of `NaN`/`Infinity` to zero.
    var orZero: Double { isFinite ? self : 0 }

    /// `self`, or nil when it is exactly zero: Kotlin's `takeIf { it != 0.0 }`.
    var nonZero: Double? { self != 0 ? self : nil }

    /// Kotlin's `coerceIn`: pinned into `lower...upper`.
    func coerced(_ lower: Double, _ upper: Double) -> Double { Swift.max(lower, Swift.min(upper, self)) }
}

extension Optional where Wrapped == Double {
    var orZero: Double {
        if let value = self, value.isFinite { return value }
        return 0
    }
}

/// Like `min(max(value, lower), upper)`, except a non-finite value lands on `lower`.
func automixClamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    value.isFinite ? max(lower, min(upper, value)) : lower
}

extension Array {
    /// A sort that keeps equal elements in their original order, as Kotlin's `sortedBy` does. The
    /// policy's tie-breaks depend on it, and Swift does not promise stability.
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated()
            .sorted { left, right in
                if areInIncreasingOrder(left.element, right.element) { return true }
                if areInIncreasingOrder(right.element, left.element) { return false }
                return left.offset < right.offset
            }
            .map(\.element)
    }
}
