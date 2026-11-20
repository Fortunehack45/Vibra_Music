import XCTest
@testable import Lyrics

/// The reader has to agree with what the download taggers write (ported from Android's
/// `EmbeddedLyricsTest`). Android wrote with its real `Mp4Tagger`/`FlacTagger`/`WebmTagger`;
/// those live in the Downloads module here, so `TestTagger` below reproduces the exact byte
/// layout each of them emits (same atoms, blocks and elements, same order). Placeholder
/// text throughout.
final class EmbeddedLyricsTests: XCTestCase {
    private let lrc = "[00:01.00]first line\n[00:05.00]second line"

    private var wordLines: [LyricLine] {
        [LyricLine(timeMs: 1_000, text: "two words", words: [
            LyricWord(startMs: 1_000, endMs: 1_400, text: "two"), LyricWord(startMs: 1_400, endMs: 2_000, text: "words"),
        ])]
    }

    func testAnM4AWrittenByTheTaggerReadsBack() {
        XCTAssertEqual(EmbeddedLyrics.fromBytes(TestTagger.mp4(lyrics: lrc)), lrc)
    }

    func testAFLACWrittenByTheTaggerReadsBack() {
        XCTAssertEqual(EmbeddedLyrics.fromBytes(TestTagger.flac(lyrics: lrc)), lrc)
    }

    func testAWebMWrittenByTheTaggerReadsBack() {
        XCTAssertEqual(EmbeddedLyrics.fromBytes(TestTagger.webm(lyrics: lrc)), lrc)
    }

    /// A cover is a `data` box too, in the same `ilst` as the lyrics. Reading the first one
    /// that turns up rather than the lyrics' own would hand a JPEG back as a string.
    func testACoverAlongsideTheLyricsIsNotMistakenForThem() {
        XCTAssertEqual(EmbeddedLyrics.fromBytes(TestTagger.mp4(lyrics: lrc, cover: Data(repeating: 0x7F, count: 64))), lrc)
    }

    /// The whole point of the second field: a word-synced download has to come back
    /// word-synced, in all three containers.
    func testWordTimingsSurviveTheWriteAndTheReadInAllThreeContainers() throws {
        let plain = LRCFormat.lrc(from: wordLines)
        let enhanced = LRCFormat.enhancedLRC(from: wordLines)
        for bytes in [
            TestTagger.mp4(lyrics: plain, wordLyrics: enhanced),
            TestTagger.flac(lyrics: plain, wordLyrics: enhanced),
            TestTagger.webm(lyrics: plain, wordLyrics: enhanced),
        ] {
            // The word-timed field wins over the plain one sitting beside it.
            let read = LRCFormat.parse(try XCTUnwrap(EmbeddedLyrics.fromBytes(bytes)))
            XCTAssertEqual(read.count, 1)
            XCTAssertEqual(read[0].text, "two words")
            XCTAssertEqual(read[0].words.map(\.text), ["two", "words"])
            XCTAssertEqual(read[0].words.map(\.startMs), [1_000, 1_400])
            XCTAssertEqual(read[0].endMs, 2_000)
        }
    }

    /// The standard field must stay plain whatever else is written beside it.
    func testThePortableFieldNeverCarriesWordStamps() {
        XCTAssertEqual(LRCFormat.lrc(from: wordLines), "[00:01.00]two words")
    }

    func testAFileWithNoLyricsAtAllReadsBackAsNothing() {
        XCTAssertNil(EmbeddedLyrics.fromBytes(TestTagger.mp4(lyrics: nil)))
    }

    func testSomethingThatIsNoneOfTheThreeContainersIsNotGuessedAt() {
        XCTAssertNil(EmbeddedLyrics.fromBytes(Data((0..<512).map { UInt8($0 & 0xFF) })))
    }

    func testTruncatedAndCorruptContainersReadAsNothingRatherThanCrashing() {
        let full = TestTagger.mp4(lyrics: lrc)
        for length in [0, 7, 12, 40, full.count / 2, full.count - 3] {
            XCTAssertNil(EmbeddedLyrics.fromBytes(full.prefix(length)), "m4a cut to \(length) bytes")
        }
        for whole in [TestTagger.flac(lyrics: lrc), TestTagger.webm(lyrics: lrc)] {
            for length in [whole.count / 2, whole.count - 3] {
                XCTAssertNil(EmbeddedLyrics.fromBytes(whole.prefix(length)), "cut to \(length) of \(whole.count) bytes")
            }
        }
        var lying = [UInt8](TestTagger.flac(lyrics: lrc))
        lying[5] = 0xFF // a block length far past the end of the file
        XCTAssertNil(EmbeddedLyrics.fromBytes(Data(lying)))
    }

    // MARK: Offline packages

    func testAPackagesLyricsComeFromTheSidecarBesideItsPlaylist() throws {
        let root = try packageDirectory(["lyrics.lrc": lrc])
        XCTAssertEqual(EmbeddedLyrics.sidecar(path: root.appendingPathComponent("playlist.m3u8").path), lrc)
    }

    func testWordTimingsSurviveASidecarToo() throws {
        let root = try packageDirectory(["lyrics.lrc": LRCFormat.enhancedLRC(from: wordLines)])
        let read = LRCFormat.parse(try XCTUnwrap(EmbeddedLyrics.sidecar(path: root.appendingPathComponent("playlist.m3u8").path)))
        XCTAssertEqual(read.first?.words.map(\.text), ["two", "words"])
        XCTAssertEqual(read.first?.words.map(\.startMs), [1_000, 1_400])
    }

    func testAPackageWithNoLyricsAndAnOrdinaryFileAreLeftToTheContainerReader() throws {
        XCTAssertNil(EmbeddedLyrics.sidecar(path: try packageDirectory(["lyrics.lrc": "  \n"]).appendingPathComponent("playlist.m3u8").path))
        XCTAssertNil(EmbeddedLyrics.sidecar(path: try packageDirectory([:]).appendingPathComponent("playlist.m3u8").path))
        XCTAssertNil(EmbeddedLyrics.sidecar(path: try packageDirectory(["lyrics.lrc": lrc]).appendingPathComponent("song.flac").path))
        XCTAssertNil(EmbeddedLyrics.sidecar(path: nil))
    }

    func testReadsAFileOnDiskAndSplitsItsBackingVocals() async throws {
        let directory = try packageDirectory([:])
        let file = directory.appendingPathComponent("song.m4a")
        try TestTagger.mp4(lyrics: "[00:01.00]lead words (echo)").write(to: file)
        let lines = await EmbeddedLyrics.lyrics(forFileAt: file)
        XCTAssertEqual(lines?.first?.text, "lead words")
        XCTAssertEqual(lines?.first?.background?.text, "(echo)")
        let missing = await EmbeddedLyrics.lyrics(forFileAt: directory.appendingPathComponent("absent.m4a"))
        XCTAssertNil(missing)
    }

    /// A file longer than the window read for tags: an m4a written without the faststart pass
    /// keeps `moov` after `mdat`, and a Matroska file keeps its tags after the audio.
    func testTagsPastTheFirstEightMiBAreStillFound() throws {
        let directory = try packageDirectory([:])
        let audio = Data(count: EmbeddedLyrics.maxTagBytes + 1024)

        let m4a = directory.appendingPathComponent("song.m4a")
        try moovAfterMdat(TestTagger.mp4(lyrics: lrc), audio: audio).write(to: m4a)
        XCTAssertEqual(EmbeddedLyrics.read(m4a), lrc)

        // The EBML header is the first 9 bytes of the tagger's output.
        let webm = TestTagger.webm(lyrics: lrc)
        let mkv = directory.appendingPathComponent("song.webm")
        try (webm.prefix(9) + audio + webm.dropFirst(9)).write(to: mkv)
        XCTAssertEqual(EmbeddedLyrics.read(mkv), lrc)
    }

    /// The same big file with no lyrics in it is still nothing.
    func testALargeM4AWithNoLyricsStillReadsAsNothing() throws {
        let file = try packageDirectory([:]).appendingPathComponent("plain.m4a")
        try moovAfterMdat(TestTagger.mp4(lyrics: nil), audio: Data(count: EmbeddedLyrics.maxTagBytes + 1024)).write(to: file)
        XCTAssertNil(EmbeddedLyrics.read(file))
    }

    /// `ftyp`, then `audio` in an `mdat`, then `moov` — the tagger's `ftyp` is its first 12 bytes.
    private func moovAfterMdat(_ tagged: Data, audio: Data) -> Data {
        let size = UInt32(8 + audio.count)
        let header = Data([UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
        return tagged.prefix(12) + header + Data("mdat".utf8) + audio + tagged.dropFirst(12)
    }

    private func packageDirectory(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offline-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "#EXTM3U\n#EXT-X-ENDLIST\n".write(to: root.appendingPathComponent("playlist.m3u8"), atomically: true, encoding: .utf8)
        for (name, text) in files {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root
    }
}

/// The byte layouts Android's three download taggers write, just enough to test the reader.
enum TestTagger {

    // MARK: MP4 (Mp4Tagger): moov gains udta/meta/ilst with ©nam ©ART ©lyr ---- covr

    static func mp4(lyrics: String?, wordLyrics: String? = nil, cover: Data? = nil) -> Data {
        var items = [Data]()
        items.append(textItem("©nam", "t"))
        items.append(textItem("©ART", "a"))
        if let lyrics, !lyrics.isEmpty { items.append(textItem("©lyr", lyrics)) }
        if let wordLyrics, !wordLyrics.isEmpty {
            let mean = box("mean", Data(count: 4) + Data("com.fortune.vibramusic.ios".utf8))
            let name = box("name", Data(count: 4) + Data(LRCFormat.wordLyricsField.utf8))
            items.append(box("----", mean + name + dataAtom(1, Data(wordLyrics.utf8))))
        }
        if let cover { items.append(box("covr", dataAtom(13, cover))) }
        var hdlr = Data(count: 25)
        hdlr.replaceSubrange(8..<12, with: Data("mdir".utf8))
        let meta = box("meta", Data(count: 4) + box("hdlr", hdlr) + box("ilst", items.reduce(Data(), +)))
        let udta = box("udta", meta)
        // The tagger appends udta at moov's end and grows moov's size to cover it.
        return box("ftyp", Data("isom".utf8)) + box("moov", udta)
    }

    private static func box(_ type: String, _ payload: Data) -> Data {
        let size = UInt32(8 + payload.count)
        var out = Data([UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
        // ISO-8859-1, so the © of the iTunes item names is the single byte 0xA9.
        out.append(contentsOf: type.unicodeScalars.map { UInt8($0.value & 0xFF) })
        return out + payload
    }

    private static func dataAtom(_ type: UInt32, _ payload: Data) -> Data {
        var body = Data([UInt8(type >> 24 & 0xFF), UInt8(type >> 16 & 0xFF), UInt8(type >> 8 & 0xFF), UInt8(type & 0xFF)])
        body.append(Data(count: 4))
        return box("data", body + payload)
    }

    private static func textItem(_ fourCC: String, _ text: String) -> Data {
        box(fourCC, dataAtom(1, Data(text.utf8)))
    }

    // MARK: FLAC (FlacTagger): STREAMINFO, then a VORBIS_COMMENT as the last block

    static func flac(lyrics: String?, wordLyrics: String? = nil) -> Data {
        var fields = ["TITLE=t", "ARTIST=a"]
        if let lyrics { fields.append("LYRICS=" + lyrics) }
        if let wordLyrics { fields.append(LRCFormat.wordLyricsField + "=" + wordLyrics) }
        var comment = Data()
        func le(_ value: Int) { comment.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]) }
        let vendor = Data("Vibra Music".utf8)
        le(vendor.count)
        comment.append(vendor)
        le(fields.count)
        for field in fields {
            let encoded = Data(field.utf8)
            le(encoded.count)
            comment.append(encoded)
        }
        let streamInfo = Data(count: 34)
        var out = Data("fLaC".utf8)
        out.append(contentsOf: [0x00, 0, 0, UInt8(streamInfo.count)])
        out.append(streamInfo)
        out.append(contentsOf: [0x84, UInt8(comment.count >> 16 & 0xFF), UInt8(comment.count >> 8 & 0xFF), UInt8(comment.count & 0xFF)])
        out.append(comment)
        out.append(0xFF)
        return out
    }

    // MARK: WebM (WebmTagger): Tags/Tag/Targets + SimpleTags appended to the Segment

    static func webm(lyrics: String?, wordLyrics: String? = nil) -> Data {
        var simple = [simpleTag("TITLE", "t"), simpleTag("ARTIST", "a")]
        if let lyrics { simple.append(simpleTag("LYRICS", lyrics)) }
        if let wordLyrics { simple.append(simpleTag(LRCFormat.wordLyricsField, wordLyrics)) }
        let tags = element([0x12, 0x54, 0xC3, 0x67], element([0x73, 0x73], element([0x63, 0xC0], Data()) + simple.reduce(Data(), +)))
        let header = Data([0x1A, 0x45, 0xDF, 0xA3, 0x84, 0, 0, 0, 0])
        let body = Data(count: 8) + tags
        let size = body.count
        let segment = Data([0x18, 0x53, 0x80, 0x67, 0x01, 0, 0, 0, 0, UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]) + body
        return header + segment
    }

    private static func simpleTag(_ name: String, _ value: String) -> Data {
        element([0x67, 0xC8], element([0x45, 0xA3], Data(name.utf8)) + element([0x44, 0x87], Data(value.utf8)))
    }

    private static func element(_ id: [UInt8], _ payload: Data) -> Data {
        Data(id) + vint(payload.count) + payload
    }

    private static func vint(_ value: Int) -> Data {
        var width = 1
        while width < 8 && value > (1 << (7 * width)) - 2 { width += 1 }
        var bytes = [UInt8](repeating: 0, count: width)
        var remaining = value
        for index in stride(from: width - 1, through: 0, by: -1) {
            bytes[index] = UInt8(remaining & 0xFF)
            remaining >>= 8
        }
        bytes[0] |= UInt8(0x80 >> (width - 1))
        return Data(bytes)
    }
}
