package com.fortune.vibramusic.data.lyrics

import android.content.Context
import java.io.File

/**
 * Local storage for user-edited or imported lyrics.
 *
 * Stored per video ID or track key as plain/synced LRC files on disk so they
 * persist across sessions, take precedence over network providers, and never
 * get overwritten by third-party metadata updates.
 */
object CustomLyricsStore {
    private lateinit var dir: File

    fun init(context: Context) {
        dir = File(context.filesDir, "custom_lyrics").apply { mkdirs() }
    }

    fun has(videoId: String): Boolean {
        if (!::dir.isInitialized) return false
        val file = File(dir, "$videoId.lrc")
        return file.exists() && file.length() > 0
    }

    fun get(videoId: String): List<LyricLine>? {
        if (!::dir.isInitialized) return null
        val file = File(dir, "$videoId.lrc")
        if (!file.exists()) return null
        val text = runCatching { file.readText() }.getOrNull() ?: return null
        if (text.isBlank()) return null
        val parsed = LrcLib.parseLrc(text)
        if (parsed.isNotEmpty()) return parsed
        return text.lines()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .map { LyricLine(0L, it) }
    }

    fun getRaw(videoId: String): String? {
        if (!::dir.isInitialized) return null
        val file = File(dir, "$videoId.lrc")
        if (!file.exists()) return null
        return runCatching { file.readText() }.getOrNull()
    }

    fun save(videoId: String, rawText: String): List<LyricLine> {
        if (!::dir.isInitialized) return emptyList()
        val file = File(dir, "$videoId.lrc")
        file.writeText(rawText.trim())
        val parsed = LrcLib.parseLrc(rawText)
        if (parsed.isNotEmpty()) return parsed
        return rawText.lines()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .map { LyricLine(0L, it) }
    }

    fun clear(videoId: String) {
        if (!::dir.isInitialized) return
        val file = File(dir, "$videoId.lrc")
        if (file.exists()) file.delete()
    }
}
