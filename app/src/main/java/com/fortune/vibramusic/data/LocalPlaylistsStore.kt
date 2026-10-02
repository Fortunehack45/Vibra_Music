package com.fortune.vibramusic.data

import android.content.Context
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.model.UserPlaylist
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * Persists user-created playlists locally on device so users can create,
 * populate, and play playlists without requiring a YouTube Music account sign-in.
 */
object LocalPlaylistsStore {
    private lateinit var file: File

    data class StoredPlaylist(
        val id: String,
        val title: String,
        val songs: MutableList<Song> = mutableListOf(),
    )

    private val playlists = mutableListOf<StoredPlaylist>()

    fun init(context: Context) {
        file = File(context.filesDir, "local_playlists.json")
        load()
    }

    @Synchronized
    private fun load() {
        playlists.clear()
        if (!::file.isInitialized || !file.exists()) return
        runCatching {
            val jsonStr = file.readText()
            val array = JSONArray(jsonStr)
            for (i in 0 until array.length()) {
                val obj = array.getJSONObject(i)
                val id = obj.getString("id")
                val title = obj.getString("title")
                val songsArray = obj.optJSONArray("songs") ?: JSONArray()
                val songList = mutableListOf<Song>()
                for (j in 0 until songsArray.length()) {
                    val sObj = songsArray.getJSONObject(j)
                    songList.add(
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
                playlists.add(StoredPlaylist(id, title, songList))
            }
        }
    }

    @Synchronized
    private fun save() {
        if (!::file.isInitialized) return
        runCatching {
            val array = JSONArray()
            for (p in playlists) {
                val obj = JSONObject()
                obj.put("id", p.id)
                obj.put("title", p.title)
                val songsArray = JSONArray()
                for (s in p.songs) {
                    val sObj = JSONObject()
                    sObj.put("videoId", s.videoId)
                    sObj.put("title", s.title)
                    sObj.put("artist", s.artist)
                    sObj.put("thumbnailUrl", s.thumbnailUrl ?: "")
                    sObj.put("durationText", s.durationText ?: "")
                    sObj.put("albumName", s.albumName ?: "")
                    songsArray.put(sObj)
                }
                obj.put("songs", songsArray)
                array.put(obj)
            }
            file.writeText(array.toString())
        }
    }

    @Synchronized
    fun getPlaylists(): List<UserPlaylist> {
        return playlists.map { p ->
            val sub = "${p.songs.size} " + if (p.songs.size == 1) "song" else "songs"
            UserPlaylist(
                playlistId = "local_${p.id}",
                title = p.title,
                subtitle = sub,
                thumbnailUrl = p.songs.firstOrNull()?.thumbnailUrl,
            )
        }
    }

    @Synchronized
    fun createPlaylist(title: String, initialSong: Song?): UserPlaylist {
        val id = UUID.randomUUID().toString().take(8)
        val list = mutableListOf<Song>()
        if (initialSong != null) list.add(initialSong)
        val stored = StoredPlaylist(id, title, list)
        playlists.add(0, stored)
        save()
        val count = list.size
        return UserPlaylist(
            playlistId = "local_$id",
            title = title,
            subtitle = "$count " + if (count == 1) "song" else "songs",
            thumbnailUrl = initialSong?.thumbnailUrl,
        )
    }

    @Synchronized
    fun addSong(playlistId: String, song: Song): Boolean {
        val cleanId = playlistId.removePrefix("VL").removePrefix("local_")
        val p = playlists.firstOrNull { it.id == cleanId } ?: return false
        if (p.songs.any { it.videoId == song.videoId }) return false
        p.songs.add(song)
        save()
        return true
    }

    @Synchronized
    fun removeSong(playlistId: String, videoId: String): Boolean {
        val cleanId = playlistId.removePrefix("VL").removePrefix("local_")
        val p = playlists.firstOrNull { it.id == cleanId } ?: return false
        val removed = p.songs.removeAll { it.videoId == videoId }
        if (removed) save()
        return removed
    }

    @Synchronized
    fun getSongs(playlistId: String): List<Song> {
        val cleanId = playlistId.removePrefix("VL").removePrefix("local_")
        return playlists.firstOrNull { it.id == cleanId }?.songs?.toList().orEmpty()
    }

    @Synchronized
    fun getPlaylist(playlistId: String): StoredPlaylist? {
        val cleanId = playlistId.removePrefix("VL").removePrefix("local_")
        return playlists.firstOrNull { it.id == cleanId }
    }

    @Synchronized
    fun renamePlaylist(playlistId: String, title: String) {
        val cleanId = playlistId.removePrefix("VL").removePrefix("local_")
        val p = playlists.firstOrNull { it.id == cleanId } ?: return
        val index = playlists.indexOf(p)
        playlists[index] = p.copy(title = title)
        save()
    }

    @Synchronized
    fun deletePlaylist(playlistId: String) {
        val cleanId = playlistId.removePrefix("VL").removePrefix("local_")
        playlists.removeAll { it.id == cleanId }
        save()
    }
}
