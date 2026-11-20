import VibraMusicTestSupport
import XCTest
@testable import Canvas

/// Apple's HLS motion artwork joined into one local file for the lock screen.
/// Fixtures are a real catalogue master (`apple-motion-master.m3u8`) and its 768x768 H.264 media
/// playlist (`apple-motion-media.m3u8`): a CMAF single file whose init map and 8 segments are
/// byte ranges of one `.mp4`, 6,142,046 bytes in all.
final class HLSClipAssemblerTests: XCTestCase {
    private let master = URL(string: "https://mvod.itunes.apple.com/itunes-assets/HLSMusic112/v4/35/7f/54/357f54ab/P471842481_default.m3u8")!

    /// The H.264 768x768 variant (the smallest at or past 720 on its short side, never HEVC), and
    /// its whole playlist as a single ranged GET of the file from byte 0 to its end.
    func testApplesMotionClipIsOneRangeOfTheSmallestSharpH264Variant() throws {
        let variants = HLSClipAssembler.variants(master: try CanvasFixture.text("apple-motion-master.m3u8"), base: master)
        let picked = try XCTUnwrap(HLSClipAssembler.pick(variants))
        XCTAssertEqual(picked.url.lastPathComponent, "P471842481_Anull_video_gr240_sdr_768x768.m3u8")
        XCTAssertTrue(picked.codecs.hasPrefix("avc1"))

        let parts = try XCTUnwrap(HLSClipAssembler.parts(media: try CanvasFixture.text("apple-motion-media.m3u8"), base: picked.url))
        XCTAssertEqual(parts.count, 9, "the init map and 8 segments")
        let plan = HLSClipAssembler.coalesce(parts)
        XCTAssertEqual(plan, [HLSClipAssembler.Part(
            url: picked.url.deletingLastPathComponent().appending(path: "P471842481_Anull_video_gr240_sdr_768x768-.mp4"),
            range: 0..<6_142_046)])
    }

    /// Segments in their own files stay separate downloads, and a range without an offset starts
    /// where the same file's last range ended.
    func testSeparateFilesAndOffsetlessRangesKeepTheirOrder() throws {
        let base = URL(string: "https://clips.test/v/media.m3u8")!
        let media = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:3.0,
        #EXT-X-BYTERANGE:10@0
        a.m4s
        #EXTINF:3.0,
        #EXT-X-BYTERANGE:5
        a.m4s
        #EXTINF:3.0,
        b.m4s
        #EXT-X-ENDLIST
        """
        let parts = try XCTUnwrap(HLSClipAssembler.parts(media: media, base: base))
        let file = { (name: String) in URL(string: "https://clips.test/v/\(name)")! }
        XCTAssertEqual(parts, [
            .init(url: file("init.mp4"), range: nil),
            .init(url: file("a.m4s"), range: 0..<10),
            .init(url: file("a.m4s"), range: 10..<15),
            .init(url: file("b.m4s"), range: nil),
        ])
        XCTAssertEqual(HLSClipAssembler.coalesce(parts).map(\.range), [nil, 0..<15, nil])
    }

    /// TS (no init map), encrypted, empty and two-init-map playlists can't be joined into a file by byte
    /// concatenation, and a range past `Int.max` is remote input that must not trap: all refused.
    func testPlaylistsThatCannotBecomeOneFileAreRefused() {
        let base = URL(string: "https://clips.test/v/media.m3u8")!
        let cases = [
            "ts": "#EXTM3U\n#EXTINF:3.0,\nseg0.ts\n#EXTINF:3.0,\nseg1.ts\n#EXT-X-ENDLIST",
            "encrypted": "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:3.0,\na.m4s",
            "no segments": "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-ENDLIST",
            "second init map": "#EXTM3U\n#EXT-X-MAP:URI=\"a.mp4\"\n#EXTINF:3.0,\na.m4s\n#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"b.mp4\"\n#EXTINF:3.0,\nb.m4s",
            "overflowing range": "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"9223372036854775807@10\"\n#EXTINF:3.0,\na.m4s",
        ]
        for (name, media) in cases {
            XCTAssertNil(HLSClipAssembler.parts(media: media, base: base), name)
        }
    }

    /// End to end through URLSession: master, media playlist, then the file's bytes, whether the
    /// server honours the Range header (206) or ignores it and sends the whole file (200).
    func testAssembleFetchesTheRangesAndJoinsThem() async throws {
        let file = Data((0..<64).map { UInt8($0) })
        let media = """
        #EXTM3U
        #EXT-X-MAP:URI="clip-.mp4",BYTERANGE="8@0"
        #EXTINF:3.0,
        #EXT-X-BYTERANGE:20@8
        clip-.mp4
        #EXTINF:3.0,
        #EXT-X-BYTERANGE:12@28
        clip-.mp4
        #EXT-X-ENDLIST
        """
        for honoursRange in [true, false] {
            let stub = URLProtocolStub()
            stub.register(url: master, response: .text("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1.64001f",RESOLUTION=768x768
            v/media.m3u8
            """))
            stub.register(host: "mvod.itunes.apple.com", path: master.deletingLastPathComponent().appending(path: "v/media.m3u8").path(), response: .text(media))
            stub.register(host: "mvod.itunes.apple.com", path: master.deletingLastPathComponent().appending(path: "v/clip-.mp4").path()) { request in
                guard honoursRange else { return .data(file) }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-39", "one request for the joined ranges")
                return .data(file.subdata(in: 0..<40), status: 206)
            }
            let joined = await HLSClipAssembler.assemble(master: master, session: stub.makeSession())
            XCTAssertEqual(joined, file.subdata(in: 0..<40), "honours Range: \(honoursRange)")
            XCTAssertEqual(stub.requests.count, 3, "master, media, one file request")
        }
    }
}
