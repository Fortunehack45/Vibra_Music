package com.fortune.vibramusic.playback.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class AutomationCurveTest {

    @Test
    fun linearFadeCalculationsAreAccurate() {
        val fadeOut = AutomationCurve.linearFadeOut()
        val fadeIn = AutomationCurve.linearFadeIn()

        assertEquals(1.0f, fadeOut.evaluate(0.0f), 0.0001f)
        assertEquals(0.5f, fadeOut.evaluate(0.5f), 0.0001f)
        assertEquals(0.0f, fadeOut.evaluate(1.0f), 0.0001f)

        assertEquals(0.0f, fadeIn.evaluate(0.0f), 0.0001f)
        assertEquals(0.5f, fadeIn.evaluate(0.5f), 0.0001f)
        assertEquals(1.0f, fadeIn.evaluate(1.0f), 0.0001f)
    }

    @Test
    fun equalPowerFadeCurvesMaintainConstantEnergy() {
        val fadeOut = AutomationCurve.equalPowerFadeOut()
        val fadeIn = AutomationCurve.equalPowerFadeIn()

        val samplePoints = listOf(0.0f, 0.25f, 0.5f, 0.75f, 1.0f)
        for (t in samplePoints) {
            val outGain = fadeOut.evaluate(t)
            val inGain = fadeIn.evaluate(t)
            val sumOfSquares = (outGain * outGain) + (inGain * inGain)
            // Equal-power sum of squares should remain 1.0 across the blend
            assertEquals("Equal-power power sum at t=$t should equal 1.0", 1.0f, sumOfSquares, 0.001f)
        }
    }

    @Test
    fun sCurveProvidesSmoothTransitions() {
        val sCurve = AutomationCurve(
            parameterId = "test_s",
            points = listOf(CurvePoint(0f, 0f), CurvePoint(1f, 1f)),
            interpolation = CurveInterpolation.S_CURVE,
        )

        assertEquals(0.0f, sCurve.evaluate(0.0f), 0.0001f)
        assertEquals(0.5f, sCurve.evaluate(0.5f), 0.0001f)
        assertEquals(1.0f, sCurve.evaluate(1.0f), 0.0001f)

        // At t=0.25, 3*(0.25^2) - 2*(0.25^3) = 3*0.0625 - 2*0.015625 = 0.1875 - 0.03125 = 0.15625
        assertEquals(0.15625f, sCurve.evaluate(0.25f), 0.0001f)
    }

    @Test
    fun exponentialCurveProvidesLogarithmicProgression() {
        val expCurve = AutomationCurve(
            parameterId = "cutoff_hz",
            points = listOf(CurvePoint(0f, 100f), CurvePoint(1f, 10000f)),
            interpolation = CurveInterpolation.EXPONENTIAL,
            minValue = 20f,
            maxValue = 20000f,
        )

        assertEquals(100f, expCurve.evaluate(0f), 0.1f)
        assertEquals(1000f, expCurve.evaluate(0.5f), 1.0f)
        assertEquals(10000f, expCurve.evaluate(1f), 0.1f)
    }

    @Test
    fun stepCurveMaintainsPreviousValueUntilStep() {
        val step = AutomationCurve(
            parameterId = "step_param",
            points = listOf(CurvePoint(0f, 10f), CurvePoint(0.5f, 20f), CurvePoint(1f, 30f)),
            interpolation = CurveInterpolation.STEP,
            minValue = 0f,
            maxValue = 50f,
        )

        assertEquals(10f, step.evaluate(0.0f), 0.0001f)
        assertEquals(10f, step.evaluate(0.25f), 0.0001f)
        assertEquals(20f, step.evaluate(0.5f), 0.0001f)
        assertEquals(20f, step.evaluate(0.75f), 0.0001f)
        assertEquals(30f, step.evaluate(1.0f), 0.0001f)
    }

    @Test
    fun evaluationClampsToConfiguredBounds() {
        val curve = AutomationCurve(
            parameterId = "clamped",
            points = listOf(CurvePoint(0f, -5f), CurvePoint(1f, 15f)),
            interpolation = CurveInterpolation.LINEAR,
            minValue = 0f,
            maxValue = 10f,
        )

        assertEquals(0f, curve.evaluate(0f), 0.0001f)
        assertEquals(10f, curve.evaluate(1f), 0.0001f)
    }

    @Test
    fun handlesEdgeCasesGracefully() {
        val emptyCurve = AutomationCurve("empty", emptyList(), minValue = 0.2f, maxValue = 0.8f)
        assertEquals(0.2f, emptyCurve.evaluate(0.5f), 0.0001f)

        val singlePoint = AutomationCurve("single", listOf(CurvePoint(0.5f, 0.7f)))
        assertEquals(0.7f, singlePoint.evaluate(0.0f), 0.0001f)
        assertEquals(0.7f, singlePoint.evaluate(1.0f), 0.0001f)

        // Clamping out-of-range timeline positions
        val standard = AutomationCurve.linearFadeOut()
        assertEquals(1.0f, standard.evaluate(-0.5f), 0.0001f)
        assertEquals(0.0f, standard.evaluate(1.5f), 0.0001f)
    }

    @Test
    fun unsortedPointsAreProperlyOrdered() {
        val unsorted = AutomationCurve(
            parameterId = "unsorted",
            points = listOf(CurvePoint(1.0f, 0.0f), CurvePoint(0.0f, 1.0f)),
            interpolation = CurveInterpolation.LINEAR,
        )

        assertEquals(1.0f, unsorted.evaluate(0.0f), 0.0001f)
        assertEquals(0.5f, unsorted.evaluate(0.5f), 0.0001f)
        assertEquals(0.0f, unsorted.evaluate(1.0f), 0.0001f)
    }
}
