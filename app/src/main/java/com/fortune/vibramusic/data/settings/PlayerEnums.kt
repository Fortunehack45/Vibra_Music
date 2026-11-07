package com.fortune.vibramusic.data.settings

/** What the phone's main player stands on, below the artwork. */
enum class PlayerTheme {
    /** The artwork's own colours hung off its bottom edge, as a mesh. */
    DEFAULT,

    /** v1.5's four quantised blobs, drifting behind the whole screen. */
    LEGACY,

    /** The cover blurred across the whole screen, as the lyrics and queue are. */
    SIMPLE,
}
