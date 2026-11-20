import AVFoundation
import Foundation
import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Downloads

// The library side: what is on the device, how the Downloads page lists it, deleting and storage,
// and Files import (PORTING.md Q8, the iOS replacement for LocalMediaRepository).

/// Android's LocalMediaFilterTest, plus the formats iOS can't play.
final class LocalMediaFilterTests: XCTestCase {
    func testRejectsShortAudio() {
        XCTAssertFalse(LocalMediaFilter.isEligibleLocalMusic(durationMs: 29_999, displayName: "effect.mp3",
                                                             path: "/Users/me/Music/effect.mp3"))
    }

    func testRejectsWaveAndRecorderFiles() {
        XCTAssertFalse(LocalMediaFilter.isEligibleLocalMusic(durationMs: 180_000, displayName: "recording.wav",
                                                             path: "/Users/me/Recordings/recording.wav"))
        XCTAssertFalse(LocalMediaFilter.isEligibleLocalMusic(durationMs: 180_000, displayName: "voice-note.mp3",
                                                             path: "/Users/me/Voice Recorder/voice-note.mp3"))
        XCTAssertFalse(LocalMediaFilter.isEligibleLocalMusic(durationMs: 180_000, displayName: "Memo.m4a",
                                                             path: "/private/var/mobile/Voice Memos/Memo.m4a"))
    }

    func testKeepsSupportedMusicFiles() {
        XCTAssertTrue(LocalMediaFilter.isEligibleLocalMusic(durationMs: 50_000, displayName: "Song.flac",
                                                            path: "/Users/me/Music/Artist/Song.flac"))
        XCTAssertTrue(LocalMediaFilter.isEligibleLocalMusic(durationMs: 50_000, displayName: "Song.M4A", path: nil))
    }

    /// Ogg, Opus and WebM are Android music formats AVPlayer can't open, so they are never imported.
    func testFormatsAVPlayerCannotOpenAreNotMusicHere() {
        for name in ["a.ogg", "a.opus", "a.webm"] {
            XCTAssertFalse(LocalMediaFilter.isEligibleLocalMusic(durationMs: 200_000, displayName: name, path: "/Music/\(name)"), name)
            XCTAssertFalse(LocalMediaFilter.isPlayableAudioFileName(name), name)
        }
        XCTAssertTrue(LocalMediaFilter.isPlayableAudioFileName("take.WAV"))
        XCTAssertFalse(LocalMediaFilter.isPlayableAudioFileName("cover.jpg"))
    }
}

/// Sorting, searching and grouping for the Songs / Artists / Albums tabs.
final class LocalLibraryListingTests: XCTestCase {
    private func row(_ id: String, _ title: String, artist: String = "A", album: String? = nil, added: Int64? = nil, modified: Int64? = nil) -> Song {
        Song(videoId: id, title: title, artist: artist, albumName: album, localDateAddedSeconds: added, localDateModifiedSeconds: modified)
    }

    func testTitleOrdersIgnoreCaseAndKeepTiesInTheirOrder() {
        let songs = [row("1", "beta"), row("2", "Alpha"), row("3", "alpha"), row("4", "Gamma")]
        XCTAssertEqual(LocalLibraryListing.sorted(songs, by: .titleAsc).map(\.videoId), ["2", "3", "1", "4"])
        XCTAssertEqual(LocalLibraryListing.sorted(songs, by: .titleDesc).map(\.videoId), ["4", "1", "2", "3"])
    }

    /// Newest first; a track with no date sorts last; the title breaks ties.
    func testDateOrdersAreNewestFirstWithUndatedLast() {
        let songs = [row("old", "Old", added: 100, modified: 900), row("none", "None"),
                     row("newB", "B", added: 300, modified: 300), row("newA", "A", added: 300, modified: 100)]
        XCTAssertEqual(LocalLibraryListing.sorted(songs, by: .dateAdded).map(\.videoId), ["newA", "newB", "old", "none"])
        XCTAssertEqual(LocalLibraryListing.sorted(songs, by: .dateModified).map(\.videoId), ["old", "newB", "newA", "none"])
    }

    func testSearchMatchesTitleArtistOrAlbumCaseInsensitively() {
        let songs = [row("1", "Blinding Lights", artist: "The Weeknd", album: "After Hours"),
                     row("2", "Levitating", artist: "Dua Lipa", album: "Future Nostalgia")]
        XCTAssertEqual(LocalLibraryListing.songs(songs, matching: "blinding").map(\.videoId), ["1"])
        XCTAssertEqual(LocalLibraryListing.songs(songs, matching: "DUA").map(\.videoId), ["2"])
        XCTAssertEqual(LocalLibraryListing.songs(songs, matching: "nostalgia").map(\.videoId), ["2"])
        XCTAssertEqual(LocalLibraryListing.songs(songs, matching: "  ").count, 2, "a blank query is everything")
        XCTAssertTrue(LocalLibraryListing.songs(songs, matching: "zzz").isEmpty)
    }

    func testArtistsAreOneRowPerArtistInNameOrderKeepingTrackOrder() {
        let songs = [row("1", "x", artist: "Zed"), row("2", "y", artist: "abba"), row("3", "z", artist: "Zed")]
        let artists = LocalLibraryListing.artists(in: songs)
        XCTAssertEqual(artists.map(\.name), ["abba", "Zed"])
        XCTAssertEqual(artists[1].songs.map(\.videoId), ["1", "3"])
        XCTAssertEqual(LocalLibraryListing.artists(in: songs, matching: "ze").map(\.name), ["Zed"])
    }

    /// A release downloaded whole wins over the tag grouping of the same name, and leads the list;
    /// tracks with no album tag have no Albums row.
    func testAlbumsMergeAskedReleasesWithTagGroupingsWithoutDoubling() {
        let songs = [row("1", "a", artist: "X", album: "Named"), row("2", "b", artist: "X", album: "Named"),
                     row("3", "c", artist: "Y", album: "Another"), row("4", "d", artist: "Y")]
        let asked = DownloadedCollection(id: "MPREb_1", title: "Named", subtitle: "", thumbnailUrl: nil, playlist: false,
                                         songs: [songs[0], songs[1]])
        let mix = DownloadedCollection(id: "VLPL1", title: "Mix", subtitle: "Me", thumbnailUrl: nil, playlist: true, songs: [songs[3]])
        let albums = LocalLibraryListing.albums(in: songs, collections: [asked, mix])
        XCTAssertEqual(albums.map(\.key), ["asked:VLPL1", "asked:MPREb_1", "tagged:Another"])
        XCTAssertEqual(albums[1].artist, "X", "an album with no subtitle is billed to its first track's artist")
        XCTAssertEqual(albums[0].artist, "Me")
        XCTAssertEqual(Set(albums.map(\.id)).count, albums.count, "keys are unique for ForEach")
        XCTAssertEqual(LocalLibraryListing.albums(in: songs, collections: [asked, mix], matching: "anoth").map(\.title), ["Another"])
    }
}

/// Deleting, pruning and the storage report.
@MainActor
final class DownloadLibraryStorageTests: XCTestCase {
    private func saveTwo(_ harness: DownloadHarness) async {
        harness.serveYouTube(Data(repeating: 1, count: 4_000))
        harness.serveArtwork()
        harness.manager.enqueue(song("a", title: "A", thumbnail: "https://lh3.googleusercontent.com/one=w120-h120"))
        harness.manager.enqueue(song("b", title: "B", thumbnail: "https://lh3.googleusercontent.com/two=w120-h120"))
        await harness.manager.waitUntilIdle()
    }

    /// The Downloads page's multi-select delete: the files go, the records go, and the space it
    /// reports is the space that was actually taken, covers included.
    func testMultiSelectDeleteFreesTheStorageItReports() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        await saveTwo(harness)
        let before = harness.library.storageUsage()
        XCTAssertEqual(before.downloadedCount, 2)
        XCTAssertEqual(before.downloadedBytes, 8_000)
        XCTAssertGreaterThan(before.artworkBytes, 0)
        XCTAssertEqual(before.partialBytes, 0)
        XCTAssertNotNil(before.availableBytes)
        XCTAssertEqual(before.totalBytes, before.downloadedBytes + before.artworkBytes)

        let deletion = harness.library.delete(["a", "b"])
        XCTAssertEqual(deletion.deletedFiles, 2)
        XCTAssertEqual(deletion.freedBytes, before.downloadedBytes + before.artworkBytes)

        let after = harness.library.storageUsage()
        XCTAssertEqual(after.totalBytes, 0)
        XCTAssertTrue(harness.library.songs().isEmpty)
        XCTAssertFalse(harness.library.isDownloaded("a"))
        let files = try FileManager.default.contentsOfDirectory(atPath: harness.library.store.tracksDirectory.path(percentEncoded: false))
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(DownloadStorageUsage.formatted(8_000), ByteCountFormatter.string(fromByteCount: 8_000, countStyle: .file))
    }

    /// A file the system refuses to remove stays in the library, so the page can still list it
    /// and a later delete can still reach it.
    func testAFileThatCannotBeRemovedKeepsItsRecord() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        await saveTwo(harness)
        let tracks = harness.library.store.tracksDirectory.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tracks)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tracks) }

        let deletion = harness.library.delete(["a"])
        XCTAssertEqual(deletion.deletedFiles, 0)
        XCTAssertTrue(harness.library.isDownloaded("a"), "the file is still there, so is its row")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tracks)
        XCTAssertEqual(harness.library.delete(["a"]).deletedFiles, 1)
        XCTAssertFalse(harness.library.isDownloaded("a"))
    }

    /// Two tracks off one album share a cover; deleting one keeps it for the other.
    func testACoverStillInUseSurvivesDeletingOneOfItsTracks() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.serveYouTube(Data(repeating: 2, count: 1_000))
        harness.serveArtwork()
        let cover = "https://lh3.googleusercontent.com/shared=w120-h120"
        harness.manager.download([song("s1", title: "S1", thumbnail: cover), song("s2", title: "S2", thumbnail: cover)])
        await harness.manager.waitUntilIdle()
        let path = try XCTUnwrap(harness.library.records["s1"]?.artworkPath)
        XCTAssertEqual(harness.library.records["s2"]?.artworkPath, path)

        let deletion = harness.library.delete(["s1"])
        XCTAssertEqual(deletion.freedBytes, 1_000, "the shared cover is not counted as freed")
        XCTAssertTrue(harness.library.store.exists(relativePath: path))
        XCTAssertTrue(try XCTUnwrap(harness.library.song(for: "s2")?.thumbnailUrl).hasPrefix("file://"))
    }

    /// A record outliving its file is pruned the first time it is read, every alias with it.
    func testAFileGoneFromUnderItsRecordIsPrunedOnRead() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        await saveTwo(harness)
        let file = try XCTUnwrap(harness.library.savedFileURL(for: "a"))
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(harness.library.isDownloaded("a"), "the cheap badge check is unverified")
        XCTAssertEqual(harness.library.songs().map(\.videoId), ["b"])
        XCTAssertFalse(harness.library.isDownloaded("a"))
        XCTAssertTrue(DownloadLibrary.isMissingLocalFile(file.absoluteString))
        XCTAssertFalse(DownloadLibrary.isMissingLocalFile("https://example.com/a.m4a"), "not a file:// URL: can't tell, so not missing")

        // The record is on disk too: a relaunch doesn't bring it back.
        let reopened = DownloadLibrary(store: harness.library.store)
        XCTAssertNil(reopened.records["a"])
        XCTAssertNotNil(reopened.records["b"])
    }

    /// The Downloads page lists with the file checks off the main actor, and comes to the same
    /// rows as the listing on it: the files that are there, each with its saved cover, and the record
    /// pruned of the one that isn't.
    func testTheListingDoneOffTheMainActorFindsTheSameFilesAndPrunesTheGoneOne() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        await saveTwo(harness)
        let expected = harness.library.songs()
        XCTAssertTrue(expected.allSatisfy { $0.thumbnailUrl?.hasPrefix("file://") == true }, "each row draws its saved cover")

        let listed = await harness.library.listSongs()
        XCTAssertEqual(listed, expected)

        try FileManager.default.removeItem(at: try XCTUnwrap(harness.library.savedFileURL(for: "a")))
        let afterRemoval = await harness.library.listSongs(includeImported: false)
        XCTAssertEqual(afterRemoval.map(\.videoId), ["b"])
        XCTAssertNil(harness.library.records["a"], "the record goes with its file")
    }

    /// Playback's recovery path: a read failed, so the record goes without a check.
    func testForgetMissingDropsTheRecord() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        await saveTwo(harness)
        harness.library.forgetMissing("a")
        XCTAssertNil(harness.library.records["a"])
        XCTAssertNotNil(harness.library.records["b"])
    }

    /// Unfinished bytes show up as partials, so the storage screen accounts for every byte.
    func testUnfinishedDownloadsAreReportedAsPartials() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        let pending = try harness.library.store.begin(name: "Half.m4a")
        try Data(repeating: 9, count: 1_234).write(to: pending.partURL)
        XCTAssertEqual(harness.library.storageUsage().partialBytes, 1_234)
    }

    /// Deleting a release takes its files off the device and forgets the release.
    func testDeletingACollectionDeletesItsFiles() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.serveYouTube(Data(repeating: 3, count: 500))
        harness.manager.download([song("c1"), song("c2")], as: DownloadTarget(id: "MPREb_x", title: "X"))
        await harness.manager.waitUntilIdle()
        let deletion = try XCTUnwrap(harness.library.deleteCollection("MPREb_x"))
        XCTAssertEqual(deletion.deletedFiles, 2)
        XCTAssertEqual(deletion.freedBytes, 1_000)
        XCTAssertNil(harness.library.collections["MPREb_x"])
        XCTAssertTrue(harness.library.songs().isEmpty)
    }
}

/// Files import (PORTING.md Q8): copy user-picked audio into the container and read its tags.
@MainActor
final class LocalMusicImportTests: XCTestCase {
    private func taggedM4a(_ url: URL, seconds: Double, title: String, artist: String, album: String) throws -> URL {
        let file = try TestAudio.m4a(seconds: seconds, at: url)
        let tagged = try XCTUnwrap(Mp4Tagger.tag(try Data(contentsOf: file), title: title, artist: artist, album: album, lyrics: nil,
                                                 cover: TestImages.image(width: 300, height: 300, type: .jpeg), coverIsPng: false))
        try tagged.write(to: file)
        return file
    }

    func testAPickedFileIsCopiedInWithItsOwnTagsAndCover() async throws {
        let dir = try makeTemporaryDirectory()
        let picked = try taggedM4a(dir.appending(path: "picked.m4a"), seconds: 3, title: "Picked", artist: "Someone", album: "Theirs")
        let library = DownloadLibrary(store: DownloadStore(root: dir.appending(path: "store")))
        let importer = LocalMusicImporter(library: library)

        let result = await importer.importItems(at: [picked])
        XCTAssertEqual(result.skipped, [])
        let track = try XCTUnwrap(result.imported.first)
        XCTAssertTrue(LocalMusicImporter.isImportedID(track.videoId))
        XCTAssertEqual(track.title, "Picked")
        XCTAssertEqual(track.artist, "Someone")
        XCTAssertEqual(track.albumName, "Theirs")
        XCTAssertEqual(track.durationText, "0:03")
        XCTAssertTrue(try XCTUnwrap(track.thumbnailUrl).hasPrefix("file://"), "the cover is drawn from a sidecar")
        let copy = try XCTUnwrap(track.localPath)
        XCTAssertTrue(copy.contains("/Imported/"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy)), try Data(contentsOf: picked))

        // It is in the same library as downloads, and the original can go.
        try FileManager.default.removeItem(at: picked)
        XCTAssertEqual(library.songs().map(\.videoId), [track.videoId])
        XCTAssertEqual(library.importedSongs().count, 1)
        XCTAssertTrue(library.songs(includeImported: false).isEmpty)
        XCTAssertEqual(library.storageUsage().importedCount, 1)
    }

    func testTheSameFileImportedTwiceIsKeptOnce() async throws {
        let dir = try makeTemporaryDirectory()
        let picked = try TestAudio.m4a(seconds: 1, at: dir.appending(path: "Same.m4a"))
        let library = DownloadLibrary(store: DownloadStore(root: dir.appending(path: "store")))
        let importer = LocalMusicImporter(library: library)
        _ = await importer.importItems(at: [picked])
        let again = await importer.importItems(at: [picked])
        XCTAssertTrue(again.imported.isEmpty)
        XCTAssertEqual(again.skipped.map(\.reason), ["Already in your library"])
        XCTAssertEqual(library.songs().count, 1)
        XCTAssertEqual(library.songs().first?.title, "Same", "untagged files are named after the file")
        XCTAssertEqual(library.songs().first?.artist, "Unknown Artist")
    }

    /// A folder goes through the music filter (too short, or under a recordings folder, stays out);
    /// a file picked on its own is the user's decision and comes in whatever its length.
    func testAFolderIsFilteredButASinglePickIsNot() async throws {
        let dir = try makeTemporaryDirectory()
        let folder = dir.appending(path: "Picked Folder", directoryHint: .isDirectory)
        let recordings = folder.appending(path: "Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        _ = try TestAudio.m4a(seconds: 31, at: folder.appending(path: "Long Song.m4a"))
        _ = try TestAudio.m4a(seconds: 2, at: folder.appending(path: "Ping.m4a"))
        _ = try TestAudio.m4a(seconds: 31, at: recordings.appending(path: "Interview.m4a"))
        try Data("not audio".utf8).write(to: folder.appending(path: "notes.txt"))
        let library = DownloadLibrary(store: DownloadStore(root: dir.appending(path: "store")))
        let importer = LocalMusicImporter(library: library)

        let fromFolder = await importer.importItems(at: [folder])
        XCTAssertEqual(fromFolder.imported.map(\.title), ["Long Song"])

        let single = await importer.importItems(at: [folder.appending(path: "Ping.m4a")])
        XCTAssertEqual(single.imported.map(\.title), ["Ping"])
    }

    func testAFileAVFoundationCannotPlayIsSkippedWithAReason() async throws {
        let dir = try makeTemporaryDirectory()
        let fake = dir.appending(path: "broken.mp3")
        try Data("definitely not an mp3".utf8).write(to: fake)
        let text = dir.appending(path: "readme.txt")
        try Data("hello".utf8).write(to: text)
        let library = DownloadLibrary(store: DownloadStore(root: dir.appending(path: "store")))
        let result = await LocalMusicImporter(library: library).importItems(at: [fake, text])
        XCTAssertTrue(result.imported.isEmpty)
        XCTAssertEqual(result.skipped.map(\.reason), ["Can't be played on this device", "Can't be played on this device"])
        XCTAssertTrue(library.songs().isEmpty)
    }

    /// Two different files with the same name (two albums' `01 Intro.m4a`) both come in.
    func testNameCollisionsGetANumberRatherThanReplacingAFile() async throws {
        let dir = try makeTemporaryDirectory()
        let one = dir.appending(path: "a", directoryHint: .isDirectory)
        let two = dir.appending(path: "b", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
        let first = try TestAudio.m4a(seconds: 1, at: one.appending(path: "01 Intro.m4a"))
        let second = try TestAudio.m4a(seconds: 2, at: two.appending(path: "01 Intro.m4a"))
        let library = DownloadLibrary(store: DownloadStore(root: dir.appending(path: "store")))
        let result = await LocalMusicImporter(library: library).importItems(at: [first, second])
        XCTAssertEqual(result.imported.count, 2)
        XCTAssertEqual(Set(result.imported.compactMap { $0.localPath.map { ($0 as NSString).lastPathComponent } }),
                       ["01 Intro.m4a", "01 Intro (2).m4a"])
    }

    /// Deleting an imported track removes the app's copy and frees its bytes.
    func testDeletingAnImportFreesItsCopy() async throws {
        let dir = try makeTemporaryDirectory()
        let picked = try TestAudio.m4a(seconds: 1, at: dir.appending(path: "Gone.m4a"))
        let library = DownloadLibrary(store: DownloadStore(root: dir.appending(path: "store")))
        let result = await LocalMusicImporter(library: library).importItems(at: [picked])
        let track = try XCTUnwrap(result.imported.first)
        let size = DownloadStore.fileSize(URL(fileURLWithPath: try XCTUnwrap(track.localPath)))
        let deletion = library.delete([track.videoId])
        XCTAssertEqual(deletion.freedBytes, size)
        XCTAssertTrue(library.songs().isEmpty)
    }
}

/// The AVFoundation double-duration fix for fragmented MP4 (no Android counterpart).
final class FragmentedMP4DurationTests: XCTestCase {
    private func realHeader() throws -> [UInt8] {
        [UInt8](try FixtureLoader(bundle: .module).data("itag140_init_segment.mp4"))
    }

    /// The real googlevideo header: `mvhd`, `tkhd` and `mdhd` declare 213 s, and exactly those
    /// three fields are zeroed.
    func testTheRealYouTubeHeaderHasExactlyItsThreeDeclaredDurationsZeroed() throws {
        let original = try realHeader()
        var patched = original
        XCTAssertEqual(FragmentedMP4Durations.patch(&patched), 3)
        XCTAssertEqual(patched.count, original.count)
        let changed = zip(original, patched).filter { $0 != $1 }.count
        XCTAssertGreaterThan(changed, 0)
        XCTAssertLessThanOrEqual(changed, 12, "three 32-bit fields and nothing else")
        var again = patched
        XCTAssertEqual(FragmentedMP4Durations.patch(&again), 0, "patching twice changes nothing")
        XCTAssertEqual(again, patched)
    }

    /// An ordinary MP4 declares its real length there; zeroing it would break the file.
    func testAnOrdinaryMp4IsLeftAlone() throws {
        let file = try TestAudio.m4a(seconds: 1, at: try makeTemporaryDirectory().appending(path: "plain.m4a"))
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try FragmentedMP4Durations.patchFile(at: file), 0)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    /// On a whole file, the patch is what makes AVFoundation read the true length.
    func testAVFoundationReadsAPatchedFileAtItsTrueLength() async throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appending(path: "shaped.m4a")
        try await TestAudio.youtubeShaped(seconds: 3, in: dir).write(to: file)
        XCTAssertEqual(try FragmentedMP4Durations.patchFile(at: file), 3)
        let tags = await EmbeddedTags.read(from: file)
        XCTAssertEqual(try XCTUnwrap(tags.durationSeconds), 3, accuracy: 0.2)
    }

    /// Tagging YouTube's layout (`moov` then `sidx` then fragments) leaves the `sidx` byte-for-byte:
    /// its offsets are relative, and it moves with everything after the `moov`.
    func testTaggingTheRealYouTubeHeaderKeepsItsLayout() throws {
        let original = try realHeader()
        let tagged = [UInt8](try XCTUnwrap(Mp4Tagger.tag(Data(original), title: "T", artist: "A", album: nil, lyrics: nil,
                                                          cover: nil, coverIsPng: false)))
        let before = Mp4Tagger.parseBoxes(original, 0, original.count)
        let after = Mp4Tagger.parseBoxes(tagged, 0, tagged.count)
        XCTAssertEqual(after.map(\.type), before.map(\.type))
        let sidxBefore = try XCTUnwrap(before.first { $0.type == "sidx" })
        let sidxAfter = try XCTUnwrap(after.first { $0.type == "sidx" })
        XCTAssertEqual(Array(tagged[sidxAfter.offset..<sidxAfter.end]), Array(original[sidxBefore.offset..<sidxBefore.end]))
        var patched = tagged
        XCTAssertEqual(FragmentedMP4Durations.patch(&patched), 3, "the patch still finds the moov after tagging")
    }
}
