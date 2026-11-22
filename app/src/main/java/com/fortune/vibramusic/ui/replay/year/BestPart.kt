package com.fortune.vibramusic.ui.replay.year

import com.fortune.vibramusic.data.lyrics.LyricLine
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * YouTube's "Most replayed" curve for a video: how much each [segmentMs] stretch
 * of it gets replayed, 0..1, start to end.
 */
data class Heatmap(val segmentMs: Long, val intensity: List<Float>) {
    val durationMs: Long get() = segmentMs * intensity.size
}

/** Where a song's best part starts, and what said so. */
data class BestPartStart(val startMs: Long, val source: Source) {
    enum class Source {
        /** The bump in YouTube's "Most replayed" curve. */
        HEATMAP,

        /** The first time the chorus comes round in the synced lyrics. */
        LYRICS,

        /** Neither had anything to say: a fixed point a way into the song. */
        FALLBACK,
    }
}

/**
 * Where a song's best part starts, worked out from what other people do with it
 * and from its words, never from its audio.
 */
object BestPart {

    /** Nothing in a song's opening seconds counts: everyone "replays" the start. */
    const val SKIP_HEAD_MS = 5_000L

    /** A best part needs some song left after it to be a clip at all. */
    const val SKIP_TAIL_MS = 30_000L

    /** Interludes and skits have no best part to skip to. */
    const val MIN_SONG_MS = 60_000L

    /** Fewer markers than this is a video YouTube has too few views on to chart. */
    private const val MIN_MARKERS = 10

    /** How far, as a share, the peak has to stand above the trend around it. */
    private const val MIN_RISE = 0.08f

    /** And at least this much in absolute terms, since curves are 0..1. */
    private const val MIN_LIFT = 0.03f

    /** The smoothing either side of a moment: one hot second shouldn't beat a hot chorus. */
    private const val SMOOTH_HALF_MS = 4_500.0

    /** The trend around a moment is the median of the curve this far either side. */
    private const val TREND_HALF_MS = 45_000.0

    /** A trend this low is treated as this, so a near-silent stretch can't make any bump look huge. */
    private const val TREND_FLOOR = 0.05f

    /** The last resort starts this far in, as a share of the song. */
    private const val FALLBACK_SHARE = 0.30

    /** But never earlier than this, which is past almost every intro. */
    private const val FALLBACK_MIN_MS = 20_000L

    /** The last resort for a song whose length nobody knows. */
    private const val FALLBACK_UNKNOWN_MS = 45_000L

    // The heat curve

    fun parseHeatmap(answer: JsonObject): Heatmap? {
        val entity = findAll(answer, "macroMarkersListEntity")
            .filterIsInstance<JsonObject>()
            .firstOrNull { entity ->
                entity.obj("markersList")?.str("markerType") == "MARKER_TYPE_HEATMAP"
            } ?: return null
        val markers = (entity.obj("markersList")?.get("markers") as? JsonArray)
            ?.mapNotNull { element ->
                val marker = element as? JsonObject ?: return@mapNotNull null
                val start = marker.str("startMillis")?.toLongOrNull() ?: return@mapNotNull null
                val length = marker.str("durationMillis")?.toLongOrNull() ?: return@mapNotNull null
                val heat = marker.str("intensityScoreNormalized")?.toFloatOrNull()
                    ?: return@mapNotNull null
                Triple(start, length, heat.coerceIn(0f, 1f))
            }
            ?.sortedBy { it.first }
            ?: return null
        if (markers.size < MIN_MARKERS) return null
        val segment = markers.map { it.second }.sorted()[markers.size / 2]
        if (segment <= 0) return null
        return Heatmap(segment, markers.map { it.third })
    }

    fun peakMs(heat: Heatmap, durationMs: Long): Long? {
        if (heat.intensity.size < MIN_MARKERS || heat.segmentMs <= 0) return null
        val seg = heat.segmentMs
        val limit = if (durationMs > 0) durationMs - SKIP_TAIL_MS else Long.MAX_VALUE
        val candidates = heat.intensity.indices.filter { i ->
            val at = i * seg
            at >= SKIP_HEAD_MS && at <= limit
        }
        if (candidates.isEmpty()) return null

        val smoothRadius = (SMOOTH_HALF_MS / seg).roundToInt().coerceAtLeast(1)
        val smoothed = FloatArray(heat.intensity.size) { i ->
            val from = (i - smoothRadius).coerceAtLeast(0)
            val to = (i + smoothRadius).coerceAtMost(heat.intensity.lastIndex)
            var sum = 0f
            for (j in from..to) sum += heat.intensity[j]
            sum / (to - from + 1)
        }

        val trendRadius = (TREND_HALF_MS / seg).roundToInt().coerceAtLeast(smoothRadius * 2)
        val window = FloatArray(trendRadius * 2 + 1)
        val trend = FloatArray(heat.intensity.size) { i ->
            val from = (i - trendRadius).coerceAtLeast(0)
            val to = (i + trendRadius).coerceAtMost(heat.intensity.lastIndex)
            val count = to - from + 1
            for (j in from..to) window[j - from] = smoothed[j]
            window.sort(0, count)
            window[count / 2]
        }

        fun rise(i: Int): Float = (smoothed[i] - trend[i]) / trend[i].coerceAtLeast(TREND_FLOOR)

        val peak = candidates.maxByOrNull { rise(it) } ?: return null
        if (rise(peak) < MIN_RISE) return null
        if (smoothed[peak] - trend[peak] < MIN_LIFT) return null

        val floor = rise(peak) * 0.5f
        var start = peak
        while (start - 1 in candidates && rise(start - 1) >= floor) start--
        var jump = start
        for (i in start..peak) {
            if (heat.intensity[i] / trend[i].coerceAtLeast(TREND_FLOOR) - 1f >= floor) {
                jump = i
                break
            }
        }
        return jump * seg
    }

    // The words

    fun chorusMs(lines: List<LyricLine>, durationMs: Long): Long? {
        if (durationMs in 1 until MIN_SONG_MS) return null
        val timed = lines.filter { it.timeMs >= 0 && !it.isGap && it.text.isNotBlank() }
        if (timed.size < 4) return null
        val keys = timed.map { normalize(it.text) }
        val counts = keys.filter { it.length >= 4 }.groupingBy { it }.eachCount()
        val most = counts.values.maxOrNull() ?: return null
        if (most < 2) return null
        val limit = if (durationMs > 0) durationMs - SKIP_TAIL_MS else Long.MAX_VALUE
        val first = keys.indices.firstOrNull { i ->
            counts[keys[i]] == most && timed[i].timeMs >= SKIP_HEAD_MS && timed[i].timeMs <= limit
        } ?: return null
        var start = first
        while (start - 1 >= 0) {
            val count = counts[keys[start - 1]] ?: 0
            if (count < 2 || count < most - 1) break
            if (timed[start - 1].timeMs < SKIP_HEAD_MS || first - start >= 4) break
            start--
        }
        return timed[start].timeMs
    }

    fun snap(targetMs: Long, lineStarts: List<Long>): Long {
        lineStarts
            .filter { it in (targetMs - 4_000)..(targetMs + 1_500) }
            .minByOrNull { abs(it - targetMs) + if (it > targetMs) 1_500 else 0 }
            ?.let { return (it - 250).coerceAtLeast(0) }
        return (targetMs - 1_000).coerceAtLeast(0)
    }

    fun fallbackMs(durationMs: Long): Long = when {
        durationMs <= 0 -> FALLBACK_UNKNOWN_MS
        durationMs < MIN_SONG_MS -> 0L
        else -> maxOf(FALLBACK_MIN_MS, (durationMs * FALLBACK_SHARE).toLong())
            .coerceAtMost(durationMs - SKIP_TAIL_MS)
    }

    fun pick(heat: Heatmap?, lines: List<LyricLine>, durationMs: Long): BestPartStart {
        val lineStarts = lines.filter { it.timeMs >= 0 && !it.isGap }.map { it.timeMs }
        heat?.let { peakMs(it, durationMs) }?.let {
            return BestPartStart(snap(it, lineStarts), BestPartStart.Source.HEATMAP)
        }
        chorusMs(lines, durationMs)?.let {
            return BestPartStart(snap(it, lineStarts), BestPartStart.Source.LYRICS)
        }
        return BestPartStart(fallbackMs(durationMs), BestPartStart.Source.FALLBACK)
    }

    private fun normalize(text: String) = text.lowercase().filter { it.isLetterOrDigit() }

    private fun findAll(element: JsonElement, key: String): List<JsonElement> = buildList {
        fun walk(e: JsonElement) {
            when (e) {
                is JsonObject -> e.forEach { (k, v) -> if (k == key) add(v) else walk(v) }
                is JsonArray -> e.forEach(::walk)
                else -> Unit
            }
        }
        walk(element)
    }

    private fun JsonObject.obj(key: String): JsonObject? = get(key) as? JsonObject

    private fun JsonObject.str(key: String): String? = (get(key) as? JsonPrimitive)?.contentOrNull
}
