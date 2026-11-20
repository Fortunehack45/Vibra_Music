import Foundation

// Ports the key factory in playback/AudioCache.kt.

/// Which entry of the audio cache a stream's bytes belong to.
///
/// The cache is keyed by track identity, never by URL. googlevideo URLs are single-use, expire
/// within hours and differ between resolves of the same track, so keying on them would cache every
/// track afresh on every play. Because the key is known *before* anything is resolved, a track that
/// is already on disk plays without resolving a URL at all, which is what makes replaying a cached
/// song in airplane mode work.
///
/// One track can own several entries, one per rendition (format): YouTube's own stream, whatever a
/// higher-ranked source substitutes for it (`#alt`), and a quality upgrade that replaces that
/// mid-track (`#<tag>`). Sharing one entry between them survives neither a reorder nor a
/// half-cached track: the next play would serve a FLAC prefix and then stream Opus into the middle
/// of it. Each gets its own entry, and the duplication costs a re-download rather than a corrupt
/// file. The cache also checks every response's total length against the entry's (see
/// ``AudioCacheError/contentChanged(key:expected:actual:)``), so a key reused for a different file
/// is caught rather than spliced.
///
/// The raw form matches Android's so logs and summaries read the same: `videoId`,
/// `videoId#rendition`, or `source|track[#rendition]` for a source-backed track.
public struct AudioCacheKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// `trackID`, or `trackID#rendition` when `rendition` is non-empty.
    public init(trackID: String, rendition: String? = nil) {
        if let rendition, !rendition.isEmpty {
            rawValue = "\(trackID)#\(rendition)"
        } else {
            rawValue = trackID
        }
    }

    /// A YouTube track. `rendition` names the format when the caller pins one before resolving
    /// (an itag, or a quality-upgrade tag); nil is YouTube's own default stream.
    public static func youtube(videoId: String, rendition: String? = nil) -> AudioCacheKey {
        AudioCacheKey(trackID: videoId, rendition: rendition)
    }

    /// A YouTube track served by a substituted source (addon, JioSaavn): `videoId#alt`.
    ///
    /// Split along Dolby Atmos permission (`#alt-noatmos` when Atmos may not play), so a listener
    /// who turns Atmos off can't be handed an Atmos file back out of the cache: the cache answers
    /// from disk without ever calling the resolver, and the Atmos check lives in the resolver.
    /// Flipping the setting back reads the original file again rather than re-fetching it.
    public static func substitute(videoId: String, atmosAllowed: Bool) -> AudioCacheKey {
        AudioCacheKey(trackID: videoId, rendition: atmosAllowed ? substituteTag : substituteTag + "-noatmos")
    }

    /// A source-backed track keyed on the source and its track id alone. Title and artist are left
    /// out on purpose: the same track queued from a row that spelled either differently would
    /// otherwise occupy a second copy of itself on disk.
    public static func source(_ sourceID: String, track: String, rendition: String? = nil) -> AudioCacheKey {
        AudioCacheKey(trackID: "\(sourceID)|\(track)", rendition: rendition)
    }

    /// The part before the first `#`: the video id (or `source|track`) the entry belongs to.
    public var trackID: String {
        guard let hash = rawValue.firstIndex(of: "#") else { return rawValue }
        return String(rawValue[..<hash])
    }

    /// The part after the first `#`, or nil for a track's plain entry.
    public var rendition: String? {
        guard let hash = rawValue.firstIndex(of: "#") else { return nil }
        let tag = rawValue[rawValue.index(after: hash)...]
        return tag.isEmpty ? nil : String(tag)
    }

    /// Whether this is a substituted source's copy (`#alt…`), which can be a different cut of the
    /// same song and so is only borrowed from when nothing else is on disk.
    public var isSubstitute: Bool {
        rendition?.hasPrefix(Self.substituteTag) == true
    }

    /// Whether this entry is one of `trackID`'s renditions (the plain entry or any `trackID#…`).
    public func belongs(toTrack trackID: String) -> Bool {
        rawValue == trackID || rawValue.hasPrefix(trackID + "#")
    }

    public var description: String { rawValue }

    public static func < (lhs: AudioCacheKey, rhs: AudioCacheKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let substituteTag = "alt"
}
