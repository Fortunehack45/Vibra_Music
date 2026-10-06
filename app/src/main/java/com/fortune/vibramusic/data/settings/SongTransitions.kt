package com.fortune.vibramusic.data.settings

/**
 * The two ways one song can hand over to the next while
 * [SongTransitions.enabled] is on: the pair Apple Music offers under Song
 * Transitions.
 */
enum class SongTransitionStyle {
    /**
     * Each handover is timed and shaped from the two tracks themselves, by
     * [com.fortune.vibramusic.playback.smart.planTransition].
     */
    AUTOMIX,

    /** A plain equal-power fade lasting [SongTransitions.crossfadeSeconds]. */
    CROSSFADE,
}

/**
 * How one song gives way to the next: whether songs blend at all, which
 * [style] they blend in, and how long a crossfade runs.
 *
 * This replaces two controls that used to sit side by side: a crossfade slider
 * whose "Off" stop doubled as the on/off switch, and an Automix switch that hid
 * the slider while it was on. Hiding it read as the crossfade having been taken
 * out of the app. Here the switch is its own thing, the style is a choice
 * between two named options, and the crossfade length survives the other style
 * or Off being chosen, so switching back finds it where it was left.
 *
 * Playback still reads the two values it always did,
 * [AppSettings.smartFadeEnabled] and [AppSettings.crossfadeSeconds]. They are
 * derived from this through [automix] and [playbackCrossfadeSeconds], so none
 * of the transition engine had to change for the merge.
 */
data class SongTransitions(
    val enabled: Boolean = false,
    val style: SongTransitionStyle = SongTransitionStyle.CROSSFADE,
    /** The crossfade length, [MIN_CROSSFADE_SECONDS] to [MAX_CROSSFADE_SECONDS]. */
    val crossfadeSeconds: Int = DEFAULT_CROSSFADE_SECONDS,
) {
    /** Whether Automix plans the transitions: what [AppSettings.smartFadeEnabled] hands playback. */
    val automix: Boolean get() = enabled && style == SongTransitionStyle.AUTOMIX

    /**
     * What [AppSettings.crossfadeSeconds] hands playback: the crossfade length
     * while transitions are on, 0 while they are off.
     *
     * Kept at the listener's length under Automix too rather than zeroed.
     * Automix reads it as the length of the plain fade it falls back on for a
     * pair it has not analysed yet (see `CrossfadeController.considerSmartTransition`),
     * which is exactly what it read before the two controls were merged.
     */
    val playbackCrossfadeSeconds: Int get() = if (enabled) crossfadeSeconds else 0

    /** This, with the crossfade length set to [seconds] pulled into range. */
    fun withCrossfadeSeconds(seconds: Int): SongTransitions =
        copy(crossfadeSeconds = seconds.coerceIn(MIN_CROSSFADE_SECONDS, MAX_CROSSFADE_SECONDS))

    companion object {
        const val MIN_CROSSFADE_SECONDS = 1
        const val MAX_CROSSFADE_SECONDS = 12

        /**
         * Six seconds: the length Automix already falls back on before a pair
         * is analysed (`CrossfadeController.DEFAULT_SMART_FALLBACK_SECONDS`),
         * so nobody's Automix changes because the controls were merged.
         */
        const val DEFAULT_CROSSFADE_SECONDS = 6

        /**
         * Reads the two settings this replaced: a 0-12 s crossfade slider where 0
         * meant off, and the Automix switch.
         *
         * Automix wins where both were set, as it always did, since the slider
         * sat hidden behind it. A length that was set is kept either way: it is
         * the Crossfade length if the listener switches style later, and under
         * Automix it is the fallback length it already was.
         */
        fun fromLegacy(crossfadeSeconds: Int, automix: Boolean): SongTransitions {
            val chosen = SongTransitions().let {
                if (crossfadeSeconds > 0) it.withCrossfadeSeconds(crossfadeSeconds) else it
            }
            return when {
                automix -> chosen.copy(enabled = true, style = SongTransitionStyle.AUTOMIX)
                crossfadeSeconds > 0 -> chosen.copy(enabled = true, style = SongTransitionStyle.CROSSFADE)
                else -> chosen
            }
        }
    }
}
