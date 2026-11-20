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

/// Stored offline analysis for one track, in that track's own timeline seconds.
///
/// This is the contract between ``TrackAnalyzer`` and the transition policy. Nothing here is
/// PCM: the policy and planner read these fields and their confidences, and never touch audio.
/// Every field is optional, because the ladder in ``TransitionPolicy/assessTier(_:_:)`` is built
/// to degrade on missing evidence rather than to require it; an all-defaults instance is a
/// legitimate input that simply lands on the bottom rung.
///
/// The DSP pass (see `AutomixAnalyzer`) fills every field; the Beat This! and open-unmix model
/// passes refine the beat grid and the vocal mask where they run. The policy treats a DSP-only
/// ``beatConfidence`` and ``vocalActivityMask`` with the same scrutiny it would a model that
/// failed to load.
public struct TrackAnalysis: Sendable, Equatable {
    public static let statusReady = "ready"

    /// Blank means "no status was reported", which counts as ready. Any other value must be
    /// ``statusReady`` for the planner to trust the rest of the fields.
    public var status: String
    /// Guards against a stale analysis being paired with the wrong track.
    public var trackId: String
    public var duration: Double

    public var bpm: Double
    /// Seconds per beat. Redundant with ``bpm``, but the analyzer measures it directly and it
    /// survives tempo drift better, so it is preferred wherever both are available.
    public var beatInterval: Double
    /// How far the beat grid can be trusted, 0...1. A catalog tempo lookup merges in at 0, so a
    /// metadata BPM alone can never authorize beat-matching.
    public var beatConfidence: Double
    public var downbeats: [Double]
    public var phraseBoundaries: [Double]
    public var firstBeat: Double

    public var key: String
    public var keyConfidence: Double

    /// Where the file starts making sound, and where the first musical event lands.
    public var audibleStartTime: Double?
    public var pickupTime: Double?
    public var introEndTime: Double
    /// Where the content actually ends, excluding trailing silence.
    public var contentEndTime: Double
    public var outroStartTime: Double

    public var mixInTime: Double
    public var mixOutTime: Double
    public var mixInCandidates: [MixCandidate]
    public var mixOutCandidates: [MixCandidate]

    public var energyCurve: [EnergySample]
    /// Low-band energy, present only when the analyzer ran a band split. Drives the bass swap.
    public var lowEnergyCurve: [EnergySample]
    /// Per-sample vocal activity, indexed against ``energyCurve`` sample times. Empty, or any
    /// length other than the energy curve's, means "no evidence", which never blocks a
    /// transition.
    public var vocalActivityMask: [Double]
    /// Whole-track vocal likelihood, distinct from the per-sample ``vocalActivityMask``.
    public var vocalProbability: Double

    public init(
        status: String = "",
        trackId: String = "",
        duration: Double = 0,
        bpm: Double = 0,
        beatInterval: Double = 0,
        beatConfidence: Double = 0,
        downbeats: [Double] = [],
        phraseBoundaries: [Double] = [],
        firstBeat: Double = 0,
        key: String = "",
        keyConfidence: Double = 0,
        audibleStartTime: Double? = nil,
        pickupTime: Double? = nil,
        introEndTime: Double = 0,
        contentEndTime: Double = 0,
        outroStartTime: Double = 0,
        mixInTime: Double = 0,
        mixOutTime: Double = 0,
        mixInCandidates: [MixCandidate] = [],
        mixOutCandidates: [MixCandidate] = [],
        energyCurve: [EnergySample] = [],
        lowEnergyCurve: [EnergySample] = [],
        vocalActivityMask: [Double] = [],
        vocalProbability: Double = 0
    ) {
        self.status = status
        self.trackId = trackId
        self.duration = duration
        self.bpm = bpm
        self.beatInterval = beatInterval
        self.beatConfidence = beatConfidence
        self.downbeats = downbeats
        self.phraseBoundaries = phraseBoundaries
        self.firstBeat = firstBeat
        self.key = key
        self.keyConfidence = keyConfidence
        self.audibleStartTime = audibleStartTime
        self.pickupTime = pickupTime
        self.introEndTime = introEndTime
        self.contentEndTime = contentEndTime
        self.outroStartTime = outroStartTime
        self.mixInTime = mixInTime
        self.mixOutTime = mixOutTime
        self.mixInCandidates = mixInCandidates
        self.mixOutCandidates = mixOutCandidates
        self.energyCurve = energyCurve
        self.lowEnergyCurve = lowEnergyCurve
        self.vocalActivityMask = vocalActivityMask
        self.vocalProbability = vocalProbability
    }

    /// Whether this analysis actually describes a track, as opposed to standing in for one that
    /// has not been analysed or could not be.
    ///
    /// Both no-analysis states have to be excluded, and they look different: a track nothing has
    /// looked at yet has a blank ``status``, while one whose decode failed is recorded
    /// ``statusReady`` with every field at its default so it is not retried forever. A zero
    /// ``bpm`` is what separates the second from a real result — and it is also the threshold the
    /// policy uses, since a tempo outside 40–220 drops a pairing to a plain crossfade anyway.
    public var isUsable: Bool { status == Self.statusReady && bpm > 0 }
}

/// One point on an energy curve. `energy` is in whatever scale the analyzer chose.
public struct EnergySample: Sendable, Equatable, Hashable {
    public var time: Double
    public var energy: Double

    public init(time: Double, energy: Double) {
        self.time = time
        self.energy = energy
    }
}

/// A candidate point for a transition to enter or leave on. `score` is the analyzer's own
/// confidence; `type` is what it recognized (`pickup`, `intro_drop`, `main_drop`, `phrase`,
/// `energy_cliff`, `outro_start`, `content_end`, ...), and carries its own weight in ranking.
public struct MixCandidate: Sendable, Equatable, Hashable {
    public var time: Double
    public var score: Double
    public var type: String

    public init(time: Double, score: Double, type: String) {
        self.time = time
        self.score = score
        self.type = type
    }
}

/// A ranked ``MixCandidate``, carrying the score the policy actually ordered it by.
public struct RankedMixCandidate: Sendable, Equatable {
    public var time: Double
    public var score: Double
    public var type: String
    public var rankScore: Double
    /// Seconds of audible music this candidate would skip by ending the transition before the
    /// content does. Mix-out only; always 0 for mix-in.
    public var discardedMusicSeconds: Double
    /// False when there was no energy curve and ``discardedMusicSeconds`` is the raw gap instead.
    public var measured: Bool

    public init(
        time: Double,
        score: Double,
        type: String,
        rankScore: Double,
        discardedMusicSeconds: Double = 0,
        measured: Bool = true
    ) {
        self.time = time
        self.score = score
        self.type = type
        self.rankScore = rankScore
        self.discardedMusicSeconds = discardedMusicSeconds
        self.measured = measured
    }
}

/// Where a transition should end on the outgoing track, and what it costs to end there.
public struct MixOutAnchor: Sendable, Equatable {
    public var time: Double
    public var type: String
    public var discardedMusicSeconds: Double

    public init(time: Double, type: String, discardedMusicSeconds: Double) {
        self.time = time
        self.type = type
        self.discardedMusicSeconds = discardedMusicSeconds
    }
}

/// The verdict on how ambitious a transition the stored evidence supports.
public struct TransitionPolicyVerdict: Sendable, Equatable {
    public var tier: TransitionTier
    /// Ordered most-disqualifying first, so `reasons.first` is the routing verdict.
    public var reasons: [String]
    public var beatConfidence: Double

    public init(tier: TransitionTier, reasons: [String], beatConfidence: Double) {
        self.tier = tier
        self.reasons = reasons
        self.beatConfidence = beatConfidence
    }
}

/// The degradation ladder. Ambition falls in explicit steps as certainty does, rather than
/// letting one engine quietly do beat math on junk data.
public enum TransitionTier: String, Sendable, Equatable, CaseIterable {
    /// Both grids trusted and the tempi sit within the transparent stretch window.
    case beatmatched
    /// Beat-quantized anchors and EQ handoffs are allowed; time-stretching is not.
    case djAssisted
    /// The evidence supports nothing beyond an equal-power fade at the analyzed anchor.
    case plainCrossfade
}

/// Where one track stands in Automix's analysis, for stats for nerds and the scrubber marker.
///
/// The three no-result states are kept apart because they call for different reactions:
/// ``waiting`` resolves itself once bytes arrive, ``analysing`` resolves itself in a few seconds,
/// and ``failed`` never resolves at all. From outside they look identical, which is precisely why
/// the line has to say which.
public enum AutomixAnalysisState: String, Sendable, Equatable, CaseIterable {
    /// Nothing in flight and no result — usually waiting on bytes to arrive.
    case waiting
    /// Decode and inference running now; a result is a few seconds away.
    case analysing
    /// Measured, with a tempo the planner can actually use.
    case analysed
    /// Measured off the track's opening, with the whole-track pass running now to replace those
    /// numbers with better ones. Its own state because it is genuinely both: already usable, and
    /// about to move.
    case refining
    /// Tried and came back with nothing usable — a decode error, or audio that yielded no tempo.
    case failed

    /// Whether the incoming side of a transition has enough to enter on: a head-only result
    /// measures exactly what the incoming side is read for.
    public var isMeasuredEnoughToEnterOn: Bool { self == .analysed || self == .refining }

    /// Derives a track's state from what the analyzer knows about it.
    ///
    /// Usable first, and a pass in flight *second*: a track measured off its opening reads as
    /// analysed, then finishes caching and has the whole-track pass run over it; reporting
    /// "analysing" throughout that would read as having gone backwards.
    public static func of(_ analysis: TrackAnalysis, running: Bool) -> AutomixAnalysisState {
        if analysis.isUsable { return running ? .refining : .analysed }
        if running { return .analysing }
        // A recorded-but-unusable result is the analyzer saying it tried and will not try again;
        // a track nothing has looked at yet has no status at all.
        if analysis.status == TrackAnalysis.statusReady { return .failed }
        return .waiting
    }
}
