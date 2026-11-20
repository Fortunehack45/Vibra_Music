import Foundation

// Ports download/FlacTagger.kt.

/// Rewrites a FLAC's metadata blocks to carry title, artist, album, lyrics and cover art.
///
/// The simplest of the taggers, and the reason is worth stating. A FLAC is `fLaC`, then a chain of
/// length-prefixed metadata blocks, then the audio frames — and nothing in the format addresses
/// anything by an absolute file offset. `SEEKTABLE` *looks* like the exception, but its offsets are
/// measured from the first frame header rather than from the start of the file, so growing the
/// metadata region moves the frames without invalidating a single number in it. The whole job is to
/// emit a new block chain and copy the frames through untouched.
///
/// What comes out is the magic, `STREAMINFO`, every other block the file already had, then a fresh
/// `VORBIS_COMMENT` and `PICTURE`. The old copies of those two are dropped rather than added to — a
/// second `VORBIS_COMMENT` is illegal, and two front covers is a coin toss over which one a player
/// shows. `PADDING` is dropped as well, which is what it is there for.
///
/// AVFoundation reads the result: `vorb/TITLE`, `vorb/ARTIST`, `vorb/ALBUM`, `vorb/LYRICS`,
/// `vorb/VIBRAMUSIC_LYRICS`, and the `PICTURE` block as `vorb/METADATA_BLOCK_PICTURE` artwork
/// (verified on macOS 27).
///
/// Anything that doesn't fit the shape above — no `fLaC`, a block that claims more bytes than the
/// file has, a first block that isn't `STREAMINFO` — returns nil, so the downloaded file is left
/// alone.
public enum FlacTagger {
    /// The finished metadata region to put in front of this file's frames, and where those frames
    /// begin in the original.
    ///
    /// Separate from ``tag(_:title:artist:album:lyrics:cover:coverMime:wordLyrics:)`` because
    /// everything a FLAC rewrite has to *think* about lives in the first few hundred kilobytes, and
    /// everything after that is a byte-for-byte copy — which ``MediaTagger`` streams rather than
    /// holding three copies of a 40 MB track in memory.
    public struct Rewrite: Sendable {
        public let metadata: Data
        public let audioStart: Int
    }

    public static func tag(
        _ data: Data,
        title: String,
        artist: String,
        album: String?,
        lyrics: String?,
        cover: Data?,
        coverMime: String,
        wordLyrics: String? = nil
    ) -> Data? {
        guard let done = header(data, title: title, artist: artist, album: album, lyrics: lyrics,
                                cover: cover, coverMime: coverMime, wordLyrics: wordLyrics) else { return nil }
        var out = done.metadata
        // The frames, verbatim.
        out.append(data.subdata(in: (data.startIndex + done.audioStart)..<data.endIndex))
        return out
    }

    /// - Parameter head: the start of the file. It only has to be long enough to contain the whole
    ///   metadata block chain; nil comes back if it isn't, so a caller that guessed a prefix too
    ///   short can tell that apart from a file this doesn't recognise only by trying again with more.
    /// - Returns: nil when there is nothing to write, or nothing here recognises the shape — in both
    ///   cases the file is to be left exactly as it is.
    public static func header(
        _ head: Data,
        title: String,
        artist: String,
        album: String?,
        lyrics: String?,
        cover: Data?,
        coverMime: String,
        wordLyrics: String? = nil
    ) -> Rewrite? {
        let bytes = [UInt8](head)
        guard bytes.count >= magic.count, Array(bytes[0..<magic.count]) == magic else { return nil }

        // The block chain. Each header is one byte of flags — bit 7 marks the last block, bits 0-6
        // are the type — and three big-endian bytes of payload length.
        var blocks: [(type: Int, start: Int, length: Int)] = []
        var offset = magic.count
        while true {
            guard offset + blockHeader <= bytes.count else { return nil }
            let flags = Int(bytes[offset])
            let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let start = offset + blockHeader
            guard start + length <= bytes.count else { return nil }
            blocks.append((flags & 0x7F, start, length))
            offset = start + length
            if flags & 0x80 != 0 { break }
        }
        // Required to be first by the format itself; a file that doesn't have it there is not one
        // to guess at.
        guard blocks.first?.type == typeStreamInfo else { return nil }

        var additions: [(Int, [UInt8])] = []
        if let comment = vorbisComment(title: title, artist: artist, album: album, lyrics: lyrics, wordLyrics: wordLyrics) {
            additions.append((typeVorbisComment, comment))
        }
        if let cover, !cover.isEmpty {
            additions.append((typePicture, picture([UInt8](cover), mime: coverMime)))
        }
        // A payload past what three bytes of length can describe costs that one block and nothing
        // else. Only a cover could realistically reach 16 MB, and losing the cover is a better
        // outcome than losing the tags.
        additions = additions.filter { $0.1.count <= maxBlockBytes }
        guard !additions.isEmpty else { return nil }

        let chain: [(Int, [UInt8])] = blocks
            .filter { !replaced.contains($0.type) }
            .map { ($0.type, Array(bytes[$0.start..<($0.start + $0.length)])) } + additions

        var out = magic
        out.reserveCapacity(offset + additions.reduce(0) { $0 + $1.1.count } + 64)
        for (index, block) in chain.enumerated() {
            let (type, payload) = block
            out.append(UInt8(index == chain.count - 1 ? type | 0x80 : type))
            out.append(UInt8((payload.count >> 16) & 0xFF))
            out.append(UInt8((payload.count >> 8) & 0xFF))
            out.append(UInt8(payload.count & 0xFF))
            out += payload
        }
        // `offset` is one past the last metadata block, which is where the frames start.
        return Rewrite(metadata: Data(out), audioStart: offset)
    }

    /// A `VORBIS_COMMENT` payload, or nil when there is nothing to say.
    ///
    /// Every length in here is **little-endian**, the one surprise in an otherwise big-endian format:
    /// the block reuses Ogg Vorbis' comment layout wholesale. It does *not* reuse the trailing
    /// framing bit — that belongs to the Vorbis packet, and writing one appends a stray byte strict
    /// parsers reject.
    ///
    /// `lyrics` goes in as `LYRICS`, where every reader that shows lyrics for a FLAC looks. A field
    /// is a length-prefixed run of UTF-8, so length and newlines don't matter.
    private static func vorbisComment(title: String, artist: String, album: String?, lyrics: String?, wordLyrics: String?) -> [UInt8]? {
        var fields: [String] = []
        if !title.isBlank { fields.append("TITLE=\(title)") }
        if !artist.isBlank { fields.append("ARTIST=\(artist)") }
        if let album, !album.isBlank { fields.append("ALBUM=\(album)") }
        if let lyrics, !lyrics.isBlank { fields.append("LYRICS=\(lyrics)") }
        // Beside `LYRICS`, never instead of it: an unknown name is skipped by every reader.
        if let wordLyrics, !wordLyrics.isBlank { fields.append("\(wordLyricsField)=\(wordLyrics)") }
        guard !fields.isEmpty else { return nil }

        var out: [UInt8] = []
        let vendorBytes = Array(vendor.utf8)
        out += le32(vendorBytes.count)
        out += vendorBytes
        out += le32(fields.count)
        for field in fields {
            let encoded = Array(field.utf8)
            out += le32(encoded.count)
            out += encoded
        }
        return out
    }

    /// A `PICTURE` payload holding `cover` as the front cover.
    ///
    /// Big-endian throughout, unlike the comment block. Dimensions and colour fields are zero, which
    /// the format defines as "unstated" — every player that draws the image decodes it anyway.
    private static func picture(_ cover: [UInt8], mime: String) -> [UInt8] {
        let mimeBytes = Array(mime.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(cover.count + 64)
        out += be32(pictureFrontCover)
        out += be32(mimeBytes.count)
        out += mimeBytes
        out += be32(0) // description length; the picture type already says it
        out += be32(0) // width
        out += be32(0) // height
        out += be32(0) // colour depth
        out += be32(0) // colours used — zero for anything that isn't paletted
        out += be32(cover.count)
        out += cover
        return out
    }

    private static func le32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private static func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static let magic: [UInt8] = Array("fLaC".utf8)

    /// One byte of flags plus three of length, before every block's payload.
    private static let blockHeader = 4

    static let typeStreamInfo = 0
    static let typePadding = 1
    static let typeVorbisComment = 4
    static let typePicture = 6

    /// Blocks this rewrites or spends, rather than carrying across.
    private static let replaced: Set<Int> = [typePadding, typeVorbisComment, typePicture]

    /// The most a three-byte length field can describe.
    private static let maxBlockBytes = (1 << 24) - 1

    /// The `PICTURE` type for a front cover, which is the only one written here.
    private static let pictureFrontCover = 3

    private static let vendor = "Vibra Music"
}
