package com.fortune.vibramusic.playback.smart

import kotlin.math.abs
import kotlin.math.min

/**
 * Represents a musical key on the Camelot Wheel (1A to 12B) used for harmonic mixing.
 *
 * @property number Hour on the wheel from 1 to 12.
 * @property isMajor True for Major keys ("B"), false for Minor keys ("A").
 */
data class CamelotKey(
    val number: Int,
    val isMajor: Boolean,
) {
    init {
        require(number in 1..12) { "Camelot number must be between 1 and 12, got: $number" }
    }

    val code: String get() = "$number${if (isMajor) "B" else "A"}"

    /**
     * Calculates the harmonic compatibility score between this key and [other] in range [0.0, 1.0].
     */
    fun compatibilityScore(other: CamelotKey): Float {
        if (this == other) return 1.0f

        // Clockwise/counter-clockwise circular distance on 12-hour wheel
        val rawDiff = abs(this.number - other.number)
        val wheelDist = min(rawDiff, 12 - rawDiff)

        return when {
            // Same mode, adjacent hour (+/- 1 fifth on wheel) -> Smooth harmonic transition
            this.isMajor == other.isMajor && wheelDist == 1 -> 0.90f

            // Relative major/minor (same number, mode flip) -> Natural mood modulation
            this.isMajor != other.isMajor && wheelDist == 0 -> 0.85f

            // Diagonal shift (+/- 1 hour and mode flip) -> Harmonic tension transition
            this.isMajor != other.isMajor && wheelDist == 1 -> 0.65f

            // Energy boost shift (+2 or +7 on circle of fifths)
            wheelDist == 2 -> 0.40f

            // 3 steps away
            wheelDist == 3 -> 0.25f

            // Incompatible / Tritone clash (>3 steps)
            else -> 0.15f
        }
    }

    /**
     * Calculates integer Camelot distance from 0 (identical) to 3 (clash).
     *
     * 0: Exactly identical key (e.g. 10A -> 10A)
     * 1: Adjacent hour (+/- 1) or relative major/minor (e.g. 10A -> 10B, 10A -> 9A/11A)
     * 2: Diagonal shift (e.g. 10A -> 9B/11B) or 2 hours
     * 3: Distant key modulation / harmonic clash
     */
    fun keyDistance(other: CamelotKey): Int {
        if (this == other) return 0
        val rawDiff = abs(this.number - other.number)
        val wheelDist = min(rawDiff, 12 - rawDiff)

        return when {
            this.isMajor != other.isMajor && wheelDist == 0 -> 1
            this.isMajor == other.isMajor && wheelDist == 1 -> 1
            this.isMajor != other.isMajor && wheelDist == 1 -> 2
            wheelDist == 2 -> 2
            else -> 3
        }
    }

    /**
     * Returns an ARGB hex color for this key badge based on harmonic compatibility with [other].
     * If [other] is null, falls back to the canonical Camelot wheel color for this key's hour.
     */
    fun badgeColor(other: CamelotKey? = null): Long {
        if (other != null) {
            return when (keyDistance(other)) {
                0 -> 0xFF3B82F6 // Blue
                1 -> if (this.isMajor == other.isMajor) 0xFF3B82F6 else 0xFF10B981 // Blue or Emerald
                2 -> 0xFFEAB308 // Amber / Yellow
                else -> 0xFFEF4444 // Coral / Red
            }
        }
        return when (number) {
            1 -> 0xFFE11D48
            2 -> 0xFF10B981
            3 -> 0xFF10B981
            4 -> 0xFFEAB308
            5 -> 0xFFF97316
            6 -> 0xFFEF4444
            7 -> 0xFF06B6D4
            8 -> 0xFF0EA5E9
            9 -> 0xFF3B82F6
            10 -> 0xFF6366F1
            11 -> 0xFF8B5CF6
            12 -> 0xFFD946EF
            else -> 0xFF8B5CF6
        }
    }

    companion object {
        /**
         * Parses a key string into a [CamelotKey].
         * Supports Camelot codes ("8A", "11B") and standard musical notation ("C", "Am", "F# Major").
         * Returns null if the key is empty, unrecognized, or ambiguous.
         */
        fun parse(raw: String?): CamelotKey? {
            if (raw.isNullOrBlank()) return null
            val clean = raw.trim()

            // 1. Check for direct Camelot notation (e.g., "8A", "12B")
            val camelotMatch = Regex("""^([1-9]|1[0-2])([a-bA-B])$""").find(clean)
            if (camelotMatch != null) {
                val num = camelotMatch.groupValues[1].toInt()
                val mode = camelotMatch.groupValues[2].uppercase()
                return CamelotKey(num, isMajor = (mode == "B"))
            }

            // 2. Normalize standard notation
            val normalized = clean.lowercase()
                .replace("major", "maj")
                .replace("minor", "m")
                .replace(" ", "")

            return PITCH_TO_CAMELOT[normalized]
        }

        private val PITCH_TO_CAMELOT = mapOf(
            // Major keys -> B
            "b" to CamelotKey(1, true), "bmaj" to CamelotKey(1, true),
            "f#" to CamelotKey(2, true), "f#maj" to CamelotKey(2, true), "gb" to CamelotKey(2, true), "gbmaj" to CamelotKey(2, true),
            "db" to CamelotKey(3, true), "dbmaj" to CamelotKey(3, true), "c#" to CamelotKey(3, true), "c#maj" to CamelotKey(3, true),
            "ab" to CamelotKey(4, true), "abmaj" to CamelotKey(4, true), "g#" to CamelotKey(4, true), "g#maj" to CamelotKey(4, true),
            "eb" to CamelotKey(5, true), "ebmaj" to CamelotKey(5, true), "d#" to CamelotKey(5, true), "d#maj" to CamelotKey(5, true),
            "bb" to CamelotKey(6, true), "bbmaj" to CamelotKey(6, true), "a#" to CamelotKey(6, true), "a#maj" to CamelotKey(6, true),
            "f" to CamelotKey(7, true), "fmaj" to CamelotKey(7, true),
            "c" to CamelotKey(8, true), "cmaj" to CamelotKey(8, true),
            "g" to CamelotKey(9, true), "gmaj" to CamelotKey(9, true),
            "d" to CamelotKey(10, true), "dmaj" to CamelotKey(10, true),
            "a" to CamelotKey(11, true), "amaj" to CamelotKey(11, true),
            "e" to CamelotKey(12, true), "emaj" to CamelotKey(12, true),

            // Minor keys -> A
            "abm" to CamelotKey(1, false), "g#m" to CamelotKey(1, false),
            "ebm" to CamelotKey(2, false), "d#m" to CamelotKey(2, false),
            "bbm" to CamelotKey(3, false), "a#m" to CamelotKey(3, false),
            "fm" to CamelotKey(4, false),
            "cm" to CamelotKey(5, false),
            "gm" to CamelotKey(6, false),
            "dm" to CamelotKey(7, false),
            "am" to CamelotKey(8, false),
            "em" to CamelotKey(9, false),
            "bm" to CamelotKey(10, false),
            "f#m" to CamelotKey(11, false), "gbm" to CamelotKey(11, false),
            "dbm" to CamelotKey(12, false), "c#m" to CamelotKey(12, false),
        )
    }
}
