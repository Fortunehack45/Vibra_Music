import VibraMusicCore
import Foundation
import Integrations
import Replay

// Ports what Android's ListeningRecorder (`enriched`) and ArtistFacts' worker do around the
// Replay: finds out what the queue didn't carry about a track, and fills in each artist's
// picture, page and genres.
//
// Most tracks reach the player with no album (a home card, a search hit, an AutoPlay suggestion),
// so the album chart would be empty for nearly everyone, and artist rows would have no page to
// open. The lookups run from the recorder's own ticks, so listening with the phone in a pocket
// is credited too, and never hold a sample back.

@MainActor
final class ReplayEnrichment {
    /// The gap between artist lookups (Android's `REQUEST_SPACING_MS`), so a backfill after an
    /// update doesn't hammer YouTube Music or Last.fm.
    static let requestSpacing: Duration = .milliseconds(1_500)
    private static let youTubeIdLength = 11

    private let stats: ReplayListeningStats
    private let facts: ReplayArtistFacts
    private let trackLinks: @Sendable (String) async throws -> Song
    private var extras: [String: Song] = [:]
    private var asked: Set<String> = []
    /// When a failed lookup may be tried again; a sample arrives every few seconds, so without a
    /// gap an offline device would make a request per tick.
    private var retryAt: [String: ContinuousClock.Instant] = [:]
    private let retryGap: Duration
    private var draining = false

    /// - `searchArtist`: the top hit of a YouTube Music artist search for the name.
    /// - `topTags`: Last.fm's top tags for the name, highest first.
    init(
        stats: ReplayListeningStats,
        facts: ReplayArtistFacts,
        spacing: Duration = ReplayEnrichment.requestSpacing,
        retryGap: Duration = .seconds(60),
        trackLinks: @escaping @Sendable (String) async throws -> Song,
        searchArtist: @escaping @Sendable (String) async -> ReplayArtistCard?,
        topTags: @escaping @Sendable (String) async -> [String]
    ) {
        self.stats = stats
        self.facts = facts
        self.trackLinks = trackLinks
        self.retryGap = retryGap
        facts.cardProvider = { name in
            try? await Task.sleep(for: spacing)
            return await searchArtist(name)
        }
        facts.tagProvider = { name in
            try? await Task.sleep(for: spacing)
            return await topTags(name)
        }
    }

    /// `song` with whatever the lookup has found so far.
    ///
    /// Returns the song unchanged while the request is in flight rather than holding the sample
    /// back: a few seconds filed without an album is a few seconds missing from the album chart,
    /// and waiting on the network would be a few seconds missing from everything.
    func enriched(_ song: Song) -> Song {
        if let extra = extras[song.videoId] {
            var filled = song
            filled.artistId = song.artistId ?? extra.artistId
            filled.albumId = song.albumId ?? extra.albumId
            filled.albumName = song.albumName ?? extra.albumName
            filled.thumbnailUrl = song.thumbnailUrl ?? extra.thumbnailUrl
            return filled
        }
        if song.albumName != nil && song.artistId != nil { return song }
        // Only tracks YouTube can answer for: a file on the device and an add-on's track carry
        // ids this endpoint has never heard of, and asking would be a failed request per play.
        if song.localUri != nil || song.videoId.count != Self.youTubeIdLength { return song }
        if let at = retryAt[song.videoId], ContinuousClock.now < at { return song }
        if asked.insert(song.videoId).inserted {
            let videoId = song.videoId
            Task {
                guard let found = try? await self.trackLinks(videoId) else {
                    // A failure is not an answer: forgotten, so a later sample asks again.
                    self.asked.remove(videoId)
                    self.retryAt[videoId] = .now + self.retryGap
                    return
                }
                self.extras[videoId] = found
                // Credits what was already banked for the track before the answer landed.
                self.stats.noteMetadata(found)
            }
        }
        return song
    }

    /// Looks up the artists the recorder has noticed, one at a time, when there are any waiting.
    func drainArtistsIfNeeded() {
        guard !draining, !facts.pendingArtists.isEmpty else { return }
        draining = true
        Task {
            await self.facts.resolvePending()
            self.draining = false
        }
    }
}

/// Last.fm's `artist.getTopTags`, which is where Replay's genres come from.
enum LastFMArtistTags {
    static func url(artist: String, apiKey: String) -> URL? {
        var components = URLComponents(string: LastFMConfiguration.defaultEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "method", value: "artist.gettoptags"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    /// The tag names in an answer, highest first; none for anything unreadable.
    static func names(in data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tags = (json["toptags"] as? [String: Any])?["tag"] as? [[String: Any]]
        else { return [] }
        return tags.compactMap { $0["name"] as? String }
    }

    static func fetch(artist: String, apiKey: String, session: URLSession) async -> [String] {
        guard !apiKey.isEmpty, let url = LastFMArtistTags.url(artist: artist, apiKey: apiKey),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        return names(in: data)
    }
}
