package com.fortune.vibramusic.data

import android.content.Context
import android.content.SharedPreferences
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.model.UserPlaylist
import com.fortune.vibramusic.data.settings.AppSettings
import com.fortune.vibramusic.playback.mix.MixAutoPlanner
import com.fortune.vibramusic.playback.mix.TransitionPlan
import com.fortune.vibramusic.playback.smart.TrackAnalysis
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.Json
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
    private lateinit var mixPrefs: SharedPreferences
    private lateinit var transitionsFile: File
    private val globalTransitions = mutableMapOf<String, MutableMap<String, String>>()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    val mixUpdates = MutableStateFlow(0L)
    const val UNIVERSAL_KEY = "_universal_"

    data class StoredPlaylist(
        val id: String,
        val title: String,
        val songs: MutableList<Song> = mutableListOf(),
        var mixEnabled: Boolean = false,
        val transitions: MutableMap<String, String> = mutableMapOf(),
    )

    private val playlists = mutableListOf<StoredPlaylist>()

    fun init(context: Context) {
        file = File(context.filesDir, "local_playlists.json")
        mixPrefs = context.getSharedPreferences("playlist_mix_settings", Context.MODE_PRIVATE)
        transitionsFile = File(context.filesDir, "mix_transitions.json")
        load()
        loadGlobalTransitions()
    }

    private fun cleanPlaylistId(playlistId: String): String =
        playlistId.removePrefix("VL").removePrefix("local_").removePrefix("local:playlist:")

    @Synchronized
    private fun loadGlobalTransitions() {
        globalTransitions.clear()
        if (!::transitionsFile.isInitialized || !transitionsFile.exists()) return
        runCatching {
            val root = JSONObject(transitionsFile.readText())
            val keys = root.keys()
            while (keys.hasNext()) {
                val pid = keys.next()
                val inner = root.optJSONObject(pid) ?: continue
                val pairMap = mutableMapOf<String, String>()
                val innerKeys = inner.keys()
                while (innerKeys.hasNext()) {
                    val pairId = innerKeys.next()
                    pairMap[pairId] = inner.getString(pairId)
                }
                globalTransitions[pid] = pairMap
            }
        }
    }

    @Synchronized
    private fun saveGlobalTransitions() {
        if (!::transitionsFile.isInitialized) return
        runCatching {
            val root = JSONObject()
            for ((pid, map) in globalTransitions) {
                val inner = JSONObject()
                for ((pairId, raw) in map) {
                    inner.put(pairId, raw)
                }
                root.put(pid, inner)
            }
            transitionsFile.writeText(root.toString())
        }
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
                val mixEnabled = obj.optBoolean("mixEnabled", false)
                val transObj = obj.optJSONObject("transitions")
                val transMap = mutableMapOf<String, String>()
                if (transObj != null) {
                    val keys = transObj.keys()
                    while (keys.hasNext()) {
                        val k = keys.next()
                        transMap[k] = transObj.getString(k)
                    }
                }
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
                playlists.add(StoredPlaylist(id, title, songList, mixEnabled, transMap))
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
                obj.put("mixEnabled", p.mixEnabled)
                val transObj = JSONObject()
                for ((k, v) in p.transitions) {
                    transObj.put(k, v)
                }
                obj.put("transitions", transObj)
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
    fun savePlaylist(title: String, songs: List<Song>): UserPlaylist {
        val id = UUID.randomUUID().toString().take(8)
        val list = songs.toMutableList()
        val stored = StoredPlaylist(id, title, list)
        playlists.add(0, stored)
        save()
        val count = list.size
        return UserPlaylist(
            playlistId = "local_$id",
            title = title,
            subtitle = "$count " + if (count == 1) "song" else "songs",
            thumbnailUrl = list.firstOrNull()?.thumbnailUrl,
        )
    }

    @Synchronized
    fun addSong(playlistId: String, song: Song): Boolean {
        val cleanId = playlistId.removePrefix("VL").removePrefix("local_")
        val p = playlists.firstOrNull { it.id == cleanId } ?: return false
        if (p.songs.any { it.videoId == song.videoId }) return false
        p.songs.add(song)
        if (p.mixEnabled) {
            reconcileTransitions(playlistId)
        } else {
            save()
        }
        return true
    }

    @Synchronized
    fun removeSong(playlistId: String, videoId: String): Boolean {
        val cleanId = playlistId.removePrefix("VL").removePrefix("local_")
        val p = playlists.firstOrNull { it.id == cleanId } ?: return false
        val removed = p.songs.removeAll { it.videoId == videoId }
        if (removed) {
            if (p.mixEnabled) {
                reconcileTransitions(playlistId)
            } else {
                save()
            }
        }
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
    fun findPlaylistByTitle(query: String): StoredPlaylist? {
        val clean = query.trim().lowercase()
        if (clean.isBlank()) return null
        return playlists.firstOrNull { it.title.trim().lowercase() == clean }
            ?: playlists.firstOrNull { it.title.trim().lowercase().contains(clean) }
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
        val cleanId = cleanPlaylistId(playlistId)
        playlists.removeAll { it.id == cleanId }
        globalTransitions.remove(cleanId)
        if (::mixPrefs.isInitialized) {
            mixPrefs.edit().remove("mix_enabled_$cleanId").apply()
        }
        save()
        saveGlobalTransitions()
    }

    @Synchronized
    fun isMixEnabled(playlistId: String?): Boolean {
        if (!com.fortune.vibramusic.data.settings.AppSettings.songTransitions.value.enabled) return false
        if (playlistId.isNullOrBlank()) return true
        val cleanId = cleanPlaylistId(playlistId)
        val p = playlists.firstOrNull { it.id == cleanId }
        if (p != null) return p.mixEnabled
        if (::mixPrefs.isInitialized && mixPrefs.contains("mix_enabled_$cleanId")) {
            return mixPrefs.getBoolean("mix_enabled_$cleanId", true)
        }
        return true
    }

    @Synchronized
    fun disableAllMix() {
        for (p in playlists) {
            p.mixEnabled = false
        }
        if (::mixPrefs.isInitialized) {
            mixPrefs.edit().clear().apply()
        }
        save()
        mixUpdates.value = System.currentTimeMillis()
    }

    @Synchronized
    fun setMixEnabled(playlistId: String, enabled: Boolean) {
        val cleanId = cleanPlaylistId(playlistId)
        val p = playlists.firstOrNull { it.id == cleanId }
        if (p != null) {
            p.mixEnabled = enabled
            save()
        }
        if (::mixPrefs.isInitialized) {
            mixPrefs.edit().putBoolean("mix_enabled_$cleanId", enabled).apply()
        }
        mixUpdates.value = System.currentTimeMillis()
    }

    @Synchronized
    fun getTransition(playlistId: String, pairId: String): TransitionPlan? {
        val cleanId = cleanPlaylistId(playlistId)
        val raw = playlists.firstOrNull { it.id == cleanId }?.transitions?.get(pairId)
            ?: globalTransitions[cleanId]?.get(pairId)
            ?: globalTransitions[UNIVERSAL_KEY]?.get(pairId)
            ?: return null
        return runCatching { json.decodeFromString<TransitionPlan>(raw) }.getOrNull()
    }

    @Synchronized
    fun getUniversalTransition(pairId: String): TransitionPlan? {
        val raw = globalTransitions[UNIVERSAL_KEY]?.get(pairId) ?: return null
        return runCatching { json.decodeFromString<TransitionPlan>(raw) }.getOrNull()
    }

    @Synchronized
    fun getTransitions(playlistId: String): Map<String, TransitionPlan> {
        val cleanId = cleanPlaylistId(playlistId)
        val map = (playlists.firstOrNull { it.id == cleanId }?.transitions ?: globalTransitions[cleanId]).orEmpty()
        val universal = globalTransitions[UNIVERSAL_KEY].orEmpty()
        val combined = universal + map
        val result = mutableMapOf<String, TransitionPlan>()
        for ((k, raw) in combined) {
            runCatching { json.decodeFromString<TransitionPlan>(raw) }.getOrNull()?.let {
                result[k] = it
            }
        }
        return result
    }

    @Synchronized
    fun saveTransition(playlistId: String, plan: TransitionPlan) {
        val cleanId = cleanPlaylistId(playlistId)
        val raw = json.encodeToString(TransitionPlan.serializer(), plan)
        if (cleanId.isNotBlank()) {
            playlists.firstOrNull { it.id == cleanId }?.let {
                it.transitions[plan.pairId] = raw
                save()
            }
            val map = globalTransitions.getOrPut(cleanId) { mutableMapOf() }
            map[plan.pairId] = raw
        }
        val universalMap = globalTransitions.getOrPut(UNIVERSAL_KEY) { mutableMapOf() }
        universalMap[plan.pairId] = raw
        saveGlobalTransitions()
        mixUpdates.value = System.currentTimeMillis()
    }

    @Synchronized
    fun reconcileTransitions(
        playlistId: String,
        songs: List<Song>? = null,
        analysisProvider: ((Song) -> TrackAnalysis?)? = null,
    ) {
        val cleanId = cleanPlaylistId(playlistId)
        val p = playlists.firstOrNull { it.id == cleanId }
        val targetSongs = songs ?: p?.songs ?: return
        if (targetSongs.size < 2) {
            p?.transitions?.clear()
            globalTransitions.remove(cleanId)
            p?.let { save() }
            saveGlobalTransitions()
            return
        }

        val activePairs = (0 until targetSongs.size - 1).map { i ->
            TransitionPlan.pairIdOf(targetSongs[i].videoId, targetSongs[i + 1].videoId)
        }.toSet()

        val map = p?.transitions ?: globalTransitions.getOrPut(cleanId) { mutableMapOf() }

        // 1. Remove obsolete transitions
        map.keys.retainAll(activePairs)

        // 2. Populate Auto for any new / unconfigured pair
        for (i in 0 until targetSongs.size - 1) {
            val s1 = targetSongs[i]
            val s2 = targetSongs[i + 1]
            val pairId = TransitionPlan.pairIdOf(s1.videoId, s2.videoId)
            if (!map.containsKey(pairId)) {
                val a1 = analysisProvider?.invoke(s1)
                val a2 = analysisProvider?.invoke(s2)
                val plan = MixAutoPlanner.autoPlan(a1, a2, s1.videoId, s2.videoId)
                map[pairId] = json.encodeToString(TransitionPlan.serializer(), plan)
            }
        }
        p?.let { save() }
        saveGlobalTransitions()
        mixUpdates.value = System.currentTimeMillis()
    }

    @Synchronized
    fun clear() {
        if (!::file.isInitialized) return
        playlists.clear()
        save()
    }
}
