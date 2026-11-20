import Foundation
import Observation

// Ports data/settings/AppSettings.kt.
//
// Dropped as Android-only (PORTING.md §3 and §4): export_downloads, output_pcm_mode,
// prefer_usb_dac, high_performance_mode, performance_refresh_rate, liquid_glass,
// stop_on_task_removed, filter_non_music_audio and local_music_folder_uri (MediaStore scanning),
// audioSessionId. `meteredConnection` is replaced by NetworkMonitor (pass its status to the
// derived-value methods). The Automix runtime flows (smartMixInProgress, smartAnalysis, …) were
// never settings and belong to Playback/Automix; their value types live in SettingsEnums.swift.

/// Every user setting, persisted to `UserDefaults` and observable from SwiftUI.
///
/// Use ``shared`` in the app; tests build their own over an ephemeral suite and an
/// ``InMemoryCredentialStore``. Assigning a property persists it immediately (write-through), and
/// SwiftUI can bind to it directly (`@Bindable var settings`; `Toggle(isOn: $settings.autoplay)`).
/// Values are normalised on assignment (clamped ranges, dependent switches), so read the property
/// back rather than assuming what you wrote stuck.
///
/// Credentials (scrobbler keys and tokens, the Discord token, WebDAV/SMB passwords, the PaxSenix
/// key, Spotify's sp_dc) are exposed here like any other setting but stored in the Keychain, which
/// keeps them out of ``exportPrefs()``.
///
/// Main-actor isolated: other actors read with `await settings.x`.
@MainActor
@Observable
public final class AppSettings {
    /// The app's instance: `UserDefaults.standard` and the Keychain.
    public static let shared = AppSettings()

    // MARK: Constants

    nonisolated public static let defaultAudioCacheLimitBytes: Int64 = 512 * 1_024 * 1_024
    nonisolated public static let maxAudioCacheLimitBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
    nonisolated public static let lyricsOffsetRangeMs: ClosedRange<Int> = -5_000...5_000
    nonisolated public static let defaultUpgradeLengthSlackSeconds = 3
    nonisolated public static let upgradeLengthSlackRange: ClosedRange<Int> = 0...10
    /// PORTING: crossfade 0–12 s.
    nonisolated public static let crossfadeRange: ClosedRange<Int> = 0...12
    /// PORTING Q10: 0.5×–2×.
    nonisolated public static let playbackSpeedRange: ClosedRange<Float> = 0.5...2.0
    /// How many playlists ``pinnedPlaylists`` can hold.
    nonisolated public static let maxPinnedPlaylists = 5
    /// The manual equaliser's band count (60, 150, 400, 1k, 2.5k, 6k, 14k Hz).
    nonisolated public static let equalizerBandCount = 7
    /// How far a manual slider travels either way, in dB.
    nonisolated public static let equalizerBandRangeDb: Float = 12
    /// How far the tone pad travels on each axis, in whole steps.
    nonisolated public static let equalizerToneSteps = 5
    /// One release gate shared by the settings UI and playback.
    nonisolated public static let scrobblingAvailable = true

    // MARK: Storage

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CredentialStoring
    @ObservationIgnored private let bundledLastfmAPIKey: String
    @ObservationIgnored private let bundledLastfmSecret: String
    /// True while reading from storage, so the read doesn't write every value straight back.
    @ObservationIgnored private var isLoading = false

    // MARK: Audio quality

    /// Streaming ceiling on an unmetered connection. The point of the split is that Wi-Fi can stay
    /// on Lossless while mobile data is capped; both default to Lossless because the mobile plan is
    /// the user's to budget, not ours to assume.
    public var audioQualityWifi: AudioQuality = .lossless {
        didSet { write(.audioQualityWifi, audioQualityWifi.rawValue) }
    }

    /// Streaming ceiling on a metered connection (cellular, hotspot, Low Data Mode).
    public var audioQualityCellular: AudioQuality = .lossless {
        didSet { write(.audioQualityCellular, audioQualityCellular.rawValue) }
    }

    /// Allowed duration difference, in seconds, when replacing a playing stream with a source's.
    public var upgradeLengthSlackSeconds: Int = AppSettings.defaultUpgradeLengthSlackSeconds {
        didSet {
            let clamped = upgradeLengthSlackSeconds.clamped(to: Self.upgradeLengthSlackRange)
            if clamped != upgradeLengthSlackSeconds { upgradeLengthSlackSeconds = clamped; return }
            write(.upgradeLengthSlackSeconds, upgradeLengthSlackSeconds)
        }
    }

    /// What a saved file should be, answered on its own terms: the streaming ceilings are about what
    /// this minute's connection costs, and a download outlives the minute. Data spend on downloads
    /// is ``wifiOnlyDownloads``' business.
    public var downloadQuality: DownloadQuality = .lossless {
        didSet { write(.downloadQuality, downloadQuality.rawValue) }
    }

    /// Refuse to start a download while the connection is metered (see ``downloadsAllowed(on:)``).
    /// On by default: with Lossless downloads a tap can cost 35 MB, and of silently overspending a
    /// data plan or refusing with a sentence naming this switch, only the second is recoverable.
    public var wifiOnlyDownloads: Bool = true {
        didSet { write(.wifiOnlyDownloads, wifiOnlyDownloads) }
    }

    // MARK: Playback

    /// Crossfade length in seconds; 0 is off. Clamped to ``crossfadeRange``.
    public var crossfadeSeconds: Int = 0 {
        didSet {
            let clamped = crossfadeSeconds.clamped(to: Self.crossfadeRange)
            if clamped != crossfadeSeconds { crossfadeSeconds = clamped; return }
            write(.crossfadeSeconds, crossfadeSeconds)
        }
    }

    /// Automix: let the analyser pick each transition's timing and length. ``crossfadeSeconds`` is
    /// only the fallback while a pair is still being analysed. Off by default: analysis costs a
    /// background decode per track.
    public var smartFadeEnabled: Bool = false {
        didSet { write(.smartFadeEnabled, smartFadeEnabled) }
    }

    /// CPU budget for Automix's beat and vocal analysis.
    public var automixPerformanceMode: AutomixPerformanceMode = .balanced {
        didSet { write(.automixPerformanceMode, automixPerformanceMode.rawValue) }
    }

    public var skipSilence: Bool = false {
        didSet { write(.skipSilence, skipSilence) }
    }

    /// Level every track to the same loudness using YouTube's per-track loudness figure
    /// (``ResolvedStream/loudnessDb``). On by default: a queue drawn from several sources spans
    /// mastering eras fifteen decibels apart. It is still a gain, so the audio pipeline readout
    /// names it as the first stage altering samples.
    public var loudnessNormalization: Bool = true {
        didSet { write(.loudnessNormalization, loudnessNormalization) }
    }

    /// Whether a source offering a Dolby Atmos rendition may serve it. The listener's answer,
    /// independent of whether this device can decode it (so a restored backup on another phone
    /// doesn't rewrite it). Atmos is lossy E-AC-3; someone on wired headphones may prefer the FLAC.
    public var dolbyAtmos: Bool = true {
        didSet { write(.dolbyAtmos, dolbyAtmos) }
    }

    /// When a track starts on a ranked source instead of on YouTube with the upgrade partway through
    /// (``StreamRequest/waitsForSources``, ``StreamRequest/readsAheadFromSources``). Playback only.
    public var directSourceStream: DirectSourceStream = .off {
        didSet {
            write(.directSourceStream, directSourceStream.rawValue)
            write(.directSourceStreamLegacy, directSourceStream == .always)
        }
    }

    /// The app's own stereo widening (not object-based spatial audio).
    public var spatialAudio: Bool = false {
        didSet { write(.spatialAudio, spatialAudio) }
    }

    /// Playback rate, clamped to ``playbackSpeedRange``.
    public var playbackSpeed: Float = 1.0 {
        didSet {
            let clamped = playbackSpeed.clamped(to: Self.playbackSpeedRange)
            if clamped != playbackSpeed { playbackSpeed = clamped; return }
            write(.playbackSpeed, playbackSpeed)
        }
    }

    /// Keep playing similar music once the queue runs out.
    public var autoplay: Bool = true {
        didSet { write(.autoplay, autoplay) }
    }

    /// Whether the queue is held in shuffled order.
    public var shuffleEnabled: Bool = false {
        didSet { write(.shuffleEnabled, shuffleEnabled) }
    }

    public var repeatMode: RepeatMode = .off {
        didSet { write(.repeatMode, repeatMode.rawValue) }
    }

    /// Swiping a song row plays it next instead of adding it to the end of the queue.
    public var swipeToPlayNext: Bool = false {
        didSet { write(.swipeToPlayNext, swipeToPlayNext) }
    }

    /// Once a song has been suggested or played this session, autoplay won't offer it again.
    public var dontRepeatSuggestions: Bool = false {
        didSet { write(.dontRepeatSuggestions, dontRepeatSuggestions) }
    }

    /// Prefer the catalogue audio release when the selected result is a music video. The video is
    /// still handed to the player first so its metadata shows while the match resolves.
    public var preferMusicOnly: Bool = false {
        didSet { write(.preferMusicOnly, preferMusicOnly) }
    }

    /// Align the playback moment by waveform when switching between song and video versions.
    public var smartVersionAlignment: Bool = true {
        didSet { write(.smartVersionAlignment, smartVersionAlignment) }
    }

    /// Disk budget for cached audio, clamped to default…10 GB (the floor is the default, not zero).
    public var audioCacheLimitBytes: Int64 = AppSettings.defaultAudioCacheLimitBytes {
        didSet {
            let clamped = audioCacheLimitBytes.clamped(to: Self.defaultAudioCacheLimitBytes...Self.maxAudioCacheLimitBytes)
            if clamped != audioCacheLimitBytes { audioCacheLimitBytes = clamped; return }
            write(.audioCacheLimitBytes, audioCacheLimitBytes)
        }
    }

    // MARK: Equalizer

    /// The app's own equaliser, master switch.
    public var equalizerEnabled: Bool = false {
        didSet { write(.equalizerEnabled, equalizerEnabled) }
    }

    /// Which tab drives the sound.
    public var equalizerMode: EqualizerMode = .dynamic {
        didSet { write(.equalizerMode, equalizerMode.rawValue) }
    }

    /// Tone pad, horizontal: warm at -5, bright at +5. Clamped to ±``equalizerToneSteps``.
    public var equalizerToneX: Int = 0 {
        didSet {
            let clamped = equalizerToneX.clamped(to: -Self.equalizerToneSteps...Self.equalizerToneSteps)
            if clamped != equalizerToneX { equalizerToneX = clamped; return }
            write(.equalizerToneX, equalizerToneX)
        }
    }

    /// Tone pad, vertical: scooped at -5, mid-forward at +5.
    public var equalizerToneY: Int = 0 {
        didSet {
            let clamped = equalizerToneY.clamped(to: -Self.equalizerToneSteps...Self.equalizerToneSteps)
            if clamped != equalizerToneY { equalizerToneY = clamped; return }
            write(.equalizerToneY, equalizerToneY)
        }
    }

    /// Tone pad bandwidth: broad when false, focused when true.
    public var equalizerFocused: Bool = false {
        didSet { write(.equalizerFocused, equalizerFocused) }
    }

    /// Left/right trim, -1 hard left to +1 hard right. Applies to both tabs.
    public var equalizerBalance: Float = 0 {
        didSet {
            let clamped = equalizerBalance.clamped(to: -1...1)
            if clamped != equalizerBalance { equalizerBalance = clamped; return }
            write(.equalizerBalance, equalizerBalance)
        }
    }

    /// The manual tab's seven gains in dB, low to high. Always exactly ``equalizerBandCount``
    /// values within ±``equalizerBandRangeDb`` (padded with 0 or truncated on assignment).
    ///
    /// Which preset these bands are is not stored: derive it with AudioDSP's preset matching, so a
    /// slider dragged back to where a preset left it shows that preset's name again. Applying a
    /// preset is assigning its bands here.
    public var equalizerBands: [Float] = Array(repeating: 0, count: AppSettings.equalizerBandCount) {
        didSet {
            let normalized = Self.normalizedBands(equalizerBands)
            if normalized != equalizerBands { equalizerBands = normalized; return }
            // One string rather than seven keys, so a backup carries them as one thing.
            write(.equalizerBands, equalizerBands.map { $0.description }.joined(separator: ","))
        }
    }

    // MARK: Appearance and player

    public var themeMode: ThemeMode = .dark {
        didSet { write(.themeMode, themeMode.rawValue) }
    }

    /// Put the playing track's codec, bitrate and sample rate on the player.
    public var showNerdStats: Bool = false {
        didSet { write(.showNerdStats, showNerdStats) }
    }

    /// Keep a log file on this device (``DiagnosticLog``). On by default; off deletes it.
    public var keepDiagnosticLog: Bool = true {
        didSet { write(.keepDiagnosticLog, keepDiagnosticLog) }
    }

    /// Freezes the player's mesh gradient instead of letting it drift and crossfade.
    public var reduceAnimation: Bool = false {
        didSet { write(.reduceAnimation, reduceAnimation) }
    }

    /// Solid fills instead of blur (status bar, mini player, bottom fade, lyrics focus).
    public var reduceDynamicBlur: Bool = false {
        didSet { write(.reduceDynamicBlur, reduceDynamicBlur) }
    }

    /// Hides the volume slider on the player.
    public var hideVolumeBar: Bool = false {
        didSet { write(.hideVolumeBar, hideVolumeBar) }
    }

    /// Shows up to 25 previously played songs above Now playing in the queue.
    public var showQueueHistory: Bool = false {
        didSet { write(.showQueueHistory, showQueueHistory) }
    }

    /// Hides the "Playing from" caption at the top of the player.
    public var hideSongStatus: Bool = false {
        didSet { write(.hideSongStatus, hideSongStatus) }
    }

    /// Cover art as a full-bleed banner off the top of the screen rather than a square card.
    public var fullBleedArtwork: Bool = true {
        didSet { write(.fullBleedArtwork, fullBleedArtwork) }
    }

    /// v1.5's backdrop: four quantised blobs drifting behind the player. Off by default (a mostly
    /// black cover with a red stripe quantises to a red screen, and drifting blobs are a full-screen
    /// blur redrawn while they move); kept because people asked for the old look.
    public var legacyMeshGradient: Bool = false {
        didSet { write(.legacyMeshGradient, legacyMeshGradient) }
    }

    /// Restores the expanded player to the surface the listener left open.
    public var lastPlayerScreen: LastPlayerScreen = .main {
        didSet { write(.lastPlayerScreen, lastPlayerScreen.rawValue) }
    }

    /// Hides the iOS status bar when the now playing player sheet is open.
    public var hideStatusBarInPlayer: Bool = false {
        didSet { write(.hideStatusBarInPlayer, hideStatusBarInPlayer) }
    }

    // MARK: Canvas

    /// A looping video behind the cover when one is published for the track.
    public var animatedCanvas: Bool = true {
        didSet { write(.animatedCanvas, animatedCanvas) }
    }

    /// Whether ``animatedCanvas`` may stream on a metered connection. Off by default: a clip loops
    /// for the whole track and every loop re-fetches it, which is how a reported 8 GB day happened.
    public var canvasOverCellular: Bool = false {
        didSet { write(.canvasOverCellular, canvasOverCellular) }
    }

    /// Collapse the lower controls after a Spotify canvas settles.
    public var spotifyCanvasAutoHide: Bool = true {
        didSet { write(.spotifyCanvasAutoHide, spotifyCanvasAutoHide) }
    }

    /// Try Spotify before Apple Music and the other animated-art providers.
    public var prioritizeSpotifyCanvas: Bool = false {
        didSet { write(.prioritizeSpotifyCanvas, prioritizeSpotifyCanvas) }
    }

    // MARK: Lyrics

    /// Time-synced lyrics on the player. Reaches third-party databases for every track, so it stays
    /// a switch, and ``lyricsSources`` narrows which get asked.
    public var syncedLyrics: Bool = true {
        didSet { write(.syncedLyrics, syncedLyrics) }
    }

    /// Blurs unfocused lyric lines, keeping the active line sharp.
    public var lyricsBlur: Bool = true {
        didSet { write(.lyricsBlur, lyricsBlur) }
    }

    /// Positive values delay synced lyrics, negative bring them forward. Clamped to ±5 s.
    public var lyricsOffsetMs: Int = 0 {
        didSet {
            let clamped = lyricsOffsetMs.clamped(to: Self.lyricsOffsetRangeMs)
            if clamped != lyricsOffsetMs { lyricsOffsetMs = clamped; return }
            write(.lyricsOffsetMs, lyricsOffsetMs)
        }
    }

    /// The language lyrics translate *into* (BCP-47). Blank means "whatever the app is set to", and
    /// is stored blank rather than resolved once, so changing the app language carries lyrics with it.
    public var translationLanguage: String = "" {
        didSet { write(.translationLanguage, translationLanguage) }
    }

    /// The databases ``syncedLyrics`` may ask. Empty is the same as off. A source added by an
    /// upgrade is enabled rather than treated as switched off (see `lyrics_sources_seen`).
    public var lyricsSources: Set<LyricsSource> = Set(LyricsSource.allCases) {
        didSet {
            write(.lyricsSources, Self.joinNames(LyricsSource.allCases.filter(lyricsSources.contains)))
            // Everything on the list this choice was made from, so a later build can tell a source
            // the user turned off from one they have never been shown.
            write(.lyricsSourcesSeen, Self.joinNames(LyricsSource.allCases))
        }
    }

    /// The order ``lyricsSources`` are asked in: every enabled source is asked at once, but a
    /// higher one still pending is never pre-empted by a lower one that answered first. Always a
    /// full permutation of ``LyricsSource/allCases`` (enabling and ordering are independent).
    public var lyricsSourceOrder: [LyricsSource] = LyricsSource.allCases {
        didSet {
            let normalized = Self.completedOrder(lyricsSourceOrder)
            if normalized != lyricsSourceOrder { lyricsSourceOrder = normalized; return }
            write(.lyricsSourceOrder, Self.joinNames(lyricsSourceOrder))
        }
    }

    /// Off: the highest-priority source to answer at all wins. On: a line-synced answer is held as
    /// a fallback while the rest are checked for a word-synced one.
    public var prioritizeSyllableSync: Bool = false {
        didSet { write(.prioritizeSyllableSync, prioritizeSyllableSync) }
    }

    /// User-issued credential for api.paxsenix.org (Keychain). Set with ``setPaxSenixApiKey(_:)``,
    /// which strips a pasted "Bearer " prefix.
    public private(set) var paxSenixApiKey: String = "" {
        didSet { writeCredential(.paxSenixApiKey, paxSenixApiKey) }
    }

    // MARK: Library

    /// Whether Replay may look up genres by artist name (the one part of Replay that isn't local).
    public var replayGenres: Bool = true {
        didSet { write(.replayGenres, replayGenres) }
    }

    /// Imported (Files) music ordering.
    public var localMusicSort: LocalMusicSort = .titleAsc {
        didSet { write(.localMusicSort, localMusicSort.rawValue) }
    }

    public var downloadedMusicSort: LocalMusicSort = .titleAsc {
        didSet { write(.downloadedMusicSort, downloadedMusicSort.rawValue) }
    }

    public var localMusicViewType: LibraryViewType = .list {
        didSet { write(.localMusicViewType, localMusicViewType.rawValue) }
    }

    public var downloadedMusicViewType: LibraryViewType = .list {
        didSet { write(.downloadedMusicViewType, downloadedMusicViewType.rawValue) }
    }

    /// Layout of the Recents shelf on Home.
    public var homeRecentsViewType: LibraryViewType = .list {
        didSet { write(.homeRecentsViewType, homeRecentsViewType.rawValue) }
    }

    /// Library "Show all" grid ordering.
    public var librarySort: LibrarySort = .default {
        didSet { write(.librarySort, librarySort.rawValue) }
    }

    /// Each album/playlist page's track order, keyed by browse id. Use ``detailSongSort(for:)`` and
    /// ``setDetailSongSort(_:for:)``.
    public private(set) var detailSongSorts: [String: SongSort] = [:] {
        didSet {
            let encoded = detailSongSorts.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.rawValue)" }
                .joined(separator: ",")
            write(.detailSongSorts, encoded)
        }
    }

    /// Browse ids pinned to the top of the Library tab, in pin order (order is part of what a pin
    /// means). At most ``maxPinnedPlaylists``; change with ``togglePinnedPlaylist(_:)``.
    public private(set) var pinnedPlaylists: [String] = [] {
        didSet { write(.pinnedPlaylists, pinnedPlaylists.joined(separator: ",")) }
    }

    // MARK: WebDAV and SMB

    /// WebDAV server root, trimmed and without a trailing slash. Empty means unconfigured.
    /// Change with ``configureWebDAV(url:username:password:)``.
    public private(set) var webdavUrl: String = "" {
        didSet { write(.webdavUrl, webdavUrl) }
    }

    public private(set) var webdavUsername: String = "" {
        didSet { write(.webdavUsername, webdavUsername) }
    }

    /// Keychain-backed.
    public private(set) var webdavPassword: String = "" {
        didSet { writeCredential(.webdavPassword, webdavPassword) }
    }

    /// SMB host. Empty host or share means unconfigured. Change with ``configureSMB(host:share:basePath:username:password:)``.
    public private(set) var smbHost: String = "" {
        didSet { write(.smbHost, smbHost) }
    }

    /// Share name, without surrounding slashes.
    public private(set) var smbShare: String = "" {
        didSet { write(.smbShare, smbShare) }
    }

    /// Folder inside the share, without surrounding slashes.
    public private(set) var smbBasePath: String = "" {
        didSet { write(.smbBasePath, smbBasePath) }
    }

    public private(set) var smbUsername: String = "" {
        didSet { write(.smbUsername, smbUsername) }
    }

    /// Keychain-backed.
    public private(set) var smbPassword: String = "" {
        didSet { writeCredential(.smbPassword, smbPassword) }
    }

    // MARK: Scrobbling

    public var lastfmEnabled: Bool = false {
        didSet { write(.lastfmEnabled, lastfmEnabled) }
    }

    public var lastfmUsername: String = "" {
        didSet { write(.lastfmUsername, lastfmUsername) }
    }

    /// Keychain-backed.
    public var lastfmSessionKey: String = "" {
        didSet { writeCredential(.lastfmSessionKey, lastfmSessionKey) }
    }

    /// Keychain-backed. Reads as the bundled key when the user hasn't set one.
    public var lastfmApiKey: String = "" {
        didSet { writeCredential(.lastfmApiKey, lastfmApiKey) }
    }

    /// Keychain-backed. Reads as the bundled secret when the user hasn't set one.
    public var lastfmSecret: String = "" {
        didSet { writeCredential(.lastfmSecret, lastfmSecret) }
    }

    /// A Last.fm-compatible API endpoint (Libre.fm); empty means Last.fm itself.
    public var lastfmEndpoint: String = "" {
        didSet { write(.lastfmEndpoint, lastfmEndpoint) }
    }

    /// Turning scrobbling off also turns off ``lastfmNowPlaying``.
    public var lastfmScrobbleEnabled: Bool = false {
        didSet {
            write(.lastfmScrobbleEnabled, lastfmScrobbleEnabled)
            if !lastfmScrobbleEnabled && lastfmNowPlaying { lastfmNowPlaying = false }
        }
    }

    /// "Now playing" updates. Can't be on while ``lastfmScrobbleEnabled`` is off.
    public var lastfmNowPlaying: Bool = false {
        didSet {
            if lastfmNowPlaying && !lastfmScrobbleEnabled { lastfmNowPlaying = false; return }
            write(.lastfmNowPlaying, lastfmNowPlaying)
        }
    }

    /// Send only the first credited artist (see ``ArtistCredit/primary(of:)``).
    public var lastfmPrimaryArtistOnly: Bool = false {
        didSet { write(.lastfmPrimaryArtistOnly, lastfmPrimaryArtistOnly) }
    }

    /// Tracks shorter than this many seconds are never scrobbled.
    public var scrobbleMinDuration: Int = 30 {
        didSet { write(.scrobbleMinDuration, scrobbleMinDuration) }
    }

    /// Scrobble once this fraction of the track has played…
    public var scrobbleDelayPercent: Float = 0.5 {
        didSet { write(.scrobbleDelayPercent, scrobbleDelayPercent) }
    }

    /// …or this many seconds, whichever comes first.
    public var scrobbleDelaySeconds: Int = 180 {
        didSet { write(.scrobbleDelaySeconds, scrobbleDelaySeconds) }
    }

    public var listenBrainzEnabled: Bool = false {
        didSet { write(.listenBrainzEnabled, listenBrainzEnabled) }
    }

    /// Keychain-backed.
    public var listenBrainzToken: String = "" {
        didSet { writeCredential(.listenBrainzToken, listenBrainzToken) }
    }

    public var listenBrainzPrimaryArtistOnly: Bool = false {
        didSet { write(.listenBrainzPrimaryArtistOnly, listenBrainzPrimaryArtistOnly) }
    }

    /// Spotify `sp_dc` cookie for the Spotify canvas provider. Keychain-backed.
    public var spotifySpdcToken: String = "" {
        didSet { writeCredential(.spotifySpdcToken, spotifySpdcToken) }
    }

    // MARK: Discord Rich Presence

    /// The connected Discord account's token; empty means not connected. Keychain-backed: unlike a
    /// scrobbler key, this one *is* the account.
    public var discordToken: String = "" {
        didSet { writeCredential(.discordToken, discordToken) }
    }

    /// Cached at login so settings can show the account offline. Set with ``setDiscordAccount(username:name:avatar:)``.
    public private(set) var discordUsername: String = "" {
        didSet { write(.discordUsername, discordUsername) }
    }

    public private(set) var discordName: String = "" {
        didSet { write(.discordName, discordName) }
    }

    public private(set) var discordAvatar: String = "" {
        didSet { write(.discordAvatar, discordAvatar) }
    }

    public var discordRpcEnabled: Bool = true {
        didSet { write(.discordRpcEnabled, discordRpcEnabled) }
    }

    /// Put the track title on the bold profile line, in place of the artist.
    public var discordUseDetails: Bool = false {
        didSet { write(.discordUseDetails, discordUseDetails) }
    }

    /// Show measured Hi-Res, Lossless or Dolby specs on the presence card.
    public var discordShowAudioQuality: Bool = true {
        didSet { write(.discordShowAudioQuality, discordShowAudioQuality) }
    }

    /// Reveals the presence-shape controls: status, activity type and name, buttons.
    public var discordAdvancedMode: Bool = false {
        didSet { write(.discordAdvancedMode, discordAdvancedMode) }
    }

    public var discordStatus: String = "online" {
        didSet { write(.discordStatus, discordStatus) }
    }

    public var discordActivityType: String = "listening" {
        didSet { write(.discordActivityType, discordActivityType) }
    }

    /// Overrides the "Listening to ___" line; empty means the app's own name.
    public var discordActivityName: String = "" {
        didSet { write(.discordActivityName, discordActivityName) }
    }

    public var discordButton1Text: String = "" {
        didSet { write(.discordButton1Text, discordButton1Text) }
    }

    public var discordButton1Visible: Bool = true {
        didSet { write(.discordButton1Visible, discordButton1Visible) }
    }

    public var discordButton2Text: String = "" {
        didSet { write(.discordButton2Text, discordButton2Text) }
    }

    public var discordButton2Visible: Bool = true {
        didSet { write(.discordButton2Visible, discordButton2Visible) }
    }

    /// The notice about what connecting an account does has been read.
    public var discordInfoDismissed: Bool = false {
        didSet { write(.discordInfoDismissed, discordInfoDismissed) }
    }

    // MARK: Init

    /// - Parameters:
    ///   - defaults: where settings persist. Tests pass an ephemeral suite.
    ///   - credentials: where credentials persist. Tests pass an ``InMemoryCredentialStore``.
    ///   - bundledLastfmAPIKey/bundledLastfmSecret: the build's own Last.fm app credentials (the
    ///     `LASTFM_API_KEY` and `LASTFM_API_SECRET` build settings, empty unless passed to the
    ///     build), used when the user hasn't entered their own.
    public init(
        defaults: UserDefaults = .standard,
        credentials: CredentialStoring = KeychainStore(),
        bundledLastfmAPIKey: String = "",
        bundledLastfmSecret: String = ""
    ) {
        self.defaults = defaults
        self.credentials = credentials
        self.bundledLastfmAPIKey = bundledLastfmAPIKey
        self.bundledLastfmSecret = bundledLastfmSecret
        readAll()
    }

    /// Re-reads every setting from storage. Call after something wrote underneath this instance
    /// (``importPrefs(_:)`` does it for you).
    public func reload() {
        readAll()
    }

    // MARK: Derived values

    /// The ceiling for a stream started now: the cellular one on a metered connection, the Wi-Fi
    /// one otherwise (including offline).
    public func effectiveAudioQuality(for network: NetworkStatus) -> AudioQuality {
        network.isMetered == true ? audioQualityCellular : audioQualityWifi
    }

    /// What to ask the resolver for, for a stream started now on `network`.
    public func playbackStreamRequest(for network: NetworkStatus) -> StreamRequest {
        .playback(effectiveAudioQuality(for: network), directSource: directSourceStream)
    }

    /// What to ask the resolver for, for a download (independent of the connection).
    public var downloadStreamRequest: StreamRequest {
        .download(downloadQuality)
    }

    /// Whether a download may start on `network`. Offline is allowed through on purpose: a download
    /// with nothing to download over fails on the network and says so, which is true, where refusing
    /// here would blame a Wi-Fi setting for an outage.
    public func downloadsAllowed(on network: NetworkStatus) -> Bool {
        !wifiOnlyDownloads || network.isMetered != true
    }

    /// Whether an animated canvas may stream on `network` (still art is always allowed).
    public func animatedCanvasAllowed(on network: NetworkStatus) -> Bool {
        animatedCanvas && (canvasOverCellular || network.isMetered != true)
    }

    /// The sources lyrics may ask, in the order to ask them.
    public var enabledLyricsSourcesInOrder: [LyricsSource] {
        guard syncedLyrics else { return [] }
        return lyricsSourceOrder.filter(lyricsSources.contains)
    }

    public var isWebDAVConfigured: Bool { !webdavUrl.isEmpty }
    public var isSMBConfigured: Bool { !smbHost.isEmpty && !smbShare.isEmpty }

    // MARK: Actions

    /// Stores the PaxSenix key, trimmed and without a pasted `Bearer ` prefix.
    public func setPaxSenixApiKey(_ value: String) {
        paxSenixApiKey = Self.normalizedPaxSenixKey(value)
    }

    /// Puts the lyrics source list, its order and ``prioritizeSyllableSync`` back the way a fresh
    /// install has them. ``syncedLyrics`` is left alone: this is "start over on *which* lyrics".
    public func resetLyricsSourceSettings() {
        lyricsSources = Set(LyricsSource.allCases)
        lyricsSourceOrder = LyricsSource.allCases
        prioritizeSyllableSync = false
    }

    public func detailSongSort(for browseId: String) -> SongSort {
        detailSongSorts[browseId] ?? .default
    }

    public func setDetailSongSort(_ sort: SongSort, for browseId: String) {
        detailSongSorts[browseId] = sort
    }

    /// Pins or unpins `browseId`; returns whether it is pinned afterwards. Pinning past
    /// ``maxPinnedPlaylists`` is refused rather than evicting the oldest pin — a playlist pinned on
    /// purpose must not vanish because a sixth was pinned. Unpinning always succeeds.
    @discardableResult
    public func togglePinnedPlaylist(_ browseId: String) -> Bool {
        if let index = pinnedPlaylists.firstIndex(of: browseId) {
            pinnedPlaylists.remove(at: index)
            return false
        }
        guard pinnedPlaylists.count < Self.maxPinnedPlaylists else { return false }
        pinnedPlaylists.append(browseId)
        return true
    }

    /// Saves the WebDAV connection. The URL is trimmed with trailing slashes removed, the username
    /// trimmed; the password goes to the Keychain as given ("" forgets it).
    public func configureWebDAV(url: String, username: String, password: String) {
        webdavUrl = Self.trimTrailingSlashes(url.trimmingCharacters(in: .whitespacesAndNewlines))
        webdavUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        webdavPassword = password
    }

    public func clearWebDAV() {
        configureWebDAV(url: "", username: "", password: "")
    }

    /// Saves the SMB connection. Host and username are trimmed; share and base path are trimmed of
    /// whitespace and surrounding slashes; the password goes to the Keychain as given.
    public func configureSMB(host: String, share: String, basePath: String, username: String, password: String) {
        smbHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        smbShare = Self.trimSlashes(share.trimmingCharacters(in: .whitespacesAndNewlines))
        smbBasePath = Self.trimSlashes(basePath.trimmingCharacters(in: .whitespacesAndNewlines))
        smbUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        smbPassword = password
    }

    public func clearSMB() {
        configureSMB(host: "", share: "", basePath: "", username: "", password: "")
    }

    /// Caches who the Discord token belongs to.
    public func setDiscordAccount(username: String, name: String, avatar: String?) {
        discordUsername = username
        discordName = name
        discordAvatar = avatar ?? ""
    }

    /// Forgets the Discord account: token and cached profile.
    public func clearDiscordAccount() {
        discordToken = ""
        setDiscordAccount(username: "", name: "", avatar: nil)
    }

    /// True the first time this is called with a `currentVersionCode` other than the last recorded
    /// one, which it then records: once per update, on the first launch after it installs. Call
    /// once per launch, before reading caches another build may have written.
    ///
    /// Two cases differ from Android, which only reports a rise. No record counts: 0.9.0 (build 1)
    /// shipped before anything recorded a build, so a device updating from it has no record and
    /// still holds 0.9.0's caches (on a fresh install they're empty, so clearing them costs
    /// nothing). A downgrade counts too: sideloading can install an older build over a newer one
    /// and keep its data, which Android doesn't allow, and the older code didn't write those caches
    /// either.
    public func consumeVersionUpdate(currentVersionCode: Int) -> Bool {
        guard isVersionUpdate(currentVersionCode: currentVersionCode) else { return false }
        recordVersionCode(currentVersionCode)
        return true
    }

    /// Whether `currentVersionCode` differs from the recorded one, without recording it. For work
    /// that may fail halfway and must run again next launch: record only once it has finished.
    public func isVersionUpdate(currentVersionCode: Int) -> Bool {
        (defaults.object(forKey: Key.lastVersionCode.rawValue) as? NSNumber)?.intValue != currentVersionCode
    }

    public func recordVersionCode(_ currentVersionCode: Int) {
        defaults.set(currentVersionCode, forKey: Key.lastVersionCode.rawValue)
    }

    // MARK: Backup

    /// The keys a backup may carry, i.e. every setting except device-local ones. Credentials are
    /// never among them (they aren't in `UserDefaults`).
    nonisolated public static var backupKeys: [String] {
        Key.allCases.filter { !$0.isDeviceLocal }.map(\.rawValue)
    }

    /// Every stored setting, typed, for an export (Replay's Backup writes these under
    /// `settings`). Only keys that have been written are included, like Android's `prefs.all`.
    /// Credentials are excluded by construction: they live in the Keychain. Includes the search
    /// history (`search_history`), which shares this storage as it does on Android.
    public func exportPrefs() -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        for key in Key.allCases where !key.isDeviceLocal {
            guard let object = defaults.object(forKey: key.rawValue),
                  let value = SettingValue(defaultsObject: object, kind: key.kind) else { continue }
            out[key.rawValue] = value
        }
        return out
    }

    /// Replaces the stored settings with `values` and re-reads them.
    ///
    /// A replace, not a merge: a partial restore leaves the device holding half of one
    /// configuration and half of another. Credentials and device-local keys survive untouched (the
    /// backup has nothing to say about them). Unknown keys — Android-only settings, or ones from a
    /// newer build — and values that can't be the key's type are skipped. Returns the number of
    /// settings applied. Call ``SearchHistory/reload()`` afterwards.
    @discardableResult
    public func importPrefs(_ values: [String: SettingValue]) -> Int {
        for key in Key.allCases where !key.isDeviceLocal {
            defaults.removeObject(forKey: key.rawValue)
        }
        var applied = 0
        for (name, value) in values {
            guard let key = Key(rawValue: name), !key.isDeviceLocal else { continue }
            // Pins are stored comma-joined, but a backup may carry them as a string set; a set has
            // no order, so sorting is the only stable one to restore.
            let restored = key == .pinnedPlaylists
                ? value.stringSetValue.map { $0.sorted().prefix(Self.maxPinnedPlaylists).joined(separator: ",") }
                : nil
            guard let object = restored ?? value.defaultsObject(as: key.kind) else { continue }
            defaults.set(object, forKey: name)
            applied += 1
        }
        readAll()
        return applied
    }

    // MARK: Reading

    private func readAll() {
        isLoading = true
        defer { isLoading = false }

        migrateSingleQuality()
        audioQualityWifi = readEnum(.audioQualityWifi, default: .lossless)
        audioQualityCellular = readEnum(.audioQualityCellular, default: .lossless)
        upgradeLengthSlackSeconds = readInt(.upgradeLengthSlackSeconds, default: Self.defaultUpgradeLengthSlackSeconds)
        migrateDownloadQuality()
        downloadQuality = readEnum(.downloadQuality, default: .lossless)
        wifiOnlyDownloads = readBool(.wifiOnlyDownloads, default: true)

        crossfadeSeconds = readInt(.crossfadeSeconds, default: 0)
        smartFadeEnabled = readBool(.smartFadeEnabled, default: false)
        automixPerformanceMode = readEnum(.automixPerformanceMode, default: .balanced)
        skipSilence = readBool(.skipSilence, default: false)
        loudnessNormalization = readBool(.loudnessNormalization, default: true)
        dolbyAtmos = readBool(.dolbyAtmos, default: true)
        migrateDirectSourceStream()
        directSourceStream = readEnum(.directSourceStream, default: .off)
        spatialAudio = readBool(.spatialAudio, default: false)
        playbackSpeed = readFloat(.playbackSpeed, default: 1.0)
        autoplay = readBool(.autoplay, default: true)
        shuffleEnabled = readBool(.shuffleEnabled, default: false)
        repeatMode = RepeatMode(rawValue: readInt(.repeatMode, default: RepeatMode.off.rawValue)) ?? .off
        swipeToPlayNext = readBool(.swipeToPlayNext, default: false)
        dontRepeatSuggestions = readBool(.dontRepeatSuggestions, default: false)
        preferMusicOnly = readBool(.preferMusicOnly, default: false)
        smartVersionAlignment = readBool(.smartVersionAlignment, default: true)
        audioCacheLimitBytes = readInt64(.audioCacheLimitBytes, default: Self.defaultAudioCacheLimitBytes)

        equalizerEnabled = readBool(.equalizerEnabled, default: false)
        equalizerMode = readEnum(.equalizerMode, default: .dynamic)
        equalizerToneX = readInt(.equalizerToneX, default: 0)
        equalizerToneY = readInt(.equalizerToneY, default: 0)
        equalizerFocused = readBool(.equalizerFocused, default: false)
        equalizerBalance = readFloat(.equalizerBalance, default: 0)
        // Padded rather than rejected: a backup from a build with a different band count restores
        // the bands it does have.
        equalizerBands = Self.normalizedBands(
            (readString(.equalizerBands) ?? "").split(separator: ",")
                .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        )

        themeMode = readEnum(.themeMode, default: .dark)
        showNerdStats = readBool(.showNerdStats, default: false)
        keepDiagnosticLog = readBool(.keepDiagnosticLog, default: true)
        reduceAnimation = readBool(.reduceAnimation, default: false)
        reduceDynamicBlur = readBool(.reduceDynamicBlur, default: false)
        hideVolumeBar = readBool(.hideVolumeBar, default: false)
        showQueueHistory = readBool(.showQueueHistory, default: false)
        hideSongStatus = readBool(.hideSongStatus, default: false)
        fullBleedArtwork = readBool(.fullBleedArtwork, default: true)
        legacyMeshGradient = readBool(.legacyMeshGradient, default: false)
        lastPlayerScreen = readEnum(.lastPlayerScreen, default: .main)
        hideStatusBarInPlayer = readBool(.hideStatusBarInPlayer, default: false)

        animatedCanvas = readBool(.animatedCanvas, default: true)
        canvasOverCellular = readBool(.canvasOverCellular, default: false)
        spotifyCanvasAutoHide = readBool(.spotifyCanvasAutoHide, default: true)
        prioritizeSpotifyCanvas = readBool(.prioritizeSpotifyCanvas, default: false)

        syncedLyrics = readBool(.syncedLyrics, default: true)
        lyricsBlur = readBool(.lyricsBlur, default: true)
        lyricsOffsetMs = readInt(.lyricsOffsetMs, default: 0)
        translationLanguage = readString(.translationLanguage) ?? ""
        lyricsSources = readLyricsSources()
        lyricsSourceOrder = Self.completedOrder(Self.parseNames(readString(.lyricsSourceOrder)))
        prioritizeSyllableSync = readBool(.prioritizeSyllableSync, default: false)
        paxSenixApiKey = readCredential(.paxSenixApiKey)

        replayGenres = readBool(.replayGenres, default: true)
        localMusicSort = readEnum(.localMusicSort, default: .titleAsc)
        downloadedMusicSort = readEnum(.downloadedMusicSort, default: .titleAsc)
        localMusicViewType = readEnum(.localMusicViewType, default: .list)
        downloadedMusicViewType = readEnum(.downloadedMusicViewType, default: .list)
        homeRecentsViewType = readEnum(.homeRecentsViewType, default: .list)
        librarySort = readEnum(.librarySort, default: .default)
        detailSongSorts = readDetailSongSorts()
        pinnedPlaylists = (readString(.pinnedPlaylists) ?? "")
            .split(separator: ",").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        webdavUrl = readString(.webdavUrl) ?? ""
        webdavUsername = readString(.webdavUsername) ?? ""
        webdavPassword = readCredential(.webdavPassword)
        smbHost = readString(.smbHost) ?? ""
        smbShare = readString(.smbShare) ?? ""
        smbBasePath = readString(.smbBasePath) ?? ""
        smbUsername = readString(.smbUsername) ?? ""
        smbPassword = readCredential(.smbPassword)

        lastfmEnabled = readBool(.lastfmEnabled, default: false)
        lastfmUsername = readString(.lastfmUsername) ?? ""
        lastfmSessionKey = readCredential(.lastfmSessionKey)
        lastfmApiKey = readCredential(.lastfmApiKey).ifBlank(bundledLastfmAPIKey)
        lastfmSecret = readCredential(.lastfmSecret).ifBlank(bundledLastfmSecret)
        lastfmEndpoint = readString(.lastfmEndpoint) ?? ""
        lastfmScrobbleEnabled = readBool(.lastfmScrobbleEnabled, default: false)
        lastfmNowPlaying = readBool(.lastfmNowPlaying, default: false) && lastfmScrobbleEnabled
        lastfmPrimaryArtistOnly = readBool(.lastfmPrimaryArtistOnly, default: false)
        scrobbleMinDuration = readInt(.scrobbleMinDuration, default: 30)
        scrobbleDelayPercent = readFloat(.scrobbleDelayPercent, default: 0.5)
        scrobbleDelaySeconds = readInt(.scrobbleDelaySeconds, default: 180)
        listenBrainzEnabled = readBool(.listenBrainzEnabled, default: false)
        listenBrainzToken = readCredential(.listenBrainzToken)
        listenBrainzPrimaryArtistOnly = readBool(.listenBrainzPrimaryArtistOnly, default: false)
        spotifySpdcToken = readCredential(.spotifySpdcToken)

        discordToken = readCredential(.discordToken)
        discordUsername = readString(.discordUsername) ?? ""
        discordName = readString(.discordName) ?? ""
        discordAvatar = readString(.discordAvatar) ?? ""
        discordRpcEnabled = readBool(.discordRpcEnabled, default: true)
        discordUseDetails = readBool(.discordUseDetails, default: false)
        discordShowAudioQuality = readBool(.discordShowAudioQuality, default: true)
        discordAdvancedMode = readBool(.discordAdvancedMode, default: false)
        discordStatus = readString(.discordStatus) ?? "online"
        discordActivityType = readString(.discordActivityType) ?? "listening"
        discordActivityName = readString(.discordActivityName) ?? ""
        discordButton1Text = readString(.discordButton1Text) ?? ""
        discordButton1Visible = readBool(.discordButton1Visible, default: true)
        discordButton2Text = readString(.discordButton2Text) ?? ""
        discordButton2Visible = readBool(.discordButton2Visible, default: true)
        discordInfoDismissed = readBool(.discordInfoDismissed, default: false)
    }

    /// A ceiling saved when there was only one applies to both connections: someone who picked Low
    /// to protect a data plan would not thank us for putting Wi-Fi *and* mobile back on Lossless.
    private func migrateSingleQuality() {
        guard let legacy = defaults.string(forKey: Key.audioQualityLegacy.rawValue) else { return }
        defaults.set(legacy, forKey: Key.audioQualityWifi.rawValue)
        defaults.set(legacy, forKey: Key.audioQualityCellular.rawValue)
        defaults.removeObject(forKey: Key.audioQualityLegacy.rawValue)
    }

    /// The switch's answer carried over where the three-way choice was never stored (an install
    /// from before Queue only, or a backup from one or from Android): on is Always, off is Off.
    private func migrateDirectSourceStream() {
        guard defaults.object(forKey: Key.directSourceStream.rawValue) == nil,
              let legacy = defaults.object(forKey: Key.directSourceStreamLegacy.rawValue) as? NSNumber else { return }
        let mode: DirectSourceStream = legacy.boolValue ? .always : .off
        defaults.set(mode.rawValue, forKey: Key.directSourceStream.rawValue)
    }

    /// Writes down the download quality the old derived behaviour produced (Lossless for all but a
    /// few installs, and what a fresh install gets anyway) before it starts being asked instead.
    private func migrateDownloadQuality() {
        guard defaults.object(forKey: Key.downloadQuality.rawValue) == nil else { return }
        defaults.set(DownloadQuality.lossless.rawValue, forKey: Key.downloadQuality.rawValue)
    }

    /// A stored list is a decision only about the sources it was chosen from. A source added since
    /// (absent from `lyrics_sources_seen`, or from the legacy list when that key predates it) is
    /// enabled rather than silently off. Names that no longer exist fall out.
    private func readLyricsSources() -> Set<LyricsSource> {
        guard let stored = readString(.lyricsSources) else { return Set(LyricsSource.allCases) }
        let chosen = Set(Self.parseNames(stored) as [LyricsSource])
        let seen = readString(.lyricsSourcesSeen).map { Set(Self.parseNames($0) as [LyricsSource]) }
            ?? LyricsSource.legacySources
        return chosen.union(LyricsSource.allCases.filter { !seen.contains($0) })
    }

    private func readDetailSongSorts() -> [String: SongSort] {
        var out: [String: SongSort] = [:]
        for entry in (readString(.detailSongSorts) ?? "").split(separator: ",") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let id = String(entry[..<equals])
            guard !id.trimmingCharacters(in: .whitespaces).isEmpty,
                  let sort = SongSort(rawValue: String(entry[entry.index(after: equals)...])) else { continue }
            out[id] = sort
        }
        return out
    }

    private func readBool(_ key: Key, default fallback: Bool) -> Bool {
        (defaults.object(forKey: key.rawValue) as? NSNumber)?.boolValue ?? fallback
    }

    private func readInt(_ key: Key, default fallback: Int) -> Int {
        (defaults.object(forKey: key.rawValue) as? NSNumber)?.intValue ?? fallback
    }

    private func readInt64(_ key: Key, default fallback: Int64) -> Int64 {
        (defaults.object(forKey: key.rawValue) as? NSNumber)?.int64Value ?? fallback
    }

    private func readFloat(_ key: Key, default fallback: Float) -> Float {
        (defaults.object(forKey: key.rawValue) as? NSNumber)?.floatValue ?? fallback
    }

    private func readString(_ key: Key) -> String? {
        defaults.object(forKey: key.rawValue) as? String
    }

    private func readEnum<E: RawRepresentable>(_ key: Key, default fallback: E) -> E where E.RawValue == String {
        readString(key).flatMap(E.init(rawValue:)) ?? fallback
    }

    private func readCredential(_ key: CredentialKey) -> String {
        do {
            return try credentials.string(forKey: key.rawValue) ?? ""
        } catch {
            DebugLog.w("VibraMusicCore", "Couldn't read credential \(key.rawValue)", error: error)
            return ""
        }
    }

    // MARK: Writing

    private func write(_ key: Key, _ value: Any) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key.rawValue)
    }

    private func writeCredential(_ key: CredentialKey, _ value: String) {
        guard !isLoading else { return }
        do {
            try credentials.setString(value, forKey: key.rawValue)
        } catch {
            DebugLog.e("VibraMusicCore", "Couldn't store credential \(key.rawValue)", error: error)
        }
    }

    // MARK: Normalisation helpers

    nonisolated static func normalizedBands(_ values: [Float]) -> [Float] {
        (0..<equalizerBandCount).map { index in
            let value = index < values.count ? values[index] : 0
            return value.isFinite ? value.clamped(to: -equalizerBandRangeDb...equalizerBandRangeDb) : 0
        }
    }

    /// The saved order, with names that no longer exist dropped and new sources appended in
    /// declaration order, so a fresh install and an upgraded one agree on where a new one lands.
    nonisolated static func completedOrder(_ saved: [LyricsSource]) -> [LyricsSource] {
        var seen = Set<LyricsSource>()
        let unique = saved.filter { seen.insert($0).inserted }
        return unique + LyricsSource.allCases.filter { !seen.contains($0) }
    }

    nonisolated static func parseNames<E: RawRepresentable>(_ joined: String?) -> [E] where E.RawValue == String {
        (joined ?? "").split(separator: ",").compactMap { E(rawValue: String($0)) }
    }

    nonisolated static func joinNames<E: RawRepresentable>(_ values: [E]) -> String where E.RawValue == String {
        values.map(\.rawValue).joined(separator: ",")
    }

    /// PaxSenix keys are sometimes pasted with the HTTP scheme attached.
    nonisolated static func normalizedPaxSenixKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bearer "), let space = trimmed.firstIndex(of: " ") else {
            return trimmed
        }
        return trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func trimSlashes(_ value: String) -> String {
        Self.trimTrailingSlashes(String(value.drop(while: { $0 == "/" })))
    }

    nonisolated static func trimTrailingSlashes(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension String {
    fileprivate func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
