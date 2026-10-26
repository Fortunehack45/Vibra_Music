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

package com.fortune.vibramusic.playback.smart

/**
 * Stored offline analysis for one track, in that track's own timeline seconds.
 *
 * This is the contract between [TrackAnalyzer] and the transition policy.
 * Nothing here is PCM: the policy and planner read these fields and their
 * confidences, and never touch audio. Every field is optional, because the
 * ladder in [assessTransitionTier] is built to degrade on missing evidence
 * rather than to require it; an all-defaults instance is a legitimate input
 * that simply lands on the bottom rung.
 *
 * Phase 1 fills every field from DSP alone (see native/analyzer/), so
 * [beatConfidence] and [vocalActivityMask] are heuristics rather than a
 * trained model's output — the policy already treats them with the same
 * scrutiny it would a model that failed to load.
 */
data class TrackAnalysis(
    /**
     * Blank means "no status was reported", which counts as ready. Any other
     * value must be [STATUS_READY] for the planner to trust the rest of the
     * fields.
     */
    val status: String = "",
    /** Guards against a stale analysis being paired with the wrong track. */
    val trackId: String = "",
    val duration: Double = 0.0,

    val bpm: Double = 0.0,
    /**
     * Seconds per beat. Redundant with [bpm], but the analyzer measures it
     * directly and it survives tempo drift better, so it is preferred
     * wherever both are available.
     */
    val beatInterval: Double = 0.0,
    /**
     * How far the beat grid can be trusted, 0..1. A catalog tempo lookup
     * merges in at 0, so a metadata BPM alone can never authorize
     * beat-matching.
     */
    val beatConfidence: Double = 0.0,
    val downbeats: List<Double> = emptyList(),
    val phraseBoundaries: List<Double> = emptyList(),
    val firstBeat: Double = 0.0,

    val key: String = "",
    val keyConfidence: Double = 0.0,

    /** Where the file starts making sound, and where the first musical event lands. */
    val audibleStartTime: Double? = null,
    val pickupTime: Double? = null,
    val introEndTime: Double = 0.0,
    /** Where the content actually ends, excluding trailing silence. */
    val contentEndTime: Double = 0.0,
    val outroStartTime: Double = 0.0,

    val mixInTime: Double = 0.0,
    val mixOutTime: Double = 0.0,
    val mixInCandidates: List<MixCandidate> = emptyList(),
    val mixOutCandidates: List<MixCandidate> = emptyList(),

    val energyCurve: List<EnergySample> = emptyList(),
    /** Low-band energy, present only when the analyzer ran a band split. Drives the bass swap. */
    val lowEnergyCurve: List<EnergySample> = emptyList(),
    /**
     * Per-sample vocal activity, indexed against [energyCurve] sample times.
     * Empty, or any length other than the energy curve's, means "no
     * evidence", which never blocks a transition.
     */
    val vocalActivityMask: List<Double> = emptyList(),
    /** Whole-track vocal likelihood, distinct from the per-sample [vocalActivityMask]. */
    val vocalProbability: Double = 0.0,

    /** Meter hypothesis representing time-signature (e.g. 4/4, 3/4, 6/8). */
    val meter: MeterHypothesis = MeterHypothesis(),
    /** Whole-track integrated loudness estimate in LUFS (nominally -70 to 0). */
    val loudnessLufs: Double = -70.0,
    /** Peak level in dBFS. */
    val peakDbfs: Double = -70.0,
    /** Dynamic range estimate in dB. */
    val dynamicRangeDb: Double = 0.0,

    /** Every measured beat timestamp in seconds across the analysed regions. */
    val beats: List<Double> = emptyList(),
    /** Rhythmic feel (STRAIGHT vs TRIPLET). */
    val feel: Feel = Feel.UNKNOWN,
    /** Smoothed local tempo trajectory over time. */
    val tempoCurve: List<TempoPoint> = emptyList(),
    /** Stability metric [0..1], 1.0 being metronomically constant. */
    val tempoStability: Double = 1.0,
    /** Alternative tempo hypotheses (e.g. half-time, double-time) with confidence weights. */
    val tempoHypotheses: List<TempoHypothesis> = emptyList(),
    /** Rhythmic groove profile across low, mid, and high bands. */
    val groove: GrooveProfile? = null,
    /** Standardized loudness profile (LUFS and true-peak). */
    val loudness: LoudnessProfile? = null,
    /** Analysis format schema version (1 = legacy, 2 = master beat clock v2). */
        /** Source of the beat grid: "model", "refined_theil_sen", "warp_map", or "dsp". */
    val gridSource: String = "model",
    /** Whether the Beat This! ONNX model was successfully loaded and executed. */
    val modelLoaded: Boolean = false,
    /** Per-beat confidence score [0..1] aligned with [beats]. */
    val perBeatConfidences: List<Double> = emptyList(),
    val analysisVersion: Int = 2,
) {
    /**
     * Whether this analysis actually describes a track, as opposed to standing
     * in for one that has not been analysed or could not be.
     *
     * Both no-analysis states have to be excluded, and they look different: a
     * track nothing has looked at yet has a blank [status], while one whose
     * decode failed is recorded [STATUS_READY] with every field at its default
     * so it is not retried forever. A zero [bpm] is what separates the second
     * from a real result — and it is also the threshold the policy uses, since
     * a tempo outside 40–220 drops a pairing to a plain crossfade anyway.
     */
    val isUsable: Boolean get() = status == STATUS_READY && bpm > 0

    companion object {
        const val STATUS_READY = "ready"
    }
}

/**
 * Estimated time-signature / meter for a track.
 *
 * [beatsPerBar] is typically 4 for quadruple meters (4/4), 3 for triple meters (3/4, waltz),
 * or 6 for compound meters (6/8). When [isAmbiguous] is true, the beat periodicities did not
 * clearly differentiate between candidates, requiring downstream transitions to avoid locking
 * to false bar drops.
 */
enum class Feel { STRAIGHT, TRIPLET, UNKNOWN }

data class TempoPoint(val time: Double, val bpm: Double)

data class TempoHypothesis(val bpm: Double, val weight: Double)

data class GrooveProfile(
    val lowBand16: FloatArray = FloatArray(16),
    val midBand16: FloatArray = FloatArray(16),
    val highBand16: FloatArray = FloatArray(16),
    val density: Float = 0f,
    val swing: Float = 0f,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is GrooveProfile) return false
        return lowBand16.contentEquals(other.lowBand16) &&
            midBand16.contentEquals(other.midBand16) &&
            highBand16.contentEquals(other.highBand16) &&
            density == other.density &&
            swing == other.swing
    }

    override fun hashCode(): Int {
        var result = lowBand16.contentHashCode()
        result = 31 * result + midBand16.contentHashCode()
        result = 31 * result + highBand16.contentHashCode()
        result = 31 * result + density.hashCode()
        result = 31 * result + swing.hashCode()
        return result
    }
}

data class LoudnessProfile(
    val integratedLufs: Double = -70.0,
    val headShortTermLufs: Double = -70.0,
    val tailShortTermLufs: Double = -70.0,
    val truePeakDbfs: Double = -70.0,
)

data class MeterHypothesis(
    val beatsPerBar: Int = 4,
    val confidence: Double = 0.0,
    val isAmbiguous: Boolean = false,
    val alternativeMeter: Int? = null,
    val reason: String = "",
)

/** One point on an energy curve. [energy] is in whatever scale the analyzer chose. */
data class EnergySample(val time: Double, val energy: Double)

/**
 * A candidate point for a transition to enter or leave on. [score] is the
 * analyzer's own confidence; [type] is what it recognized, and carries its
 * own weight during ranking.
 */
data class MixCandidate(val time: Double, val score: Double, val type: String)

/** A ranked [MixCandidate], carrying the score the policy actually ordered it by. */
data class RankedMixCandidate(
    val time: Double,
    val score: Double,
    val type: String,
    val rankScore: Double,
    /**
     * Seconds of audible music this candidate would skip by ending the
     * transition before the content does. Mix-out only; always 0 for mix-in.
     */
    val discardedMusicSeconds: Double = 0.0,
    /** False when there was no energy curve and [discardedMusicSeconds] is the raw gap instead. */
    val measured: Boolean = true,
)

/** Where a transition should end on the outgoing track, and what it costs to end there. */
data class MixOutAnchor(
    val time: Double,
    val type: String,
    val discardedMusicSeconds: Double,
)

/** The verdict on how ambitious a transition the stored evidence supports. */
data class TransitionPolicyVerdict(
    val tier: TransitionTier,
    /** Ordered most-disqualifying first, so `reasons.first()` is the routing verdict. */
    val reasons: List<String>,
    val beatConfidence: Double,
)

/**
 * The degradation ladder. Ambition falls in explicit steps as certainty does,
 * rather than letting one engine quietly do beat math on junk data.
 */
enum class TransitionTier {
    /** Both grids trusted and the tempi sit within the transparent stretch window. */
    BEATMATCHED,

    /** Beat-quantized anchors and EQ handoffs are allowed; time-stretching is not. */
    DJ_ASSISTED,

    /** The evidence supports nothing beyond an equal-power fade at the analyzed anchor. */
    PLAIN_CROSSFADE,
}
