import AVFoundation
import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Downloads

/// Ports OfflineDashTest: the MPD reader, against a real Tidal manifest rather than a made-up one,
/// because a parser that drops the last segment or overstates a duration fails silently.
final class OfflineDashManifestTests: XCTestCase {
    /// Tidal's manifest for The Weeknd's "Starboy" at `quality=LOSSLESS`, September 2026, with the
    /// signed CloudFront URLs shortened. The timeline, the timescale, the `$Number$` template and the
    /// escaped `&amp;` are verbatim. Also in Fixtures/tidal_starboy_lossless.mpd.
    private func starboy() throws -> String {
        try FixtureLoader(bundle: .module).string("tidal_starboy_lossless.mpd")
    }

    func testAManifestIsRecognisedByItsExtensionQueryStringAndAll() {
        XCTAssertTrue(OfflineDash.handles("https://im-cf.manifest.tidal.com/1/manifests/AbC.mpd?Expires=1&Signature=x"))
        XCTAssertTrue(OfflineDash.handles("https://host/a.MPD"))
        XCTAssertFalse(OfflineDash.handles("https://im-cf.manifest.tidal.com/1/manifests/AbC.m3u8?Expires=1"))
        XCTAssertFalse(OfflineDash.handles("https://aac.saavncdn.com/820/abc_320.mp4"))
        XCTAssertTrue(OfflineDash.handles(URL(string: "https://im-cf.manifest.tidal.com/1/manifests/AbC.mpd?Expires=1")!))
    }

    /// `r` counts *repeats*, not segments, so `r="56"` is 57 of them. Read as a count it silently
    /// truncates every download by one segment — four seconds of the end of the song.
    func testTheTimelineExpandsToOneEntryPerSegment() throws {
        let plan = try OfflineDash.parse(starboy())
        XCTAssertEqual(plan.media.count, 58)
        XCTAssertEqual(plan.seconds.count, 58)
        XCTAssertEqual(plan.seconds.first!, 3.994, accuracy: 0.001)
        XCTAssertEqual(plan.seconds[56], 3.994, accuracy: 0.001)
        XCTAssertEqual(plan.seconds.last!, 2.813, accuracy: 0.001)
        // They add up to the runtime the manifest states: the one number that catches an off-by-one
        // anywhere in the expansion.
        XCTAssertEqual(plan.seconds.reduce(0, +), 230.461, accuracy: 0.01)
    }

    /// `$Number$` starts at `startNumber`, and the init segment is a separate URL rather than number
    /// zero — getting that wrong fetches the init segment twice and loses the last one.
    func testSegmentUrlsComeOffTheTemplateUnescaped() throws {
        let plan = try OfflineDash.parse(starboy())
        XCTAssertEqual(plan.initialization, "https://sp-ad-cf.audio.tidal.com/mediatracks/BLOB/0.mp4?Policy=P&Signature=S")
        XCTAssertEqual(plan.media.first, "https://sp-ad-cf.audio.tidal.com/mediatracks/BLOB/1.mp4?Policy=P&Signature=S")
        XCTAssertEqual(plan.media.last, "https://sp-ad-cf.audio.tidal.com/mediatracks/BLOB/58.mp4?Policy=P&Signature=S")
    }

    /// No timeline: a fixed segment duration across the stated presentation length.
    func testAFixedDurationManifestCoversThePresentation() throws {
        let manifest = """
        <MPD mediaPresentationDuration="PT1M0.5S"><Period><AdaptationSet><Representation>
        <SegmentTemplate timescale="1000" duration="4000" initialization="init.mp4" media="seg-$Number$.m4s" startNumber="0"/>
        </Representation></AdaptationSet></Period></MPD>
        """
        let plan = try OfflineDash.parse(manifest)
        XCTAssertEqual(plan.media.count, 16, "60.5 s in 4 s segments, rounded up")
        XCTAssertEqual(plan.media.first, "seg-0.m4s")
        XCTAssertEqual(plan.initialization, "init.mp4")
        XCTAssertEqual(OfflineDash.isoSeconds("PT3M50.461S")!, 230.461, accuracy: 0.0001)
        XCTAssertEqual(OfflineDash.isoSeconds("PT1H2M3S")!, 3723, accuracy: 0.0001)
        XCTAssertNil(OfflineDash.isoSeconds("PT0S"))
    }

    /// Half a song is worse than a refusal, because only the refusal is recoverable.
    func testManifestsThatCannotBeSavedWholeAreRefused() throws {
        let manifest = try starboy()
        func refusal(_ text: String) -> String? {
            do {
                _ = try OfflineDash.parse(text)
                return nil
            } catch {
                return (error as? OfflinePackageError)?.message
            }
        }
        XCTAssertEqual(refusal(manifest.replacingOccurrences(of: "<SegmentTemplate", with: #"<ContentProtection schemeIdUri="urn:x"/><SegmentTemplate"#)),
                       "Encrypted DASH cannot be saved")
        XCTAssertEqual(refusal(manifest.replacingOccurrences(of: "</MPD>", with: #"<Period id="1"></Period></MPD>"#)),
                       "Multi-period DASH cannot be saved")
        XCTAssertEqual(refusal(manifest.replacingOccurrences(of: "$Number$", with: "$Time$")),
                       "Unsupported DASH media template")
        XCTAssertEqual(refusal("<MPD><Period></Period></MPD>"), "DASH manifest has no segment template")
    }
}

final class OfflineHlsPlaylistTests: XCTestCase {
    private let base = URL(string: "https://cdn.example/track/media.m3u8?token=1")!

    func testAnFmp4PlaylistListsTheMapFirstThenEachSegmentOnce() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:4
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        seg-1.m4s
        #EXTINF:4.0,
        seg-2.m4s
        #EXTINF:4.0,
        seg-2.m4s
        #EXT-X-ENDLIST
        """
        XCTAssertEqual(try OfflineHls.parse(playlist, base: base), .segments([
            URL(string: "https://cdn.example/track/init.mp4")!,
            URL(string: "https://cdn.example/track/seg-1.m4s")!,
            URL(string: "https://cdn.example/track/seg-2.m4s")!,
        ]))
    }

    /// Android saved a master playlist's variant URLs as if they were audio; iOS follows the
    /// highest-bandwidth variant.
    func testAMasterPlaylistPointsAtItsBestVariant() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"
        low/media.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1411000,CODECS="flac"
        https://other.example/high/media.m3u8
        """
        XCTAssertEqual(try OfflineHls.parse(master, base: base), .variant(URL(string: "https://other.example/high/media.m3u8")!))
    }

    func testPlaylistsThatCantBeSavedAreRefusedWithASentence() {
        func refusal(_ text: String) -> String? {
            do {
                _ = try OfflineHls.parse(text, base: base)
                return nil
            } catch {
                return (error as? OfflinePackageError)?.message
            }
        }
        XCTAssertEqual(refusal("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXT-X-MAP:URI=\"i.mp4\"\na.m4s"), "Encrypted HLS cannot be saved")
        XCTAssertEqual(refusal("<html>"), "Invalid HLS playlist")
        XCTAssertEqual(refusal("#EXTM3U\n#EXTINF:4,\na.ts\n"), "This stream's format can't be saved on this device")
        XCTAssertEqual(refusal("#EXTM3U\n#EXT-X-ENDLIST"), "HLS playlist has no fragments")
    }
}

/// The iOS half: segments flattened into one fragmented `.m4a` that AVFoundation plays and the
/// tagger can tag. Uses real segments cut by AVAssetWriter's own HLS segmenter.
final class OfflinePackageFlattenTests: XCTestCase {
    func testMediaSegmentsKeepOnlyTheirFragments() throws {
        func box(_ type: String, _ size: Int) -> [UInt8] {
            let total = size + 8
            return [0, 0, UInt8(total >> 8), UInt8(total & 0xFF)] + Array(type.utf8) + [UInt8](repeating: 1, count: size)
        }
        let segment = box("styp", 8) + box("sidx", 24) + box("moof", 16) + box("mdat", 32) + box("moof", 16) + box("mdat", 4)
        let flat = [UInt8](try Downloader.flatten(Data(segment), isInitialization: false))
        XCTAssertEqual(flat, box("moof", 16) + box("mdat", 32) + box("moof", 16) + box("mdat", 4))
        XCTAssertThrowsError(try Downloader.flatten(Data([0x47, 0x40, 0x11, 0x10] + [UInt8](repeating: 0, count: 184)), isInitialization: true))
        XCTAssertThrowsError(try Downloader.flatten(Data(box("ftyp", 8)), isInitialization: true), "an init segment needs a moov")
    }

    /// The whole DASH route through the queue: manifest, init + media segments, flattened, tagged,
    /// and played back by AVFoundation for the full length.
    @MainActor
    func testADashDownloadBecomesOnePlayableTaggedFile() async throws {
        let dir = try makeTemporaryDirectory()
        let source = try TestAudio.m4a(seconds: 5, at: dir.appending(path: "source.m4a"))
        let segments = try await TestAudio.fmp4Segments(from: source)
        XCTAssertGreaterThanOrEqual(segments.media.count, 3)

        let timescale = 1000
        let timeline = segments.durations.map { #"<S d="\#(Int(($0 * Double(timescale)).rounded()))"/>"# }.joined()
        let manifest = """
        <?xml version='1.0' encoding='UTF-8'?><MPD type="static" mediaPresentationDuration="PT5S"><Period id="0">\
        <AdaptationSet contentType="audio"><Representation id="AAC" codecs="mp4a.40.2">\
        <SegmentTemplate timescale="\(timescale)" initialization="init.mp4?sig=a&amp;x=1" media="seg-$Number$.m4s?sig=a&amp;x=1" startNumber="1">\
        <SegmentTimeline>\(timeline)</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>
        """
        let harness = DownloadHarness(root: dir.appending(path: "store"),
                                      lyrics: { _ in DownloadLyrics(plain: "[00:01.00]offline words") },
                                      resolver: FakeResolver { _, _ in
            ResolvedStream(url: URL(string: "https://sp-ad-cf.audio.tidal.com/manifests/abc.mpd?Expires=1")!, origin: .addon,
                           mimeType: "application/dash+xml", format: StreamFormat(codec: "flac", bitDepth: 16))
        })
        harness.stub.register(host: "sp-ad-cf.audio.tidal.com") { request in
            let path = request.url!.path(percentEncoded: false)
            XCTAssertEqual(request.url?.query(), path.hasSuffix(".mpd") ? "Expires=1" : "sig=a&x=1")
            if path.hasSuffix(".mpd") { return .text(manifest, headers: ["Content-Type": "application/dash+xml"]) }
            if path.hasSuffix("init.mp4") { return .data(segments.initialization) }
            let number = Int(path.split(separator: "-").last!.split(separator: ".").first!)!
            return .data(segments.media[number - 1])
        }

        harness.manager.enqueue(song("dash1", title: "Package", artist: "Source Artist", album: "Lossless Album"))
        await harness.manager.waitUntilIdle()

        XCTAssertEqual(harness.manager.session.state.finished, 1, "\(harness.manager.session.state.items)")
        let file = try XCTUnwrap(harness.library.savedFileURL(for: "dash1"))
        XCTAssertEqual(file.lastPathComponent, "Source Artist - Package.m4a")
        let tags = await EmbeddedTags.read(from: file)
        XCTAssertTrue(tags.isPlayable)
        XCTAssertEqual(try XCTUnwrap(tags.durationSeconds), 5, accuracy: 0.2, "every segment made it into the file")
        XCTAssertEqual(tags.title, "Package")
        XCTAssertEqual(tags.album, "Lossless Album")
        XCTAssertEqual(tags.lyrics, "[00:01.00]offline words")
        XCTAssertEqual(harness.library.songs().first?.downloadFormat, "FLAC")
        XCTAssertEqual(harness.stub.requests(toPath: "/manifests/abc.mpd").count, 1)
    }

    /// A source that labels an HLS playlist as FLAC gets its playlist saved as a package rather than
    /// its text saved as `.flac` (Android's `isDirectAudioFile` found the same mislabel).
    @MainActor
    func testAMislabelledHlsPlaylistIsSavedAsAPackage() async throws {
        let dir = try makeTemporaryDirectory()
        let source = try TestAudio.m4a(seconds: 3, at: dir.appending(path: "source.m4a"))
        let segments = try await TestAudio.fmp4Segments(from: source)
        var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for (index, duration) in segments.durations.enumerated() {
            playlist += "#EXTINF:\(duration),\nseg\(index).m4s\n"
        }
        playlist += "#EXT-X-ENDLIST\n"
        let served = playlist
        let harness = DownloadHarness(root: dir.appending(path: "store"), resolver: FakeResolver { _, _ in
            ResolvedStream(url: URL(string: "https://module.example/stream/track.flac")!, origin: .module,
                           mimeType: "audio/flac", format: StreamFormat(codec: "flac"))
        })
        harness.stub.register(host: "module.example") { request in
            let name = request.url!.lastPathComponent
            if name == "track.flac" { return .text(served) }
            if name == "init.mp4" { return .data(segments.initialization) }
            let index = Int(name.dropFirst(3).dropLast(4))!
            return .data(segments.media[index])
        }
        harness.manager.enqueue(song("hls1", title: "Mislabelled"))
        await harness.manager.waitUntilIdle()

        let file = try XCTUnwrap(harness.library.savedFileURL(for: "hls1"))
        XCTAssertEqual(file.pathExtension, "m4a")
        let tags = await EmbeddedTags.read(from: file)
        XCTAssertTrue(tags.isPlayable)
        XCTAssertEqual(try XCTUnwrap(tags.durationSeconds), 3, accuracy: 0.2)
    }

    /// An add-on's DASH stream reaches the downloader as the playlist the app converted it to,
    /// under a scheme only the player's loader answers. The playlist is read from this device and
    /// its segments (absolute https URLs) are fetched; before, URLSession was asked for the
    /// playlist itself and failed with "unsupported URL" (-1002).
    @MainActor
    func testAConvertedDashPlaylistOnThisDeviceIsSavedAsAPackage() async throws {
        let dir = try makeTemporaryDirectory()
        let source = try TestAudio.m4a(seconds: 3, at: dir.appending(path: "source.m4a"))
        let segments = try await TestAudio.fmp4Segments(from: source)
        var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-MAP:URI=\"https://cdn.example/init.mp4\"\n"
        for (index, duration) in segments.durations.enumerated() {
            playlist += "#EXTINF:\(duration),\nhttps://cdn.example/seg\(index).m4s\n"
        }
        playlist += "#EXT-X-ENDLIST\n"
        let converted = playlist
        let playlistURL = URL(string: "vibramusic-hls://playlist/abc123.m3u8")!
        let harness = DownloadHarness(root: dir.appending(path: "store"), resolver: FakeResolver { _, _ in
            ResolvedStream(url: playlistURL, origin: .addon, mimeType: "application/vnd.apple.mpegurl", format: StreamFormat(codec: "flac"))
        })
        harness.manager.localPlaylist = { $0 == playlistURL ? converted : nil }
        harness.stub.register(host: "cdn.example") { request in
            let name = request.url!.lastPathComponent
            if name == "init.mp4" { return .data(segments.initialization) }
            let index = Int(name.dropFirst(3).dropLast(4))!
            return .data(segments.media[index])
        }
        harness.manager.enqueue(song("dash1", title: "Converted"))
        await harness.manager.waitUntilIdle()

        let file = try XCTUnwrap(harness.library.savedFileURL(for: "dash1"), "the download finished")
        let tags = await EmbeddedTags.read(from: file)
        XCTAssertTrue(tags.isPlayable)
        XCTAssertEqual(try XCTUnwrap(tags.durationSeconds), 3, accuracy: 0.2)
    }

    /// The converted playlist is gone from this device (swept from Caches): the download says so
    /// in words, and URLSession is never asked for the app-private URL.
    @MainActor
    func testAConvertedPlaylistThatIsGoneFailsInWords() async throws {
        let dir = try makeTemporaryDirectory()
        let harness = DownloadHarness(root: dir.appending(path: "store"), resolver: FakeResolver { _, _ in
            ResolvedStream(url: URL(string: "vibramusic-hls://playlist/gone.m3u8")!, origin: .addon,
                           mimeType: "application/vnd.apple.mpegurl", format: StreamFormat(codec: "flac"))
        })
        harness.manager.enqueue(song("gone1", title: "Gone"))
        await harness.manager.waitUntilIdle()

        XCTAssertNil(harness.library.savedFileURL(for: "gone1"))
        guard case .failed(let reason)? = harness.manager.active["gone1"] else { return XCTFail("the download failed, visibly") }
        XCTAssertTrue(reason.contains("can't be read on this device"), "said in words, not as -1002: \(reason)")
    }
}
