import VibraMusicCore
import Foundation

/// ListenBrainz submission client (ports `ListenBrainzManager.kt`).
///
/// Two listen types: `playing_now` while the track plays and `single` when it
/// finishes. The API rejects a zero/negative `duration_ms`, and it is
/// optional — so it is only sent when actually known, matching the Kotlin.
/// `release_name` is omitted when the album is blank. JSON is built with
/// `JSONSerialization` (never string interpolation) so titles with quotes or
/// backslashes can't break the payload — the Kotlin hand-escapes; encoding
/// properly removes the need.
public actor ListenBrainzClient {
    public static let submitURL = URL(string: "https://api.listenbrainz.org/1/submit-listens")!
    public static let submissionClient = "Vibra Music"
    /// ListenBrainz ignores absurdly old timestamps; the Kotlin clamps to "now" below this floor.
    public static let minimumListenTimestamp: Int64 = 1_033_430_400

    private let session: URLSession

    public init(session: URLSession = VibraMusicHTTP.session) {
        self.session = session
    }

    // MARK: - Payload builders (public for tests)

    /// Body for a `playing_now` submission, or `nil` when there is nothing to send.
    public static func playingNowBody(
        song: Song,
        positionMs: Int64,
        durationMsOverride: Int64? = nil,
        primaryArtistOnly: Bool = false
    ) -> Data? {
        guard !song.title.isEmpty else { return nil }
        let durationMs = durationMsOverride ?? ScrobbleTiming.parseDurationMs(song.durationText)
        var additionalInfo: [String: Any] = [
            "position_ms": positionMs,
            "submission_client": submissionClient,
        ]
        if durationMs > 0 { additionalInfo["duration_ms"] = durationMs }
        let metadata: [String: Any] = [
            "artist_name": primaryArtistOnly ? ArtistCredit.primary(of: song.artist) : song.artist,
            "track_name": song.title,
            "release_name": song.albumName ?? "",
            "additional_info": additionalInfo,
        ]
        // Kotlin always emits release_name (possibly empty); keep the wire shape identical.
        let body: [String: Any] = ["listen_type": "playing_now", "payload": [["track_metadata": metadata]]]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Body for a finished (`single`) listen, or `nil` when there is nothing to send.
    public static func finishedBody(
        song: Song,
        startMs: Int64,
        endMs: Int64,
        nowSeconds: Int64? = nil,
        durationMsOverride: Int64? = nil,
        primaryArtistOnly: Bool = false
    ) -> Data? {
        guard !song.title.isEmpty else { return nil }
        let durationMs = durationMsOverride ?? ScrobbleTiming.parseDurationMs(song.durationText)
        var listenedAt = startMs / 1000
        if listenedAt < minimumListenTimestamp {
            listenedAt = nowSeconds ?? Int64(Date().timeIntervalSince1970)
        }
        var additionalInfo: [String: Any] = [
            "start_ms": startMs,
            "end_ms": endMs,
            "submission_client": submissionClient,
        ]
        if durationMs > 0 { additionalInfo["duration_ms"] = durationMs }
        let metadata: [String: Any] = [
            "artist_name": primaryArtistOnly ? ArtistCredit.primary(of: song.artist) : song.artist,
            "track_name": song.title,
            "release_name": song.albumName ?? "",
            "additional_info": additionalInfo,
        ]
        let payloadEntry: [String: Any] = ["listened_at": listenedAt, "track_metadata": metadata]
        let body: [String: Any] = ["listen_type": "single", "payload": [payloadEntry]]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: - Submission

    /// Submits a `playing_now` listen. Returns `false` (never throws) when the
    /// token/song is missing or the request fails, mirroring the Kotlin.
    @discardableResult
    public func submitPlayingNow(
        token: String,
        song: Song?,
        positionMs: Int64,
        durationMsOverride: Int64? = nil,
        primaryArtistOnly: Bool = false
    ) async -> Bool {
        guard !token.isEmpty, let song,
              let body = Self.playingNowBody(
                  song: song, positionMs: positionMs,
                  durationMsOverride: durationMsOverride, primaryArtistOnly: primaryArtistOnly
              )
        else { return false }
        return await post(token: token, body: body)
    }

    /// Submits a finished (`single`) listen. Returns `false` (never throws) on
    /// missing input or failure, mirroring the Kotlin.
    @discardableResult
    public func submitFinished(
        token: String,
        song: Song?,
        startMs: Int64,
        endMs: Int64,
        durationMsOverride: Int64? = nil,
        primaryArtistOnly: Bool = false
    ) async -> Bool {
        guard !token.isEmpty, let song,
              let body = Self.finishedBody(
                  song: song, startMs: startMs, endMs: endMs,
                  durationMsOverride: durationMsOverride, primaryArtistOnly: primaryArtistOnly
              )
        else { return false }
        return await post(token: token, body: body)
    }

    private func post(token: String, body: Data) async -> Bool {
        var request = URLRequest(url: Self.submitURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse).map { (200 ... 299).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }
}
