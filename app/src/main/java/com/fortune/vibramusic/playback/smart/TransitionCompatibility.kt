package com.fortune.vibramusic.playback.smart

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Result of evaluating transition compatibility between an outgoing track and incoming track.
 *
 * @property totalScore Overall compatibility score [0.0, 1.0].
 * @property confidence Confidence in the score based on available analysis evidence [0.0, 1.0].
 * @property tempoScore Score for BPM alignment and octave compatibility [0.0, 1.0].
 * @property keyScore Score for harmonic Camelot key alignment [0.0, 1.0].
 * @property energyScore Score for energy flow between outgoing tail and incoming head [0.0, 1.0].
 * @property transitionPointScore Score for mix-in/mix-out anchor suitability [0.0, 1.0].
 * @property loudnessScore Score for volume / loudness consistency [0.0, 1.0].
 * @property recommendedStyle Suggested transition style for this pair.
 */
data class CompatibilityResult(
    val totalScore: Float,
    val confidence: Float,
    val tempoScore: Float,
    val keyScore: Float,
    val energyScore: Float,
    val transitionPointScore: Float,
    val loudnessScore: Float,
    val recommendedStyle: TransitionStyle,
)

object TransitionCompatibility {

    // BPM is primary (40%), followed closely by harmonic key (35%), energy/mood (15%), and anchors (10%)
    private const val WEIGHT_TEMPO = 0.40f
    private const val WEIGHT_KEY = 0.35f
    private const val WEIGHT_ENERGY = 0.15f
    private const val WEIGHT_ANCHORS = 0.10f

    /**
     * Evaluates compatibility between [outgoing] and [incoming] track analyses.
     */
    fun evaluate(outgoing: TrackAnalysis, incoming: TrackAnalysis): CompatibilityResult {
        // 1. Tempo compatibility (40% - Primary factor)
        val tempoScore = calculateTempoScore(outgoing.bpm, incoming.bpm)
        val tempoConfidence = min(outgoing.beatConfidence, incoming.beatConfidence).toFloat().coerceIn(0f, 1f)

        // 2. Key compatibility (35% - Secondary harmonic factor)
        val keyOut = CamelotKey.parse(outgoing.key)
        val keyIn = CamelotKey.parse(incoming.key)
        val keyScore = if (keyOut != null && keyIn != null) {
            keyOut.compatibilityScore(keyIn)
        } else {
            0.50f // Neutral baseline when key metadata is unknown
        }
        val keyConfidence = if (keyOut != null && keyIn != null) {
            min(outgoing.keyConfidence, incoming.keyConfidence).toFloat().coerceIn(0f, 1f)
        } else {
            0.0f
        }

        // 3. Energy continuity (15% - Mood and vibe preservation)
        val energyScore = calculateEnergyScore(outgoing, incoming)
        val energyConfidence = if (outgoing.energyCurve.isNotEmpty() && incoming.energyCurve.isNotEmpty()) 0.8f else 0.4f

        // 4. Transition point suitability (10% - Phrase & anchor alignment)
        val anchorScore = calculateAnchorScore(outgoing, incoming)
        val anchorConfidence = if (outgoing.mixOutTime > 0.0 && incoming.mixInTime > 0.0) 0.9f else 0.3f

        // 5. Loudness & vocal separation
        val loudnessScore = calculateLoudnessScore(outgoing, incoming)

        // Weighted total score
        val totalScore = (
            tempoScore * WEIGHT_TEMPO +
            keyScore * WEIGHT_KEY +
            energyScore * WEIGHT_ENERGY +
            anchorScore * WEIGHT_ANCHORS
        ).coerceIn(0f, 1f)

        // Aggregate confidence
        val overallConfidence = (
            tempoConfidence * 0.40f +
            keyConfidence * 0.30f +
            energyConfidence * 0.15f +
            anchorConfidence * 0.15f
        ).coerceIn(0f, 1f)

        val meterMatch = if (outgoing.meter.confidence >= 0.5 && incoming.meter.confidence >= 0.5) {
            outgoing.meter.beatsPerBar == incoming.meter.beatsPerBar && !outgoing.meter.isAmbiguous && !incoming.meter.isAmbiguous
        } else {
            true
        }

        // Determine recommended transition style
        val style = when {
            overallConfidence < 0.25f -> TransitionStyle.EQUAL_POWER
            !meterMatch -> TransitionStyle.DJ_FILTER
            tempoScore >= 0.75f && anchorScore >= 0.60f -> TransitionStyle.DJ_BLEND
            keyScore >= 0.80f && energyScore <= 0.65f -> TransitionStyle.DJ_RISE
            tempoScore >= 0.50f || keyScore >= 0.70f -> TransitionStyle.DJ_FILTER
            else -> TransitionStyle.EQUAL_POWER
        }

        return CompatibilityResult(
            totalScore = totalScore,
            confidence = overallConfidence,
            tempoScore = tempoScore,
            keyScore = keyScore,
            energyScore = energyScore,
            transitionPointScore = anchorScore,
            loudnessScore = loudnessScore,
            recommendedStyle = style,
        )
    }

    /**
     * Evaluates tempo compatibility accounting for direct matching and octave harmonic relationships:
     * - 1:1 direct tempo match (<=2% = 1.0, <=6% = linear 1.0..0.70)
     * - 1:2 and 2:1 octave relationship (e.g. 70 BPM to 140 BPM, capped at 0.85)
     * - 3:2 and 2:3 polyrhythm / triplet swing relationship (e.g. 80 and 120 BPM, capped at 0.70)
     * - Distant BPMs (>15% divergence) return a low baseline score without throwing.
     */
    fun calculateTempoScore(bpmA: Double, bpmB: Double): Float {
        if (bpmA <= 30.0 || bpmB <= 30.0) return 0.50f // Unknown or unmeasured tempo

        var bestScore = 0.0f
        val multipliers = listOf(1.0, 0.5, 2.0)

        for (m in multipliers) {
            val targetBpm = bpmB * m
            val high = max(bpmA, targetBpm)
            val low = min(bpmA, targetBpm)
            val diff = (high - low) / low

            val cap = when (m) {
                1.0 -> 1.0f
                0.5, 2.0 -> 0.85f
                else -> 0.70f
            }

            val score = when {
                diff <= 0.02 -> 1.0f
                diff <= 0.06 -> (1.0 - (diff - 0.02) / 0.04 * 0.30).toFloat()
                diff <= 0.10 -> 0.55f
                diff <= 0.15 -> 0.40f
                else -> 0.20f
            }

            val effective = min(score, cap)
            if (effective > bestScore) {
                bestScore = effective
            }
        }

        return bestScore
    }

    private fun calculateEnergyScore(outgoing: TrackAnalysis, incoming: TrackAnalysis): Float {
        val outTailEnergy = if (outgoing.energyCurve.isNotEmpty()) {
            outgoing.energyCurve.takeLast(5).map { it.energy }.average()
        } else {
            0.5
        }
        val inHeadEnergy = if (incoming.energyCurve.isNotEmpty()) {
            incoming.energyCurve.take(5).map { it.energy }.average()
        } else {
            0.5
        }

        val energyDelta = abs(outTailEnergy - inHeadEnergy)
        return (1.0 - energyDelta * 1.5).toFloat().coerceIn(0.30f, 1.0f)
    }

    private fun calculateAnchorScore(outgoing: TrackAnalysis, incoming: TrackAnalysis): Float {
        var score = 0.50f
        if (outgoing.mixOutTime > 0.0) score += 0.25f
        if (incoming.mixInTime > 0.0) score += 0.25f
        return score.coerceIn(0f, 1f)
    }

    private fun calculateLoudnessScore(outgoing: TrackAnalysis, incoming: TrackAnalysis): Float {
        val outProb = outgoing.vocalProbability
        val inProb = incoming.vocalProbability
        // Complementary vocal probability reduces clash risk
        val vocalClash = if (outProb > 0.6 && inProb > 0.6) 0.3f else 0.0f
        return (1.0f - vocalClash).coerceIn(0.40f, 1.0f)
    }
}
