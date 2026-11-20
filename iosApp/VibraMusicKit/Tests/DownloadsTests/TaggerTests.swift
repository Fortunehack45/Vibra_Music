import AVFoundation
import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Downloads

// Ports MediaTaggerTest (the MP4 and FLAC halves; WebM isn't saved on iOS) at the byte level, then
// checks the same output the way the app and every other player will actually read it: AVAsset.

/// Stand-in LRC in the shape the lyrics writer emits: two stamped lines and the newline between.
private let lrc = "[00:01.20]first line here\n[00:04.50]second line here"

private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    let size = 8 + payload.count
    return [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
        + Array(type.data(using: .isoLatin1)!) + payload
}

private func u32(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

private func be32(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
}

private func le32(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
}

private func indexOf(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
    guard needle.count <= haystack.count else { return nil }
    for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle { return i }
    return nil
}

/// `ftyp` + `moov(trak/mdia/minf/stbl/stco)` + `mdat`, with `stco`'s one entry pointing at `mdat`'s
/// payload.
private func fakeMp4(mdatPayload: [UInt8], withUdta: [UInt8]? = nil) -> (bytes: [UInt8], mdatPayloadOffset: Int) {
    let ftyp = box("ftyp", [UInt8](repeating: 0, count: 8))
    func moov(stcoOffset: Int) -> [UInt8] {
        let stco = box("stco", [0, 0, 0, 0] + u32(1) + u32(stcoOffset))
        let trak = box("trak", box("mdia", box("minf", box("stbl", stco))))
        return box("moov", trak + (withUdta ?? []))
    }
    // moov's length doesn't depend on the offset value, so a placeholder pass finds where mdat's
    // payload will start.
    let placeholder = moov(stcoOffset: 0)
    let payloadOffset = ftyp.count + placeholder.count + 8
    return (ftyp + moov(stcoOffset: payloadOffset) + box("mdat", mdatPayload), payloadOffset)
}

final class Mp4TaggerTests: XCTestCase {
    func testTaggingPreservesMdatBytesAndRepointsStcoAtTheirNewOffset() throws {
        let payload = (1...24).map(UInt8.init)
        let (original, payloadOffset) = fakeMp4(mdatPayload: payload)
        let cover: [UInt8] = [9, 8, 7, 6, 5]

        let tagged = try XCTUnwrap(Mp4Tagger.tag(Data(original), title: "My Title", artist: "My Artist", album: "My Album",
                                                 lyrics: nil, cover: Data(cover), coverIsPng: false))
        let bytes = [UInt8](tagged)
        let delta = bytes.count - original.count
        XCTAssertGreaterThan(delta, 0, "tagging should grow the file")

        let newOffset = payloadOffset + delta
        XCTAssertEqual(Array(bytes[newOffset..<(newOffset + payload.count)]), payload)
        let stco = try XCTUnwrap(indexOf(bytes, Array("stco".utf8)))
        XCTAssertEqual(be32(bytes, stco + 4 + 4 + 4), newOffset, "past type, version/flags and entry_count")

        XCTAssertNotNil(indexOf(bytes, Array("My Title".utf8)))
        XCTAssertNotNil(indexOf(bytes, Array("My Artist".utf8)))
        XCTAssertNotNil(indexOf(bytes, Array("My Album".utf8)))
        XCTAssertNotNil(indexOf(bytes, cover))
    }

    /// `moov` after `mdat` (a file written without the faststart pass, EmbeddedArtTest's "moov at
    /// end"): the samples sit before the splice, so no offset moves, and the cover is written.
    func testMoovAfterMdatLeavesTheSampleOffsetsAlone() throws {
        let ftyp = box("ftyp", [UInt8](repeating: 0, count: 8))
        let payload = [UInt8](repeating: 0xAB, count: 100)
        let payloadOffset = ftyp.count + 8
        let stco = box("stco", [0, 0, 0, 0] + u32(1) + u32(payloadOffset))
        let file = ftyp + box("mdat", payload) + box("moov", box("trak", box("mdia", box("minf", box("stbl", stco)))))
        let tagged = [UInt8](try XCTUnwrap(Mp4Tagger.tag(Data(file), title: "T", artist: "A", album: nil, lyrics: nil,
                                                          cover: Data([0xFF, 0xD8, 0xFF, 0xE0]), coverIsPng: false)))
        XCTAssertEqual(Array(tagged[payloadOffset..<(payloadOffset + payload.count)]), payload)
        let stcoType = try XCTUnwrap(indexOf(tagged, Array("stco".utf8)))
        XCTAssertEqual(be32(tagged, stcoType + 12), payloadOffset)
        XCTAssertNotNil(indexOf(tagged, Array("covr".utf8)))
    }

    func testNoMoovMeansLeaveTheFileAlone() {
        let bytes = box("ftyp", [UInt8](repeating: 0, count: 8)) + box("mdat", [UInt8](repeating: 0, count: 16))
        XCTAssertNil(Mp4Tagger.tag(Data(bytes), title: "Title", artist: "Artist", album: nil, lyrics: nil, cover: nil, coverIsPng: false))
    }

    func testNothingWorthWritingMeansLeaveTheFileAlone() {
        let (original, _) = fakeMp4(mdatPayload: [0, 0, 0, 0])
        XCTAssertNil(Mp4Tagger.tag(Data(original), title: "", artist: "  ", album: nil, lyrics: nil, cover: nil, coverIsPng: false))
    }

    /// Lyrics on their own have to be enough to trigger a rewrite, or a track with lyrics and nothing
    /// else would silently never get the field.
    func testLyricsAloneGoIntoALyrAtom() throws {
        let (original, _) = fakeMp4(mdatPayload: [0, 0, 0, 0])
        let tagged = try XCTUnwrap(Mp4Tagger.tag(Data(original), title: "", artist: "", album: nil, lyrics: lrc, cover: nil, coverIsPng: false))
        let bytes = [UInt8](tagged)
        // ISO-8859-1, because the atom name leads with the 0xA9 byte ASCII can't encode.
        XCTAssertNotNil(indexOf(bytes, Array("\u{A9}lyr".data(using: .isoLatin1)!)))
        XCTAssertNotNil(indexOf(bytes, Array(lrc.utf8)))
    }

    /// iOS-specific: an existing `udta` is merged, not joined by a second one (AVFoundation reads
    /// only the first), and its items this rewrite doesn't own — the gapless `iTunSMPB` — survive.
    func testAnExistingUdtaIsMergedAndItsOtherItemsKept() throws {
        let smpb = box("----", box("mean", [0, 0, 0, 0] + Array("com.apple.iTunes".utf8))
            + box("name", [0, 0, 0, 0] + Array("iTunSMPB".utf8))
            + box("data", u32(1) + u32(0) + Array(" 00000000 00000840".utf8)))
        let oldTitle = box("\u{A9}nam", box("data", u32(1) + u32(0) + Array("Old Title".utf8)))
        var hdlr = [UInt8](repeating: 0, count: 25)
        hdlr.replaceSubrange(8..<12, with: Array("mdir".utf8))
        let udta = box("udta", box("meta", [0, 0, 0, 0] + box("hdlr", hdlr) + box("ilst", oldTitle + smpb)))
        let payload = (1...32).map(UInt8.init)
        let (original, payloadOffset) = fakeMp4(mdatPayload: payload, withUdta: udta)

        let tagged = try XCTUnwrap(Mp4Tagger.tag(Data(original), title: "New Title", artist: "A", album: nil,
                                                 lyrics: nil, cover: nil, coverIsPng: false, wordLyrics: "<00:01.00>w"))
        let bytes = [UInt8](tagged)
        let moov = try XCTUnwrap(Mp4Tagger.parseBoxes(bytes, 0, bytes.count).first { $0.type == "moov" })
        let children = Mp4Tagger.parseBoxes(bytes, moov.contentOffset, moov.end)
        XCTAssertEqual(children.filter { $0.type == "udta" }.count, 1)
        XCTAssertNil(indexOf(bytes, Array("Old Title".utf8)))
        XCTAssertNotNil(indexOf(bytes, Array("New Title".utf8)))
        XCTAssertNotNil(indexOf(bytes, Array("iTunSMPB".utf8)))
        XCTAssertNotNil(indexOf(bytes, Array(wordLyricsField.utf8)))

        let delta = bytes.count - original.count
        XCTAssertEqual(Array(bytes[(payloadOffset + delta)..<(payloadOffset + delta + payload.count)]), payload)
        let stco = try XCTUnwrap(indexOf(bytes, Array("stco".utf8)))
        XCTAssertEqual(be32(bytes, stco + 12), payloadOffset + delta)
    }

    /// A fragmented file (YouTube's adaptive audio, a flattened package) with an explicit tfhd
    /// base-data-offset: that absolute offset moves with the splice too.
    func testFragmentBaseOffsetsMoveWithTheSplice() throws {
        let (header, _) = fakeMp4(mdatPayload: [])
        let moofStart = header.count - 8 // the empty mdat is dropped below
        let head = Array(header[0..<moofStart])
        let target = moofStart + 200
        // tfhd: version/flags with base-data-offset-present, track_ID, 64-bit base offset.
        let tfhd = box("tfhd", [0, 0, 0, 1] + u32(1) + u32(0) + u32(target))
        let moof = box("moof", box("traf", tfhd))
        let file = head + moof + box("mdat", [UInt8](repeating: 7, count: 300))

        let tagged = try XCTUnwrap(Mp4Tagger.tag(Data(file), title: "T", artist: "A", album: nil, lyrics: nil, cover: nil, coverIsPng: false))
        let bytes = [UInt8](tagged)
        let delta = bytes.count - file.count
        let tfhdAt = try XCTUnwrap(indexOf(bytes, Array("tfhd".utf8)))
        XCTAssertEqual(be32(bytes, tfhdAt + 4 + 4 + 4 + 4), target + delta)
    }
}

private let typeStreamInfo = 0
private let typePadding = 1
private let typeSeekTable = 3
private let typeVorbisComment = 4
private let typePicture = 6
private let flacMagic = Array("fLaC".utf8)

private func flacBlock(_ type: Int, _ payload: [UInt8], last: Bool = false) -> [UInt8] {
    [UInt8(type | (last ? 0x80 : 0)), UInt8(payload.count >> 16 & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)] + payload
}

private func le(_ value: Int) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
}

private func vorbisComment(vendor: String, fields: [String]) -> [UInt8] {
    var out = le(vendor.utf8.count) + Array(vendor.utf8) + le(fields.count)
    for field in fields { out += le(field.utf8.count) + Array(field.utf8) }
    return out
}

/// The metadata chain as (type, payload), and where the audio frames begin. Walks to the last-block
/// flag rather than a known count: a flag left set on a block that is no longer last stops the walk
/// early, which is exactly the bug worth catching.
private func flacChain(_ bytes: [UInt8]) -> (blocks: [(Int, [UInt8])], framesAt: Int) {
    XCTAssertEqual(Array(bytes[0..<4]), flacMagic)
    var blocks: [(Int, [UInt8])] = []
    var offset = 4
    while true {
        let flags = Int(bytes[offset])
        let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        blocks.append((flags & 0x7F, Array(bytes[(offset + 4)..<(offset + 4 + length)])))
        offset += 4 + length
        if flags & 0x80 != 0 { return (blocks, offset) }
    }
}

final class FlacTaggerTests: XCTestCase {
    func testKeepsTheFramesCarriesOtherBlocksAndSpendsThePadding() throws {
        let streamInfo = (0..<34).map(UInt8.init)
        let seekTable = (0..<18).map { UInt8($0 + 100) }
        let frames = (1...64).map(UInt8.init)
        let original = flacMagic + flacBlock(typeStreamInfo, streamInfo) + flacBlock(typeSeekTable, seekTable)
            + flacBlock(typePadding, [UInt8](repeating: 0, count: 200), last: true) + frames
        let cover: [UInt8] = [9, 8, 7, 6, 5]

        let tagged = [UInt8](try XCTUnwrap(FlacTagger.tag(Data(original), title: "My Title", artist: "My Artist",
                                                          album: "My Album", lyrics: nil, cover: Data(cover), coverMime: "image/jpeg")))
        let (blocks, framesAt) = flacChain(tagged)
        XCTAssertEqual(blocks.map(\.0), [typeStreamInfo, typeSeekTable, typeVorbisComment, typePicture])
        XCTAssertEqual(blocks[0].1, streamInfo)
        XCTAssertEqual(blocks[1].1, seekTable)
        XCTAssertEqual(Array(tagged[framesAt...]), frames)

        // Little-endian lengths, and no framing bit after the last field.
        let comment = blocks[2].1
        let vendorLength = le32(comment, 0)
        XCTAssertEqual(String(decoding: comment[4..<(4 + vendorLength)], as: UTF8.self), "Vibra Music")
        var at = 4 + vendorLength
        let count = le32(comment, at)
        at += 4
        XCTAssertEqual(count, 3)
        var fields: [String] = []
        for _ in 0..<count {
            let length = le32(comment, at)
            at += 4
            fields.append(String(decoding: comment[at..<(at + length)], as: UTF8.self))
            at += length
        }
        XCTAssertEqual(fields, ["TITLE=My Title", "ARTIST=My Artist", "ALBUM=My Album"])
        XCTAssertEqual(comment.count, at)

        // The picture block is big-endian, unlike the one above it.
        let picture = blocks[3].1
        XCTAssertEqual(be32(picture, 0), 3, "front cover")
        let mimeLength = be32(picture, 4)
        XCTAssertEqual(String(decoding: picture[8..<(8 + mimeLength)], as: UTF8.self), "image/jpeg")
        var p = 8 + mimeLength
        for _ in 0..<5 {
            XCTAssertEqual(be32(picture, p), 0)
            p += 4
        }
        XCTAssertEqual(be32(picture, p), cover.count)
        XCTAssertEqual(Array(picture[(p + 4)...]), cover)
    }

    func testReplacesAnExistingCommentRatherThanAddingASecond() throws {
        let stale = vorbisComment(vendor: "Somebody Else", fields: ["TITLE=Old Title", "COMMENT=stale"])
        let frames = [UInt8](repeating: 7, count: 16)
        let original = flacMagic + flacBlock(typeStreamInfo, [UInt8](repeating: 0, count: 34))
            + flacBlock(typeVorbisComment, stale, last: true) + frames

        let tagged = [UInt8](try XCTUnwrap(FlacTagger.tag(Data(original), title: "New Title", artist: "New Artist",
                                                          album: nil, lyrics: nil, cover: nil, coverMime: "image/jpeg")))
        let (blocks, framesAt) = flacChain(tagged)
        XCTAssertEqual(blocks.filter { $0.0 == typeVorbisComment }.count, 1)
        XCTAssertEqual(Array(tagged[framesAt...]), frames)
        XCTAssertNotNil(indexOf(tagged, Array("TITLE=New Title".utf8)))
        XCTAssertNil(indexOf(tagged, Array("Old Title".utf8)))
        XCTAssertNil(indexOf(tagged, Array("stale".utf8)))
    }

    /// The streaming rewrite (header + a copy of the frames) must produce the same file as the
    /// in-memory one: two implementations of one output, pinned together.
    func testHeaderPlusAStreamCopyOfTheFramesIsTheWholeTaggedFile() throws {
        let streamInfo = (0..<34).map(UInt8.init)
        let seekTable = (0..<18).map { UInt8($0 + 100) }
        let frames = (0..<4096).map { UInt8(truncatingIfNeeded: $0 * 31) }
        let original = flacMagic + flacBlock(typeStreamInfo, streamInfo) + flacBlock(typeSeekTable, seekTable)
            + flacBlock(typePadding, [UInt8](repeating: 0, count: 200), last: true) + frames
        let cover = Data((0..<512).map { UInt8(truncatingIfNeeded: $0 + 3) })

        let whole = try XCTUnwrap(FlacTagger.tag(Data(original), title: "T", artist: "A", album: "Alb", lyrics: lrc, cover: cover, coverMime: "image/jpeg"))
        let rewrite = try XCTUnwrap(FlacTagger.header(Data(original), title: "T", artist: "A", album: "Alb", lyrics: lrc, cover: cover, coverMime: "image/jpeg"))
        XCTAssertEqual(rewrite.metadata + Data(original[rewrite.audioStart...]), whole)
        XCTAssertEqual(Array(original[rewrite.audioStart...]), frames, "the offset is where the frames begin")
    }

    /// Nil means "leave the file alone"; a prefix cut short of the chain must read as incomplete, not
    /// as a file with no metadata.
    func testHeaderRefusesAChainThatRunsPastTheBytesItWasGiven() {
        let original = flacMagic + flacBlock(typeStreamInfo, [UInt8](repeating: 0, count: 34))
            + flacBlock(typeSeekTable, [UInt8](repeating: 0, count: 4_000), last: true) + [UInt8](repeating: 7, count: 64)
        XCTAssertNil(FlacTagger.header(Data(original[0..<100]), title: "T", artist: "A", album: nil, lyrics: nil, cover: nil, coverMime: "image/jpeg"))
        XCTAssertNotNil(FlacTagger.header(Data(original), title: "T", artist: "A", album: nil, lyrics: nil, cover: nil, coverMime: "image/jpeg"))
    }

    func testNoMagicMeansLeaveTheFileAlone() {
        XCTAssertNil(FlacTagger.tag(Data((0..<64).map(UInt8.init)), title: "Title", artist: "Artist", album: nil, lyrics: nil, cover: nil, coverMime: "image/jpeg"))
    }

    func testABlockClaimingMoreBytesThanTheFileHasMeansLeaveItAlone() {
        let original = flacMagic + [UInt8(typeStreamInfo), 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 34)
        XCTAssertNil(FlacTagger.tag(Data(original), title: "Title", artist: "Artist", album: nil, lyrics: nil, cover: nil, coverMime: "image/jpeg"))
    }

    func testNothingToWriteMeansLeaveTheFileAlone() {
        let original = flacMagic + flacBlock(typeStreamInfo, [UInt8](repeating: 0, count: 34), last: true) + [UInt8](repeating: 0, count: 16)
        XCTAssertNil(FlacTagger.tag(Data(original), title: "   ", artist: "", album: nil, lyrics: nil, cover: nil, coverMime: "image/jpeg"))
    }

    /// Lyrics alone produce a VORBIS_COMMENT, and the field survives its own newlines (it is
    /// length-prefixed, so a truncation at the first line break would be the bug).
    func testMultiLineLyricsAloneGoIntoALyricsField() throws {
        let frames = [UInt8](repeating: 7, count: 16)
        let original = flacMagic + flacBlock(typeStreamInfo, [UInt8](repeating: 0, count: 34), last: true) + frames
        let tagged = [UInt8](try XCTUnwrap(FlacTagger.tag(Data(original), title: "", artist: "", album: nil, lyrics: lrc, cover: nil, coverMime: "image/jpeg")))
        let (blocks, framesAt) = flacChain(tagged)
        XCTAssertEqual(blocks.map(\.0), [typeStreamInfo, typeVorbisComment])
        XCTAssertEqual(Array(tagged[framesAt...]), frames)
        XCTAssertNotNil(indexOf(tagged, Array("LYRICS=\(lrc)".utf8)))
    }
}

/// The tagged files as AVFoundation reads them — what the player, the lock screen and a Files
/// import see. Also covers EmbeddedArtTest's MP4 `covr` and FLAC `PICTURE` cases for the files the
/// taggers write.
final class TagRoundTripTests: XCTestCase {
    private func tag(_ url: URL, ext: String, cover: DownloadArtwork?, lyrics: DownloadLyrics?) async throws -> EmbeddedTags {
        let store = DownloadStore(root: url.deletingLastPathComponent())
        let tagger = MediaTagger(store: store, http: URLProtocolStub().makeSession())
        let track = Song(videoId: "abc", title: "My Title", artist: "My Artist", albumName: "My Album")
        let rewritten = await tagger.embed(file: url, track: track, extension: ext, lyrics: lyrics, artwork: cover)
        XCTAssertTrue(rewritten)
        return await EmbeddedTags.read(from: url)
    }

    func testM4aTitleArtistAlbumArtworkAndLyricsReadBackThroughAVAsset() async throws {
        let dir = try makeTemporaryDirectory()
        let file = try TestAudio.m4a(at: dir.appending(path: "t.m4a"))
        let before = await EmbeddedTags.read(from: file)
        let jpeg = TestImages.image(width: 40, height: 30, type: .jpeg)

        let tags = try await tag(file, ext: "m4a", cover: DownloadArtwork(data: jpeg, mime: "image/jpeg"),
                                 lyrics: DownloadLyrics(plain: lrc, enhanced: "[00:01.20]<00:01.20>first <00:01.60>line"))
        XCTAssertEqual(tags.title, "My Title")
        XCTAssertEqual(tags.artist, "My Artist")
        XCTAssertEqual(tags.album, "My Album")
        XCTAssertEqual(tags.lyrics, lrc)
        XCTAssertEqual(tags.wordLyrics, "[00:01.20]<00:01.20>first <00:01.60>line")
        XCTAssertEqual(tags.artwork, jpeg)
        XCTAssertEqual(tags.artworkMime, "image/jpeg")
        XCTAssertTrue(tags.isPlayable)
        XCTAssertEqual(try XCTUnwrap(tags.durationSeconds), try XCTUnwrap(before.durationSeconds), accuracy: 0.01,
                       "the samples still play in full after the stco shift")
    }

    func testM4aPngCoverIsDeclaredAsPng() async throws {
        let dir = try makeTemporaryDirectory()
        let file = try TestAudio.m4a(at: dir.appending(path: "t.m4a"))
        let png = TestImages.image(width: 8, height: 8, type: .png)
        let tags = try await tag(file, ext: "m4a", cover: DownloadArtwork(data: png, mime: "image/png"), lyrics: nil)
        XCTAssertEqual(tags.artwork, png)
        XCTAssertEqual(tags.artworkMime, "image/png")
    }

    func testFlacTitleArtistAlbumArtworkAndLyricsReadBackThroughAVAsset() async throws {
        let dir = try makeTemporaryDirectory()
        let file = try TestAudio.flac(at: dir.appending(path: "t.flac"))
        let before = await EmbeddedTags.read(from: file)
        let png = TestImages.image(width: 16, height: 16, type: .png)

        let tags = try await tag(file, ext: "flac", cover: DownloadArtwork(data: png, mime: "image/png"),
                                 lyrics: DownloadLyrics(plain: lrc, enhanced: "<words>"))
        XCTAssertEqual(tags.title, "My Title")
        XCTAssertEqual(tags.artist, "My Artist")
        XCTAssertEqual(tags.album, "My Album")
        XCTAssertEqual(tags.lyrics, lrc)
        XCTAssertEqual(tags.wordLyrics, "<words>")
        XCTAssertEqual(tags.artwork, png)
        XCTAssertEqual(tags.artworkMime, "image/png")
        XCTAssertTrue(tags.isPlayable)
        XCTAssertEqual(try XCTUnwrap(tags.durationSeconds), try XCTUnwrap(before.durationSeconds), accuracy: 0.01)
    }

    /// A file with no cover reads back as none, rather than as some other item's bytes.
    func testFilesWithoutACoverReadBackWithoutOne() async throws {
        let dir = try makeTemporaryDirectory()
        let m4a = try TestAudio.m4a(at: dir.appending(path: "t.m4a"))
        let flac = try TestAudio.flac(at: dir.appending(path: "t.flac"))
        let m4aTags = try await tag(m4a, ext: "m4a", cover: nil, lyrics: nil)
        let flacTags = try await tag(flac, ext: "flac", cover: nil, lyrics: nil)
        XCTAssertNil(m4aTags.artwork)
        XCTAssertNil(flacTags.artwork)
        XCTAssertEqual(m4aTags.title, "My Title")
        XCTAssertEqual(flacTags.title, "My Title")
    }

    /// Re-tagging a tagged file replaces the fields rather than stacking a second set.
    func testTaggingTwiceReplacesRatherThanStacks() async throws {
        let dir = try makeTemporaryDirectory()
        let file = try TestAudio.m4a(at: dir.appending(path: "t.m4a"))
        _ = try await tag(file, ext: "m4a", cover: DownloadArtwork(data: TestImages.image(width: 4, height: 4, type: .jpeg), mime: "image/jpeg"), lyrics: DownloadLyrics(plain: "[00:01.00]old"))
        let tags = try await tag(file, ext: "m4a", cover: nil, lyrics: DownloadLyrics(plain: lrc))
        XCTAssertEqual(tags.lyrics, lrc)
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: "[00:01.00]old"))
        XCTAssertNil(tags.artwork, "the second pass wrote no cover, and the old covr is one this rewrite owns")
    }

    func testWavCarriesNoTagsAndIsLeftAlone() async throws {
        let dir = try makeTemporaryDirectory()
        let file = try TestAudio.wav(at: dir.appending(path: "t.wav"))
        let before = try Data(contentsOf: file)
        let tagger = MediaTagger(store: DownloadStore(root: dir), http: URLProtocolStub().makeSession())
        let rewritten = await tagger.embed(file: file, track: song("a"), extension: "wav", lyrics: DownloadLyrics(plain: lrc), artwork: nil)
        XCTAssertFalse(rewritten)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(MediaTagger.carriesTags("wav"))
        XCTAssertTrue(MediaTagger.carriesTags("m4a"))
        XCTAssertTrue(MediaTagger.carriesTags("FLAC"))
    }
}

/// Cover handling: fetched at 1200 px, scaled to 1000 on the long side, saved as JPEG beside the audio.
final class DownloadArtworkTests: XCTestCase {
    func testLargeCoversAreScaledToTheLongSideAndReencodedAsJpeg() throws {
        let big = TestImages.image(width: 1600, height: 1200, type: .png)
        let jpeg = try XCTUnwrap(MediaTagger.normalizedCover(big))
        XCTAssertEqual(ImageKind.sniff(jpeg), .jpeg)
        XCTAssertEqual(TestImages.size(of: jpeg), CGSize(width: 1000, height: 750))
    }

    func testSmallCoversAreNeverScaledUp() throws {
        let small = TestImages.image(width: 300, height: 300, type: .png)
        let jpeg = try XCTUnwrap(MediaTagger.normalizedCover(small))
        XCTAssertEqual(TestImages.size(of: jpeg), CGSize(width: 300, height: 300))
    }

    func testBytesThatArentAnImageGiveNoCover() {
        XCTAssertNil(MediaTagger.normalizedCover(Data("hello world!".utf8)))
    }

    func testMimeIsSniffedFromTheBytes() {
        XCTAssertEqual(ImageKind.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2])), .jpeg)
        XCTAssertEqual(ImageKind.sniff(Data([0x89, 0x50, 0x4E, 0x47, 5, 6])), .png)
        XCTAssertNil(ImageKind.sniff(Data()))
        XCTAssertNil(ImageKind.sniff(Data("hello".utf8)))
    }

    func testCoversAreFetchedAt1200AndSavedAsASidecarSharedByTheAlbum() async throws {
        let dir = try makeTemporaryDirectory()
        let stub = URLProtocolStub()
        stub.register(host: "lh3.googleusercontent.com") { request in
            XCTAssertTrue(request.url!.absoluteString.contains("w1200-h1200"))
            return .data(TestImages.image(width: 1200, height: 1200, type: .jpeg), headers: ["Content-Type": "image/jpeg"])
        }
        let store = DownloadStore(root: dir)
        let tagger = MediaTagger(store: store, http: stub.makeSession())
        let cover = "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj"
        let first = try await XCTUnwrapAsync(await tagger.artwork(for: song("a", thumbnail: cover)))
        XCTAssertEqual(TestImages.size(of: first.data), CGSize(width: 1000, height: 1000))
        let path = try XCTUnwrap(tagger.persistArtwork(sourceUrl: cover, artwork: first))
        XCTAssertTrue(store.exists(relativePath: path))

        // The next track off the same album reads the sidecar instead of the network.
        _ = try await XCTUnwrapAsync(await tagger.artwork(for: song("b", thumbnail: cover)))
        XCTAssertEqual(stub.requests.count, 1)
        let none = await tagger.artwork(for: song("c"))
        XCTAssertNil(none, "no URL, no cover")
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
