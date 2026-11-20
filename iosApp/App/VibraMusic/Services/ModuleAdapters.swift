import VibraMusicCore
import Foundation
import InnerTube
import Lyrics
import PlaybackQueue
import Sources
import StreamResolution

// The small protocols each module declares for what it needs from another (README "Module
// boundaries"), implemented here where both sides are visible.

/// StreamResolution's view of the signed-in session, read from InnerTube on every resolve so a
/// profile switch applies to the next stream (InnerTube report, "Wiring the app has to write").
struct InnerTubeStreamAuth: StreamAuthProvider {
    let client: InnerTubeClient

    func streamAuthSession() async -> StreamAuthSession? {
        let identity = await client.requestIdentity()
        guard let cookie = identity.cookie else { return nil }
        return StreamAuthSession(
            cookie: cookie,
            authUser: identity.authUser,
            pageId: identity.pageId,
            dataSyncId: identity.onBehalfOfUser,
            // Only a visitor id minted for this session: an anonymous one would sign requests as
            // somebody else.
            visitorData: identity.visitorDataIsSessionBound ? identity.visitorData : nil,
            webRemixClientVersion: identity.liveClientVersion
        )
    }
}

/// YouTube's own streams as Core's ``StreamResolving``: what Sources injects as its YouTube leg
/// and what the refresh of an expired YouTube URL goes back to. Never the SourceResolver itself,
/// which would recurse (Sources report).
struct YouTubeStreamResolving: StreamResolving {
    let resolver: StreamResolver

    func resolveStream(for song: Song, request: StreamRequest) async throws -> ResolvedStream {
        switch request.purpose {
        case .download:
            // AVPlayer can't play WebM, so a download is always AAC in MP4 (StreamResolution
            // report); the ceiling is the download quality's.
            let stream = try await resolver.resolveForDownload(song.videoId, maxKbps: request.maxKbps ?? Int.max, requireM4a: true)
            return Self.resolved(stream)
        case .playback:
            // The playback ceiling is read by the resolver itself through its configuration
            // (`playbackCeilingKbps`), which follows the same per-network setting.
            return Self.resolved(try await resolver.resolve(song.videoId))
        }
    }

    static func resolved(_ stream: ResolvedYouTubeStream) -> ResolvedStream {
        ResolvedStream(
            url: stream.url,
            origin: .youtube,
            mimeType: stream.mimeType,
            format: StreamFormat(codec: codec(of: stream.mimeType), kbps: stream.kbps),
            headers: stream.mediaHeaders,
            loudnessDb: stream.loudnessDb,
            contentLength: stream.contentLength,
            expiresAt: stream.expiresAt,
            durationSeconds: stream.approxDurationMs.map { Int($0 / 1_000) }
        )
    }

    /// `audio/mp4; codecs="mp4a.40.2"` → "aac"; `audio/webm; codecs="opus"` → "opus".
    static func codec(of mimeType: String) -> String? {
        let lower = mimeType.lowercased()
        if lower.contains("mp4a") { return "aac" }
        if lower.contains("opus") { return "opus" }
        if lower.contains("mp4") { return "aac" }
        return nil
    }
}

/// InnerTube's songs search, for Sources' YouTube source and for matching device files to a
/// YouTube seed.
struct InnerTubeSongSearch: YouTubeSongSearching {
    let repository: YTMusicRepository

    func searchSongs(_ query: String) async throws -> [Song] {
        try await repository.search(query: query, filter: .songs).compactMap(\.song)
    }
}

/// AutoPlay and "Start radio" from YouTube Music's `RDAMVM` watch queue.
struct InnerTubeRadioSource: AutoplayRadioSource {
    let repository: YTMusicRepository

    /// A source-backed row (`src:<config>::<track>`) has no YouTube id, so it is matched on YouTube
    /// first, as Android's `youtubeSeedFor` did; a file on this device has no station at all.
    func youtubeSeed(for song: Song) async -> String? {
        if song.localUri != nil || song.videoId.hasPrefix("file:") || song.videoId.hasPrefix("ipod-library:")
            || song.videoId.hasPrefix(LocalBrowseID.playlistPrefix) || song.videoId.hasPrefix("local:") {
            return nil
        }
        guard SourceRegistry.parseTrackKey(song.videoId) != nil else { return song.videoId }
        let query = "\(song.title) \(song.primaryArtist)"
        let candidates = (try? await repository.search(query: query, filter: .songs).compactMap(\.song)) ?? []
        let target = TrackMatcher.targetOf(song)
        return (TrackMatcher.best(candidates, target) ?? candidates.first)?.videoId
    }

    func radio(seedVideoId: String) async throws -> [Song] {
        try await repository.radio(videoId: seedVideoId)
    }
}

/// The two YouTube lyric sources reach InnerTube through the signed-in client, so lyrics that need
/// the account (and the account's region) come back the same as on YouTube Music.
struct InnerTubeLyricsClient: LyricsInnerTubeClient {
    let client: InnerTubeClient

    func next(videoId: String) async throws -> Data {
        try await client.next(videoId: videoId).serialized()
    }

    func browse(browseId: String, params: String?) async throws -> Data {
        try await client.browse(browseId, params: params).serialized()
    }

    func transcript(videoId: String) async throws -> Data {
        try await client.transcript(videoId: videoId).serialized()
    }
}
