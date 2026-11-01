package com.fortune.vibramusic.playback.smart

import kotlin.math.abs

/**
 * Higher trust wins when two sources disagree.
 */
enum class MetaSource(val trust: Int) {
    USER(100),           // the person corrected it by hand: never overwritten
    TAG(90),             // ID3 / Vorbis tag in a local file (verify against analysis)
    ANALYZED_FULL(80),   // whole-track on-device analysis
    SHARED(70),          // verified record from the shared cache
    ANALYZED_FAST(60),   // quick pass on part of the song
}

data class Field<T>(
    val value: T,
    val confidence: Float,          // 0..1
    val source: MetaSource,
)

data class TrackMeta(
    val trackId: String,
    val bpm: Field<Double>? = null,          // true tempo, one decimal, NOT folded into a fixed range
    val key: Field<CamelotKey>? = null,
    val analyzerVersion: Int = 0,
    val updatedAt: Long = 0L,
) {
    val complete: Boolean get() = bpm != null && key != null
}

/**
 * Pick the better of two fields. Never lets a lower-trust source overwrite USER.
 */
fun <T> mergeField(old: Field<T>?, new: Field<T>?, sameValue: (T, T) -> Boolean): Field<T>? {
    if (new == null) return old
    if (old == null) return new
    if (old.source == MetaSource.USER) return old
    if (new.source == MetaSource.USER) return new
    // A tag the analysis strongly disagrees with is replaced; otherwise higher trust wins.
    val disagree = !sameValue(old.value, new.value)
    return when {
        new.source.trust > old.source.trust && !(disagree && new.confidence < 0.5f) -> new
        new.source.trust == old.source.trust && new.confidence > old.confidence -> new
        old.source == MetaSource.TAG && disagree && new.confidence >= 0.8f -> new  // tags are often wrong
        else -> old
    }
}
