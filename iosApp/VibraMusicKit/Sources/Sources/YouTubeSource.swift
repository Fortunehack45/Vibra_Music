import Foundation
import VibraMusicCore

// Ports data/sources/YouTubeSource.kt. The search and the stream resolver are injected
// (InnerTube's repository and StreamResolution's resolver); this module depends on Core only.

/// YouTube Music, wrapped so it can be ordered alongside everything else.
///
/// A thin adapter: the stream resolver keeps its client walk, URL cache and 403 handling. Tracks
/// keep their bare video ids rather than a ``SourceRegistry/trackKey(configId:trackId:)`` — the
/// like button, lyrics, radio, canvas and scrobbler all key on video ids, and an unwrapped id
/// already routes here by default.
public final class YouTubeSource: MusicSource, @unchecked Sendable {
    public let config: SourceConfig?
    private let sourceConfig: SourceConfig
    private let searcher: YouTubeSongSearching?
    private let resolver: StreamResolving?

    public var configId: String { sourceConfig.id }
    public var kind: SourceKind { .youtube }
    public var displayName: String { sourceConfig.label.nonBlank ?? SourceKind.youtube.label }

    public init(config: SourceConfig, search: YouTubeSongSearching?, streams: StreamResolving?) {
        self.config = config
        sourceConfig = config
        searcher = search
        self.resolver = streams
    }

    /// Always ok. No cheap probe is worth making: a failing YouTube shows up as a failed resolve with
    /// a real reason attached.
    public func health() async -> SourceHealth { .ok() }

    /// `waitForAll` and `tier` are moot: one endpoint, and the tier is decided per stream.
    public func search(_ query: String, limit: Int, waitForAll: Bool, tier: StreamRequest.Tier?) async throws -> [Song] {
        guard let searcher else { return [] }
        let songs = (try? await searcher.searchSongs(query)) ?? []
        try Task.checkCancellation()
        return Array(songs.prefix(max(limit, 0)))
    }

    /// YouTube publishes no lossless rendition, which is why ``SourceKind/canServeLossless`` is
    /// false and the resolver asks this source last. The bitrate ceiling is applied inside the
    /// resolver, where the format list is in hand.
    public func stream(trackId: String, tier: StreamRequest.Tier) async throws -> ResolvedStream? {
        guard let resolver else { return nil }
        let song = Song(videoId: trackId, title: "", artist: "")
        let request = StreamRequest(tier: tier, permittedSources: [.youtube])
        var stream = try await resolver.resolveStream(for: song, request: request)
        stream.origin = .youtube
        return stream
    }
}
