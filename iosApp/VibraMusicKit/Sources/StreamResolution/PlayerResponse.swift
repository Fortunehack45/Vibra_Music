import Foundation

/// The parts of a `/youtubei/v1/player` response this module reads. Everything is optional:
/// the shape differs per client and Google adds and drops fields freely, so a missing field
/// reads as absent rather than failing the decode.
struct PlayerResponse: Decodable {
    var responseContext: ResponseContext?
    var playabilityStatus: PlayabilityStatus?
    var streamingData: StreamingData?
    var playerConfig: PlayerConfig?
    var videoDetails: VideoDetails?
    var playbackTracking: PlaybackTracking?
    /// The PoToken the request that produced this response carried, so the stream URLs built
    /// from it get the matching `pot`. Not part of the wire format.
    var attachedPoToken: StreamPoToken?

    private enum CodingKeys: String, CodingKey {
        case responseContext, playabilityStatus, streamingData, playerConfig, videoDetails, playbackTracking
    }

    struct ResponseContext: Decodable {
        var visitorData: String?
    }

    struct PlayabilityStatus: Decodable {
        var status: String?
        var reason: String?
        var errorScreen: ErrorScreen?

        struct ErrorScreen: Decodable {
            var playerErrorMessageRenderer: Renderer?

            struct Renderer: Decodable {
                var reason: FormattedText?
                var subreason: FormattedText?
            }
        }

        /// Reason and subreason together, which is where Google says *why* (the reason alone is
        /// often just "Video unavailable").
        var explanation: String {
            let renderer = errorScreen?.playerErrorMessageRenderer
            return [reason, renderer?.reason?.text, renderer?.subreason?.text]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
        }
    }

    struct StreamingData: Decodable {
        var expiresInSeconds: String?
        var adaptiveFormats: [Format]?
        var formats: [Format]?
        var serverAbrStreamingUrl: String?
        var hlsManifestUrl: String?
    }

    struct Format: Decodable {
        var itag: Int
        var url: String?
        var signatureCipher: String?
        var cipher: String?
        var mimeType: String?
        var bitrate: Int?
        var averageBitrate: Int?
        var contentLength: String?
        var approxDurationMs: String?
        var audioQuality: String?
        var loudnessDb: Double?
        var audioSampleRate: String?
        var isDrc: Bool?
        var xtags: String?
        var audioTrack: AudioTrack?

        struct AudioTrack: Decodable {
            var displayName: String?
            var id: String?
            var audioIsDefault: Bool?
        }

        var isAudio: Bool { mimeType?.hasPrefix("audio/") == true }
        var isMP4Audio: Bool { mimeType?.hasPrefix("audio/mp4") == true }
        var isWebMOpus: Bool { mimeType?.hasPrefix("audio/webm") == true && mimeType?.contains("opus") == true }

        /// kbps as the Kotlin measured it: the average when given, the peak otherwise.
        var kbps: Int { (averageBitrate ?? bitrate ?? 0) / 1000 }

        var contentLengthValue: Int64? { contentLength.flatMap { Int64($0) } }
        var approxDurationMsValue: Int64? { approxDurationMs.flatMap { Int64($0) } }

        /// A rendition this app should never pick: dynamic-range-compressed copies (`drc`) and
        /// dubbed tracks other than the original. Both are the same song done worse.
        var isAlternateRendition: Bool {
            if isDrc == true { return true }
            if xtags?.contains("drc") == true { return true }
            if let track = audioTrack, track.audioIsDefault == false { return true }
            return false
        }
    }

    struct PlayerConfig: Decodable {
        var audioConfig: AudioConfig?

        struct AudioConfig: Decodable {
            var loudnessDb: Double?
            var loudnessTargetLkfs: Double?
        }
    }

    struct VideoDetails: Decodable {
        var videoId: String?
        var lengthSeconds: String?
        var title: String?
        var author: String?
    }

    struct PlaybackTracking: Decodable {
        var videostatsPlaybackUrl: TrackingURL?
        var videostatsWatchtimeUrl: TrackingURL?
        var atrUrl: TrackingURL?

        struct TrackingURL: Decodable {
            var baseUrl: String?
            var elapsedMediaTimeSeconds: Int?

            private enum CodingKeys: String, CodingKey { case baseUrl, elapsedMediaTimeSeconds }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl)
                // Sometimes a number, sometimes a string; either is a count of seconds.
                if let number = try? container.decodeIfPresent(Int.self, forKey: .elapsedMediaTimeSeconds) {
                    elapsedMediaTimeSeconds = number
                } else if let text = try? container.decodeIfPresent(String.self, forKey: .elapsedMediaTimeSeconds) {
                    elapsedMediaTimeSeconds = Int(text)
                } else {
                    elapsedMediaTimeSeconds = nil
                }
            }
        }
    }

    /// `{"runs":[{"text":…}]}` or `{"simpleText":…}`.
    struct FormattedText: Decodable {
        var runs: [Run]?
        var simpleText: String?

        struct Run: Decodable { var text: String? }

        var text: String? { simpleText ?? runs?.compactMap(\.text).joined() }
    }

    static func decode(_ data: Data) throws -> PlayerResponse {
        try JSONDecoder().decode(PlayerResponse.self, from: data)
    }

    /// Every audio format on offer, adaptive or progressive: audio lives in `adaptiveFormats`
    /// today, but a client that answers usable audio only in `formats` (Android's extractor
    /// read progressive streams) must not read as "no usable format".
    var audioFormats: [Format] {
        ((streamingData?.adaptiveFormats ?? []) + (streamingData?.formats ?? [])).filter(\.isAudio)
    }

    /// Loudness for `format`, falling back to the response-wide figure.
    /// YouTube's figure is relative to the answering client's own target: −14 LKFS for the app
    /// clients, −7 for WEB_REMIX, so one track read 7 dB apart depending on who answered. Re-based
    /// on −14, the target the gain mapping (Android's) assumes.
    func loudnessDb(for format: Format) -> Double? {
        guard let db = format.loudnessDb ?? playerConfig?.audioConfig?.loudnessDb else { return nil }
        return db + (playerConfig?.audioConfig?.loudnessTargetLkfs ?? -14) + 14
    }
}

// MARK: - Playability

/// Why a track can never be played by this app, as a message worth showing. The distinction
/// from "not just now" is the difference between one failed track and a request storm.
///
/// Ported from `StreamResolver.permanentReason`, which classified NewPipe's exception types;
/// the same verdicts are read here from the player response itself.
enum PermanentReason: Int, Comparable, Sendable {
    // Ordered by how much a listener can do about it: an age gate is fixed by signing in, so it
    // is the reason worth reporting when clients disagree.
    case ageRestricted = 0
    case geoBlocked
    case privateVideo
    case premiumOnly
    case paidContent
    case channelTerminated
    case removed

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    func message(signedIn: Bool) -> String {
        switch self {
        case .ageRestricted:
            return signedIn
                ? "YouTube will not serve this age-restricted track to this app."
                : "This track is age-restricted. Sign in to YouTube to play it."
        case .geoBlocked: return "This track isn't available in your country"
        case .privateVideo: return "This track is private"
        case .premiumOnly: return "This track needs YouTube Music Premium"
        case .paidContent: return "This track is paid content"
        case .channelTerminated: return "The channel behind this track was terminated"
        case .removed: return "This track is no longer available on YouTube"
        }
    }
}

/// What one client's answer means for the walk.
enum PlayabilityVerdict: Equatable {
    /// Formats are on offer (whether any is usable is a separate question).
    case playable
    /// "Sign in to confirm you're not a bot": the visitor id may be burned. Worth exactly one
    /// fresh visitor id, since an id can be burned while the session around it is fine.
    case botCheck
    /// This client is turned away for a reason another client may not share.
    case refused(String)
    /// A verdict about the track rather than the client.
    case permanent(PermanentReason)

    static func classify(_ status: PlayerResponse.PlayabilityStatus?) -> PlayabilityVerdict {
        guard let status else { return .refused("no playabilityStatus") }
        let code = status.status ?? ""
        if code == "OK" { return .playable }
        let text = status.explanation
        let lower = text.lowercased()

        if lower.contains("not a bot") { return .botCheck }
        if lower.contains("confirm your age") || lower.contains("age-restricted") || lower.contains("age restricted")
            || lower.contains("inappropriate for some users") {
            return .permanent(.ageRestricted)
        }
        if lower.contains("in your country") || lower.contains("not available in your location")
            || lower.contains("blocked it in your country") {
            return .permanent(.geoBlocked)
        }
        if lower.contains("private video") || lower.contains("video is private") { return .permanent(.privateVideo) }
        if lower.contains("music premium") { return .permanent(.premiumOnly) }
        if lower.contains("requires payment") || lower.contains("purchase") || lower.contains("rent this") {
            return .permanent(.paidContent)
        }
        if lower.contains("terminated") { return .permanent(.channelTerminated) }
        // ERROR is the video not existing (removed, or never did). UNPLAYABLE with the same
        // words is a client-specific refusal — WEB_REMIX says "Video unavailable" for anything
        // that is not music — so only ERROR counts, and only when every client agrees.
        if code == "ERROR" { return .permanent(.removed) }
        return .refused(text.isEmpty ? code : "\(code): \(text)")
    }
}

// MARK: - Format selection

/// Highest of `candidates` at or under `maxKbps`; if everything is above it — Low on a track
/// whose ladder starts at 130 kbps, say — the cheapest available, because a rung over budget
/// still beats no audio at all. Port of `StreamResolver.underCeiling`.
func underCeiling<T>(_ candidates: [(kbps: Int, value: T)], maxKbps: Int) -> T? {
    guard !candidates.isEmpty else { return nil }
    let withinBudget = candidates.filter { $0.kbps <= maxKbps }
    if let best = withinBudget.max(by: { $0.kbps < $1.kbps }) { return best.value }
    return candidates.min(by: { $0.kbps < $1.kbps })?.value
}

/// What the caller wants out of a player response.
enum StreamSelection: Equatable, Sendable {
    /// Playback: AAC-in-MP4 only, because AVPlayer cannot demux WebM (PORTING.md §4). This is
    /// the main iOS deviation — Android plays YouTube's Opus ladder.
    case playback(maxKbps: Int)
    /// Download: the container the destination requires, under the download ceiling.
    case download(maxKbps: Int, requireM4a: Bool)

    var maxKbps: Int {
        switch self {
        case .playback(let kbps), .download(let kbps, _): return kbps
        }
    }

    func accepts(_ format: PlayerResponse.Format) -> Bool {
        guard format.isAudio, !format.isAlternateRendition else { return false }
        switch self {
        case .playback: return format.isMP4Audio
        case .download(_, let requireM4a): return requireM4a ? format.isMP4Audio : format.isWebMOpus
        }
    }

    /// The format to use out of `formats`, or nil when none is acceptable. Only formats that
    /// carry a `url` or a `signatureCipher` count; SABR-only answers have neither.
    func pick(from formats: [PlayerResponse.Format]) -> PlayerResponse.Format? {
        let usable = formats.filter { accepts($0) && ($0.url != nil || $0.signatureCipher != nil || $0.cipher != nil) }
        return underCeiling(usable.map { (kbps: $0.kbps, value: $0) }, maxKbps: maxKbps)
    }

    /// Whether any format of the wanted container exists at all, usable or not — the Kotlin's
    /// `offered`, which separates "try again" from "this track has none".
    func offersContainer(_ formats: [PlayerResponse.Format]) -> Bool {
        formats.contains { accepts($0) }
    }
}
