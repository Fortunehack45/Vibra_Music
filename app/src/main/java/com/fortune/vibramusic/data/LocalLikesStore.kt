package com.fortune.vibramusic.data

import android.content.Context
import android.content.SharedPreferences
import com.fortune.vibramusic.data.model.LikeStatus
import com.fortune.vibramusic.data.model.Song
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Persists favorites (liked songs) locally when the user is not signed in
 * with a YouTube Music account.
 */
object LocalLikesStore {
    private const val PREFS_NAME = "local_likes"
    private const val KEY_LIKED_IDS = "liked_video_ids"
    private lateinit var prefs: SharedPreferences
    private lateinit var file: File
    private val songs = mutableListOf<Song>()

    fun init(context: Context) {
        prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        file = File(context.filesDir, "local_likes.json")
        loadSongs()
    }

    @Synchronized
    private fun loadSongs() {
        songs.clear()
        if (!::file.isInitialized || !file.exists()) return
        runCatching {
            val jsonStr = file.readText()
            val array = JSONArray(jsonStr)
            for (i in 0 until array.length()) {
                val sObj = array.getJSONObject(i)
                songs.add(
                    Song(
                        videoId = sObj.getString("videoId"),
                        title = sObj.getString("title"),
                        artist = sObj.optString("artist", ""),
                        thumbnailUrl = sObj.optString("thumbnailUrl").takeIf { it.isNotBlank() },
                        durationText = sObj.optString("durationText").takeIf { it.isNotBlank() },
                        albumName = sObj.optString("albumName").takeIf { it.isNotBlank() },
                    )
                )
            }
        }
    }

    @Synchronized
    private fun saveSongs() {
        if (!::file.isInitialized) return
        runCatching {
            val array = JSONArray()
            for (s in songs) {
                val sObj = JSONObject()
                sObj.put("videoId", s.videoId)
                sObj.put("title", s.title)
                sObj.put("artist", s.artist)
                sObj.put("thumbnailUrl", s.thumbnailUrl ?: "")
                sObj.put("durationText", s.durationText ?: "")
                sObj.put("albumName", s.albumName ?: "")
                array.put(sObj)
            }
            file.writeText(array.toString())
        }
    }

    fun getLikedIds(): Set<String> {
        if (!::prefs.isInitialized) return emptySet()
        return prefs.getStringSet(KEY_LIKED_IDS, emptySet())?.toSet() ?: emptySet()
    }

    @Synchronized
    fun getLikedSongs(): List<Song> = songs.toList()

    @Synchronized
    fun set(videoId: String, status: LikeStatus, song: Song? = null) {
        if (!::prefs.isInitialized) return
        val current = getLikedIds().toMutableSet()
        if (status == LikeStatus.LIKE) {
            current.add(videoId)
            if (song != null && songs.none { it.videoId == videoId }) {
                songs.add(0, song)
                saveSongs()
            }
        } else {
            current.remove(videoId)
            if (songs.removeAll { it.videoId == videoId }) {
                saveSongs()
            }
        }
        prefs.edit().putStringSet(KEY_LIKED_IDS, current).apply()
    }

    fun isLiked(videoId: String): Boolean = videoId in getLikedIds()
}
