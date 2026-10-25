package com.fortune.vibramusic.playback.smart.harness

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 0 Baseline Benchmark Test Suite.
 * Executes the measurement harness across synthetic track pairs to quantify the
 * current transition engine's baseline performance and reproduce the double-kick / flam symptom.
 */
class Phase0BaselineTest {

    data class BaselineRow(
        val pairName: String,
        val bpmA: Double,
        val bpmB: Double,
        val meterA: String,
        val meterB: String,
        val injectedJitterMs: Double,
        val planStyle: String,
        val phaseMedianMs: Double,
        val phaseP95Ms: Double,
        val doubleKicks: Int,
        val midpointDipDb: Double,
        val truePeakDb: Double,
        val downbeatBarOffset: Double,
    )

    @Test
    fun runPhase0BaselineEvaluationMatrix() {
        val testConfigs = listOf(
            // S1: 115 -> 115 BPM (Rema Bounce tempo) with increasing clock jitter
            TestConfig("115bpm_0ms_jitter", 115.0, 115.0, 4, 4, 0.0),
            TestConfig("115bpm_40ms_jitter", 115.0, 115.0, 4, 4, 40.0),
            TestConfig("115bpm_120ms_jitter", 115.0, 115.0, 4, 4, 120.0),
            TestConfig("115bpm_250ms_jitter", 115.0, 115.0, 4, 4, 250.0),

            // S2: 100 BPM Hip-hop/Afro tempo
            TestConfig("100bpm_0ms_jitter", 100.0, 100.0, 4, 4, 0.0),
            TestConfig("100bpm_40ms_jitter", 100.0, 100.0, 4, 4, 40.0),

            // S3: 128 BPM EDM / Dance tempo
            TestConfig("128bpm_0ms_jitter", 128.0, 128.0, 4, 4, 0.0),
            TestConfig("128bpm_40ms_jitter", 128.0, 128.0, 4, 4, 40.0),

            // S4: Close tempo conforming (115 -> 120 BPM, ~4.3% stretch)
            TestConfig("115to120bpm_0ms_jitter", 115.0, 120.0, 4, 4, 0.0),
            TestConfig("115to120bpm_40ms_jitter", 115.0, 120.0, 4, 4, 40.0),

            // S5: Wide tempo gap (>10%, 100 -> 128 BPM, falls back to plain fade)
            TestConfig("100to128bpm_wide_gap", 100.0, 128.0, 4, 4, 0.0),

            // S6: Meter mismatch (4/4 -> 3/4)
            TestConfig("115bpm_4over4_to_3over4", 115.0, 115.0, 4, 3, 0.0),
        )

        val rows = mutableListOf<BaselineRow>()
        var flamReproducedCount = 0

        for (cfg in testConfigs) {
            val trackA = SyntheticAudioGenerator.generateTrack(
                bpm = cfg.bpmA,
                beatsPerBar = cfg.meterA,
                durationSeconds = 60.0,
                phaseOffsetMs = 0.0,
                seed = 101L,
            )
            val trackB = SyntheticAudioGenerator.generateTrack(
                bpm = cfg.bpmB,
                beatsPerBar = cfg.meterB,
                durationSeconds = 60.0,
                phaseOffsetMs = 0.0,
                seed = 202L,
            )

            val render = CurrentOfflineRenderer.render(
                outgoing = trackA,
                incoming = trackB,
                simulatedClockJitterMs = cfg.jitterMs,
            )

            val metrics = MixMetricEvaluator.evaluate(
                deckA = render.dryOutgoing,
                deckB = render.dryIncoming,
                mixed = render.mixedAudio,
                overlapStartSec = render.overlapStartSec,
                overlapEndSec = render.overlapEndSec,
                sampleRate = render.sampleRate,
                expectedBpmA = cfg.bpmA,
                expectedBpmB = cfg.bpmB,
                beatsPerBar = cfg.meterA,
            )

            if (metrics.doubleKickCount > 0 || metrics.kickPhaseOffsetMedianMs > 30.0) {
                flamReproducedCount++
            }

            rows.add(
                BaselineRow(
                    pairName = cfg.name,
                    bpmA = cfg.bpmA,
                    bpmB = cfg.bpmB,
                    meterA = "${cfg.meterA}/4",
                    meterB = "${cfg.meterB}/4",
                    injectedJitterMs = cfg.jitterMs,
                    planStyle = render.plan.transitionStyle.name,
                    phaseMedianMs = metrics.kickPhaseOffsetMedianMs,
                    phaseP95Ms = metrics.kickPhaseOffsetP95Ms,
                    doubleKicks = metrics.doubleKickCount,
                    midpointDipDb = metrics.midpointDipDb,
                    truePeakDb = metrics.truePeakDb,
                    downbeatBarOffset = metrics.downbeatBarOffsetBeats,
                )
            )
        }

        // Output formatted markdown baseline table to stdout
        println()
        println("====================================================================================================")
        println("VIBRA MUSIC - PHASE 0 TRANSITION ENGINE BASELINE REPORT")
        println("====================================================================================================")
        println(
            String.format(
                "| %-25s | %-7s | %-7s | %-6s | %-12s | %-9s | %-7s | %-9s | %-8s |",
                "Test Pair", "BPM", "Jitter", "Meter", "Plan Style", "Phase Med", "Flams", "Mid Dip", "TruePeak",
            )
        )
        println(
            String.format(
                "|-%-25s-|-%-7s-|-%-7s-|-%-6s-|-%-12s-|-%-9s-|-%-7s-|-%-9s-|-%-8s-|",
                "-".repeat(25), "-".repeat(7), "-".repeat(7), "-".repeat(6),
                "-".repeat(12), "-".repeat(9), "-".repeat(7), "-".repeat(9), "-".repeat(8),
            )
        )

        for (r in rows) {
            println(
                String.format(
                    "| %-25s | %3.0f->%3.0f | %4.0f ms | %-6s | %-12s | %6.1f ms | %7d | %6.2f dB | %5.1f dB |",
                    r.pairName,
                    r.bpmA,
                    r.bpmB,
                    r.injectedJitterMs,
                    "${r.meterA}->${r.meterB}",
                    r.planStyle,
                    r.phaseMedianMs,
                    r.doubleKicks,
                    r.midpointDipDb,
                    r.truePeakDb,
                )
            )
        }
        println("====================================================================================================")
        println()

        // Assertions for Phase 0 Gate:
        // 1. All 12 pairs executed
        assertTrue("All 12 baseline pairs must be evaluated", rows.size == 12)

        // 2. The 'extra off-grid kick / flam' symptom is successfully reproduced whenever clock jitter is injected
        assertTrue(
            "Harness must reproduce double-kick / flam symptom under two-player clock jitter",
            flamReproducedCount >= 3,
        )

        // 3. Wide tempo gap (>10%) avoids beatmatched blend (falls back to DJ_RISE or EQUAL_POWER)
        val wideGapRow = rows.first { it.pairName == "100to128bpm_wide_gap" }
        assertTrue(
            "Wide tempo gap pair must not beatmatch (falls back to DJ_RISE or EQUAL_POWER)",
            wideGapRow.planStyle != "DJ_BLEND",
        )
    }

    private data class TestConfig(
        val name: String,
        val bpmA: Double,
        val bpmB: Double,
        val meterA: Int,
        val meterB: Int,
        val jitterMs: Double,
    )
}
