package com.fortune.vibramusic.playback.smart.harness

import com.fortune.vibramusic.playback.smart.CrossfadeMode
import com.fortune.vibramusic.playback.smart.TrackAnalysis
import com.fortune.vibramusic.playback.smart.TransitionPlan
import com.fortune.vibramusic.playback.smart.TransitionStyle
import com.fortune.vibramusic.playback.smart.planTransition
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Offline execution oracle that reproduces the CURRENT production transition logic
 * from [com.fortune.vibramusic.playback.CrossfadeController] and [planTransition]
 * over raw PCM audio blocks, without requiring Android framework or AudioTrack hardware.
 */
object CurrentOfflineRenderer {

    data class RenderResult(
        val plan: TransitionPlan,
        val mixedAudio: FloatArray,
        val dryOutgoing: FloatArray,
        val dryIncoming: FloatArray,
        val overlapStartSec: Double,
        val overlapEndSec: Double,
        val sampleRate: Int,
    )

    /**
     * Renders a transition between [outgoing] and [incoming] tracks according to the CURRENT engine.
     *
     * @param simulatedClockJitterMs Injected clock misalignment between the two players (e.g. 0ms, 40ms).
     */
    fun render(
        outgoing: SyntheticAudioGenerator.SyntheticTrack,
        incoming: SyntheticAudioGenerator.SyntheticTrack,
        simulatedClockJitterMs: Double = 0.0,
        sampleRate: Int = SyntheticAudioGenerator.DEFAULT_SAMPLE_RATE,
        requestedStyle: String? = null,
    ): RenderResult {
        val outDuration = outgoing.durationSeconds
        val inDuration = incoming.durationSeconds

        // 1. Run production planner
        val plan = planTransition(
            analysis = outgoing.analysis,
            nextAnalysis = incoming.analysis,
            currentTime = 0.0,
            duration = outDuration,
            fadeSeconds = 6.0,
            mode = CrossfadeMode.SMART,
            advanced = true,
            requestedStyle = requestedStyle,
        )

        val overlapStartSec = plan.transitionStart
        val overlapEndSec = plan.transitionEnd
        val fadeDurationSec = max(0.1, overlapEndSec - overlapStartSec)
        val incomingCueSec = plan.incomingCueTime

        val totalOutputDuration = overlapStartSec + inDuration - incomingCueSec
        val totalSamples = (totalOutputDuration * sampleRate).toInt()

        val mixed = FloatArray(totalSamples)
        val dryOut = FloatArray(totalSamples)
        val dryIn = FloatArray(totalSamples)

        val jitterSec = simulatedClockJitterMs / 1000.0

        for (i in 0 until totalSamples) {
            val tOut = i.toDouble() / sampleRate
            val outSampleIdx = (tOut * sampleRate).toInt()

            // 1. Outgoing sample
            var sampleOut = 0f
            if (outSampleIdx in outgoing.pcm.indices && tOut <= overlapEndSec) {
                sampleOut = outgoing.pcm[outSampleIdx]
            }

            // 2. Incoming sample (anchored at overlapStartSec + jitterSec)
            val tSinceTransition = tOut - (overlapStartSec + jitterSec)
            val tIn = incomingCueSec + (tSinceTransition * plan.incomingPlaybackRate)
            val inSampleIdx = (tIn * sampleRate).toInt()

            var sampleIn = 0f
            if (tSinceTransition >= 0.0 && inSampleIdx in incoming.pcm.indices) {
                sampleIn = incoming.pcm[inSampleIdx]
            }

            dryOut[i] = sampleOut
            dryIn[i] = sampleIn

            // 3. Current gain computation from CrossfadeController.driveFade()
            if (tOut < overlapStartSec) {
                // Pre-transition: Outgoing full volume
                mixed[i] = sampleOut
            } else if (tOut in overlapStartSec..overlapEndSec) {
                // Inside transition window
                val elapsed = tOut - overlapStartSec
                val progress = (elapsed / fadeDurationSec).coerceIn(0.0, 1.0).toFloat()

                val rad = progress * (PI / 2.0)
                val fall = cos(rad).toFloat()
                val rise = sin(rad).toFloat()

                // Headroom trim: trim = baseTrim * baseTrim, baseTrim = 1 / max(1f, rise + fall)
                val sum = rise + fall
                val baseTrim = if (sum > 1.0f) 1.0f / sum else 1.0f
                val trim = baseTrim * baseTrim

                var gainOut = fall * trim
                var gainIn = rise * trim

                // Bass swap logic if enabled
                if (plan.bassSwap) {
                    val swapThreshold = plan.bassSwapFraction.toFloat()
                    if (progress < swapThreshold) {
                        // Incoming bass suppressed before swap
                        gainIn *= 0.60f
                    } else {
                        // Outgoing bass suppressed after swap
                        gainOut *= 0.40f
                    }
                }

                mixed[i] = (sampleOut * gainOut + sampleIn * gainIn).coerceIn(-1.0f, 1.0f)
            } else {
                // Post-transition: Incoming full volume
                mixed[i] = sampleIn
            }
        }

        return RenderResult(
            plan = plan,
            mixedAudio = mixed,
            dryOutgoing = dryOut,
            dryIncoming = dryIn,
            overlapStartSec = overlapStartSec,
            overlapEndSec = overlapEndSec,
            sampleRate = sampleRate,
        )
    }
}
