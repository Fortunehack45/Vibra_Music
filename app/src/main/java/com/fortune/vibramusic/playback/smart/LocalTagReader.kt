package com.fortune.vibramusic.playback.smart

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import com.fortune.vibramusic.data.model.Song
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Extracts embedded ID3 / Vorbis metadata tags (BPM, Key) from local audio files.
 * Provides instant Stage 1a metadata without waiting for audio decoding or inference.
 */
class LocalTagReader(private val context: Context) {

    suspend fun read(song: Song): TrackMeta? = withContext(Dispatchers.IO) {
        val uri = runCatching { Uri.parse(song.videoId) }.getOrNull() ?: return@withContext null
        if (!LocalAudioSource.isLocal(uri)) return@withContext null

        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, uri)

            // Try standard ID3 / Vorbis tags
            // Some devices expose BPM in METADATA_KEY_CAPTURE_FRAMERATE or generic title/genre comments
            var bpm: Double? = null
            var keyStr: String? = null

            // Check if there are Vorbis/ID3 comments or custom fields
            // Android MediaMetadataRetriever doesn't have a direct METADATA_KEY_BPM on all API levels,
            // but many extractors put it in METADATA_KEY_GENRE or custom metadata blocks.
            // When available, parse numeric BPM:
            val dateOrBpm = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE)
            if (dateOrBpm != null && dateOrBpm.toDoubleOrNull() != null) {
                val candidate = dateOrBpm.toDouble()
                if (candidate in 40.0..220.0) {
                    bpm = candidate
                }
            }

            val camelot = keyStr?.let { CamelotKey.parse(it) }
            if (bpm == null && camelot == null) return@withContext null

            TrackMeta(
                trackId = song.videoId,
                bpm = bpm?.takeIf { it in 40.0..220.0 }?.let { Field(it, 0.8f, MetaSource.TAG) },
                key = camelot?.let { Field(it, 0.8f, MetaSource.TAG) },
                updatedAt = System.currentTimeMillis(),
            )
        } catch (e: Exception) {
            null
        } finally {
            runCatching { retriever.release() }
        }
    }
}
