/*
 * Copyright (C) 2026 Kushagra Singh
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
 * Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

// Where the analyzer and the aligner get their audio from. On Android these are AudioCache,
// LocalAudioSource and the source-to-YouTube matching in TrackAnalyzer; here the cache and the
// catalogue belong to other modules (Playback, Sources, InnerTube), so they are protocols the app
// wires in.

/// Keeps Automix analysis on the canonical YouTube rendition of a recording.
///
/// Playback may deliberately use a source substitute (JioSaavn, a lossless add-on), but its cache
/// entry is not interchangeable with the YouTube recording that analysis owns. The plain video id
/// is the cache key pinned to that YouTube copy; suffixed keys (`#alt`, `#hifi`, ...) belong to
/// substitutes or upgrades.
///
/// The names keep Android's "Opus" because the playback URI marker is shared with the resolver.
/// AVFoundation cannot decode WebM/Opus, so on iOS the resolver should answer this marker with the
/// YouTube AAC/M4A rendition (itag 140) — the point of the marker is "YouTube's own copy, not a
/// substitute", not the codec.
public enum AutomixAnalysisSource {
    public static let opusQueryParameter = "automix_opus"

    public static func isCanonicalYouTubeRendition(videoId: String?, cacheKey: String) -> Bool {
        videoId == nil || cacheKey == videoId
    }

    /// A private playback URI for analysis-only reads.
    ///
    /// A normal `watch?v=` URI is allowed to reuse the source race already pinned for audible
    /// playback. That is exactly the wrong thing for Automix: its independently cached copy must
    /// always be YouTube's, even while playback is JioSaavn or a lossless upgrade.
    public static func opusURI(videoId: String) -> String {
        "vibramusic://watch?v=\(videoId)&\(opusQueryParameter)=1"
    }

    public static func requestsYouTubeOpus(_ marker: String?) -> Bool { marker == "1" }
}

/// One cached copy of a recording, as the playback cache knows it.
public struct AutomixRendition: Sendable, Hashable {
    /// The cache key: the plain video id for YouTube's own copy, `id#alt`, `id#hifi`, ... for others.
    public var key: String
    /// The full length in bytes, or 0 when not yet known.
    public var contentLength: Int64
    /// How many bytes from the start are on disk, contiguously.
    public var cachedPrefix: Int64
    /// A local file AVAssetReader can open holding (at least) the rendition's first
    /// ``cachedPrefix`` bytes. A partially written file is fine: decoding stops where the bytes do.
    public var fileURL: URL

    public init(key: String, contentLength: Int64, cachedPrefix: Int64, fileURL: URL) {
        self.key = key
        self.contentLength = contentLength
        self.cachedPrefix = cachedPrefix
        self.fileURL = fileURL
    }

    public var isComplete: Bool { contentLength > 0 && cachedPrefix >= contentLength }
}

/// The playback cache, as far as Automix needs it. Implemented by Playback's audio cache.
public protocol AutomixRenditionProvider: AnyObject, Sendable {
    /// Every rendition of the recording `uri` points at that is on disk, cheapest first. One video
    /// id can own several (YouTube's copy, a substitute's `#alt`, a quality upgrade); they hold the
    /// same music, so analysing the lightest complete one describes all of them.
    func renditions(of uri: URL) -> [AutomixRendition]

    /// The cache key the player's own copy of `uri` resolves to right now.
    func cacheKey(of uri: URL) -> String

    /// Asks the cache to fetch the opening of `uri` for analysis. Expected to be a no-op after the
    /// first call and for anything that isn't YouTube-backed.
    func requestAnalysisHead(for uri: URL)

    /// Deletes a rendition the cache calls complete but which decoded short, so a clean copy can
    /// replace it. Returns false when refused (for example, it is what the player is reading).
    func discardBadRendition(for uri: URL, key: String) -> Bool
}

/// Finds the YouTube recording for a source-backed playback URI (JioSaavn, add-on, ...), so its
/// analysis reads YouTube's copy while playback stays on the source. Implemented by the app on top
/// of Sources' track matcher and InnerTube search.
public protocol AutomixCatalogMatcher: Sendable {
    /// The YouTube video id matching the track `sourceURI` describes, or nil when there is none.
    func youTubeVideoId(forSourceURI sourceURI: URL) async -> String?
}

/// A reader over a track that is already on the device.
///
/// A track playing off the device never lands in the playback cache, so the whole rendition
/// apparatus answers "nothing cached" for a track that is entirely present. A local file needs
/// none of that machinery: there is one copy, it is complete the moment it exists, and it is the
/// user's file — nothing here may delete it when a decode disappoints.
public enum AutomixLocalAudioSource {
    /// Whether `url` names a file on the device (a file URL, or a media-library `ipod-library://`
    /// asset URL) rather than something to fetch.
    public static func isLocal(_ url: URL) -> Bool {
        url.isFileURL || url.scheme?.lowercased() == "ipod-library"
    }

    /// Whether `url` can be read for analysis right now. Best-effort like the rest of analysis: a
    /// file that has since gone, a directory, or an empty file all answer false, and the caller
    /// falls back to no analysis.
    public static func isReadable(_ url: URL) -> Bool {
        guard url.isFileURL else { return isLocal(url) }
        return withAccess(to: url) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return false
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return size > 0
        }
    }

    /// Runs `body` with security-scoped access to `url` when it needs it (a file the user picked
    /// with the document picker), releasing it afterwards.
    public static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = url.isFileURL && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// The async counterpart of ``withAccess(to:_:)``.
    public static func withAccess<T>(to url: URL, _ body: () async throws -> T) async rethrows -> T {
        let scoped = url.isFileURL && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try await body()
    }
}

extension URL {
    /// A query parameter, or nil. Forgiving like Android's `Uri.getQueryParameter`: a URL without
    /// a query simply has no parameters.
    func automixQueryParameter(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}
