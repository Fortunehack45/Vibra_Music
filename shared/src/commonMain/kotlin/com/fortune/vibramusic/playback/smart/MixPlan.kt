package com.fortune.vibramusic.playback.smart

/**
 * Transition styles supported by the Master Beat Clock engine.
 */
enum class TransitionStyleV2 {
    /** Beatmatched blend with bass swap and vocal separation. */
    BLEND,

    /** Smooth equal-power crossfade for unaligned or low-confidence material. */
    FADE,

    /** Bar-quantized high-pass riser build ending in a downbeat drop. */
    RISE,

    /** Outgoing track low-cut with 1-beat tempo-synced delay tail into incoming drop. */
    ECHO_OUT,

    /** Clean downbeat cut for abrupt tempo transitions or disparate genres. */
    CUT,

    /** Sequential album track handoff. */
    GAPLESS,

    /** Safe fallback crossfade. */
    PLAIN,
}

/**
 * Controllable DSP automation parameters.
 */
enum class Param {
    GAIN,
    EQ_LOW,
    EQ_MID,
    EQ_HIGH,
    HP_HZ,
    LP_HZ,
    HP_Q,
    ECHO_SEND,
    RISER_LEVEL,
}

/**
 * Which deck an automation lane governs.
 */
enum class Deck {
    OUTGOING,
    INCOMING,
}

/**
 * A single automation control point in master beats.
 */
data class LanePoint(val masterBeat: Double, val value: Float)

/**
 * An automation lane defining parameter evolution across master beats.
 */
data class Lane(
    val deck: Deck,
    val param: Param,
    val points: List<LanePoint>,
) {
    /**
     * Linearly interpolates the parameter value at [masterBeat].
     */
    fun evaluate(masterBeat: Double): Float {
        if (points.isEmpty()) return 0f
        if (masterBeat <= points.first().masterBeat) return points.first().value
        if (masterBeat >= points.last().masterBeat) return points.last().value

        for (i in 0 until points.size - 1) {
            val p0 = points[i]
            val p1 = points[i + 1]
            if (masterBeat in p0.masterBeat..p1.masterBeat) {
                val span = p1.masterBeat - p0.masterBeat
                if (span <= 1e-6) return p0.value
                val t = ((masterBeat - p0.masterBeat) / span).toFloat()
                return p0.value + t * (p1.value - p0.value)
            }
        }
        return points.last().value
    }
}

/**
 * A knot on the piecewise master tempo curve.
 */
data class TempoKnot(
    val masterBeat: Double,
    val bpm: Double,
)

/**
 * Deck playback and anchor assignment within the mix.
 */
data class DeckPlan(
    val trackId: String = "",
    val mediaAnchorSec: Double = 0.0,
    val masterAnchorBeat: Double = 0.0,
    val startMediaSec: Double = 0.0,
    val endMediaSec: Double = 0.0,
    val nativeBpm: Double = 120.0,
)

/**
 * The complete, beat-aligned transition execution plan for a track pair.
 */
data class MixPlan(
    val style: TransitionStyleV2,
    val outgoing: DeckPlan = DeckPlan(),
    val incoming: DeckPlan = DeckPlan(),
    val tempoKnots: List<TempoKnot> = emptyList(),
    val lanes: List<Lane> = emptyList(),
    val handoffBeat: Double = 0.0,
    val totalMasterBeats: Double = 0.0,
    val score: Double = 1.0,
    val reasons: List<String> = emptyList(),
) {
    fun lane(deck: Deck, param: Param): Lane? =
        lanes.firstOrNull { it.deck == deck && it.param == param }

    fun evaluate(deck: Deck, param: Param, masterBeat: Double, default: Float = 0f): Float =
        lane(deck, param)?.evaluate(masterBeat) ?: default
}
