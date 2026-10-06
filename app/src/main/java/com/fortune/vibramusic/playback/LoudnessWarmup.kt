package com.fortune.vibramusic.playback

/**
 * Which queued tracks are worth resolving ahead of time for nothing but their
 * loudness figure, for `PlaybackService.warmLoudnessFigures`.
 */
internal object LoudnessWarmup {

    /**
     * Whether a track whose playback uri has this [scheme] and [authority]
     * should be resolved now so its figure is known before it is heard.
     *
     * Only tracks queued from YouTube, as `siren://watch?v=<id>` or `vibramusic://watch?v=<id>`,
     * and only while their figure is still unknown: once
     * [com.fortune.vibramusic.data.innertube.StreamResolver] has one, it keeps it
     * for as long as the process runs. A source-backed track has no YouTube figure
     * to fetch. A download or a file from the device's library (`file://`, `content://`)
     * plays without the network by design, so it is not handed a network round trip for one.
     */
    fun wanted(scheme: String?, authority: String?, figureKnown: Boolean): Boolean =
        !figureKnown && (scheme == "siren" || scheme == "vibramusic" || scheme == "bitchord") && authority == "watch"
}
