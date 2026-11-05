package com.fortune.vibramusic.playback.mix

import android.util.Log
import com.fortune.vibramusic.data.db.TrackAnalysis

data class NativeAnalysisResult(
    val durationMs: Long,
    val startMs: Long,
    val bpm: Float,
    val bpmConfidence: Float,
    val bpmAmbiguous: Boolean,
    val beatsMs: FloatArray,
    val downbeatsMs: FloatArray,
    val camelot: String,
    val keyConfidence: Float,
    val lufs: Float,
    val energyPerBar: FloatArray,
    val introEndMs: Long,
    val outroStartMs: Long,
    val vocalRegionsMs: LongArray,
    val phraseStartsMs: FloatArray
) {
    fun toEntity(trackId: String, fingerprint: String, version: Int): TrackAnalysis {
        return TrackAnalysis(
            trackId = trackId,
            fingerprint = fingerprint,
            analysisVersion = version,
            durationMs = durationMs,
            startMs = startMs,
            bpm = bpm,
            bpmConfidence = bpmConfidence,
            bpmAmbiguous = bpmAmbiguous,
            beatsMs = beatsMs,
            downbeatsMs = downbeatsMs,
            camelot = camelot,
            keyConfidence = keyConfidence,
            lufs = lufs,
            energyPerBar = energyPerBar,
            introEndMs = introEndMs,
            outroStartMs = outroStartMs,
            vocalRegionsMs = vocalRegionsMs,
            phraseStartsMs = phraseStartsMs
        )
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as NativeAnalysisResult

        if (durationMs != other.durationMs) return false
        if (startMs != other.startMs) return false
        if (bpm != other.bpm) return false
        if (bpmConfidence != other.bpmConfidence) return false
        if (bpmAmbiguous != other.bpmAmbiguous) return false
        if (!beatsMs.contentEquals(other.beatsMs)) return false
        if (!downbeatsMs.contentEquals(other.downbeatsMs)) return false
        if (camelot != other.camelot) return false
        if (keyConfidence != other.keyConfidence) return false
        if (lufs != other.lufs) return false
        if (!energyPerBar.contentEquals(other.energyPerBar)) return false
        if (introEndMs != other.introEndMs) return false
        if (outroStartMs != other.outroStartMs) return false
        if (!vocalRegionsMs.contentEquals(other.vocalRegionsMs)) return false
        if (!phraseStartsMs.contentEquals(other.phraseStartsMs)) return false

        return true
    }

    override fun hashCode(): Int {
        var result = durationMs.hashCode()
        result = 31 * result + startMs.hashCode()
        result = 31 * result + bpm.hashCode()
        result = 31 * result + bpmConfidence.hashCode()
        result = 31 * result + bpmAmbiguous.hashCode()
        result = 31 * result + beatsMs.contentHashCode()
        result = 31 * result + downbeatsMs.contentHashCode()
        result = 31 * result + camelot.hashCode()
        result = 31 * result + keyConfidence.hashCode()
        result = 31 * result + lufs.hashCode()
        result = 31 * result + energyPerBar.contentHashCode()
        result = 31 * result + introEndMs.hashCode()
        result = 31 * result + outroStartMs.hashCode()
        result = 31 * result + vocalRegionsMs.contentHashCode()
        result = 31 * result + phraseStartsMs.contentHashCode()
        return result
    }
}

object NativeAnalyzer {
    private const val TAG = "NativeAnalyzer"

    init {
        try {
            System.loadLibrary("vibra_analysis")
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to load libvibra_analysis.so", e)
        }
    }

    /**
     * Fold octave errors so BPM lies cleanly in the 78..160 range.
     * Flag ambiguous when half or double time is plausible (<90 or >140).
     */
    fun foldBpm(raw: Float): Pair<Float, Boolean> {
        if (raw <= 0f) return 120f to true
        var b = raw
        while (b < 78f) b *= 2f
        while (b > 160f) b /= 2f
        val ambiguous = b < 90f || b > 140f
        return b to ambiguous
    }

    fun analyze(audioPath: String): NativeAnalysisResult? {
        if (audioPath.isBlank()) return null
        return runCatching {
            nativeAnalyze(audioPath)
        }.getOrNull()
    }

    @JvmStatic
    private external fun nativeAnalyze(path: String): NativeAnalysisResult?
}
