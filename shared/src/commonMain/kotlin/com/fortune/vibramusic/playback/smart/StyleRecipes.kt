package com.fortune.vibramusic.playback.smart

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Procedural recipes for building automation lanes across master beats.
 */
object StyleRecipes {

    /**
     * Builds automation lanes for a beatmatched DJ Blend with groove-aligned bass swap.
     */
    fun createBlendLanes(
        totalBeats: Double,
        swapBeat: Double,
        vocalClash: Boolean = false,
    ): List<Lane> {
        val steps = 16
        val outGainPoints = ArrayList<LanePoint>()
        val inGainPoints = ArrayList<LanePoint>()

        for (i in 0..steps) {
            val beat = (i.toDouble() / steps) * totalBeats
            val progress = (i.toDouble() / steps).coerceIn(0.0, 1.0)
            val rad = progress * (PI / 2.0)
            outGainPoints += LanePoint(beat, cos(rad).toFloat())
            inGainPoints += LanePoint(beat, sin(rad).toFloat())
        }

        val lanes = mutableListOf(
            Lane(Deck.OUTGOING, Param.GAIN, outGainPoints),
            Lane(Deck.INCOMING, Param.GAIN, inGainPoints),
        )

        // Bass swap automation: 1 bar window around swapBeat
        val swapWindow = 4.0
        val swapStart = (swapBeat - swapWindow / 2.0).coerceAtLeast(0.0)
        val swapEnd = (swapBeat + swapWindow / 2.0).coerceAtMost(totalBeats)

        lanes += Lane(
            Deck.OUTGOING,
            Param.EQ_LOW,
            listOf(
                LanePoint(0.0, 0f),
                LanePoint(swapStart, 0f),
                LanePoint(swapEnd, -24f),
                LanePoint(totalBeats, -24f),
            ),
        )

        lanes += Lane(
            Deck.INCOMING,
            Param.EQ_LOW,
            listOf(
                LanePoint(0.0, -24f),
                LanePoint(swapStart, -24f),
                LanePoint(swapEnd, 0f),
                LanePoint(totalBeats, 0f),
            ),
        )

        // Vocal separation: dip outgoing midrange if both vocals collide
        if (vocalClash) {
            lanes += Lane(
                Deck.OUTGOING,
                Param.EQ_MID,
                listOf(
                    LanePoint(0.0, 0f),
                    LanePoint(swapStart, -4f),
                    LanePoint(totalBeats, -6f),
                ),
            )
        }

        return lanes
    }

    /**
     * Builds automation lanes for the RISE preset:
     * High-pass sweeps to 2,500 Hz with resonant build and low-cut, dropping into incoming on downbeat.
     */
    fun createRiseLanes(
        totalBeats: Double,
        dropBeat: Double,
    ): List<Lane> {
        val riserStartBeat = (dropBeat - 16.0).coerceAtLeast(0.0) // 4 bars build
        val lowCutStartBeat = (dropBeat - 8.0).coerceAtLeast(0.0) // Low cut 2 bars before drop

        return listOf(
            // Outgoing gain: stays full up to dropBeat, then cuts immediately to 0
            Lane(
                Deck.OUTGOING,
                Param.GAIN,
                listOf(
                    LanePoint(0.0, 1.0f),
                    LanePoint(dropBeat - 0.05, 1.0f),
                    LanePoint(dropBeat, 0.0f),
                    LanePoint(totalBeats, 0.0f),
                ),
            ),
            // Incoming gain: silent up to dropBeat, drops in at 1.0 on downbeat
            Lane(
                Deck.INCOMING,
                Param.GAIN,
                listOf(
                    LanePoint(0.0, 0.0f),
                    LanePoint(dropBeat - 0.05, 0.0f),
                    LanePoint(dropBeat, 1.0f),
                    LanePoint(totalBeats, 1.0f),
                ),
            ),
            // Outgoing high-pass sweep: 20 Hz up to 2500 Hz
            Lane(
                Deck.OUTGOING,
                Param.HP_HZ,
                listOf(
                    LanePoint(0.0, 20f),
                    LanePoint(riserStartBeat, 20f),
                    LanePoint(dropBeat - 1.0, 1200f),
                    LanePoint(dropBeat, 2500f),
                ),
            ),
            // Outgoing low EQ: cuts out low end before drop
            Lane(
                Deck.OUTGOING,
                Param.EQ_LOW,
                listOf(
                    LanePoint(0.0, 0f),
                    LanePoint(lowCutStartBeat, 0f),
                    LanePoint(dropBeat - 2.0, -18f),
                    LanePoint(dropBeat, -24f),
                ),
            ),
            // Outgoing resonance Q sweep: rising peak near drop
            Lane(
                Deck.OUTGOING,
                Param.HP_Q,
                listOf(
                    LanePoint(0.0, 0.707f),
                    LanePoint(riserStartBeat, 0.707f),
                    LanePoint(dropBeat, 2.5f),
                ),
            ),
            // Incoming high-pass: fully open (20 Hz) at drop
            Lane(
                Deck.INCOMING,
                Param.HP_HZ,
                listOf(
                    LanePoint(0.0, 20f),
                    LanePoint(dropBeat, 20f),
                    LanePoint(totalBeats, 20f),
                ),
            ),
        )
    }

    /**
     * Builds automation lanes for ECHO_OUT:
     * Low-cut and 1-beat echo trail on outgoing deck, incoming enters on downbeat.
     */
    fun createEchoOutLanes(
        totalBeats: Double,
        cutBeat: Double,
    ): List<Lane> {
        val sendStart = (cutBeat - 1.0).coerceAtLeast(0.0)

        return listOf(
            Lane(
                Deck.OUTGOING,
                Param.GAIN,
                listOf(
                    LanePoint(0.0, 1.0f),
                    LanePoint(cutBeat - 0.05, 1.0f),
                    LanePoint(cutBeat, 0.0f),
                    LanePoint(totalBeats, 0.0f),
                ),
            ),
            Lane(
                Deck.INCOMING,
                Param.GAIN,
                listOf(
                    LanePoint(0.0, 0.0f),
                    LanePoint(cutBeat - 0.05, 0.0f),
                    LanePoint(cutBeat, 1.0f),
                    LanePoint(totalBeats, 1.0f),
                ),
            ),
            Lane(
                Deck.OUTGOING,
                Param.HP_HZ,
                listOf(
                    LanePoint(0.0, 20f),
                    LanePoint(sendStart, 200f),
                    LanePoint(cutBeat, 400f),
                ),
            ),
            Lane(
                Deck.OUTGOING,
                Param.ECHO_SEND,
                listOf(
                    LanePoint(0.0, 0f),
                    LanePoint(sendStart, 0.85f),
                    LanePoint(cutBeat + 2.0, 0.40f),
                    LanePoint(totalBeats, 0f),
                ),
            ),
        )
    }

    /**
     * Builds automation lanes for clean CUT on downbeat.
     */
    fun createCutLanes(
        totalBeats: Double,
        cutBeat: Double,
    ): List<Lane> {
        return listOf(
            Lane(
                Deck.OUTGOING,
                Param.GAIN,
                listOf(
                    LanePoint(0.0, 1.0f),
                    LanePoint(cutBeat - 0.05, 1.0f),
                    LanePoint(cutBeat, 0.0f),
                    LanePoint(totalBeats, 0.0f),
                ),
            ),
            Lane(
                Deck.INCOMING,
                Param.GAIN,
                listOf(
                    LanePoint(0.0, 0.0f),
                    LanePoint(cutBeat - 0.05, 0.0f),
                    LanePoint(cutBeat, 1.0f),
                    LanePoint(totalBeats, 1.0f),
                ),
            ),
        )
    }

    /**
     * Builds automation lanes for standard equal-power FADE.
     */
    fun createFadeLanes(totalBeats: Double): List<Lane> {
        val steps = 16
        val outGainPoints = ArrayList<LanePoint>()
        val inGainPoints = ArrayList<LanePoint>()

        for (i in 0..steps) {
            val beat = (i.toDouble() / steps) * totalBeats
            val progress = (i.toDouble() / steps).coerceIn(0.0, 1.0)
            val rad = progress * (PI / 2.0)
            outGainPoints += LanePoint(beat, cos(rad).toFloat())
            inGainPoints += LanePoint(beat, sin(rad).toFloat())
        }

        return listOf(
            Lane(Deck.OUTGOING, Param.GAIN, outGainPoints),
            Lane(Deck.INCOMING, Param.GAIN, inGainPoints),
        )
    }
}
