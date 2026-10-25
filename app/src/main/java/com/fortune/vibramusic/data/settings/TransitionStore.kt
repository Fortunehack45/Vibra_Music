package com.fortune.vibramusic.data.settings

import android.content.Context
import android.util.Log
import com.fortune.vibramusic.playback.audio.AutomationCurve
import com.fortune.vibramusic.playback.audio.CurveInterpolation
import com.fortune.vibramusic.playback.audio.CurvePoint
import com.fortune.vibramusic.playback.audio.TransitionProfile
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Persisted custom transition configuration between two tracks or within a playlist.
 */
@Serializable
data class TransitionConfig(
    val schemaVersion: Int = TransitionStore.CURRENT_SCHEMA_VERSION,
    val playlistId: String? = null,
    val fromItemId: String,
    val toItemId: String,
    val preset: String = TransitionProfile.PRESET_EQUAL_POWER,
    val durationMs: Long = 8000L,
    val startPositionMs: Long = 0L,
    val alignmentMode: String = "beat",
    val outgoingGainCurve: List<PointDto> = emptyList(),
    val incomingGainCurve: List<PointDto> = emptyList(),
    val filterAutomation: List<CurveDto> = emptyList(),
    val eqAutomation: List<CurveDto> = emptyList(),
) {
    fun toProfile(): TransitionProfile {
        val outGain = if (outgoingGainCurve.isNotEmpty()) {
            AutomationCurve(
                parameterId = AutomationCurve.PARAM_GAIN_OUT,
                points = outgoingGainCurve.map { CurvePoint(it.time, it.value) },
                interpolation = CurveInterpolation.EQUAL_POWER_COS,
            )
        } else {
            AutomationCurve.equalPowerFadeOut()
        }

        val inGain = if (incomingGainCurve.isNotEmpty()) {
            AutomationCurve(
                parameterId = AutomationCurve.PARAM_GAIN_IN,
                points = incomingGainCurve.map { CurvePoint(it.time, it.value) },
                interpolation = CurveInterpolation.EQUAL_POWER_SIN,
            )
        } else {
            AutomationCurve.equalPowerFadeIn()
        }

        return TransitionProfile(
            id = preset,
            name = preset.replace('_', ' ').replaceFirstChar { it.uppercase() },
            outgoingGain = outGain,
            incomingGain = inGain,
        )
    }
}

@Serializable
data class PointDto(val time: Float, val value: Float)

@Serializable
data class CurveDto(
    val parameterId: String,
    val points: List<PointDto>,
    val interpolation: String = "LINEAR",
    val minValue: Float = 0f,
    val maxValue: Float = 1f,
)

/**
 * Manages disk persistence and memory caching of custom transition configurations.
 */
class TransitionStore(private val baseDir: File) {

    constructor(context: Context) : this(context.filesDir)

    private val directory by lazy { File(baseDir, DIRECTORY_NAME).apply { mkdirs() } }
    private val memoryCache = ConcurrentHashMap<String, TransitionConfig>()

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        prettyPrint = false
    }

    /**
     * Loads a transition configuration for the transition between [fromItemId] and [toItemId],
     * optionally constrained by [playlistId].
     */
    fun load(fromItemId: String, toItemId: String, playlistId: String? = null): TransitionConfig? {
        if (fromItemId.isBlank() || toItemId.isBlank()) return null
        val key = cacheKey(fromItemId, toItemId, playlistId)

        memoryCache[key]?.let { return it }

        val file = File(directory, "$key.json")
        if (!file.exists()) return null

        return runCatching {
            val text = file.readText()
            val config = json.decodeFromString<TransitionConfig>(text)
            if (config.schemaVersion == CURRENT_SCHEMA_VERSION) {
                memoryCache[key] = config
                config
            } else {
                file.delete()
                null
            }
        }.onFailure {
            Log.w(TAG, "Failed to load transition config for $key", it)
            file.delete()
        }.getOrNull()
    }

    /**
     * Stores a transition configuration.
     */
    fun save(config: TransitionConfig) {
        if (config.fromItemId.isBlank() || config.toItemId.isBlank()) return
        val key = cacheKey(config.fromItemId, config.toItemId, config.playlistId)
        memoryCache[key] = config

        runCatching {
            val file = File(directory, "$key.json")
            val temp = File(directory, "$key.tmp")
            temp.writeText(json.encodeToString(config))
            if (!temp.renameTo(file)) {
                temp.delete()
            }
        }.onFailure {
            Log.w(TAG, "Failed to persist transition config for $key", it)
        }
    }

    /**
     * Deletes a stored transition configuration.
     */
    fun delete(fromItemId: String, toItemId: String, playlistId: String? = null) {
        val key = cacheKey(fromItemId, toItemId, playlistId)
        memoryCache.remove(key)
        runCatching {
            File(directory, "$key.json").delete()
        }
    }

    private fun cacheKey(fromItemId: String, toItemId: String, playlistId: String?): String {
        val prefix = if (!playlistId.isNullOrBlank()) "${playlistId}_" else ""
        return "${prefix}${fromItemId.hashCode().toUInt()}_${toItemId.hashCode().toUInt()}"
    }

    companion object {
        private const val TAG = "TransitionStore"
        private const val DIRECTORY_NAME = "custom_transitions"
        const val CURRENT_SCHEMA_VERSION = 1
    }
}
