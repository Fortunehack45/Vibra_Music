import XCTest
@testable import NetworkLibrary

/// Ports EmbeddedArtTest.kt: every tag walk against in-memory readers.
final class EmbeddedArtTests: XCTestCase {
    private struct MemReader: EmbeddedArt.Reader {
        var bytes: Data
        var size: Int64 { Int64(bytes.count) }
        func read(offset: Int64, length: Int) -> Data {
            guard length > 0, offset >= 0, offset < Int64(bytes.count) else { return Data() }
            let end = min(Int(offset) + length, bytes.count)
            return bytes[Int(offset)..<end]
        }
        func close() {}
    }

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 5, 6, 7, 8])

    private func u32be(_ value: Int) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }

    private func syncsafe(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F),
        ])
    }

    private func box(_ type: String, _ payloads: Data...) -> Data {
        let body = payloads.reduce(Data(), +)
        return u32be(8 + body.count) + Data(type.utf8) + body
    }

    // MARK: - ID3v2

    private func id3File(version: UInt8, frames: [Data], unsync: Bool = false) -> Data {
        let tag = frames.reduce(Data(), +)
        let flags: UInt8 = unsync ? 0x80 : 0x00
        return Data("ID3".utf8) + Data([version, 0, flags]) + syncsafe(tag.count) + tag
    }

    private func apicFrame(payload: Data, v24: Bool) -> Data {
        let size = v24 ? syncsafe(payload.count) : u32be(payload.count)
        return Data("APIC".utf8) + size + Data([0, 0]) + payload
    }

    private func apicPayload(mime: String, art: Data) -> Data {
        Data([0]) + Data("\(mime)\0".utf8) + Data([3]) + Data("d\0".utf8) + art
    }

    func testId3v23ApicExtracts() {
        let file = id3File(version: 3, frames: [apicFrame(payload: apicPayload(mime: "image/jpeg", art: jpeg), v24: false)]) + Data(repeating: 0, count: 100)
        let picture = EmbeddedArt.extract(MemReader(bytes: file))
        XCTAssertEqual(picture?.mime, "image/jpeg")
        XCTAssertEqual(picture?.bytes, jpeg)
    }

    func testId3v24ApicExtracts() {
        let file = id3File(version: 4, frames: [apicFrame(payload: apicPayload(mime: "image/png", art: png), v24: true)]) + Data(repeating: 0, count: 100)
        let picture = EmbeddedArt.extract(MemReader(bytes: file))
        XCTAssertEqual(picture?.mime, "image/png")
        XCTAssertEqual(picture?.bytes, png)
    }

    func testId3v22PicExtracts() {
        let payload = Data([0]) + Data("JPG".utf8) + Data([0, 0]) + jpeg
        let frame = Data("PIC".utf8) + Data([0, 0, UInt8(payload.count)]) + payload
        let file = id3File(version: 2, frames: [frame]) + Data(repeating: 0, count: 100)
        let picture = EmbeddedArt.extract(MemReader(bytes: file))
        XCTAssertEqual(picture?.mime, "image/jpeg")
        XCTAssertEqual(picture?.bytes, jpeg)
    }

    func testId3v23ExtendedHeaderStillExtracts() {
        // v2.3's extended size (6) excludes its own four bytes; the zero padding field sits where
        // a self-counting size would put the frames.
        let extended = u32be(6) + Data([0, 0]) + u32be(0)
        let tag = extended + apicFrame(payload: apicPayload(mime: "image/jpeg", art: jpeg), v24: false)
        let file = Data("ID3".utf8) + Data([3, 0, 0x40]) + syncsafe(tag.count) + tag + Data(repeating: 0, count: 100)
        XCTAssertEqual(EmbeddedArt.extract(MemReader(bytes: file))?.bytes, jpeg)
    }

    func testId3UnsynchronisedPayloadStillExtracts() {
        // As stored (with the stuffing byte) and as decoded (without it).
        let stored = Data([0xFF, 0xD8, 0xFF, 0x00, 0xE0, 9])
        let decoded = Data([0xFF, 0xD8, 0xFF, 0xE0, 9])
        let file = id3File(version: 3, frames: [apicFrame(payload: apicPayload(mime: "image/jpeg", art: stored), v24: false)], unsync: true)
            + Data(repeating: 0, count: 100)
        XCTAssertEqual(EmbeddedArt.extract(MemReader(bytes: file))?.bytes, decoded)
    }

    func testId3WithoutPictureReturnsNil() {
        let frame = Data("TIT2".utf8) + u32be(5) + Data([0, 0]) + Data([0]) + Data("hi\0".utf8)
        let file = id3File(version: 3, frames: [frame]) + Data(repeating: 0, count: 100)
        XCTAssertNil(EmbeddedArt.extract(MemReader(bytes: file)))
    }

    // MARK: - FLAC

    private func flacBlock(type: UInt8, payload: Data, last: Bool) -> Data {
        let head: UInt8 = (last ? 0x80 : 0) | type
        let length = payload.count
        return Data([head, UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]) + payload
    }

    private func flacPicturePayload(mime: String, art: Data) -> Data {
        u32be(3) + u32be(mime.count) + Data(mime.utf8) + u32be(0) + Data(repeating: 0, count: 16) + u32be(art.count) + art
    }

    func testFlacPictureExtracts() {
        let file = Data("fLaC".utf8)
            + flacBlock(type: 0, payload: Data(repeating: 0, count: 34), last: false)
            + flacBlock(type: 6, payload: flacPicturePayload(mime: "image/png", art: png), last: true)
            + Data(repeating: 0, count: 64)
        let picture = EmbeddedArt.extract(MemReader(bytes: file))
        XCTAssertEqual(picture?.mime, "image/png")
        XCTAssertEqual(picture?.bytes, png)
    }

    func testFlacWithoutPictureReturnsNil() {
        let file = Data("fLaC".utf8) + flacBlock(type: 0, payload: Data(repeating: 0, count: 34), last: true) + Data(repeating: 0, count: 64)
        XCTAssertNil(EmbeddedArt.extract(MemReader(bytes: file)))
    }

    func testFlacAbsurdPictureSizeReturnsNilWithoutAllocating() {
        let evil = u32be(3) + u32be(3) + Data("jpg".utf8) + u32be(0) + Data(repeating: 0, count: 16)
            + u32be(Int.max) + Data([1, 2, 3])
        let file = Data("fLaC".utf8) + flacBlock(type: 6, payload: evil, last: true)
        XCTAssertNil(EmbeddedArt.extract(MemReader(bytes: file)))
    }

    // MARK: - MP4

    func testMp4CovrExtracts() {
        let data = u32be(13) + u32be(0) + jpeg
        let covr = box("covr", box("data", data))
        let ilst = box("ilst", covr)
        let meta = box("meta", Data([0, 0, 0, 0]) + ilst)
        let moov = box("moov", box("udta", meta))
        let file = box("ftyp", Data("isom".utf8) + u32be(0) + Data("isom".utf8)) + moov + Data(repeating: 0, count: 64)
        let picture = EmbeddedArt.extract(MemReader(bytes: file))
        XCTAssertEqual(picture?.mime, "image/jpeg")
        XCTAssertEqual(picture?.bytes, jpeg)
    }

    func testMp4MoovAtEndExtracts() {
        let data = u32be(14) + u32be(0) + png
        let moov = box("moov", box("udta", box("meta", Data([0, 0, 0, 0]) + box("ilst", box("covr", box("data", data))))))
        let file = box("ftyp", Data("isom".utf8)) + box("mdat", Data(repeating: 0, count: 5000)) + moov
        let picture = EmbeddedArt.extract(MemReader(bytes: file))
        XCTAssertEqual(picture?.mime, "image/png")
        XCTAssertEqual(picture?.bytes, png)
    }

    func testMp4WithoutCovrReturnsNil() {
        let file = box("ftyp", Data("isom".utf8)) + box("moov", box("mvhd", Data(repeating: 0, count: 16)))
        XCTAssertNil(EmbeddedArt.extract(MemReader(bytes: file)))
    }

    // MARK: - Ogg

    private func oggPage(body: Data, serial: Int = 1, sequence: Int = 0, continued: Bool = false) -> Data {
        var segments: [UInt8] = []
        var rest = body.count
        while rest >= 255 {
            segments.append(255)
            rest -= 255
        }
        segments.append(UInt8(rest))
        let type: UInt8 = continued ? 0x01 : 0x00
        var head = Data("OggS".utf8) + Data([0, type]) + Data(repeating: 0, count: 8)
            + u32be(serial) + u32be(sequence) + u32be(0) + Data([UInt8(segments.count)])
        head += Data(segments)
        return head + body
    }

    private func u32le(_ value: Int) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }

    private func vorbisCommentPacket(opus: Bool, artB64: String) -> Data {
        let field = Data("METADATA_BLOCK_PICTURE=\(artB64)".utf8)
        let vendor = Data("X".utf8)
        var packet = opus ? Data("OpusTags".utf8) : Data([3]) + Data("vorbis".utf8)
        packet += u32le(vendor.count) + vendor + u32le(1) + u32le(field.count) + field
        return packet
    }

    private func oggFile(opus: Bool, artB64: String?) -> Data {
        let ident: Data = opus
            ? Data("OpusHead".utf8) + Data(repeating: 0, count: 11)
            : Data([1]) + Data("vorbis".utf8) + Data(repeating: 0, count: 23)
        var out = oggPage(body: ident, sequence: 0)
        if let artB64 {
            out += oggPage(body: vorbisCommentPacket(opus: opus, artB64: artB64), sequence: 1)
        }
        return out + oggPage(body: Data(repeating: 0, count: 100), sequence: 2)
    }

    private func b64FlacPicture(mime: String, art: Data) -> String {
        flacPicturePayload(mime: mime, art: art).base64EncodedString()
    }

    func testVorbisCommentPictureExtracts() {
        let file = oggFile(opus: false, artB64: b64FlacPicture(mime: "image/jpeg", art: jpeg))
        let picture = EmbeddedArt.extract(MemReader(bytes: file))
        XCTAssertEqual(picture?.mime, "image/jpeg")
        XCTAssertEqual(picture?.bytes, jpeg)
    }

    func testOpusTagsPictureExtracts() {
        let file = oggFile(opus: true, artB64: b64FlacPicture(mime: "image/png", art: png))
        let picture = EmbeddedArt.extract(MemReader(bytes: file))
        XCTAssertEqual(picture?.mime, "image/png")
        XCTAssertEqual(picture?.bytes, png)
    }

    func testOggWithoutPictureReturnsNil() {
        XCTAssertNil(EmbeddedArt.extract(MemReader(bytes: oggFile(opus: false, artB64: nil))))
    }

    // MARK: - Negatives

    func testGarbageAndEmptiesReturnNil() {
        XCTAssertNil(EmbeddedArt.extract(MemReader(bytes: Data())))
        XCTAssertNil(EmbeddedArt.extract(MemReader(bytes: Data(repeating: 0, count: 11))))
        XCTAssertNil(EmbeddedArt.extract(MemReader(bytes: Data("hello world!".utf8))))
    }

    func testMimeFallsBackToSniffedBytes() {
        // APIC with a blank mime still resolves through the JPEG magic.
        let payload = Data([0]) + Data("\0".utf8) + Data([3]) + Data("d\0".utf8) + jpeg
        let file = id3File(version: 3, frames: [apicFrame(payload: payload, v24: false)]) + Data(repeating: 0, count: 64)
        XCTAssertEqual(EmbeddedArt.extract(MemReader(bytes: file))?.mime, "image/jpeg")
    }
}
