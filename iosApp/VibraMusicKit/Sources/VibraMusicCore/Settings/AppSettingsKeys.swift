import Foundation

// The persisted names of every setting. They are Android's SharedPreferences keys verbatim, so a
// backup written by either platform restores on the other.

extension AppSettings {
    /// A `UserDefaults` key and the type its value is stored (and backed up) as.
    enum Key: String, CaseIterable {
        // Audio quality
        case audioQualityLegacy = "audio_quality"
        case audioQualityWifi = "audio_quality_wifi"
        case audioQualityCellular = "audio_quality_cellular"
        case upgradeLengthSlackSeconds = "upgrade_length_slack_seconds"
        case downloadQuality = "audio_quality_download"
        case wifiOnlyDownloads = "wifi_only_downloads"

        // Playback
        case crossfadeSeconds = "crossfade_seconds"
        case smartFadeEnabled = "smart_fade_enabled"
        case automixPerformanceMode = "automix_performance_mode"
        case skipSilence = "skip_silence"
        case loudnessNormalization = "loudness_normalization"
        case dolbyAtmos = "dolby_atmos"
        /// Android's on/off switch for "Direct source stream" (on is Always). Still written beside
        /// ``directSourceStream`` so a backup restores on Android and older builds; read only
        /// when the three-way choice was never stored.
        case directSourceStreamLegacy = "direct_source_stream"
        case directSourceStream = "direct_source_stream_mode"
        case spatialAudio = "spatial_audio"
        case playbackSpeed = "playback_speed"
        case autoplay = "autoplay"
        case shuffleEnabled = "shuffle_enabled"
        case repeatMode = "repeat_mode"
        case swipeToPlayNext = "swipe_to_play_next"
        case dontRepeatSuggestions = "dont_repeat_suggestions"
        case preferMusicOnly = "prefer_music_only"
        case smartVersionAlignment = "smart_version_alignment"
        case audioCacheLimitBytes = "audio_cache_limit_bytes"

        // Equalizer
        case equalizerEnabled = "equalizer_enabled"
        case equalizerMode = "equalizer_mode"
        case equalizerToneX = "equalizer_tone_x"
        case equalizerToneY = "equalizer_tone_y"
        case equalizerFocused = "equalizer_focused"
        case equalizerBalance = "equalizer_balance"
        case equalizerBands = "equalizer_bands"

        // Appearance and player
        case themeMode = "theme_mode"
        case showNerdStats = "show_nerd_stats"
        case reduceAnimation = "reduce_animation"
        case reduceDynamicBlur = "reduce_dynamic_blur"
        case hideVolumeBar = "hide_volume_bar"
        case showQueueHistory = "show_queue_history"
        case hideSongStatus = "hide_song_status"
        case fullBleedArtwork = "full_bleed_artwork"
        case legacyMeshGradient = "legacy_mesh_gradient"
        case lastPlayerScreen = "last_player_screen"
        case hideStatusBarInPlayer = "hide_status_bar_in_player"

        // Canvas
        case animatedCanvas = "animated_canvas"
        case canvasOverCellular = "canvas_over_cellular"
        case spotifyCanvasAutoHide = "spotify_canvas_auto_hide"
        case prioritizeSpotifyCanvas = "prioritize_spotify_canvas"

        // Lyrics
        case syncedLyrics = "synced_lyrics"
        case lyricsBlur = "lyrics_blur"
        case lyricsOffsetMs = "lyrics_offset_ms"
        case translationLanguage = "translation_language"
        case lyricsSources = "lyrics_sources"
        case lyricsSourcesSeen = "lyrics_sources_seen"
        case lyricsSourceOrder = "lyrics_source_order"
        case prioritizeSyllableSync = "prioritize_syllable_sync"

        // Library
        case replayGenres = "replay_genres"
        case localMusicSort = "local_music_sort"
        case downloadedMusicSort = "downloaded_music_sort"
        case librarySort = "library_sort"
        case detailSongSorts = "detail_song_sorts"
        case localMusicViewType = "local_music_view_type"
        case downloadedMusicViewType = "downloaded_music_view_type"
        case homeRecentsViewType = "home_recents_view_type"
        case pinnedPlaylists = "pinned_playlists"
        case searchHistory = "search_history"

        // Network libraries (passwords are credentials, not here)
        case webdavUrl = "webdav_url"
        case webdavUsername = "webdav_username"
        case smbHost = "smb_host"
        case smbShare = "smb_share"
        case smbBasePath = "smb_base_path"
        case smbUsername = "smb_username"

        // Scrobbling (keys and tokens are credentials, not here)
        case lastfmEnabled = "lastfm_enabled"
        case lastfmUsername = "lastfm_username"
        case lastfmEndpoint = "lastfm_endpoint"
        case lastfmScrobbleEnabled = "lastfm_scrobble_enabled"
        case lastfmNowPlaying = "lastfm_now_playing"
        case lastfmPrimaryArtistOnly = "lastfm_primary_artist_only"
        case scrobbleMinDuration = "scrobble_min_duration"
        case scrobbleDelayPercent = "scrobble_delay_percent"
        case scrobbleDelaySeconds = "scrobble_delay_seconds"
        case listenBrainzEnabled = "listenbrainz_enabled"
        case listenBrainzPrimaryArtistOnly = "listenbrainz_primary_artist_only"

        // Discord Rich Presence (the token is a credential, not here)
        case discordUsername = "discord_username"
        case discordName = "discord_name"
        case discordAvatar = "discord_avatar"
        case discordRpcEnabled = "discord_rpc_enabled"
        case discordUseDetails = "discord_use_details"
        case discordShowAudioQuality = "discord_show_audio_quality"
        case discordAdvancedMode = "discord_advanced_mode"
        case discordStatus = "discord_status"
        case discordActivityType = "discord_activity_type"
        case discordActivityName = "discord_activity_name"
        case discordButton1Text = "discord_button_1_text"
        case discordButton1Visible = "discord_button_1_visible"
        case discordButton2Text = "discord_button_2_text"
        case discordButton2Visible = "discord_button_2_visible"
        case discordInfoDismissed = "discord_info_dismissed"

        // Device-local
        case lastVersionCode = "last_version_code"
        case keepDiagnosticLog = "keep_diagnostic_log"

        enum Kind {
            case bool, int, long, float, string
        }

        var kind: Kind {
            switch self {
            case .upgradeLengthSlackSeconds, .crossfadeSeconds, .repeatMode, .equalizerToneX,
                 .equalizerToneY, .lyricsOffsetMs, .scrobbleMinDuration, .scrobbleDelaySeconds,
                 .lastVersionCode:
                return .int
            case .audioCacheLimitBytes:
                return .long
            case .playbackSpeed, .equalizerBalance, .scrobbleDelayPercent:
                return .float
            case .audioQualityLegacy, .audioQualityWifi, .audioQualityCellular, .downloadQuality,
                 .directSourceStream, .automixPerformanceMode, .equalizerMode, .equalizerBands, .themeMode,
                 .lastPlayerScreen, .translationLanguage, .lyricsSources, .lyricsSourcesSeen,
                 .lyricsSourceOrder, .localMusicSort, .downloadedMusicSort, .librarySort,
                 .detailSongSorts, .localMusicViewType, .downloadedMusicViewType,
                 .homeRecentsViewType, .pinnedPlaylists, .searchHistory, .webdavUrl,
                 .webdavUsername, .smbHost, .smbShare, .smbBasePath, .smbUsername, .lastfmUsername,
                 .lastfmEndpoint, .discordUsername, .discordName, .discordAvatar, .discordStatus,
                 .discordActivityType, .discordActivityName, .discordButton1Text,
                 .discordButton2Text:
                return .string
            default:
                return .bool
            }
        }

        /// Describes *this device* rather than the configuration, so it is neither exported nor
        /// overwritten by an import (Android's `DEVICE_LOCAL`).
        var isDeviceLocal: Bool { self == .lastVersionCode || self == .keepDiagnosticLog }
    }

    /// Credentials: kept in the Keychain (``CredentialStoring``), never in `UserDefaults`, and so
    /// never in a backup. Android's `SECRETS` plus what its encrypted `AuthStore` held.
    enum CredentialKey: String, CaseIterable {
        case lastfmSessionKey = "lastfm_session_key"
        case lastfmApiKey = "lastfm_api_key"
        case lastfmSecret = "lastfm_secret"
        case listenBrainzToken = "listenbrainz_token"
        case spotifySpdcToken = "spotify_spdc_token"
        case paxSenixApiKey = "paxsenix_api_key"
        case discordToken = "discord_token"
        case webdavPassword = "webdav_password"
        case smbPassword = "smb_password"
    }
}

extension SettingValue {
    /// Reads a `UserDefaults` object as `kind`. Nil when the stored object isn't that kind.
    init?(defaultsObject object: Any, kind: AppSettings.Key.Kind) {
        switch kind {
        case .bool:
            guard let number = object as? NSNumber else { return nil }
            self = .bool(number.boolValue)
        case .int:
            guard let number = object as? NSNumber else { return nil }
            self = .int(number.intValue)
        case .long:
            guard let number = object as? NSNumber else { return nil }
            self = .long(number.int64Value)
        case .float:
            guard let number = object as? NSNumber else { return nil }
            self = .float(number.floatValue)
        case .string:
            guard let string = object as? String else { return nil }
            self = .string(string)
        }
    }

    /// The `UserDefaults` object for this value stored as `kind`, coercing between numeric types
    /// (a backup's "long" for an int key still restores). Nil when it can't be one.
    func defaultsObject(as kind: AppSettings.Key.Kind) -> Any? {
        switch kind {
        case .bool: return boolValue
        case .int: return intValue
        case .long: return int64Value
        case .float: return floatValue
        case .string: return stringValue
        }
    }
}
