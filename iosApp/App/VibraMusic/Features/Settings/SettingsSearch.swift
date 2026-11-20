import Foundation

// Ports SettingsSearch / SettingsGroupScope / SearchableSettingsGroup from ui/screens/SettingsSheet.kt.
//
// Android decided which rows answered the query while composing them; here the same decision is a
// value (`SettingsCatalog.groups`) the screen renders, so the filtering is testable without a view.

/// What is typed into the search field, and whether a group, a row, or anything at all answered.
///
/// A blank query matches everything, so the screen with the field untouched is the screen as it
/// was before there was a field.
struct SettingsSearch {
    /// Trimmed, because a trailing space is a typo rather than a search for something ending in one
    /// — and on a phone keyboard it is one keystroke away from every word typed.
    let needle: String

    init(_ query: String) {
        needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBlank: Bool { needle.isEmpty }

    /// Whether any of `keywords` contains the query, ignoring case (and, as iOS search does,
    /// diacritics). The group header counts for every row beneath it: searching "playback" turns up
    /// the playback group entire, not nothing at all.
    func matches(_ keywords: [String?]) -> Bool {
        guard !needle.isEmpty else { return true }
        return keywords.contains { keyword in
            guard let keyword else { return false }
            return keyword.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// Every row on the Settings screen, in Android's order.
///
/// Rows Android draws that iOS can't honour are left out, per PORTING.md §3: Output precision and
/// Prefer USB DAC (Android output rules), Liquid Glass (Haze/glass shaders; SwiftUI materials are
/// always on), Export compatible downloads (no shared Music folder), Stop music on close (iOS has
/// no task-removed callback for a playing audio app), the whole Performance group (ProMotion is the
/// system's) and the whole Local music group (MediaStore scanning; Files imports live on the
/// Downloads screen).
enum SettingsRowID: String, CaseIterable, Hashable {
    // No header: the account and the party.
    case account, listenTogether
    // Audio quality
    case source, onWifi, onMobileData, dolbyAtmos, directSourceStream
    // Downloads
    case downloadQuality, downloadWifiOnly
    // Playback
    case preferMusicOnly, loudnessNormalization, crossfade, automix, automixPerformance, skipSilence,
         spatialAudio, equalizer
    // Appearance
    case theme, reduceAnimation, reduceDynamicBlur, fullScreenCoverArt, legacyMeshGradient,
         animatedCoverArt, animatedCoverCellular, spotifyCanvas, syncedLyrics, lyricsBlur,
         lyricsSources, translationLanguage
    // Storage
    case songCacheLimit, clearSongCache, clearImageCache
    // Your data
    case replay, workOutGenres, exportData, importData
    // Miscellaneous
    case playNextOnSwipe, dontRepeatSongs, hideVolumeBar, showQueueHistory, hideSongStatus, hideStatusBarInPlayer
    // Language
    case appLanguage
    // Advanced
    case smartVersionAlignment, showNerdStats, appIcon, keepDiagnosticLog, shareDiagnosticLog
}

/// One searchable setting: what somebody might type looking for it, and whether it is drawn as
/// part of the row above it (Android's `divided = false`) rather than as a setting of its own.
struct SettingsRowSpec: Hashable, Identifiable {
    let id: SettingsRowID
    let keywords: [String]
    var isSubRow = false
}

/// One group of rows under an optional header.
struct SettingsGroupSpec: Hashable, Identifiable {
    let id: String
    let header: String?
    var rows: [SettingsRowSpec]
}

/// The switches that decide which rows exist at all, read off `AppSettings`.
struct SettingsVisibility: Hashable {
    /// Automix picks its own overlap, so the crossfade slider goes while it is on.
    var automix = false
    /// The cellular and Spotify rows only mean something while animated covers are on.
    var animatedCanvas = true
    /// The lyrics blur, sources and translation rows only mean something while synced lyrics are on.
    var syncedLyrics = true
    /// The app icon row only where the system can change the icon: not on Mac Catalyst, which
    /// keeps one Dock icon.
    var alternateIcons = true
    /// Sharing the log file only means something while it is being kept.
    var diagnosticLog = true
}

/// The Settings screen's rows, grouped and filtered.
enum SettingsCatalog {
    /// Every group that has a row answering `search`, with only those rows, in Android's order. An
    /// empty result is the "no settings match" state.
    static func groups(visibility: SettingsVisibility, search: SettingsSearch) -> [SettingsGroupSpec] {
        allGroups(visibility: visibility).compactMap { group in
            var filtered = group
            filtered.rows = group.rows.filter { search.matches([group.header] + $0.keywords) }
            return filtered.rows.isEmpty ? nil : filtered
        }
    }

    /// Every group and row that exists for these switches, before any search.
    static func allGroups(visibility v: SettingsVisibility) -> [SettingsGroupSpec] {
        func row(_ id: SettingsRowID, _ title: String, _ extra: String..., sub: Bool = false) -> SettingsRowSpec {
            SettingsRowSpec(id: id, keywords: [title] + extra, isSubRow: sub)
        }
        var playback = [
            row(.preferMusicOnly, L10n.preferMusicOnly, "video", "audio", "music video"),
            row(.loudnessNormalization, L10n.loudnessNormalization, "loudness", "volume", "normalize", "replaygain", "lufs"),
        ]
        if !v.automix {
            playback.append(row(.crossfade, L10n.crossfade, "fade", "gapless"))
        }
        playback += [
            row(.automix, L10n.automix, "crossfade", "smart fade", "mix"),
            row(.automixPerformance, L10n.automixPerformance, "cpu", "battery"),
            row(.skipSilence, L10n.skipSilence, "silence"),
            row(.spatialAudio, L10n.spatialAudio, "surround", "3d"),
            row(.equalizer, L10n.equalizer, "eq", "bass", "treble"),
        ]

        var appearance = [
            row(.theme, L10n.theme, "dark mode", "light mode"),
            row(.reduceAnimation, L10n.reduceAnimation, "motion"),
            row(.reduceDynamicBlur, L10n.reduceDynamicBlur, "blur", "performance"),
            row(.fullScreenCoverArt, L10n.fullScreenCoverArt, "artwork", "player"),
            row(.legacyMeshGradient, L10n.legacyMeshGradient, "background", "player"),
            // Carries the keywords of the rows that only appear once it is on, so searching
            // "spotify" with animated covers off turns up the switch that brings that row back.
            row(.animatedCoverArt, L10n.animatedCoverArt, "canvas", "video", "spotify"),
        ]
        if v.animatedCanvas {
            appearance += [
                row(.animatedCoverCellular, L10n.animatedCoverCellular, "canvas", "cellular", sub: true),
                row(.spotifyCanvas, L10n.integrateSpotifyCanvas, "spotify", "canvas", sub: true),
            ]
        }
        appearance.append(row(.syncedLyrics, L10n.syncedLyrics, "lyrics", "translation", "lrclib", "musixmatch"))
        if v.syncedLyrics {
            appearance += [
                row(.lyricsBlur, L10n.blurUnfocusedLyrics, "lyrics", "blur"),
                row(.lyricsSources, L10n.lyricsSources, "lyrics", "lrclib", "musixmatch"),
                row(.translationLanguage, L10n.translationLanguage, "lyrics", "translate"),
            ]
        }

        return [
            SettingsGroupSpec(id: "account", header: nil, rows: [
                // The row opens the scrobbling screen, so the services it signs into are worth
                // typing even though none is named on the row.
                row(.account, L10n.accountIntegrations, "scrobbling", "last.fm", "listenbrainz"),
                row(.listenTogether, L10n.listenTogether, "jam", "party", "sync", "friends"),
            ]),
            SettingsGroupSpec(id: "audioQuality", header: L10n.audioQuality, rows: [
                row(.source, L10n.source, L10n.sourcesSubtitle, "addon", "lossless"),
                row(.onWifi, L10n.onWifi, "wi-fi", "streaming quality"),
                row(.onMobileData, L10n.onMobileData, "cellular", "streaming quality"),
                row(.dolbyAtmos, L10n.dolbyAtmos, "surround", "e-ac-3"),
                row(.directSourceStream, L10n.directSourceStream, L10n.directSourceStreamSubtitle, "addon", "lossless", "atmos", "youtube", "fallback"),
            ]),
            SettingsGroupSpec(id: "downloads", header: L10n.downloads, rows: [
                row(.downloadQuality, L10n.downloadQuality, "offline", "lossless"),
                row(.downloadWifiOnly, L10n.downloadWifiOnly, "wi-fi", "cellular", sub: true),
            ]),
            SettingsGroupSpec(id: "playback", header: L10n.playback, rows: playback),
            SettingsGroupSpec(id: "appearance", header: L10n.appearance, rows: appearance),
            SettingsGroupSpec(id: "storage", header: L10n.storage, rows: [
                row(.songCacheLimit, L10n.songCacheLimit, "cache", "space"),
                row(.clearSongCache, L10n.clearSongCache, "cache", "free space"),
                row(.clearImageCache, L10n.clearImageCache, "cache", "artwork", "free space"),
            ]),
            SettingsGroupSpec(id: "yourData", header: L10n.yourData, rows: [
                row(.replay, L10n.replay, "stats", "history", "wrapped"),
                row(.workOutGenres, L10n.workOutGenres, "genre", "replay"),
                row(.exportData, L10n.exportData, "backup"),
                row(.importData, L10n.importData, "backup", "restore"),
            ]),
            SettingsGroupSpec(id: "miscellaneous", header: L10n.miscellaneous, rows: [
                row(.playNextOnSwipe, L10n.playNextOnSwipe, "swipe", "queue"),
                row(.dontRepeatSongs, L10n.dontRepeatSongs, "radio", "suggestions"),
                row(.hideVolumeBar, L10n.hideVolumeBar, "volume", "player"),
                row(.hideStatusBarInPlayer, L10n.hideStatusBar, "status bar", "player", "fullscreen"),
                row(.showQueueHistory, L10n.showQueueHistory, "player", "queue", "history", "previously played"),
                row(.hideSongStatus, L10n.hideSongStatus, "player", "playing from", "played by"),
            ]),
            SettingsGroupSpec(id: "language", header: L10n.language, rows: [
                row(.appLanguage, L10n.appLanguage, "locale", "translate"),
            ]),
            SettingsGroupSpec(id: "advanced", header: L10n.advancedOptions, rows: [
                row(.smartVersionAlignment, L10n.smartVersionAlignment, "alignment", "sync", "waveform", "video", "audio", "skit", "intro"),
                row(.showNerdStats, L10n.showNerdStats, "debug", "bitrate", "codec"),
                row(.keepDiagnosticLog, L10n.keepDiagnosticLog, "debug", "logs", "bug report", "support"),
            ] + (v.diagnosticLog ? [row(.shareDiagnosticLog, L10n.shareDiagnosticLog, "debug", "logs", "bug report", "support", "export")] : [])
              + (v.alternateIcons ? [row(.appIcon, L10n.appIcon, "icon", "launcher", "logo")] : [])),
        ]
    }
}
