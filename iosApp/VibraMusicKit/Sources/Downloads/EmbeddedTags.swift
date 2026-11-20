import AVFoundation
import Foundation

/// The tags inside an audio file, as AVFoundation reads them.
///
/// The read side of what ``MediaTagger`` writes, and what a Files import (PORTING.md Q8) is filled
/// from: Android asked `MediaMetadataRetriever` and the media scanner, iOS asks `AVAsset`. Covers
/// MP4 (iTunes `ilst`), FLAC (Vorbis comments and `PICTURE`), MP3 (ID3) and anything else
/// AVFoundation opens, by matching both the common keys and the format-specific identifiers.
///
/// Never throws: a file AVFoundation can't read comes back with every field nil.
public struct EmbeddedTags: Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// The container's standard lyrics field (`©lyr`, `LYRICS`, ID3 `USLT`): plain LRC.
    public var lyrics: String?
    /// This app's own word-timed field (``wordLyricsField``), when present.
    public var wordLyrics: String?
    public var artwork: Data?
    /// `image/jpeg` or `image/png`, from the bytes themselves.
    public var artworkMime: String?
    /// Nil when unknown.
    public var durationSeconds: Double?
    /// Whether AVFoundation says it can play the file.
    public var isPlayable: Bool

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        lyrics: String? = nil,
        wordLyrics: String? = nil,
        artwork: Data? = nil,
        artworkMime: String? = nil,
        durationSeconds: Double? = nil,
        isPlayable: Bool = false
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.lyrics = lyrics
        self.wordLyrics = wordLyrics
        self.artwork = artwork
        self.artworkMime = artworkMime
        self.durationSeconds = durationSeconds
        self.isPlayable = isPlayable
    }

    /// Reads `url` (a local file).
    public static func read(from url: URL) async -> EmbeddedTags {
        let asset = AVURLAsset(url: url)
        var tags = EmbeddedTags()
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            tags.durationSeconds = duration.seconds
        }
        tags.isPlayable = (try? await asset.load(.isPlayable)) ?? false

        var items = (try? await asset.load(.metadata)) ?? []
        // `metadata` is the top level only on some containers; the per-format lists catch the rest.
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                items += (try? await asset.loadMetadata(for: format)) ?? []
            }
        }

        for item in items {
            let identifier = item.identifier
            let common = item.commonKey
            if tags.title == nil, common == .commonKeyTitle || Self.titleIDs.contains(identifier) {
                tags.title = await Self.text(item)
            } else if tags.artist == nil, common == .commonKeyArtist || Self.artistIDs.contains(identifier) {
                tags.artist = await Self.text(item)
            } else if tags.album == nil, common == .commonKeyAlbumName || Self.albumIDs.contains(identifier) {
                tags.album = await Self.text(item)
            } else if tags.lyrics == nil, Self.lyricsIDs.contains(identifier) {
                tags.lyrics = await Self.text(item)
            } else if tags.wordLyrics == nil, Self.wordLyricsIDs.contains(identifier) {
                tags.wordLyrics = await Self.text(item)
            } else if tags.artwork == nil, common == .commonKeyArtwork || Self.artworkIDs.contains(identifier) {
                if let data = try? await item.load(.dataValue), !data.isEmpty {
                    let image = Self.pictureBytes(data)
                    tags.artwork = image
                    tags.artworkMime = ImageKind.sniff(image)?.mime
                }
            }
        }
        return tags
    }

    private static func text(_ item: AVMetadataItem) async -> String? {
        guard let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    /// AVFoundation hands a FLAC `PICTURE` over as the image itself on macOS 27, but the Vorbis
    /// `METADATA_BLOCK_PICTURE` form wraps the image in the block header. Unwrap it when it does.
    static func pictureBytes(_ data: Data) -> Data {
        if ImageKind.sniff(data) != nil { return data }
        let bytes = [UInt8](data)
        guard bytes.count > 32 else { return data }
        var p = 4
        let mimeLength = Int(readU32(bytes, p)); p += 4 + mimeLength
        guard p + 4 <= bytes.count else { return data }
        let descriptionLength = Int(readU32(bytes, p)); p += 4 + descriptionLength + 16
        guard p + 4 <= bytes.count else { return data }
        let length = Int(readU32(bytes, p)); p += 4
        guard length > 0, p + length <= bytes.count else { return data }
        return Data(bytes[p..<(p + length)])
    }

    private static let titleIDs: Set<AVMetadataIdentifier?> = [
        .iTunesMetadataSongName, .id3MetadataTitleDescription, .quickTimeMetadataTitle,
        AVMetadataIdentifier(rawValue: "vorb/TITLE"),
    ]
    private static let artistIDs: Set<AVMetadataIdentifier?> = [
        .iTunesMetadataArtist, .id3MetadataLeadPerformer, .quickTimeMetadataArtist,
        AVMetadataIdentifier(rawValue: "vorb/ARTIST"),
    ]
    private static let albumIDs: Set<AVMetadataIdentifier?> = [
        .iTunesMetadataAlbum, .id3MetadataAlbumTitle, .quickTimeMetadataAlbum,
        AVMetadataIdentifier(rawValue: "vorb/ALBUM"),
    ]
    private static let lyricsIDs: Set<AVMetadataIdentifier?> = [
        .iTunesMetadataLyrics, .id3MetadataUnsynchronizedLyric,
        AVMetadataIdentifier(rawValue: "vorb/LYRICS"),
    ]
    private static let wordLyricsIDs: Set<AVMetadataIdentifier?> = [
        AVMetadataIdentifier(rawValue: "itlk/\(Mp4Tagger.freeformMean).\(wordLyricsField)"),
        AVMetadataIdentifier(rawValue: "vorb/\(wordLyricsField)"),
    ]
    private static let artworkIDs: Set<AVMetadataIdentifier?> = [
        .iTunesMetadataCoverArt, .id3MetadataAttachedPicture, .quickTimeMetadataArtwork,
        AVMetadataIdentifier(rawValue: "vorb/METADATA_BLOCK_PICTURE"),
    ]
}

/// The two cover formats the taggers write, told apart by their magic bytes.
public enum ImageKind: String, Sendable {
    case jpeg
    case png

    public var mime: String { self == .jpeg ? "image/jpeg" : "image/png" }

    /// JPEG starts `FF D8 FF`, PNG `89 50 4E 47`; anything else is nil. Used where a declared type
    /// is missing or can't be trusted (a blank ID3 MIME, a cover a server labelled wrongly).
    public static func sniff(_ data: Data) -> ImageKind? {
        let head = [UInt8](data.prefix(4))
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return .jpeg }
        if head.count == 4, head == [0x89, 0x50, 0x4E, 0x47] { return .png }
        return nil
    }
}
