package com.fortune.vibramusic.data.model

/**
 * Persisted user listening preferences and statistics buckets:
 * - Audio configuration (quality, equalizer, pitch/tempo)
 * - Canvas & lyrics settings
 * - Listening stats JSON for Replay experience
 * - Connected Spotify session (sp_dc cookie)
 */
data class UserListeningExperience(
    val userId: String,
    val spotifySpdcToken: String? = null,
    val spotifyConnected: Boolean = false,
    val audioQuality: String = "HIGH",
    val equalizerEnabled: Boolean = false,
    val equalizerPreset: String = "FLAT",
    val volumeNormalization: Boolean = true,
    val bassBoostPercent: Int = 0,
    val virtualizerPercent: Int = 0,
    val pitchCents: Int = 0,
    val tempoMultiplier: Float = 1.0f,
    val autoSkipSilence: Boolean = false,
    val lyricsSource: String = "DEFAULT",
    val canvasEnabled: Boolean = true,
    val preferredGenres: List<String> = emptyList(),
    val listeningStatsJson: String? = null,
)
