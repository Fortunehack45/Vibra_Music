package com.fortune.vibramusic.wear

/**
 * The Vibra watch app as one of this phone's outputs, for the output sheet.
 */
data class WatchOutputState(
    /** A watch with Vibra Music on it is in reach. */
    val available: Boolean = false,
    /** What the watch calls itself — "Galaxy Watch4 Classic (KX4F)". */
    val name: String? = null,
    /** The watch is the speaker. */
    val active: Boolean = false,
    /** The watch's own volume, 0..1, while it is. */
    val volume: Float = 0f,
)
