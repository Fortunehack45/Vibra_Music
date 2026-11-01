package com.fortune.vibramusic.playback.smart

import android.net.Uri
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.model.durationMillis
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.PriorityBlockingQueue
import java.util.concurrent.atomic.AtomicLong

enum class MetaPriority { VISIBLE, UP_NEXT, PLAYLIST, LIBRARY }

private data class Job(val song: Song, val priority: MetaPriority, val seq: Long) : Comparable<Job> {
    override fun compareTo(other: Job): Int =
        compareValuesBy(this, other, { it.priority.ordinal }, { it.seq })
}

/**
 * Prioritized scheduler for asynchronous metadata analysis.
 * Ensures visible screen items and upcoming queue songs are resolved within seconds,
 * while respecting battery, data, and thermal limits (max 2 parallel workers).
 */
class MetaScheduler(
    private val scope: CoroutineScope,
    private val analyzer: TrackAnalyzer,
    private val tags: LocalTagReader,
    private val shared: SharedMetaClient,
    private val dao: TrackMetaDao,
    private val maxParallel: Int = 2,
) {
    private val queue = PriorityBlockingQueue<Job>()
    private val inFlight = ConcurrentHashMap.newKeySet<String>()
    private val seq = AtomicLong()

    init {
        repeat(maxParallel) {
            scope.launch(Dispatchers.IO) { worker() }
        }
    }

    /** Called when any playlist, album, or queue opens. Non-blocking. */
    fun prefetch(songs: List<Song>, priority: MetaPriority) {
        if (songs.isEmpty()) return
        scope.launch(Dispatchers.IO) {
            val missing = songs.filter { TrackMetaRepository.peek(it.videoId)?.complete != true }
            if (missing.isEmpty()) return@launch

            // Stage 1b: ONE batched request for the entire missing set
            val sharedResults = shared.lookup(missing.map { it.videoId })
            sharedResults.forEach { TrackMetaRepository.ingest(it, dao) }

            // Stage 1a and Stage 2: Enqueue whatever is still missing
            missing.filter { TrackMetaRepository.peek(it.videoId)?.complete != true }
                .forEach { enqueue(it, priority) }
        }
    }

    fun enqueue(song: Song, priority: MetaPriority) {
        if (inFlight.add(song.videoId)) {
            queue.add(Job(song, priority, seq.incrementAndGet()))
        }
    }

    /** Move songs to the front of the line when the user scrolls to them. */
    fun prioritize(ids: Collection<String>, songsById: Map<String, Song>) {
        ids.mapNotNull { songsById[it] }.forEach { song ->
            if (queue.removeIf { it.song.videoId == song.videoId }) {
                queue.add(Job(song, MetaPriority.VISIBLE, seq.incrementAndGet()))
            } else {
                enqueue(song, MetaPriority.VISIBLE)
            }
        }
    }

    private suspend fun worker() {
        while (true) {
            val job = withContext(Dispatchers.IO) { queue.take() }
            try {
                resolveOne(job.song)
            } catch (_: Exception) {
            } finally {
                inFlight.remove(job.song.videoId)
            }
        }
    }

    private suspend fun resolveOne(song: Song) {
        // Stage 1a: local tags (only for local audio files)
        tags.read(song)?.let { TrackMetaRepository.ingest(it, dao) }
        if (TrackMetaRepository.peek(song.videoId)?.complete == true) return

        // Stage 2: on-device audio analysis
        val durSec = (song.durationMillis() / 1000.0).takeIf { it > 10.0 } ?: 0.0
        val uri = if (LocalAudioSource.isLocal(runCatching { Uri.parse(song.videoId) }.getOrNull() ?: Uri.EMPTY)) {
            Uri.parse(song.videoId)
        } else {
            Uri.parse(AutomixAnalysisSource.opusUri(song.videoId))
        }
        analyzer.request(song.videoId, uri, durSec)
    }
}
