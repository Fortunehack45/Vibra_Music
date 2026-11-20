import Foundation
import VibraMusicCore

// Ports data/sources/JioSaavnSource.kt.

/// JioSaavn: AAC in MP4 up to 320 kbps, answering a search and a stream URL in about 0.4 s — the
/// one source quick enough to ask before a track plays (``SourceKind/worthPrefetching``).
public final class JioSaavnSource: MusicSource, @unchecked Sendable {
    public let config: SourceConfig?
    private let sourceConfig: SourceConfig
    private let service: JioSaavnService

    public var configId: String { sourceConfig.id }
    public var kind: SourceKind { .jioSaavn }
    public var displayName: String { sourceConfig.label.nonBlank ?? SourceKind.jioSaavn.label }

    public init(config: SourceConfig, service: JioSaavnService) {
        self.config = config
        sourceConfig = config
        self.service = service
    }

    /// Always ok: the endpoints need no authentication to search.
    public func health() async -> SourceHealth { .ok() }

    /// `waitForAll` and `tier` are moot: one endpoint, one catalogue, no tiers to ask at.
    public func search(_ query: String, limit: Int, waitForAll: Bool, tier: StreamRequest.Tier?) async throws -> [Song] {
        SourcesLog.d("▶ JioSaavn searchSongs() query=\"\(query)\" limit=\(limit)")
        let results = JioSaavnService.prioritizeExplicit(await service.searchSongs(query))
        try Task.checkCancellation()
        if !results.isEmpty {
            let preview = results.prefix(5).map { row in
                "'\(row.title)' by '\(row.primaryArtists.map(\.name).joined(separator: ", "))' \(row.duration)s "
                    + "id=\(row.id) album='\(row.album)' explicit=\(row.explicitContent)"
            }.joined(separator: "; ")
            SourcesLog.d("  ✓ JioSaavn returned \(results.count) tracks: \(preview)")
        }
        return results.prefix(max(limit, 0)).map { raw in
            let artists = raw.primaryArtists.map(\.name).joined(separator: ", ")
            return Song(
                videoId: SourceRegistry.trackKey(configId: configId, trackId: raw.id),
                title: raw.title,
                artist: artists.nonBlank ?? "Unknown Artist",
                thumbnailUrl: Self.largeArtwork(raw.image),
                durationText: Int(raw.duration).map(TrackMatcher.durationText),
                // Keep the release identity: the catalogue holds different recordings under the
                // same title and artist (two releases of one song), and without the album only
                // duration is left to choose between them.
                albumName: raw.album.nonBlank,
                sourceQuality: .high,
                isExplicit: raw.isExplicit
            )
        }
    }

    public func stream(trackId: String, tier: StreamRequest.Tier) async throws -> ResolvedStream? {
        SourcesLog.d("▶ JioSaavn getStreamUrl() trackId=\(trackId) request=\(tier)")
        guard let stream = await service.streamURL(for: trackId), let url = URL(string: stream.url), stream.url.nonBlank != nil else {
            try Task.checkCancellation()
            SourcesLog.w("  ✗ JioSaavn had no stream URL for \(trackId)")
            return nil
        }
        // A rendition this thin is worse than the YouTube stream it would replace. Refused here, as
        // a miss, so the resolver steps to the next source rather than taking it and then declining
        // to upgrade.
        if let kbps = stream.kbps, kbps <= Self.minUsableKbps {
            SourcesLog.w("  ✗ JioSaavn only offered \(kbps)kbps for \(trackId); not worth playing")
            return nil
        }
        SourcesLog.d("  ✓ JioSaavn \(stream.kbps.map(String.init) ?? "?")kbps \(stream.url.prefix(96))")
        // `mp4` is the container; the AAC inside is reported by the decoder itself. The rate is
        // what the URL really serves, never a flat 320.
        return ResolvedStream(url: url, origin: .jioSaavn, mimeType: "audio/mp4", format: StreamFormat(codec: "mp4", kbps: stream.kbps))
    }

    /// The 500×500 artwork instead of the 150×150 the API names, over https.
    static func largeArtwork(_ image: String) -> String? {
        guard image.nonBlank != nil else { return nil }
        var url = image.replacingOccurrences(of: "150x150", with: "500x500").replacingOccurrences(of: "50x50", with: "500x500")
        if url.hasPrefix("http://") { url = "https://" + url.dropFirst("http://".count) }
        return url
    }

    /// JioSaavn files a track at 48, 96, 160 or 320. The first two are below YouTube's own AAC.
    static let minUsableKbps = 96
}
