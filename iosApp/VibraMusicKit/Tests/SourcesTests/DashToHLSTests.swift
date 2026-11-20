import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Sources

/// AVPlayer has no DASH, so an addon's `.mpd` becomes either a progressive file (one-file
/// representations) or an HLS media playlist over the same fMP4 segments. These pin the MPD reading
/// (SegmentTemplate with and without a timeline, SegmentList, SegmentBase, BaseURL chains, template
/// identifiers) and the playlist written.
final class DashToHLSTests: XCTestCase {
    private let fixtures = FixtureLoader(bundle: .module)

    private func manifest(_ name: String, at url: String) throws -> DashManifest {
        try DashManifest.parse(try fixtures.data(name), url: URL(string: url)!)
    }

    /// Tidal's shape: absolute `$Number$` URLs, a SegmentTimeline with a repeat, `&amp;` in the
    /// query. 1 + 52 + 1 segments.
    func testASegmentTimelineBecomesAnHLSPlaylistOverTheSameSegments() throws {
        let parsed = try manifest("dash_tidal_hires_timeline.mpd", at: "https://im-fa.manifest.tidal.com/1/manifests/x")
        let conversion = try DashToHLS.convert(parsed, atmosAllowed: true)
        guard case .playlist(let text, let track) = conversion else { return XCTFail("expected a playlist") }

        XCTAssertEqual(track.codecs, "flac")
        XCTAssertEqual(track.sampleRate, 96_000)
        XCTAssertEqual(track.segments.count, 54)
        XCTAssertEqual(track.segments[0].url.absoluteString, "https://sp-pr-fa.audio.tidal.com/mediatracks/GisIAxIn/1.mp4?token=1788633325~ZmQ&x=1")
        XCTAssertEqual(track.segments[53].url.absoluteString, "https://sp-pr-fa.audio.tidal.com/mediatracks/GisIAxIn/54.mp4?token=1788633325~ZmQ&x=1")
        XCTAssertEqual(track.segments[0].duration, 383_040.0 / 96_000, accuracy: 1e-9)
        XCTAssertEqual(track.segments[53].duration, 87_808.0 / 96_000, accuracy: 1e-9)
        XCTAssertEqual(track.totalDuration, 20_385_600.0 / 96_000, accuracy: 1e-6)

        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(6)), [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:4", "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
        ])
        XCTAssertEqual(lines[6], #"#EXT-X-MAP:URI="https://sp-pr-fa.audio.tidal.com/mediatracks/GisIAxIn/0.mp4?token=1788633325~ZmQ&x=1""#)
        XCTAssertEqual(lines[7], "#EXTINF:3.990,")
        XCTAssertEqual(lines[8], "https://sp-pr-fa.audio.tidal.com/mediatracks/GisIAxIn/1.mp4?token=1788633325~ZmQ&x=1")
        XCTAssertEqual(lines.last, "#EXT-X-ENDLIST")
        XCTAssertEqual(lines.filter { $0.hasPrefix("#EXTINF:") }.count, 54)
    }

    /// Relative templates resolve through the BaseURL chain; `$RepresentationID$` and
    /// `$Number%05d$` expand; a duration-addressed template counts its segments from the
    /// presentation duration, the last one short.
    func testADurationTemplateExpandsIdentifiersAgainstTheBaseURLChain() throws {
        let parsed = try manifest("dash_atmos_and_flac.mpd", at: "https://cdn.example.com/dash/tidal-atmos")
        XCTAssertEqual(parsed.tracks.map(\.representationId), ["eac3", "flac"])
        let flac = try XCTUnwrap(parsed.tracks.last)
        XCTAssertEqual(flac.initialization?.url.absoluteString, "https://cdn.example.com/tidal/527739156/flac/init.mp4")
        XCTAssertEqual(flac.segments.count, 91)
        XCTAssertEqual(flac.segments.first?.url.absoluteString, "https://cdn.example.com/tidal/527739156/flac/seg-00000.m4s")
        XCTAssertEqual(flac.segments.last?.url.absoluteString, "https://cdn.example.com/tidal/527739156/flac/seg-00090.m4s")
        XCTAssertEqual(flac.segments.last?.duration ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(flac.totalDuration, 362, accuracy: 1e-9)
    }

    /// The immersive representation wins when Atmos is allowed and is passed over when it isn't —
    /// the same gate the whole-stream check applies.
    func testTheImmersiveRepresentationIsChosenOnlyWhenAtmosIsAllowed() throws {
        let parsed = try manifest("dash_atmos_and_flac.mpd", at: "https://cdn.example.com/dash/tidal-atmos")
        XCTAssertEqual(try DashToHLS.convert(parsed, atmosAllowed: true).track.representationId, "eac3")
        XCTAssertTrue(try DashToHLS.convert(parsed, atmosAllowed: true).track.isDolby)
        XCTAssertEqual(try DashToHLS.convert(parsed, atmosAllowed: false).track.representationId, "flac")

        let atmosOnly = DashManifest(tracks: parsed.tracks.filter(\.isDolby), isDynamic: false)
        XCTAssertThrowsError(try DashToHLS.convert(atmosOnly, atmosAllowed: false))
    }

    /// Byte-range segments of one file: `EXT-X-BYTERANGE` on the map and on every segment.
    func testASegmentListOfByteRangesBecomesByteRangeHLS() throws {
        let parsed = try manifest("dash_segment_list.mpd", at: "https://host.example/audio/manifest.mpd")
        guard case .playlist(let text, let track) = try DashToHLS.convert(parsed, atmosAllowed: false) else {
            return XCTFail("expected a playlist")
        }
        XCTAssertEqual(track.codecs, "mp4a.40.2")
        XCTAssertEqual(track.initialization?.url.absoluteString, "https://host.example/audio/media/track.mp4")
        XCTAssertEqual(track.initialization?.byteRange, 0...863)
        XCTAssertEqual(track.segments.map(\.byteRange), [864...65_000, 65_001...130_000, 130_001...160_000])
        XCTAssertTrue(text.contains(#"#EXT-X-MAP:URI="https://host.example/audio/media/track.mp4",BYTERANGE="864@0""#), text)
        XCTAssertTrue(text.contains("#EXTINF:4.000,\n#EXT-X-BYTERANGE:64137@864\nhttps://host.example/audio/media/track.mp4"), text)
    }

    /// One-file representations play progressively: the best audio one, never the video.
    func testASegmentBaseRepresentationIsPlayedAsOneFile() throws {
        let parsed = try manifest("dash_segment_base.mpd", at: "https://host.example/m.mpd")
        XCTAssertEqual(parsed.tracks.map(\.representationId), ["lo", "hi"], "the video adaptation set is ignored")
        guard case .progressive(let url, let track) = try DashToHLS.convert(parsed, atmosAllowed: true) else {
            return XCTFail("expected a single file")
        }
        XCTAssertEqual(url.absoluteString, "https://files.example.com/hi.mp4")
        XCTAssertEqual(track.bandwidth, 2_900_000)
    }

    /// A manifest's numbers come from an add-on or a module. `S@t="1e300"` or `"nan"`
    /// trapped converting to Int64, a huge `S@r` built segments until memory ran out, and a
    /// `$Number%099999999d$` width padded every segment URL to 100 MB.
    func testHostileTimelineNumbersAreRefusedOrBounded() throws {
        func mpd(_ timeline: String, media: String = "seg-$Number$.m4s", startNumber: String = "1", representations: Int = 1) -> Data {
            let representation = """
            <Representation id="a" codecs="mp4a.40.2" bandwidth="128000" audioSamplingRate="44100">
            <SegmentTemplate timescale="1000" startNumber="\(startNumber)" media="\(media)"><SegmentTimeline>\(timeline)</SegmentTimeline></SegmentTemplate>
            </Representation>
            """
            return Data("""
            <MPD type="static" mediaPresentationDuration="PT10S"><Period><AdaptationSet contentType="audio" mimeType="audio/mp4">
            \(String(repeating: representation, count: representations))
            </AdaptationSet></Period></MPD>
            """.utf8)
        }
        let url = URL(string: "https://x/m.mpd")!
        func refusal(_ data: Data) -> DashManifestError? {
            do {
                _ = try DashManifest.parse(data, url: url)
                return nil
            } catch {
                return error as? DashManifestError
            }
        }
        let hostile: [(timeline: String, refusal: DashManifestError)] = [
            (#"<S t="1e300" d="1000"/>"#, .unsupported("SegmentTimeline time out of range")),
            (#"<S t="nan" d="1000"/>"#, .unsupported("SegmentTimeline time out of range")),
            (#"<S d="1000" r="200000"/>"#, .unsupported("more than 100000 segments left of the 100000 one manifest may describe")),
            // An open-ended repeat up to a far-negative next time: the span is Int.min, and the next entry's time is refused.
            (#"<S t="0" d="1" r="-1"/><S t="-9223372036854775808" d="1"/>"#, .unsupported("SegmentTimeline time out of range")),
        ]
        // The segment budget is the manifest's, not each representation's.
        XCTAssertEqual(refusal(mpd(#"<S d="1000" r="59999"/>"#, representations: 2)), .unsupported("more than 40000 segments left of the 100000 one manifest may describe"))
        // startNumber is an unsigned 32-bit number: one past Int32 still numbers the segments.
        let late = try DashManifest.parse(mpd(#"<S d="1000"/>"#, startNumber: "3000000000"), url: url)
        XCTAssertEqual(late.tracks.first?.segments.first?.url.lastPathComponent, "seg-3000000000.m4s")
        // One outside it is refused, not numbered from 1: that URL isn't the one the server publishes.
        for number in ["4294967296", "-1", "1e3"] {
            XCTAssertEqual(refusal(mpd(#"<S d="1000"/>"#, startNumber: number)), .unsupported("startNumber out of range"), number)
        }
        for (timeline, expected) in hostile {
            XCTAssertEqual(refusal(mpd(timeline)), expected, timeline)
        }
        // A padding width over 20 is refused, not clamped to a URL the server doesn't publish.
        for width in ["21", "99999999", "99999999999999999999999"] {
            XCTAssertEqual(refusal(mpd(#"<S d="1000"/>"#, media: "seg-$Number%0\(width)d$.m4s")), .unsupported("padding width over 20"), width)
        }
        let padded = try DashManifest.parse(mpd(#"<S d="1000"/>"#, media: "seg-$Number%020d$.m4s"), url: url)
        XCTAssertEqual(padded.tracks.first?.segments.first?.url.lastPathComponent, "seg-00000000000000000001.m4s")
    }

    func testRefusesWhatItCannotPlay() {
        XCTAssertThrowsError(try DashManifest.parse(Data("<html/>".utf8), url: URL(string: "https://x")!))
        XCTAssertThrowsError(try DashManifest.parse(Data("not xml".utf8), url: URL(string: "https://x")!))
        let live = Data(#"<MPD type="dynamic"><Period><AdaptationSet contentType="audio"><Representation id="a"><BaseURL>a.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>"#.utf8)
        XCTAssertThrowsError(try DashToHLS.convert(try DashManifest.parse(live, url: URL(string: "https://x/m.mpd")!), atmosAllowed: true))
        let videoOnly = Data(#"<MPD><Period><AdaptationSet contentType="video"><Representation id="v"/></AdaptationSet></Period></MPD>"#.utf8)
        XCTAssertThrowsError(try DashManifest.parse(videoOnly, url: URL(string: "https://x")!)) { error in
            XCTAssertEqual(error as? DashManifestError, .noAudio)
        }
    }

    /// The nearest contentType wins, as mimeType already does: a Representation declaring itself
    /// audio inside a video-typed AdaptationSet is audio, and the reverse is not.
    func testARepresentationsOwnContentTypeOutranksItsAdaptationSets() throws {
        let url = URL(string: "https://x/m.mpd")!
        let audioInVideoSet = Data(#"<MPD><Period><AdaptationSet contentType="video"><Representation id="a" contentType="audio"><BaseURL>a.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>"#.utf8)
        XCTAssertEqual(try DashManifest.parse(audioInVideoSet, url: url).tracks.map(\.representationId), ["a"])
        let videoInAudioSet = Data(#"<MPD><Period><AdaptationSet contentType="audio"><Representation id="v" contentType="video"><BaseURL>v.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>"#.utf8)
        XCTAssertThrowsError(try DashManifest.parse(videoInAudioSet, url: url)) { error in
            XCTAssertEqual(error as? DashManifestError, .noAudio)
        }
    }

    func testTemplateIdentifiers() throws {
        let track = DashAudioTrack(representationId: "FLAC,96000,24", codecs: nil, mimeType: nil, bandwidth: 2_651_581, sampleRate: nil,
                                   singleFileURL: nil, initialization: nil, segments: [], totalDuration: 0)
        XCTAssertEqual(try DashManifest.substitute("$RepresentationID$/$Number%05d$-$Time$-$Bandwidth$$$.m4s", track: track, number: 7, time: 383_040),
                       "FLAC,96000,24/00007-383040-2651581$.m4s")
        XCTAssertEqual(try DashManifest.substitute("plain.mp4", track: track, number: nil, time: nil), "plain.mp4")
    }

    func testISO8601Durations() {
        XCTAssertEqual(DashManifest.seconds("PT3M32.1S") ?? 0, 212.1, accuracy: 1e-9)
        XCTAssertEqual(DashManifest.seconds("PT1H0M2S"), 3_602)
        XCTAssertEqual(DashManifest.seconds("P1DT1S"), 86_401)
        XCTAssertNil(DashManifest.seconds("3 minutes"))
    }

    func testPlaylistsAreWrittenOnePerManifestURL() throws {
        let files = SourceManifestFiles(directory: try makeTemporaryDirectory())
        let a = try files.write("#EXTM3U\n", for: URL(string: "https://x/a.mpd")!)
        let again = try files.write("#EXTM3U\n#EXT-X-ENDLIST\n", for: URL(string: "https://x/a.mpd")!)
        let b = try files.write("#EXTM3U\n", for: URL(string: "https://x/b.mpd")!)
        XCTAssertEqual(a, again)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.pathExtension, "m3u8")
        XCTAssertEqual(try String(contentsOf: again, encoding: .utf8), "#EXTM3U\n#EXT-X-ENDLIST\n")
        // The URL the player is handed names the file, and nothing outside the directory.
        let url = SourceManifestFiles.playlistURL(for: a)
        XCTAssertEqual(url.absoluteString, "vibramusic-hls://playlist/\(a.lastPathComponent)")
        XCTAssertEqual(files.playlistText(for: url), "#EXTM3U\n#EXT-X-ENDLIST\n")
        XCTAssertNil(files.file(for: URL(string: "vibramusic-hls://playlist/..%2F..%2Fsecrets.json")!))
        XCTAssertNil(files.playlistText(for: URL(string: "https://x/a.m3u8")!))
    }
}
