package com.fortune.vibramusic.data.settings

/**
 * Handover styles available when transitions are enabled:
 * - AUTOMIX: Full DJ mix with beatmatching, key matching, bass swap, and phrase alignment
 * - CROSSFADE: Constant-energy equal-power fade
 * - RISE: Riser / build-up transition using resonant high-pass filter sweeps
 * - CUSTOM: Custom transition configuration
 */
enum class SongTransitionStyle {
    /**
     * Each handover is timed and shaped from the two tracks themselves, by
     * [com.fortune.vibramusic.playback.smart.planTransition].
     */
    AUTOMIX,

    /** A plain equal-power fade lasting [SongTransitions.crossfadeSeconds]. */
    CROSSFADE,

    /** A riser / build-up transition that sweeps high frequencies into the incoming drop. */
    RISE,

    /** Fine-tuned user parameters for duration and curve style. */
    CUSTOM,
}

/**
 * How one song gives way to the next: whether songs blend at all, which
 * [style] they blend in, and how long a crossfade runs.
 *
 * Automix is turned on automatically by default to deliver professional DJ-style
 * seamless transitions out of the box.
 */
data class SongTransitions(
    val enabled: Boolean = true,
    val style: SongTransitionStyle = SongTransitionStyle.AUTOMIX,
    /** The crossfade length, [MIN_CROSSFADE_SECONDS] to [MAX_CROSSFADE_SECONDS]. */
    val crossfadeSeconds: Int = DEFAULT_CROSSFADE_SECONDS,
) {
    /** Whether Automix plans the transitions: what [AppSettings.smartFadeEnabled] hands playback. */
    val automix: Boolean get() = enabled && (style == SongTransitionStyle.AUTOMIX || style == SongTransitionStyle.RISE)

    /**
     * What [AppSettings.crossfadeSeconds] hands playback: the crossfade length
     * while transitions are on, 0 while they are off.
     */
    val playbackCrossfadeSeconds: Int get() = if (enabled) crossfadeSeconds else 0

    /** This, with the crossfade length set to [seconds] pulled into range. */
    fun withCrossfadeSeconds(seconds: Int): SongTransitions =
        copy(crossfadeSeconds = seconds.coerceIn(MIN_CROSSFADE_SECONDS, MAX_CROSSFADE_SECONDS))

    companion object {
        const val MIN_CROSSFADE_SECONDS = 1
        const val MAX_CROSSFADE_SECONDS = 16

        /**
         * Eight seconds: standard 8-bar quantized window for musical transitions.
         */
        const val DEFAULT_CROSSFADE_SECONDS = 8

        /**
         * Reads legacy crossfade and automix preferences.
         */
        fun fromLegacy(crossfadeSeconds: Int, automix: Boolean): SongTransitions {
            val chosen = SongTransitions().let {
                if (crossfadeSeconds > 0) it.withCrossfadeSeconds(crossfadeSeconds) else it
            }
            return when {
                automix -> chosen.copy(enabled = true, style = SongTransitionStyle.AUTOMIX)
                crossfadeSeconds > 0 -> chosen.copy(enabled = true, style = SongTransitionStyle.CROSSFADE)
                else -> chosen.copy(enabled = false, style = SongTransitionStyle.CROSSFADE)
            }
        }
    }
}
