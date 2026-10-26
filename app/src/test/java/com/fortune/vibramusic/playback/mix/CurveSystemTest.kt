package com.fortune.vibramusic.playback.mix

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CurveSystemTest {

    @Test
    fun testLinearInterpolation() {
        val pts = listOf(
            Point("a", 0f, 0f, CurveType.LINEAR),
            Point("b", 1f, 1f, CurveType.LINEAR),
        )
        val v = Curves.evaluate(pts, 0.25f)
        assertEquals(0.25f, v, 0.001f)
    }

    @Test
    fun testInstantStepContinuity() {
        val pts = listOf(
            Point("a", 0f, 1f, CurveType.LINEAR),
            Point("b", 0.5f, 1f, CurveType.LINEAR),
            Point("c", 0.5f, 0f, CurveType.LINEAR),
            Point("d", 1f, 0f, CurveType.LINEAR),
        )
        assertEquals(1f, Curves.evaluate(pts, 0.49f), 0.001f)
        assertEquals(0f, Curves.evaluate(pts, 0.5f), 0.001f)
        assertEquals(0f, Curves.evaluate(pts, 0.51f), 0.001f)
    }

    @Test
    fun testSmoothSegmentsNeverOvershoot() {
        val pts = listOf(
            Point("a", 0f, 0f, CurveType.SMOOTH),
            Point("b", 1f, 1f, CurveType.LINEAR),
        )
        var t = 0f
        while (t <= 1.0f) {
            val v = Curves.evaluate(pts, t)
            assertTrue(v in 0f..1f)
            t += 0.02f
        }
    }

    @Test
    fun testAddPointOnLinePreservesShape() {
        val base = listOf(
            Point("a", 0f, 1f, CurveType.LINEAR),
            Point("b", 1f, 0f, CurveType.LINEAR),
        )
        val next = Curves.addPointOnLine(base, 0.5f)
        assertEquals(3, next.size)
        assertEquals(0.7f, Curves.evaluate(next, 0.3f), 0.001f)
        assertEquals(Curves.evaluate(base, 0.3f), Curves.evaluate(next, 0.3f), 0.001f)
    }

    @Test
    fun testMovePointPinsEdgePoints() {
        val base = listOf(
            Point("a", 0f, 1f, CurveType.LINEAR),
            Point("b", 1f, 0f, CurveType.LINEAR),
        )
        val moved = Curves.movePoint(base, "a", 0.4f, 0.2f)
        assertEquals(0f, moved[0].t, 0.001f)
        assertEquals(0.2f, moved[0].v, 0.001f)
    }

    @Test
    fun testRemovePointRefusesEdgePoints() {
        val base = listOf(
            Point("a", 0f, 1f, CurveType.LINEAR),
            Point("b", 0.5f, 0.5f, CurveType.LINEAR),
            Point("c", 1f, 0f, CurveType.LINEAR),
        )
        // Trying to remove edge point 'a' should do nothing
        val afterEdge = Curves.removePoint(base, "a")
        assertEquals(3, afterEdge.size)

        // Removing interior point 'b' works
        val afterInterior = Curves.removePoint(base, "b")
        assertEquals(2, afterInterior.size)
        assertEquals("a", afterInterior[0].id)
        assertEquals("c", afterInterior[1].id)
    }

    @Test
    fun testPointLimitCap() {
        var pts = listOf(
            Point("a", 0f, 1f, CurveType.LINEAR),
            Point("b", 1f, 0f, CurveType.LINEAR),
        )
        for (i in 0 until 100) {
            pts = Curves.addPointOnLine(pts, (i + 1) / 101f)
        }
        assertTrue(pts.size <= Curves.MAX_POINTS)
    }

    @Test
    fun testSnapT() {
        val grid = listOf(0.0f, 0.25f, 0.5f, 0.75f, 1.0f)
        assertEquals(0.25f, Curves.snapT(0.255f, grid, tolerance = 0.02f), 0.001f)
        // Outside tolerance keeps original
        assertEquals(0.35f, Curves.snapT(0.35f, grid, tolerance = 0.02f), 0.001f)
    }
}
