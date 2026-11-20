import VibraMusicCore
import Lyrics
import Replay
import Sources
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Ports ui/screens/SettingsSheet.kt (SettingsScreen) and the callbacks MainActivity.kt hands it:
// Account & integrations → account screen, Listen Together, Source → Sources, Equalizer, Replay,
// Lyrics sources and Translation language (sheets), Spotify Canvas setup and the app language.
//
// Android's page title ("Settings", displayLarge) and search field under it are the navigation
// bar's large title and its always-visible search field here — the native form of the same
// layout. Rows are grouped in an inset grouped list, which is what Android drew by hand.

/// Grouped settings with search. Opened from the account avatar (signed out) or the account
/// selector's "Open settings" (`AppRoute.settings`).
struct SettingsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(PlayerController.self) private var player

    @State private var query = ""
    @State private var metered: Bool?
    @State private var picking: QualityTarget?
    @State private var pickingDownloadQuality = false
    @State private var pickingAutomixPerformance = false
    @State private var pickingDirectSourceStream = false
    @State private var pickingLanguage = false
    @State private var openingSpotifyCanvas = false
    // What the last export or import did, shown on the row that did it rather than as a toast: a
    // backup is the one action here whose outcome nobody can check by looking at the app
    // afterwards. Held per direction, or an import's result reports itself under "Export".
    @State private var exportStatus: String?
    @State private var importStatus: String?
    @State private var confirmImport = false
    @State private var exportDocument: SettingsBackupDocument?
    @State private var exportMonths = 0
    @State private var showExporter = false
    @State private var showImporter = false

    var body: some View {
        let search = SettingsSearch(query)
        let groups = SettingsCatalog.groups(visibility: visibility, search: search)
        ScrollViewReader { proxy in
            List {
                ForEach(groups) { group in
                    SettingsGroup(header: group.header) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, spec in
                            let nextIsSub = index + 1 < group.rows.count && group.rows[index + 1].isSubRow
                            rowView(spec.id)
                                .id(spec.id)
                                .listRowSeparator(nextIsSub ? .hidden : .automatic, edges: .bottom)
                                .listRowSeparator(spec.isSubRow && index > 0 ? .hidden : .automatic, edges: .top)
                        }
                    }
                    .id(group.id)
                }

                // Read after every group has had its turn at the query, which is what makes this
                // an accurate "nothing here" rather than a guess.
                if groups.isEmpty {
                    Section {
                        Text(L10n.settingsSearchEmpty(query))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 24)
                            .listRowBackground(Color.clear)
                    }
                }

                // The version line is the page's colophon, not a setting: it goes when the list is
                // narrowed to a few rows.
                if search.isBlank {
                    Section {
                        SettingsColophon()
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .settingsGroupList()
            // What is left after a keystroke is a different list, and the offset the last one was
            // scrolled to means nothing in it.
            .onChange(of: query) { _, _ in
                if let first = groups.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.settingsSearchHint)
        .background { SearchFieldRedraw() }
        .navigationTitle(L10n.settings)
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: $openingSpotifyCanvas) { SpotifyCanvasSetupScreen() }
        .task {
            for await status in app.network.statusUpdates() {
                metered = status.isMetered
            }
        }
        .sheet(item: $picking) { target in qualitySheet(target) }
        .sheet(isPresented: $pickingDownloadQuality) { downloadQualitySheet }
        .sheet(isPresented: $pickingAutomixPerformance) { automixPerformanceSheet }
        .sheet(isPresented: $pickingDirectSourceStream) { directSourceStreamSheet }
        .sheet(isPresented: $pickingLanguage) {
            AppLanguagePicker(selected: AppLanguage.current()) { language in
                app.setLanguage(language.code)
            }
        }
        // Asked before the picker opens rather than after a file is chosen: what is being
        // confirmed is that this device's own history is about to be replaced, whichever file.
        .alert(L10n.importBackupTitle, isPresented: $confirmImport) {
            Button(L10n.chooseFile) { showImporter = true }
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.importBackupWarning)
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json,
                      defaultFilename: ReplayBackup.suggestedName()) { result in
            switch result {
            case .success: exportStatus = SettingsBackup.exportStatus(.success(exportMonths))
            case .failure(let error):
                // Cancelling the picker is not a failed export.
                if (error as NSError).code != NSUserCancelledError {
                    exportStatus = SettingsBackup.exportStatus(.failure(error))
                }
            }
            exportDocument = nil
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: SettingsBackupDocument.readableContentTypes) { result in
            guard case .success(let url) = result else { return }
            importStatus = SettingsBackup.importStatus(Result { try backup.restore(from: Self.read(url)) })
        }
    }

    // MARK: - State

    private var visibility: SettingsVisibility {
        SettingsVisibility(automix: settings.smartFadeEnabled,
                           animatedCanvas: settings.animatedCanvas,
                           syncedLyrics: settings.syncedLyrics,
                           alternateIcons: UIApplication.shared.supportsAlternateIcons,
                           diagnosticLog: settings.keepDiagnosticLog)
    }

    private var backup: SettingsBackup {
        SettingsBackup(settings: settings, stats: app.replayStats, searchHistory: app.searchHistory)
    }

    private static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ id: SettingsRowID) -> some View {
        @Bindable var settings = settings
        switch id {
        case .account:
            let account = app.accounts.account
            SettingsRow(symbol: "person.fill", title: L10n.accountIntegrations,
                        subtitle: account.map(\.email).flatMap { $0.isEmpty ? nil : $0 }
                            ?? (app.accounts.isSignedIn ? L10n.signedIn : L10n.notSignedIn)) {
                router.open(.account)
            }
        case .listenTogether:
            let party = app.listenTogether.state
            SettingsRow(symbol: "person.3.fill", title: L10n.listenTogether,
                        subtitle: party.code.map { L10n.listenTogetherInParty($0) } ?? L10n.listenTogetherSubtitle,
                        badge: party.inParty && party.members.count > 1 ? "\(party.members.count)" : nil) {
                router.open(.listenTogether)
            }

        case .source:
            SettingsRow(symbol: "puzzlepiece.extension.fill", title: L10n.source, subtitle: L10n.sourcesSubtitle) {
                router.open(.sources)
            }
        case .onWifi:
            SettingsRow(symbol: "wifi", title: L10n.onWifi, value: settings.audioQualityWifi.settingsLabel,
                        badge: metered == false ? L10n.inUse : nil) { picking = .wifi }
        case .onMobileData:
            SettingsRow(symbol: "antenna.radiowaves.left.and.right", title: L10n.onMobileData,
                        value: settings.audioQualityCellular.settingsLabel,
                        badge: metered == true ? L10n.inUse : nil) { picking = .cellular }
        case .dolbyAtmos:
            // Greyed rather than hidden where the device can't decode E-AC-3: a missing row reads as
            // a feature the app doesn't have; a disabled one says the phone has no decoder. The
            // stored preference is left untouched either way.
            let supported = DeviceCodecs.shared.playsDolbyAtmos
            SettingsToggleRow(symbol: "hifispeaker.2.fill", title: L10n.dolbyAtmos,
                              subtitle: supported ? L10n.dolbyAtmosSubtitle : L10n.dolbyAtmosUnavailable,
                              enabled: supported,
                              isOn: Binding(get: { settings.dolbyAtmos && supported }, set: { settings.dolbyAtmos = $0 }))
        case .directSourceStream:
            SettingsRow(symbol: "arrow.triangle.branch", title: L10n.directSourceStream,
                        subtitle: L10n.directSourceStreamSubtitle,
                        value: settings.directSourceStream.settingsLabel) { pickingDirectSourceStream = true }

        case .downloadQuality:
            SettingsRow(symbol: "arrow.down.circle", title: L10n.downloadQuality,
                        subtitle: L10n.downloadQualitySubtitle(settings.downloadQuality.perTrack),
                        value: settings.downloadQuality.settingsLabel) { pickingDownloadQuality = true }
        case .downloadWifiOnly:
            SettingsSubToggleRow(title: L10n.downloadWifiOnly,
                                 badge: settings.wifiOnlyDownloads && metered == true ? L10n.blocking : nil,
                                 isOn: $settings.wifiOnlyDownloads)

        case .preferMusicOnly:
            SettingsToggleRow(symbol: "play.rectangle", title: L10n.preferMusicOnly,
                              subtitle: L10n.preferMusicOnlySubtitle, isOn: $settings.preferMusicOnly)
        case .loudnessNormalization:
            SettingsToggleRow(symbol: "speaker.wave.2.fill", title: L10n.loudnessNormalization,
                              subtitle: L10n.loudnessNormalizationSubtitle, isOn: $settings.loudnessNormalization)
        case .crossfade:
            SettingsSliderRow(symbol: "water.waves", title: L10n.crossfade, subtitle: L10n.crossfadeSubtitle,
                              value: settings.crossfadeSeconds == 0 ? L10n.off : L10n.secondsShort(settings.crossfadeSeconds),
                              sliderValue: Binding(get: { Double(settings.crossfadeSeconds) },
                                                   set: { settings.crossfadeSeconds = Int($0.rounded()) }),
                              range: Double(AppSettings.crossfadeRange.lowerBound)...Double(AppSettings.crossfadeRange.upperBound),
                              step: 1)
        case .automix:
            SettingsToggleRow(symbol: "sparkles", title: L10n.automix,
                              subtitle: settings.smartFadeEnabled ? L10n.automixEnabledSubtitle : L10n.automixDisabledSubtitle,
                              isOn: $settings.smartFadeEnabled)
        case .automixPerformance:
            SettingsRow(symbol: "slider.horizontal.3", title: L10n.automixPerformance,
                        subtitle: L10n.automixPerformanceSubtitle,
                        value: settings.automixPerformanceMode.settingsLabel) { pickingAutomixPerformance = true }
        case .skipSilence:
            // Android explains that silence skipping does nothing on its float output branch; on
            // iOS the detector runs in the app's own tap, so the plain subtitle is always true.
            SettingsToggleRow(symbol: "speaker.slash.fill", title: L10n.skipSilence,
                              subtitle: L10n.skipSilenceSubtitle, isOn: $settings.skipSilence)
        case .spatialAudio:
            // Held off for the length of an Atmos track (the object mix is spatialized already);
            // said on the row because the switch stays where the listener left it.
            SettingsToggleRow(symbol: "dot.radiowaves.left.and.right", title: L10n.spatialAudio,
                              subtitle: player.signalPath == .spatialPassthrough ? L10n.spatialAudioAtmosSubtitle : L10n.spatialAudioSubtitle,
                              isOn: $settings.spatialAudio)
        case .equalizer:
            SettingsRow(symbol: "slider.vertical.3", title: L10n.equalizer, subtitle: L10n.equalizerSubtitle) {
                router.open(.equalizer)
            }

        case .theme:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: SettingsMetrics.iconGap) {
                    SettingsIcon(symbol: "circle.lefthalf.filled")
                    Text(L10n.theme)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
                Picker(L10n.theme, selection: $settings.themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.settingsLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: settings.themeMode)
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        case .reduceAnimation:
            SettingsToggleRow(symbol: "circle.dashed", title: L10n.reduceAnimation,
                              subtitle: L10n.reduceAnimationSubtitle, isOn: $settings.reduceAnimation)
        case .reduceDynamicBlur:
            SettingsToggleRow(symbol: "drop.halffull", title: L10n.reduceDynamicBlur,
                              subtitle: L10n.reduceDynamicBlurSubtitle, isOn: $settings.reduceDynamicBlur)
        case .fullScreenCoverArt:
            // Android hides this where its player can't fill the window; the iOS player always
            // does (a full-screen cover on iPhone and iPad), so the row is always here.
            SettingsToggleRow(symbol: "arrow.up.left.and.arrow.down.right", title: L10n.fullScreenCoverArt,
                              subtitle: L10n.fullScreenCoverArtSubtitle, isOn: $settings.fullBleedArtwork)
        case .legacyMeshGradient:
            SettingsToggleRow(symbol: "circle.hexagongrid.fill", title: L10n.legacyMeshGradient,
                              subtitle: L10n.legacyMeshGradientSubtitle, isOn: $settings.legacyMeshGradient)
        case .animatedCoverArt:
            SettingsToggleRow(symbol: "play.square.stack", title: L10n.animatedCoverArt,
                              subtitle: L10n.animatedCoverArtSubtitle, isOn: $settings.animatedCanvas)
        case .animatedCoverCellular:
            SettingsSubToggleRow(title: L10n.animatedCoverCellular, isOn: $settings.canvasOverCellular)
        case .spotifyCanvas:
            Button { openingSpotifyCanvas = true } label: {
                HStack {
                    Text(L10n.integrateSpotifyCanvas).foregroundStyle(.primary).lineLimit(1)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer()
                    SettingsChevron()
                }
                .padding(.leading, SettingsMetrics.textInset)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsRowButtonStyle())
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
        case .syncedLyrics:
            SettingsToggleRow(symbol: "text.alignleft", title: L10n.syncedLyrics,
                              subtitle: L10n.syncedLyricsSubtitle, isOn: $settings.syncedLyrics)
        case .lyricsBlur:
            SettingsToggleRow(symbol: "aqi.medium", title: L10n.blurUnfocusedLyrics,
                              subtitle: L10n.blurUnfocusedLyricsSubtitle, isOn: $settings.lyricsBlur)
        case .lyricsSources:
            let names = LyricsSource.allCases.filter { settings.lyricsSources.contains($0) }.map(\.label)
            SettingsRow(symbol: "globe", title: L10n.lyricsSources,
                        subtitle: names.isEmpty ? L10n.noLyricsSourcesEnabled : names.joined(separator: ", ")) {
                router.present(.lyricsSources)
            }
        case .translationLanguage:
            SettingsRow(symbol: "character.bubble", title: L10n.translationLanguage,
                        subtitle: settings.translationLanguage.isEmpty
                            ? L10n.translationLanguageSubtitle
                            : TranslationLanguage.displayName(for: settings.translationLanguage, in: LanguageBundle.locale)) {
                router.present(.translationLanguage)
            }

        case .songCacheLimit:
            // Read straight off the setting (as Android's slider is), so a restored backup or any
            // other writer moves the slider too.
            let mb = SongCacheLimit.megabytes(ofBytes: settings.audioCacheLimitBytes)
            SettingsSliderRow(symbol: "internaldrive", title: L10n.songCacheLimit,
                              subtitle: SongCacheLimit.subtitle(megabytes: mb),
                              value: SongCacheLimit.format(megabytes: mb),
                              sliderValue: Binding(get: { Double(SongCacheLimit.megabytes(ofBytes: settings.audioCacheLimitBytes)) },
                                                   set: { settings.audioCacheLimitBytes = SongCacheLimit.bytes(ofMegabytes: Int($0.rounded())) }),
                              range: Double(SongCacheLimit.minMB)...Double(SongCacheLimit.maxMB),
                              step: Double(SongCacheLimit.stepMB))
        case .clearSongCache:
            SettingsRow(symbol: "trash", title: L10n.clearSongCache, subtitle: L10n.clearSongCacheSubtitle) {
                Task {
                    await SettingsStorage.clearSongCache(app.audioCache)
                    player.notice = QueueNotice(message: L10n.songCacheCleared, symbol: "trash")
                }
            }
        case .clearImageCache:
            SettingsRow(symbol: "trash", title: L10n.clearImageCache, subtitle: L10n.clearImageCacheSubtitle) {
                Task {
                    await SettingsStorage.clearImageCache(ArtworkImageCache.shared)
                    player.notice = QueueNotice(message: L10n.imageCacheCleared, symbol: "trash")
                }
            }

        case .replay:
            SettingsRow(symbol: "chart.bar.fill", title: L10n.replay, subtitle: L10n.replaySubtitle) {
                router.open(.replay)
            }
        case .workOutGenres:
            SettingsToggleRow(symbol: "tag.fill", title: L10n.workOutGenres,
                              subtitle: settings.replayGenres ? L10n.replayGenresEnabledSubtitle : L10n.replayGenresDisabledSubtitle,
                              isOn: $settings.replayGenres)
        case .exportData:
            SettingsRow(symbol: "square.and.arrow.up", title: L10n.exportData,
                        subtitle: exportStatus ?? L10n.exportDataSubtitle) { startExport() }
        case .importData:
            SettingsRow(symbol: "square.and.arrow.down", title: L10n.importData,
                        subtitle: importStatus ?? L10n.importDataSubtitle) { confirmImport = true }

        case .playNextOnSwipe:
            SettingsToggleRow(symbol: "text.line.first.and.arrowtriangle.forward", title: L10n.playNextOnSwipe,
                              subtitle: settings.swipeToPlayNext ? L10n.swipePlaysNext : L10n.swipeAddsToQueue,
                              isOn: $settings.swipeToPlayNext)
        case .dontRepeatSongs:
            SettingsToggleRow(symbol: "clock.arrow.circlepath", title: L10n.dontRepeatSongs,
                              subtitle: L10n.dontRepeatSongsSubtitle, isOn: $settings.dontRepeatSuggestions)
        case .hideVolumeBar:
            SettingsToggleRow(symbol: "speaker.slash", title: L10n.hideVolumeBar,
                              subtitle: L10n.hideVolumeBarSubtitle, isOn: $settings.hideVolumeBar)
        case .hideStatusBarInPlayer:
            SettingsToggleRow(symbol: "iphone.slash", title: L10n.hideStatusBar,
                              subtitle: L10n.hideStatusBarSubtitle, isOn: $settings.hideStatusBarInPlayer)
        case .showQueueHistory:
            SettingsToggleRow(symbol: "clock.arrow.circlepath", title: L10n.showQueueHistory,
                              subtitle: L10n.showQueueHistorySubtitle, isOn: $settings.showQueueHistory)
        case .hideSongStatus:
            SettingsToggleRow(symbol: "eye.slash", title: L10n.hideSongStatus,
                              subtitle: L10n.hideSongStatusSubtitle, isOn: $settings.hideSongStatus)

        case .appLanguage:
            SettingsRow(symbol: "globe", title: L10n.appLanguage, subtitle: AppLanguage.current().name()) {
                pickingLanguage = true
            }

        case .smartVersionAlignment:
            SettingsToggleRow(symbol: "waveform", title: L10n.smartVersionAlignment,
                              subtitle: L10n.smartVersionAlignmentSubtitle, isOn: $settings.smartVersionAlignment)
        case .showNerdStats:
            SettingsToggleRow(symbol: "chart.bar.xaxis", title: L10n.showNerdStats,
                              subtitle: L10n.showNerdStatsSubtitle, isOn: $settings.showNerdStats)
        case .keepDiagnosticLog:
            SettingsToggleRow(symbol: "doc.text", title: L10n.keepDiagnosticLog,
                              subtitle: L10n.keepDiagnosticLogSubtitle, isOn: $settings.keepDiagnosticLog)
        case .shareDiagnosticLog:
            // Both files once the log has rotated. Turning the log on writes its first line at
            // once, so the current file is there to share even when this row was drawn before it.
            let files = DiagnosticLog.shared.existingFileURLs
            ShareLink(items: files.isEmpty ? [DiagnosticLog.shared.fileURL] : files) {
                SettingsRow(symbol: "square.and.arrow.up", title: L10n.shareDiagnosticLog,
                            subtitle: L10n.shareDiagnosticLogSubtitle)
            }
            .buttonStyle(SettingsRowButtonStyle())
        case .appIcon:
            AppIconPickerRow()
        }
    }

    private func startExport() {
        do {
            let (data, months) = try backup.export()
            exportDocument = SettingsBackupDocument(data: data)
            exportMonths = months
            showExporter = true
        } catch {
            exportStatus = SettingsBackup.exportStatus(.failure(error))
        }
    }

    // MARK: - Sheets

    private func qualitySheet(_ target: QualityTarget) -> some View {
        let selected = target == .wifi ? settings.audioQualityWifi : settings.audioQualityCellular
        // Best first — the option most people want shouldn't be last.
        return SettingsChoiceSheet(
            symbol: target.symbol,
            title: L10n.audioQuality,
            subtitle: L10n.audioQualityConnection(target.title.lowercased(with: LanguageBundle.locale)),
            options: AudioQuality.allCases.reversed().map {
                SettingsChoice(value: $0, label: $0.settingsLabel, detail: L10n.qualityHourly($0.detail, $0.hourly))
            },
            selected: selected
        ) { quality in
            // Writes the one ceiling being edited and nothing else: which sources a rung consults
            // is read per stream off the connection in force (AudioQuality.permits).
            switch target {
            case .wifi: settings.audioQualityWifi = quality
            case .cellular: settings.audioQualityCellular = quality
            }
        }
    }

    private var downloadQualitySheet: some View {
        // Priced per track rather than per hour: a download is paid for once.
        SettingsChoiceSheet(
            symbol: "arrow.down.circle",
            title: L10n.downloadQuality,
            subtitle: L10n.downloadQualityDialogSubtitle,
            options: DownloadQuality.allCases.reversed().map {
                SettingsChoice(value: $0, label: $0.settingsLabel, detail: L10n.qualityPerTrack($0.detail, $0.perTrack))
            },
            selected: settings.downloadQuality
        ) { settings.downloadQuality = $0 }
    }

    private var directSourceStreamSheet: some View {
        SettingsChoiceSheet(
            symbol: "arrow.triangle.branch",
            title: L10n.directSourceStream,
            subtitle: L10n.directSourceStreamSubtitle,
            options: DirectSourceStream.allCases.map {
                SettingsChoice(value: $0, label: $0.settingsLabel, detail: $0.settingsDetail)
            },
            selected: settings.directSourceStream
        ) { settings.directSourceStream = $0 }
    }

    private var automixPerformanceSheet: some View {
        SettingsChoiceSheet(
            symbol: "slider.horizontal.3",
            title: L10n.automixPerformance,
            subtitle: L10n.automixPerformanceWarning,
            options: AutomixPerformanceMode.allCases.map {
                SettingsChoice(value: $0, label: $0.settingsLabel, detail: $0.settingsDetail)
            },
            selected: settings.automixPerformanceMode
        ) { settings.automixPerformanceMode = $0 }
    }
}

/// Which ceiling the open quality sheet is editing.
enum QualityTarget: String, Identifiable {
    case wifi, cellular
    var id: String { rawValue }

    var symbol: String { self == .wifi ? "wifi" : "antenna.radiowaves.left.and.right" }
    var title: String { self == .wifi ? L10n.wifi : L10n.mobileData }
}

// MARK: - Localized labels

extension AudioQuality {
    var settingsLabel: String {
        switch self {
        case .low: return L10n.low
        case .medium: return L10n.medium
        case .high: return L10n.high
        case .lossless: return L10n.lossless
        }
    }
}

extension DownloadQuality {
    var settingsLabel: String {
        switch self {
        case .standard: return L10n.standard
        case .high: return L10n.high
        case .lossless: return L10n.lossless
        }
    }
}

extension ThemeMode {
    var settingsLabel: String {
        switch self {
        case .system: return L10n.system
        case .light: return L10n.light
        case .dark: return L10n.dark
        }
    }
}

extension DirectSourceStream {
    var settingsLabel: String {
        switch self {
        case .off: return L10n.off
        case .queueOnly: return L10n.directSourceStreamQueueOnly
        case .always: return L10n.directSourceStreamAlways
        }
    }

    var settingsDetail: String {
        switch self {
        case .off: return L10n.directSourceStreamOffSubtitle
        case .queueOnly: return L10n.directSourceStreamQueueOnlySubtitle
        case .always: return L10n.directSourceStreamAlwaysSubtitle
        }
    }
}

extension AutomixPerformanceMode {
    var settingsLabel: String {
        switch self {
        case .efficient: return L10n.automixModeEfficient
        case .balanced: return L10n.automixModeBalanced
        case .performance: return L10n.automixModePerformance
        }
    }

    var settingsDetail: String {
        switch self {
        case .efficient: return L10n.automixModeEfficientSubtitle
        case .balanced: return L10n.automixModeBalancedSubtitle
        case .performance: return L10n.automixModePerformanceSubtitle
        }
    }
}

// MARK: - Colophon

/// "vibramusic 1.0  GitHub  Developer  Discord  Website" and the backend credit, centred under the
/// last group (not localized on Android either: names and links).
private struct SettingsColophon: View {
    var body: some View {
        Text(Self.text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .tint(Color.accentColor)
    }

    private static var text: AttributedString {
        let links: [(String, String)] = [
            ("GitHub", "https://github.com/kushagrasinghx/Vibra Music"),
            ("Developer", "https://github.com/kushagrasinghx"),
            ("Discord", "https://discord.gg/pDdKfrdHY6"),
            ("Website", "https://vibramusic.kushagrasingh.in/"),
        ]
        var result = AttributedString("vibramusic \(SettingsBackup.appVersion)")
        for (label, url) in links {
            result += AttributedString("  ")
            var link = AttributedString(label)
            link.link = URL(string: url)
            link.underlineStyle = .single
            result += link
        }
        result += AttributedString("\n~YouTube Music & Listen Together Backend")
        return result
    }
}
