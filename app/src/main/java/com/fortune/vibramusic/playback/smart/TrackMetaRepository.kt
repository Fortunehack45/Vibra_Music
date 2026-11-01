package com.fortune.vibramusic.playback.smart

import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.abs

/**
 * In-memory thread-safe store backed by SQLite persistence.
 * Guarantees 0ms synchronous read access from UI composition without jank.
 */
object TrackMetaRepository {
    private val cache = ConcurrentHashMap<String, TrackMeta>()
    private val _updates = MutableSharedFlow<String>(
        extraBufferCapacity = 512,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val updates: SharedFlow<String> = _updates.asSharedFlow()

    /** Synchronous, no I/O: safe to call from composition. */
    fun peek(trackId: String): TrackMeta? = cache[trackId]

    /** Call once from Application.onCreate on a background dispatcher, before the first screen. */
    suspend fun loadAll(dao: TrackMetaDao) {
        dao.all().forEach { cache[it.trackId] = it }
    }

    suspend fun ingest(incoming: TrackMeta, dao: TrackMetaDao) {
        val merged = merge(cache[incoming.trackId], incoming)
        if (merged == cache[incoming.trackId]) return
        cache[incoming.trackId] = merged
        dao.upsert(merged)                     // off the main thread
        _updates.tryEmit(incoming.trackId)
    }

    private fun merge(old: TrackMeta?, new: TrackMeta): TrackMeta = TrackMeta(
        trackId = new.trackId,
        bpm = mergeField(old?.bpm, new.bpm) { a, b -> sameTempo(a, b) },
        key = mergeField(old?.key, new.key) { a, b -> a == b },
        analyzerVersion = maxOf(old?.analyzerVersion ?: 0, new.analyzerVersion),
        updatedAt = System.currentTimeMillis(),
    )

    /** Same tempo within 2%, or exactly half/double (octave error is not a real disagreement). */
    fun sameTempo(a: Double, b: Double): Boolean {
        if (a <= 0.0 || b <= 0.0) return false
        val r = a / b
        return listOf(1.0, 2.0, 0.5).any { abs(r / it - 1.0) < 0.02 }
    }
}
