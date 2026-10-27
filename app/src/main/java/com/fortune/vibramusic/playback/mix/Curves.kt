package com.fortune.vibramusic.playback.mix

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random

/**
 * Mathematical evaluation and manipulation operations for automation curves.
 */
object Curves {
    const val MAX_POINTS: Int = 64

    private var pointCounter: Long = 0L

    fun clamp01(x: Float): Float = max(0f, min(1f, x))

    /**
     * Hermite smoothstep polynomial without overshoot in range [0, 1].
     */
    fun smoothstep(u: Float): Float {
        val clamped = clamp01(u)
        return clamped * clamped * (3f - 2f * clamped)
    }

    /**
     * Generates a stable unique point identifier.
     */
    fun newPointId(): String {
        val count = pointCounter++
        val rand = Random.nextInt(1000, 9999)
        return "pt_${count}_$rand"
    }

    /**
     * Stably sorts points by normalized time [t]. Equal-t points retain their relative order.
     */
    fun sortPoints(points: List<Point>): List<Point> =
        points.sortedWith(compareBy<Point> { it.t })

    /**
     * Evaluates the automation curve at time [t] in range [0.0, 1.0].
     *
     * Points must be sorted by [t]. If two adjacent points share the exact same [t],
     * evaluation is right-continuous (the second point's value applies instantly at [t]),
     * enabling precise vertical cuts and instantaneous parameter swaps without interpolation latency.
     */
    fun evaluate(points: List<Point>, t: Float): Float {
        val n = points.size
        if (n == 0) return 0f
        if (n == 1) return points[0].v

        val clampedT = clamp01(t)
        if (clampedT <= points[0].t) return points[0].v
        if (clampedT >= points[n - 1].t) return points[n - 1].v

        var i = 0
        for (k in 0 until n - 1) {
            if (points[k].t <= clampedT) {
                i = k
            } else {
                break
            }
        }

        val a = points[i]
        val b = points[i + 1]

        if (b.t == a.t) {
            return b.v
        }

        val u = (clampedT - a.t) / (b.t - a.t)
        val w = if (a.curve == CurveType.SMOOTH) smoothstep(u) else u
        return a.v + (b.v - a.v) * w
    }

    /**
     * Pre-samples a curve into a FloatArray of size [sampleCount], optionally applying [map].
     */
    fun sampleCurve(
        points: List<Point>,
        sampleCount: Int,
        map: (Float) -> Float = { it },
    ): FloatArray {
        require(sampleCount > 1) { "sampleCount must be greater than 1" }
        val out = FloatArray(sampleCount)
        val sorted = sortPoints(points)
        val denom = (sampleCount - 1).toFloat()
        for (i in 0 until sampleCount) {
            val t = i.toFloat() / denom
            out[i] = map(evaluate(sorted, t))
        }
        return out
    }

    /**
     * Taps on a line: inserts a point directly on the existing curve so curve geometry
     * remains unchanged until the user drags the newly created point.
     */
    fun addPointOnLine(points: List<Point>, t: Float): List<Point> {
        if (points.size >= MAX_POINTS) return points
        val sorted = sortPoints(points)
        val clampedT = t.coerceIn(0.015f, 0.985f)
        val v = evaluate(sorted, clampedT)
        val owner = sorted.lastOrNull { it.t <= clampedT }
        val p = Point(
            id = newPointId(),
            t = clampedT,
            v = clamp01(v),
            curve = owner?.curve ?: CurveType.LINEAR,
        )
        return sortPoints(points + p)
    }

    /**
     * Drags a point in both time [t] and value [v] axes.
     * Boundary points at index 0 and last index have their [t] pinned to 0.0 and 1.0 respectively.
     * Re-sorts points stably if dragged past neighboring points.
     */
    fun movePoint(points: List<Point>, id: String, t: Float, v: Float): List<Point> {
        val sorted = sortPoints(points)
        val idx = sorted.indexOfFirst { it.id == id }
        if (idx < 0) return points

        val isStartBoundary = sorted.firstOrNull()?.let { it.id == id && it.t == 0f } ?: false
        val isEndBoundary = sorted.lastOrNull()?.let { it.id == id && it.t == 1f } ?: false

        val targetT = when {
            isStartBoundary -> 0f
            isEndBoundary -> 1f
            else -> t.coerceIn(0.015f, 0.985f)
        }
        val targetV = clamp01(v)

        val updated = sorted.map { p ->
            if (p.id == id) p.copy(t = targetT, v = targetV) else p
        }
        return sortPoints(updated)
    }

    /**
     * Removes an interior point. Boundary points at t = 0 and t = 1 can never be deleted.
     */
    fun removePoint(points: List<Point>, id: String): List<Point> {
        val sorted = sortPoints(points)
        val idx = sorted.indexOfFirst { it.id == id }
        if (idx <= 0 || idx >= sorted.size - 1) return points
        return sorted.filter { it.id != id }
    }

    /**
     * Snaps a normalized time [t] to the closest beat grid position if within [tolerance].
     */
    fun snapT(t: Float, gridT: List<Float>, tolerance: Float = 0.018f): Float {
        var best = t
        var bestD = tolerance
        for (g in gridT) {
            val d = abs(g - t)
            if (d < bestD) {
                best = g
                bestD = d
            }
        }
        return best
    }

    /**
     * Calculates the minimum pixel distance between a touch point (px, py) and the curve,
     * returning the distance and corresponding time t.
     */
    fun distanceToCurvePx(
        points: List<Point>,
        widthPx: Float,
        heightPx: Float,
        px: Float,
        py: Float,
        steps: Int = 120,
    ): Pair<Float, Float> {
        val sorted = sortPoints(points)
        var bestDist = Float.MAX_VALUE
        var bestT = 0f

        val stepT = 1f / steps.toFloat()
        for (i in 0..steps) {
            val t = i * stepT
            val v = evaluate(sorted, t)
            val x = t * widthPx
            val y = (1f - v) * heightPx
            val dx = px - x
            val dy = py - y
            val dist = kotlin.math.sqrt(dx * dx + dy * dy)
            if (dist < bestDist) {
                bestDist = dist
                bestT = t
            }
        }
        return Pair(bestDist, bestT)
    }
}
