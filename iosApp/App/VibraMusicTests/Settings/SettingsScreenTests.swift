import AudioCache
import VibraMusicCore
import SwiftUI
import XCTest
@testable import VibraMusic

/// PORTING §2.11 "Settings screen with search": the rows, their order, and the filter.
@MainActor
final class SettingsSearchTests: XCTestCase {
    private func ids(_ groups: [SettingsGroupSpec]) -> [SettingsRowID] { groups.flatMap { $0.rows.map(\.id) } }

    /// The PORTING done criterion.
    func testSearchingCrossfadeFindsTheSetting() {
        let groups = SettingsCatalog.groups(visibility: SettingsVisibility(), search: SettingsSearch("crossfade"))
        XCTAssertTrue(ids(groups).contains(.crossfade))
        // Automix answers too: "crossfade" is one of its keywords.
        XCTAssertTrue(ids(groups).contains(.automix))
        XCTAssertEqual(groups.map(\.header), [L10n.playback])
    }

    func testSearchingForTheDirectSourceStreamFindsItByTitleOrByWhatItDoes() {
        for query in ["direct source", "lossless", "fallback"] {
            let groups = SettingsCatalog.groups(visibility: .init(), search: SettingsSearch(query))
            XCTAssertTrue(ids(groups).contains(.directSourceStream), query)
        }
    }

    func testAQueryIsTrimmedAndCaseInsensitive() {
        XCTAssertEqual(ids(SettingsCatalog.groups(visibility: .init(), search: SettingsSearch("  CROSSFADE "))),
                       ids(SettingsCatalog.groups(visibility: .init(), search: SettingsSearch("crossfade"))))
    }

    func testABlankQueryShowsEveryGroupInAndroidsOrder() {
        let groups = SettingsCatalog.groups(visibility: .init(), search: SettingsSearch(""))
        XCTAssertEqual(groups.map(\.id), ["account", "audioQuality", "downloads", "playback", "appearance",
                                          "storage", "yourData", "miscellaneous", "language", "advanced"])
        XCTAssertEqual(groups.first?.rows.map(\.id), [.account, .listenTogether])
        XCTAssertEqual(groups[1].rows.map(\.id), [.source, .onWifi, .onMobileData, .dolbyAtmos, .directSourceStream])
        XCTAssertEqual(groups[3].rows.last?.id, .equalizer)
        XCTAssertEqual(groups[5].rows.map(\.id), [.songCacheLimit, .clearSongCache, .clearImageCache])
        XCTAssertEqual(groups[6].rows.map(\.id), [.replay, .workOutGenres, .exportData, .importData])
    }

    /// Searching a group's header turns up the group entire.
    func testAHeaderMatchesEveryRowUnderIt() {
        let groups = SettingsCatalog.groups(visibility: .init(), search: SettingsSearch(L10n.storage))
        XCTAssertEqual(groups.first { $0.id == "storage" }?.rows.count, 3)
    }

    func testCrossfadeGoesWhileAutomixIsOn() {
        let groups = SettingsCatalog.groups(visibility: SettingsVisibility(automix: true), search: SettingsSearch(""))
        XCTAssertFalse(ids(groups).contains(.crossfade))
        XCTAssertTrue(ids(groups).contains(.automix))
    }

    /// With animated covers off the Spotify row is gone, but its keyword still finds the switch
    /// that brings it back.
    func testAHiddenRowsKeywordFindsTheSwitchThatShowsIt() {
        let hidden = SettingsCatalog.groups(visibility: SettingsVisibility(animatedCanvas: false), search: SettingsSearch("spotify"))
        XCTAssertEqual(ids(hidden), [.animatedCoverArt])
        let shown = SettingsCatalog.groups(visibility: SettingsVisibility(animatedCanvas: true), search: SettingsSearch("spotify"))
        XCTAssertEqual(ids(shown), [.animatedCoverArt, .spotifyCanvas])
        XCTAssertTrue(shown[0].rows[1].isSubRow)
    }

    func testLyricsRowsFollowSyncedLyrics() {
        let off = ids(SettingsCatalog.groups(visibility: SettingsVisibility(syncedLyrics: false), search: SettingsSearch("")))
        XCTAssertFalse(off.contains(.lyricsSources))
        XCTAssertFalse(off.contains(.translationLanguage))
        let on = ids(SettingsCatalog.groups(visibility: SettingsVisibility(syncedLyrics: true), search: SettingsSearch("")))
        XCTAssertTrue(on.contains(.lyricsSources))
    }

    func testNothingMatchingLeavesNoGroups() {
        XCTAssertTrue(SettingsCatalog.groups(visibility: .init(), search: SettingsSearch("zzqx")).isEmpty)
    }

    /// Android-only rows (PORTING §3) are not offered on iOS.
    func testAndroidOnlyRowsAreNotListed() {
        for query in ["usb", "pcm", "refresh rate", "liquid glass", "music folder"] {
            XCTAssertTrue(SettingsCatalog.groups(visibility: .init(), search: SettingsSearch(query)).isEmpty, query)
        }
    }

    func testTheScreenRendersFilteredAndUnfiltered() {
        let settings = makeSettingsTestSettings()
        let app = makeSettingsTestApp(settings: settings)
        settingsHostAndLayOut(NavigationStack { SettingsScreen() }.settingsTestEnvironment(app))
        settings.smartFadeEnabled = true
        settings.themeMode = .light
        settingsHostAndLayOut(NavigationStack { SettingsScreen() }.settingsTestEnvironment(app), size: CGSize(width: 820, height: 1180))
    }
}

/// PORTING §2.11 "Theme": System / Light / Dark, reduce animation and blur, full-screen cover art.
@MainActor
final class SettingsThemeTests: XCTestCase {
    func testTheThemeRowOffersSystemLightAndDarkAndLightForcesLight() {
        XCTAssertEqual(ThemeMode.allCases.map(\.settingsLabel), [L10n.system, L10n.light, L10n.dark])
        let settings = makeSettingsTestSettings()
        settings.themeMode = .light
        XCTAssertEqual(settings.themeMode.colorScheme, .light)
        settings.themeMode = .system
        XCTAssertNil(settings.themeMode.colorScheme)
    }

    func testTheAppearanceGroupCarriesTheThemeSwitches() {
        let appearance = SettingsCatalog.allGroups(visibility: .init()).first { $0.id == "appearance" }!.rows.map(\.id)
        XCTAssertEqual(Array(appearance.prefix(4)), [.theme, .reduceAnimation, .reduceDynamicBlur, .fullScreenCoverArt])
    }

    func testTheScreenRendersInDarkAndLight() {
        for mode in [ThemeMode.light, .dark] {
            let settings = makeSettingsTestSettings()
            settings.themeMode = mode
            let app = makeSettingsTestApp(settings: settings)
            settingsHostAndLayOut(NavigationStack { SettingsScreen() }
                .settingsTestEnvironment(app)
                .preferredColorScheme(mode.colorScheme))
        }
    }
}

/// PORTING §2.1 "Audio quality per network" (the settings side) and §2.6 "Download settings".
@MainActor
final class SettingsQualityTests: XCTestCase {
    func testTheCeilingInForceFollowsTheConnection() {
        let settings = makeSettingsTestSettings()
        settings.audioQualityWifi = .lossless
        settings.audioQualityCellular = .low
        XCTAssertEqual(SourcesModel.ceiling(settings: settings, metered: true), .low)
        XCTAssertEqual(SourcesModel.ceiling(settings: settings, metered: false), .lossless)
        // Offline reads as Wi-Fi, as Android's nullable metered flag did.
        XCTAssertEqual(SourcesModel.ceiling(settings: settings, metered: nil), .lossless)
        XCTAssertEqual(settings.effectiveAudioQuality(for: .cellular), .low)
        XCTAssertEqual(AudioQuality.low.maxKbps, 64)
    }

    func testTheQualitySheetsListBestFirstWithTheirCost() {
        XCTAssertEqual(AudioQuality.allCases.reversed().map(\.settingsLabel), [L10n.lossless, L10n.high, L10n.medium, L10n.low])
        XCTAssertEqual(DownloadQuality.allCases.reversed().map(\.settingsLabel), [L10n.lossless, L10n.high, L10n.standard])
        XCTAssertTrue(L10n.qualityHourly(AudioQuality.low.detail, AudioQuality.low.hourly).contains("29 MB/hr"))
    }

    func testWifiOnlyDownloadsWaitOnCellularAndSitsUnderDownloadQuality() {
        let settings = makeSettingsTestSettings()
        settings.wifiOnlyDownloads = true
        XCTAssertFalse(settings.downloadsAllowed(on: .cellular))
        XCTAssertTrue(settings.downloadsAllowed(on: .wifi))
        let downloads = SettingsCatalog.allGroups(visibility: .init()).first { $0.id == "downloads" }!
        XCTAssertEqual(downloads.rows.map(\.id), [.downloadQuality, .downloadWifiOnly])
        XCTAssertTrue(downloads.rows[1].isSubRow)
    }

    func testThePickerSheetRenders() {
        settingsHostAndLayOut(SettingsChoiceSheet(
            symbol: "wifi", title: L10n.audioQuality, subtitle: L10n.audioQualityConnection(L10n.wifi),
            options: AudioQuality.allCases.map { SettingsChoice(value: $0, label: $0.settingsLabel, detail: $0.detail) },
            selected: .lossless, onSelect: { _ in }))
    }
}

/// PORTING §2.11 "Storage controls".
final class SongCacheLimitTests: XCTestCase {
    func testTheSliderRunsFrom512MBTo10GBIn512MBNotches() {
        XCTAssertEqual(SongCacheLimit.minMB, 512)
        XCTAssertEqual(SongCacheLimit.maxMB, 10_240)
        XCTAssertEqual(SongCacheLimit.stepMB, 512)
        XCTAssertEqual(SongCacheLimit.bytes(ofMegabytes: 20_000), AppSettings.maxAudioCacheLimitBytes)
        XCTAssertEqual(SongCacheLimit.bytes(ofMegabytes: 1), AppSettings.defaultAudioCacheLimitBytes)
    }

    func testSizesReadNaturally() {
        XCTAssertEqual(SongCacheLimit.format(megabytes: 512), "512 MB")
        XCTAssertEqual(SongCacheLimit.format(megabytes: 2_048), "2 GB")
        XCTAssertEqual(SongCacheLimit.format(megabytes: 2_560), "2.5 GB")
    }

    @MainActor
    func testALargeLimitWarns() {
        XCTAssertEqual(SongCacheLimit.subtitle(megabytes: 2_048), L10n.songCacheLimitSubtitle)
        XCTAssertEqual(SongCacheLimit.subtitle(megabytes: 4_096), L10n.songCacheLargeSubtitle("4 GB"))
    }

    /// What the slider writes is what the song cache then enforces.
    @MainActor
    func testTheLimitSettingIsWhatTheCacheFollows() async throws {
        let settings = makeSettingsTestSettings()
        let cache = try AudioStreamCache(configuration: .init(directory: makeTemporaryDirectory(self).appending(path: "cache"),
                                                              minimumFreeBytes: 0, availableCapacity: { _ in nil }))
        let follower = cache.followLimit(of: settings)
        defer { follower.cancel() }

        let wanted = SongCacheLimit.bytes(ofMegabytes: 3_072)
        XCTAssertNotEqual(wanted, AppSettings.defaultAudioCacheLimitBytes)
        settings.audioCacheLimitBytes = wanted
        var limit = await cache.usage().limitBytes
        for _ in 0..<100 where limit != wanted {
            try await Task.sleep(for: .milliseconds(50))
            limit = await cache.usage().limitBytes
        }
        XCTAssertEqual(limit, wanted)
    }
}

/// The search field's box went missing for seconds after coming back from Listen together; the page
/// now asks the bar for a layout pass once it has appeared.
@MainActor
final class SearchFieldRedrawTests: XCTestCase {
    private final class CountingSearchBar: UISearchBar {
        var layouts = 0
        override func setNeedsLayout() {
            layouts += 1
            super.setNeedsLayout()
        }
    }

    private final class CountingSearchController: UISearchController {
        let counting = CountingSearchBar()
        override var searchBar: UISearchBar { counting }
    }

    /// The page appearing is what triggers it, so drive the hook through a real appearance.
    func testAPageAppearingLaysTheSearchFieldOutAgain() {
        let page = UIViewController()
        let search = CountingSearchController(searchResultsController: nil)
        page.navigationItem.searchController = search
        let hook = SearchFieldRedraw.Controller()
        page.addChild(hook)
        page.view.addSubview(hook.view)
        hook.didMove(toParent: page)
        // On screen in a window, so the stack and the page are really showing when the hook appears.
        let navigation = UINavigationController(rootViewController: page)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        navigation.view.layoutIfNeeded()
        XCTAssertTrue(hook.navigationController === navigation, "the hook reaches the stack that holds the search field")
        let before = search.counting.layouts

        hook.beginAppearanceTransition(true, animated: false)
        hook.endAppearanceTransition()

        XCTAssertGreaterThan(search.counting.layouts, before)
    }

    /// The real page installs the hook: without `.background { SearchFieldRedraw() }` on Settings
    /// the appearance test above would still pass and the field would vanish again after a pop.
    func testTheSettingsPageInstallsTheSearchFieldRedraw() {
        let app = makeSettingsTestApp(settings: makeSettingsTestSettings())
        let host = settingsHostAndLayOut(NavigationStack { SettingsScreen() }.settingsTestEnvironment(app))
        func controllers(_ root: UIViewController) -> [UIViewController] {
            [root] + root.children.flatMap(controllers)
        }
        XCTAssertTrue(controllers(host).contains { $0 is SearchFieldRedraw.Controller },
                      "Settings no longer installs the search-field redraw")
    }

    func testRedrawingWithoutASearchFieldIsHarmless() {
        SearchFieldRedraw.redraw(in: UINavigationController(rootViewController: UIViewController()))
        SearchFieldRedraw.redraw(in: nil)
    }
}
