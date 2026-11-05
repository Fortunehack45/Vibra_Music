package com.fortune.vibramusic.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "track_analysis")
data class TrackAnalysis(
    @PrimaryKey val trackId: String,
    val fingerprint: String,        // size + mtime or hash; re-analyze on change
    val analysisVersion: Int,       // bump when the analyzer improves
    val durationMs: Long,
    val startMs: Long,              // end of leading silence (below -50 dB)
    val bpm: Float,
    val bpmConfidence: Float,       // 0..1
    val bpmAmbiguous: Boolean,      // half/double time possible
    val beatsMs: FloatArray,        // via TypeConverter to BLOB
    val downbeatsMs: FloatArray,    // first beat of each bar
    val camelot: String,            // for example 8A, 11B
    val keyConfidence: Float,
    val lufs: Float,                // integrated loudness, BS.1770
    val energyPerBar: FloatArray,   // 0..1, one value per bar
    val introEndMs: Long,
    val outroStartMs: Long,
    val vocalRegionsMs: LongArray,  // start,end pairs
    val phraseStartsMs: FloatArray  // section boundaries snapped to downbeats
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as TrackAnalysis

        if (trackId != other.trackId) return false
        if (fingerprint != other.fingerprint) return false
        if (analysisVersion != other.analysisVersion) return false
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
        var result = trackId.hashCode()
        result = 31 * result + fingerprint.hashCode()
        result = 31 * result + analysisVersion
        result = 31 * result + durationMs.hashCode()
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

@Entity(tableName = "mix_plan", primaryKeys = ["fromId", "toId", "preset"])
data class MixPlanEntity(
    val fromId: String,
    val toId: String,
    val preset: String,
    val planVersion: Int,
    val score: Float,
    val style: String,
    val bars: Int,
    val outAlignDownbeat: Int,      // index into from.downbeatsMs
    val inAlignDownbeat: Int,       // index into to.downbeatsMs
    val rampBars: Int,
    val targetBpm: Float,
    val cutOutMs: Long              // outgoing track stops being rendered here
)
