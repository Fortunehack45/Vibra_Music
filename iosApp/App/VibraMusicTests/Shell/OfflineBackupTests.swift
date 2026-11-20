import AudioCache
import VibraMusicCore
import Playback
import XCTest
@testable import VibraMusic

@MainActor
final class OfflineBackupTests: XCTestCase {
    private func song(_ id: String) -> Song { Song(videoId: id, title: "Title \(id)", artist: "Artist") }

    private func fill(_ cache: AudioStreamCache, _ key: AudioCacheKey, bytes: Int = 200_000) async {
        let saved = await cache.cacheCompletely(key, source: InMemoryAudioSource(data: Data(repeating: 7, count: bytes), mimeType: "audio/mp4"))
        XCTAssertTrue(saved)
    }

    func testTheBackupListsOnlyWholeTracksMostRecentFirst() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let backup = OfflineBackup(cache: cache, file: nil)
        backup.isPinned = { _ in false }
        let now = Date()
        backup.note([song("oldWhole001")], at: now.addingTimeInterval(-60))
        backup.note([song("partialTrk1")], at: now.addingTimeInterval(-30))
        // The one that started, with the one read ahead behind it.
        backup.note([song("newWhole001"), song("readAhead01")], at: now)
        await fill(cache, .youtube(videoId: "oldWhole001"))
        await fill(cache, .substitute(videoId: "newWhole001", atmosAllowed: true))
        await fill(cache, AudioCacheKey(trackID: "readAhead01", rendition: "hifi"))
        await cache.warmRange(.youtube(videoId: "partialTrk1"), source: InMemoryAudioSource(data: Data(repeating: 7, count: 4_000_000), mimeType: "audio/mp4"),
                              range: 0..<100_000)
        await fill(cache, .youtube(videoId: "neverNoted1"))

        let listed = await backup.songs().map(\.videoId)
        XCTAssertEqual(listed, ["newWhole001", "readAhead01", "oldWhole001"],
                       "whole copies of any rendition, newest first; a partial track and one nobody named are left out")
    }

    func testDownloadsAreLeftToTheDownloadsPage() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let backup = OfflineBackup(cache: cache, file: nil)
        backup.savedSongs = { [Song(videoId: "downloaded1", title: "Title downloaded1", artist: "Artist")] }
        backup.note([song("downloaded1"), song("streamed001")])
        await fill(cache, .youtube(videoId: "downloaded1"))
        await fill(cache, .youtube(videoId: "streamed001"))
        // A download's own cache entry doesn't make the track a backup entry either.
        backup.note([song("dlEntryOnly")])
        await fill(cache, .youtube(videoId: "dlEntryOnly", rendition: "download"))

        let listed = await backup.songs().map(\.videoId)
        XCTAssertEqual(listed, ["streamed001"])
    }

    /// The list never offers a row that wouldn't play: a track pinned to YouTube's own whose only
    /// whole copy is a substitute is left out, the same rule the player applies.
    func testAPinnedTrackWithOnlyASubstituteOnDiskIsNotOffered() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let backup = OfflineBackup(cache: cache, file: nil)
        backup.isPinned = { $0 == "pinnedSub01" || $0 == "pinnedOwn01" }
        backup.note([song("pinnedSub01"), song("pinnedOwn01"), song("freeSubst01")])
        await fill(cache, .substitute(videoId: "pinnedSub01", atmosAllowed: true))
        await fill(cache, .youtube(videoId: "pinnedOwn01"))
        await fill(cache, .substitute(videoId: "freeSubst01", atmosAllowed: true))

        let listed = await backup.songs().map(\.videoId)
        XCTAssertEqual(listed, ["pinnedOwn01", "freeSubst01"])
    }

    /// Nor a track whose only whole copy is an upgrade's when the player wouldn't play it: the row
    /// is pinned to YouTube's own, or Atmos is off.
    func testATrackWhoseOnlyWholeCopyIsAnUpgradesIsOfferedOnlyWhereItPlays() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let backup = OfflineBackup(cache: cache, file: nil)
        backup.isPinned = { $0 == "pinnedHifi1" }
        var atmos = true
        backup.atmosAllowed = { atmos }
        backup.note([song("pinnedHifi1"), song("freeHifi001"), song("ownCopy0001")])
        await fill(cache, AudioCacheKey(trackID: "pinnedHifi1", rendition: "hifi"))
        await fill(cache, AudioCacheKey(trackID: "freeHifi001", rendition: "hifi-2"))
        await fill(cache, .youtube(videoId: "ownCopy0001"))

        let withAtmos = await backup.songs().map(\.videoId)
        XCTAssertEqual(withAtmos, ["freeHifi001", "ownCopy0001"], "the pinned row's upgrade copy isn't offered")
        atmos = false
        let withoutAtmos = await backup.songs().map(\.videoId)
        XCTAssertEqual(withoutAtmos, ["ownCopy0001"], "with Atmos off, no upgrade copy is")
    }

    /// A music video and the song it was converted to are both whole on disk, with different
    /// lengths (the video runs longer): one row, the song, at the pair's most recent place.
    func testAVideoAndItsSongVersionAreOneRow() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let backup = OfflineBackup(cache: cache, file: nil)
        backup.isPinned = { _ in false }
        var video = Song(videoId: "twinVideo01", title: "SWIM", artist: "BTS", durationText: "4:05")
        video.isVideo = true
        let audio = Song(videoId: "twinAudio01", title: "SWIM", artist: "BTS", durationText: "2:40")
        let other = Song(videoId: "otherSong01", title: "Boston", artist: "STELLA LEFTY", durationText: "2:51")
        let now = Date()
        backup.note([audio], at: now.addingTimeInterval(-20))
        backup.note([other], at: now.addingTimeInterval(-10))
        backup.note([video], at: now)
        for id in ["twinVideo01", "twinAudio01", "otherSong01"] { await fill(cache, .youtube(videoId: id)) }

        let listed = await backup.songs().map(\.videoId)
        XCTAssertEqual(listed, ["twinAudio01", "otherSong01"])
    }

    /// The music video streamed, its song version downloaded (never streamed, so not in the
    /// cache): the pair is one row, and that row is on the Downloads page, so the video isn't
    /// listed here either.
    func testAVideoWhoseSongVersionIsDownloadedIsLeftToTheDownloadsPage() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let backup = OfflineBackup(cache: cache, file: nil)
        backup.isPinned = { _ in false }
        backup.savedSongs = { [Song(videoId: "savedAudio1", title: "SWIM ", artist: "bts", durationText: "2:40")] }
        var video = Song(videoId: "savedVideo1", title: "SWIM", artist: "BTS", durationText: "4:05")
        video.isVideo = true
        let other = Song(videoId: "otherSong02", title: "Boston", artist: "STELLA LEFTY", durationText: "2:51")
        let now = Date()
        backup.note([other], at: now.addingTimeInterval(-10))
        backup.note([video], at: now)
        for id in ["savedVideo1", "otherSong02"] { await fill(cache, .youtube(videoId: id)) }

        let listed = await backup.songs().map(\.videoId)
        XCTAssertEqual(listed, ["otherSong02"])
    }

    /// Only a video and a non-video merge. Two songs sharing a title and credit (an album cut and
    /// a live one) are both whole on disk and both listed; and the song stays when it is the one
    /// seen more recently than its video.
    func testTwoSongsWithTheSameTitleStayTwoRows() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let backup = OfflineBackup(cache: cache, file: nil)
        backup.isPinned = { _ in false }
        let album = Song(videoId: "sameAlbum01", title: "Bleed It Out", artist: "Linkin Park", durationText: "2:44")
        let live = Song(videoId: "sameLive001", title: "bleed it out", artist: "Linkin Park")
        var video = Song(videoId: "pairVideo01", title: "Internet Girl", artist: "KATSEYE", durationText: "3:30")
        video.isVideo = true
        let audio = Song(videoId: "pairAudio01", title: "Internet Girl ", artist: "KATSEYE", durationText: "2:44")
        let now = Date()
        backup.note([video], at: now.addingTimeInterval(-30))
        backup.note([live], at: now.addingTimeInterval(-20))
        backup.note([album], at: now.addingTimeInterval(-10))
        backup.note([audio], at: now)
        for id in ["sameAlbum01", "sameLive001", "pairVideo01", "pairAudio01"] { await fill(cache, .youtube(videoId: id)) }

        let listed = await backup.songs().map(\.videoId)
        XCTAssertEqual(listed, ["pairAudio01", "sameAlbum01", "sameLive001"])
    }

    /// Rows keep their place for the visit: playing one (it becomes the most recent) doesn't move
    /// it, nor does leaving and coming back, nor a video folded into its song. New rows go on top,
    /// and every row shows the latest details.
    func testThePageKeepsItsOrderWhileOpen() {
        func ids(_ songs: [Song]) -> [String] { songs.map(\.videoId) }
        var places = OfflineBackup.Places()
        let first = OfflineBackup.ordered(["a", "b", "c", "d"].map(song), places: &places)
        XCTAssertEqual(ids(first), ["a", "b", "c", "d"], "first load: newest first")

        // "c" just played: the store now lists it first.
        XCTAssertEqual(ids(OfflineBackup.ordered(["c", "a", "b", "d"].map(song), places: &places)), ["a", "b", "c", "d"])
        // "e" became whole; "b" was evicted.
        XCTAssertEqual(ids(OfflineBackup.ordered(["e", "c", "a", "d"].map(song), places: &places)), ["e", "a", "c", "d"])
        // "b" is back: its old place, not the top.
        XCTAssertEqual(ids(OfflineBackup.ordered(["b", "e", "c", "a", "d"].map(song), places: &places)), ["e", "a", "b", "c", "d"])

        // The read comes back empty: the page empties, and the rows come back to their places.
        XCTAssertEqual(ids(OfflineBackup.ordered([], places: &places)), [])
        XCTAssertEqual(ids(OfflineBackup.ordered(["c", "e", "a", "b", "d"].map(song), places: &places)), ["e", "a", "b", "c", "d"])

        // Two songs sharing a title and credit (an album cut and a live one) each hold their own
        // place: the first load is as the store gave it, and playing one doesn't swap the pair.
        var twinPlaces = OfflineBackup.Places()
        let album = Song(videoId: "albumCut001", title: "Bleed It Out", artist: "Linkin Park")
        let live = Song(videoId: "liveCut0001", title: "bleed it out", artist: "Linkin Park")
        XCTAssertEqual(ids(OfflineBackup.ordered([live, song("y"), album, song("x")], places: &twinPlaces)), ["liveCut0001", "y", "albumCut001", "x"])
        XCTAssertEqual(ids(OfflineBackup.ordered([album, live, song("y"), song("x")], places: &twinPlaces)), ["liveCut0001", "y", "albumCut001", "x"])

        // The album cut is evicted and a third same-titled song arrives: it is new (on top), not
        // heir to the album cut's place; and the album cut, back, returns to its own.
        let remix = Song(videoId: "remixCut001", title: "Bleed It Out", artist: "Linkin Park")
        XCTAssertEqual(ids(OfflineBackup.ordered([remix, live, song("y"), song("x")], places: &twinPlaces)), ["remixCut001", "liveCut0001", "y", "x"])
        XCTAssertEqual(ids(OfflineBackup.ordered([album, remix, live, song("y"), song("x")], places: &twinPlaces)),
                       ["remixCut001", "liveCut0001", "y", "albumCut001", "x"])

        // A video row whose song version became whole is now listed as the song: same place.
        var videoPlaces = OfflineBackup.Places()
        var video = Song(videoId: "videoId0001", title: "SWIM", artist: "BTS")
        video.isVideo = true
        let audio = Song(videoId: "audioId0001", title: "SWIM", artist: "BTS", thumbnailUrl: "https://new.example/cover.jpg")
        _ = OfflineBackup.ordered([song("x"), video, song("y")], places: &videoPlaces)
        let folded = OfflineBackup.ordered([audio, song("x"), song("y")], places: &videoPlaces)
        XCTAssertEqual(ids(folded), ["x", "audioId0001", "y"])
        XCTAssertEqual(folded[1].thumbnailUrl, "https://new.example/cover.jpg", "the latest details, not the first load's")
        // And back again: the video, when it is the one listed, has the same place.
        XCTAssertEqual(ids(OfflineBackup.ordered([video, song("x"), song("y")], places: &videoPlaces)), ["x", "videoId0001", "y"])
    }

    func testTheListOfTracksOutlivesTheProcess() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = try makeTestCache(in: directory)
        let file = directory.appending(path: "offline-backup.json")
        let first = OfflineBackup(cache: cache, file: file)
        first.note([song("relaunch001")])
        await first.flush()
        await fill(cache, .youtube(videoId: "relaunch001"))

        let relaunched = OfflineBackup(cache: cache, file: file)
        let listed = await relaunched.songs()
        XCTAssertEqual(listed.map(\.title), ["Title relaunch001"], "titles come back with the tracks")
    }

    func testAReadAheadDoesNotOutrankARealPlay() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let backup = OfflineBackup(cache: cache, file: nil)
        let now = Date()
        backup.note([song("playedLast1")], at: now)
        backup.note([song("otherTrack1"), song("playedLast1")], at: now.addingTimeInterval(-600))
        await fill(cache, .youtube(videoId: "playedLast1"))
        await fill(cache, .youtube(videoId: "otherTrack1"))

        let listed = await backup.songs().map(\.videoId)
        XCTAssertEqual(listed, ["playedLast1", "otherTrack1"])
    }

    /// End to end: with no connection, a track whose only whole copy is the one a quality upgrade
    /// left plays from disk, and nothing is asked of the network.
    func testWithNoConnectionATrackPlaysFromTheCopyAnUpgradeLeft() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache)
        harness.factory.isOffline = { true }
        // The audio exists only in the cache: the resolver has nothing for this id.
        let audio = try TestAudio.tone(seconds: 8, format: .m4a, in: harness.directory, name: "offlineOnly")
        let saved = await cache.cacheCompletely(AudioCacheKey(trackID: "offlineOnly", rendition: "hifi"),
                                                source: InMemoryAudioSource(data: try Data(contentsOf: audio), mimeType: "audio/mp4"))
        XCTAssertTrue(saved)
        let song = Song(videoId: "offlineOnly", title: "Offline only", artist: "Artist", durationText: "0:08")

        harness.player.play([song], startAt: 0)

        await waitUntil("the track plays from disk") { harness.engine.isPlaying && harness.player.position > 0.5 }
        XCTAssertEqual(harness.player.currentSong?.videoId, "offlineOnly")
    }

    // MARK: Which whole copy plays

    private func rendition(_ key: AudioCacheKey, whole: Bool = true, bytes: Int64 = 1_000) -> AudioCacheRendition {
        AudioCacheRendition(key: key, contentLength: bytes, cachedPrefix: whole ? bytes : bytes / 2)
    }

    func testAnUpgradesCopyOnDiskIsPlayedInsteadOfUpgradingAgain() {
        let known = [rendition(.youtube(videoId: "v")), rendition(AudioCacheKey(trackID: "v", rendition: "hifi"), bytes: 9_000)]
        XCTAssertEqual(PlaybackSourceFactory.cachedCopy(among: known, videoId: "v", pinned: false, wantsLossless: true, atmosAllowed: true, offline: false),
                       AudioCacheKey(trackID: "v", rendition: "hifi"))
        XCTAssertEqual(PlaybackSourceFactory.cachedCopy(among: known, videoId: "v", pinned: true, wantsLossless: true, atmosAllowed: true, offline: false),
                       .youtube(videoId: "v"), "pinned to the original: YouTube's own")
        XCTAssertEqual(PlaybackSourceFactory.cachedCopy(among: known, videoId: "v", pinned: false, wantsLossless: false, atmosAllowed: true, offline: false),
                       .youtube(videoId: "v"), "lossless not asked for: YouTube's own")
    }

    func testAHalfCachedUpgradeIsNotPlayedFromDisk() {
        let known = [rendition(AudioCacheKey(trackID: "v", rendition: "hifi"), whole: false)]
        XCTAssertNil(PlaybackSourceFactory.cachedCopy(among: known, videoId: "v", pinned: false, wantsLossless: true, atmosAllowed: true, offline: true))
    }

    func testWithNoConnectionAPinnedRowNeverBorrowsASubstitute() {
        let substitute = AudioCacheKey.substitute(videoId: "v", atmosAllowed: true)
        let known = [rendition(AudioCacheKey(trackID: "v", rendition: "original"), bytes: 500), rendition(substitute, bytes: 9_000)]
        XCTAssertEqual(PlaybackSourceFactory.cachedCopy(among: known, videoId: "v", pinned: true, wantsLossless: true, atmosAllowed: true, offline: true),
                       AudioCacheKey(trackID: "v", rendition: "original"), "the smaller copy, not the substitute it was pinned away from")
        XCTAssertNil(PlaybackSourceFactory.cachedCopy(among: [rendition(substitute)], videoId: "v", pinned: true, wantsLossless: true,
                                                      atmosAllowed: true, offline: true))
        // Unsorted input: the largest is picked by size, not by position.
        let unsorted = [rendition(AudioCacheKey(trackID: "v", rendition: "big"), bytes: 9_000), rendition(AudioCacheKey(trackID: "v", rendition: "small"), bytes: 500)]
        XCTAssertEqual(PlaybackSourceFactory.cachedCopy(among: unsorted, videoId: "v", pinned: false, wantsLossless: false, atmosAllowed: true, offline: true),
                       AudioCacheKey(trackID: "v", rendition: "big"))
    }

    func testWithNoConnectionAnyWholeCopyPlays() {
        // Online this row would resolve (the request doesn't pick an upgrade's copy); offline it can't.
        let known = [rendition(AudioCacheKey(trackID: "v", rendition: "hifi"), bytes: 9_000)]
        XCTAssertNil(PlaybackSourceFactory.cachedCopy(among: known, videoId: "v", pinned: false, wantsLossless: false, atmosAllowed: true, offline: false))
        XCTAssertEqual(PlaybackSourceFactory.cachedCopy(among: known, videoId: "v", pinned: false, wantsLossless: false, atmosAllowed: true, offline: true),
                       AudioCacheKey(trackID: "v", rendition: "hifi"))
    }

    /// An upgrade's copy is a ranked source's, like a substitute: a row pinned to YouTube's own
    /// ("Revert to original") doesn't play it with no connection either, but YouTube's smaller one.
    func testWithNoConnectionAPinnedRowNeverPlaysAnUpgradesCopy() {
        let original = AudioCacheKey(trackID: "v", rendition: "original")
        for tag in ["hifi", "hifi-2"] {
            let known = [rendition(original, bytes: 500), rendition(AudioCacheKey(trackID: "v", rendition: tag), bytes: 9_000)]
            XCTAssertEqual(PlaybackSourceFactory.cachedCopy(among: known, videoId: "v", pinned: true, wantsLossless: true, atmosAllowed: true, offline: true),
                           original, tag)
            XCTAssertNil(PlaybackSourceFactory.cachedCopy(among: [rendition(AudioCacheKey(trackID: "v", rendition: tag))], videoId: "v", pinned: true,
                                                          wantsLossless: true, atmosAllowed: true, offline: true), tag)
        }
    }

    /// An upgrade's entry doesn't record its format, so with Atmos off (the switch, or a device that
    /// can't decode it) it never plays off the disk: it may be the add-on's Atmos mix. Nor does the
    /// substitute fetched while Atmos was on.
    func testWithAtmosOffAnUpgradesCopyIsNotPlayedFromDisk() {
        for tag in ["hifi", "hifi-2"] {
            let upgrade = rendition(AudioCacheKey(trackID: "v", rendition: tag), bytes: 9_000)
            XCTAssertEqual(PlaybackSourceFactory.cachedCopy(among: [rendition(.youtube(videoId: "v")), upgrade], videoId: "v", pinned: false,
                                                            wantsLossless: true, atmosAllowed: false, offline: false),
                           .youtube(videoId: "v"), "\(tag): YouTube's own instead")
            XCTAssertNil(PlaybackSourceFactory.cachedCopy(among: [upgrade], videoId: "v", pinned: false, wantsLossless: true, atmosAllowed: false, offline: false),
                         "\(tag): online, the row resolves under the switch")
            XCTAssertNil(PlaybackSourceFactory.cachedCopy(among: [upgrade], videoId: "v", pinned: false, wantsLossless: true, atmosAllowed: false, offline: true),
                         "\(tag): offline too")
        }
        // The substitute's entry is split by the switch: the copy fetched with Atmos on doesn't play
        // even offline, the Atmos-free one does.
        let free = AudioCacheKey.substitute(videoId: "v", atmosAllowed: false)
        let fetchedWithAtmos = rendition(.substitute(videoId: "v", atmosAllowed: true), bytes: 9_000)
        XCTAssertNil(PlaybackSourceFactory.cachedCopy(among: [fetchedWithAtmos], videoId: "v", pinned: false, wantsLossless: false, atmosAllowed: false, offline: true))
        XCTAssertEqual(PlaybackSourceFactory.cachedCopy(among: [fetchedWithAtmos, rendition(free)], videoId: "v", pinned: false, wantsLossless: true,
                                                        atmosAllowed: false, offline: true),
                       free)
    }
}
