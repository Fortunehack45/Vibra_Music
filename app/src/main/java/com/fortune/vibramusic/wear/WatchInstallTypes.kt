package com.fortune.vibramusic.wear

/**
 * What Settings -> "Wear OS" draws.
 */
data class WatchEntry(
    /** The Wearable node id: what every message to this watch is addressed to. */
    val nodeId: String,
    /** What the watch calls itself — "Galaxy Watch4 Classic (WZTM)". */
    val name: String,
    val status: WatchAppStatus,
    /** The watch app's versionName, once it has said. */
    val versionName: String? = null,
)

enum class WatchAppStatus {
    /** Asked; no answer yet. */
    CHECKING,

    /** This build of Vibra Music isn't on the watch. */
    NOT_INSTALLED,

    /** The watch has exactly the build this phone carries. */
    UP_TO_DATE,

    /** The watch has a different build from the one this phone carries. */
    UPDATE_AVAILABLE,

    /** Installed, but it didn't answer. */
    UNKNOWN,
}

/** Sending this phone's watch build to a watch that already has Vibra Music. */
sealed interface WatchUpdateState {
    data object Idle : WatchUpdateState
    data class Sending(val nodeId: String) : WatchUpdateState
    data class Sent(val nodeId: String) : WatchUpdateState
    data class Failed(val nodeId: String, val reason: String) : WatchUpdateState
}

/**
 * The first install via ADB wireless pairing.
 */
sealed interface WatchPairingState {
    data object Idle : WatchPairingState
    data object Searching : WatchPairingState
    data class Found(val host: String) : WatchPairingState
    data object Pairing : WatchPairingState
    data object Installing : WatchPairingState
    data object Installed : WatchPairingState
    data class Failed(val reason: String) : WatchPairingState
}
