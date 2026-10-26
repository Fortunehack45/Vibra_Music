package com.fortune.vibramusic.playback.mix

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MixOptionsAndPresetsTest {

    @Test
    fun testAllVolumeOptionsProduceValidPoints() {
        for (opt in MixOptions.volumeOptions) {
            val res = opt.build(4)
            assertTrue(res.out.isNotEmpty())
            assertTrue(res.`in`.isNotEmpty())
            assertTrue(res.out.first().t == 0f && res.out.last().t == 1f)
            assertTrue(res.`in`.first().t == 0f && res.`in`.last().t == 1f)
        }
    }

    @Test
    fun testAllEqOptionsProduceValidBands() {
        for (opt in MixOptions.eqOptions) {
            val res = opt.build(4)
            assertTrue(res.out.low.isNotEmpty())
            assertTrue(res.out.mid.isNotEmpty())
            assertTrue(res.out.high.isNotEmpty())
            assertTrue(res.`in`.low.isNotEmpty())
            assertTrue(res.`in`.mid.isNotEmpty())
            assertTrue(res.`in`.high.isNotEmpty())
        }
    }

    @Test
    fun testApplyPresetAndValidation() {
        val base = TransitionPlan.createEmpty("track1", "track2")
        val rise = MixPresets.find("rise")
        val plan = TransitionPlan.applyPreset(base, rise)

        assertEquals(TransitionMode.PRESET, plan.mode)
        assertEquals("rise", plan.presetId)
        assertEquals(4, plan.lengthBars)
        assertEquals("fade-in-cut-out", plan.volume.option)
        assertEquals("center-bass-swap", plan.eq.option)
        assertEquals("hpf-in", plan.filter.option)

        val errors = TransitionPlan.validatePlan(plan)
        assertTrue(errors.isEmpty())
    }

    @Test
    fun testBassSwapLowEnergyNoClash() {
        val swap = MixOptions.findEqOption("center-bass-swap").build(4)
        // At t = 0.49: out low is 1, in low is 0 -> sum = 1
        val outLowBefore = Curves.evaluate(swap.out.low, 0.49f)
        val inLowBefore = Curves.evaluate(swap.`in`.low, 0.49f)
        assertEquals(1f, outLowBefore + inLowBefore, 0.01f)

        // At t = 0.51: out low is 0, in low is 1 -> sum = 1
        val outLowAfter = Curves.evaluate(swap.out.low, 0.51f)
        val inLowAfter = Curves.evaluate(swap.`in`.low, 0.51f)
        assertEquals(1f, outLowAfter + inLowAfter, 0.01f)
    }
}
