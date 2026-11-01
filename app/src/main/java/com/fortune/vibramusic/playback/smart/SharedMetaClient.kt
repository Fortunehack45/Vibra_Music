package com.fortune.vibramusic.playback.smart

import android.util.Log
import com.fortune.vibramusic.data.supabase.PostgrestSanitizer
import com.fortune.vibramusic.data.supabase.SupabaseConfig
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Batched shared cache client for instantaneous cloud metadata lookup.
 * Retrieves verified pre-computed BPM and Camelot keys for streamed tracks.
 */
class SharedMetaClient {

    companion object {
        private const val TAG = "SharedMetaClient"
        private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    }

    private val client by lazy { HttpClient(OkHttp) }

    suspend fun lookup(trackIds: List<String>): List<TrackMeta> = withContext(Dispatchers.IO) {
        if (trackIds.isEmpty()) return@withContext emptyList()
        val validIds = trackIds.filter { it.isNotBlank() }.distinct()
        if (validIds.isEmpty()) return@withContext emptyList()

        try {
            val encodedIds = validIds.joinToString(",") { "\"${it.replace("\"", "")}\"" }
            val url = "${SupabaseConfig.url}/rest/v1/track_meta?track_id=in.($encodedIds)"

            val response = client.get(url) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Accept", "application/json")
            }

            if (!response.status.isSuccess()) {
                return@withContext emptyList()
            }

            val array = json.parseToJsonElement(response.bodyAsText()).jsonArray
            val results = mutableListOf<TrackMeta>()

            for (elem in array) {
                val obj = elem.jsonObject
                val id = obj["track_id"]?.jsonPrimitive?.content ?: continue
                val bpmVal = obj["bpm"]?.jsonPrimitive?.content?.toDoubleOrNull()
                val bpmConf = obj["bpm_conf"]?.jsonPrimitive?.content?.toFloatOrNull() ?: 0.9f
                val keyVal = obj["key_code"]?.jsonPrimitive?.content
                val keyConf = obj["key_conf"]?.jsonPrimitive?.content?.toFloatOrNull() ?: 0.9f

                val bpmField = bpmVal?.takeIf { it in 40.0..220.0 }?.let {
                    Field(it, bpmConf, MetaSource.SHARED)
                }
                val keyField = keyVal?.let { CamelotKey.parse(it) }?.let {
                    Field(it, keyConf, MetaSource.SHARED)
                }

                if (bpmField != null || keyField != null) {
                    results += TrackMeta(
                        trackId = id,
                        bpm = bpmField,
                        key = keyField,
                        updatedAt = System.currentTimeMillis(),
                    )
                }
            }
            results
        } catch (e: Exception) {
            Log.d(TAG, "Shared cache lookup failed (offline or network): ${e.message}")
            emptyList()
        }
    }

    suspend fun upload(meta: TrackMeta) = withContext(Dispatchers.IO) {
        if (!meta.complete) return@withContext
        try {
            val url = "${SupabaseConfig.url}/rest/v1/track_meta"
            val payload = kotlinx.serialization.json.buildJsonObject {
                put("track_id", kotlinx.serialization.json.JsonPrimitive(meta.trackId))
                meta.bpm?.let {
                    put("bpm", kotlinx.serialization.json.JsonPrimitive(it.value))
                    put("bpm_conf", kotlinx.serialization.json.JsonPrimitive(it.confidence))
                    put("bpm_src", kotlinx.serialization.json.JsonPrimitive(it.source.name))
                }
                meta.key?.let {
                    put("key_code", kotlinx.serialization.json.JsonPrimitive(it.value.code))
                    put("key_conf", kotlinx.serialization.json.JsonPrimitive(it.confidence))
                    put("key_src", kotlinx.serialization.json.JsonPrimitive(it.source.name))
                }
                put("version", kotlinx.serialization.json.JsonPrimitive(meta.analyzerVersion))
            }.toString()

            client.post(url) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Content-Type", "application/json")
                header("Prefer", "resolution=merge-duplicates")
                setBody(payload)
            }
        } catch (e: Exception) {
            Log.d(TAG, "Shared cache upload failed: ${e.message}")
        }
    }
}
