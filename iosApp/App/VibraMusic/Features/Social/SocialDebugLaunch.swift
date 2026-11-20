import VibraMusicCore
import Foundation
import ListenTogether
import Observation
import Replay

#if DEBUG
/// Debug-build launch arguments that fill the Social screens with sample data, for screenshots
/// and manual checks without a party server or months of listening. Open the screens with the
/// app's own links (`vibramusic://replay`, `vibramusic://listen-together`). Release builds ignore them.
///
/// - `-socialDemo replay` — a Replay with a year of sample listening.
/// - `-socialDemo party` / `partyGuest` / `landing` / `signedOut` — Listen Together as the host of
///   a live party, as a guest, before joining, or signed out.
/// - `-socialOpen <what>` — also opens: `story:<n>` (the stories at card n), `share` (the whole
///   Replay's share sheet), `shareCard:<n>`, `create`, `join`, `confirm`, `invite`, `editor`,
///   `members`.
enum SocialDebugLaunch {
    static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var demo: String? { argument("-socialDemo") }
    static var open: String? { argument("-socialOpen") }

    static var replaySource: ReplayDataSource? {
        demo == "replay" ? SampleReplaySource() : nil
    }

    @MainActor private static var party: SampleListenTogetherService?

    @MainActor static var partyService: ListenTogetherService? {
        guard let demo, ["party", "partyGuest", "landing", "signedOut"].contains(demo) else { return nil }
        if let party { return party }
        let made = SampleListenTogetherService(mode: demo)
        party = made
        return made
    }

    /// `story:3` → the fourth card.
    static var storyPage: ReplayStoryPage? {
        guard let open, open.hasPrefix("story:"), let n = Int(open.dropFirst(6)) else { return nil }
        return ReplayStoryPage(rawValue: n)
    }

    static var sharePage: ReplayShareRequest? {
        guard let open else { return nil }
        if open == "share" { return ReplayShareRequest(page: nil) }
        if open.hasPrefix("shareCard:"), let n = Int(open.dropFirst(10)) { return ReplayShareRequest(page: ReplayStoryPage(rawValue: n)) }
        return nil
    }
}

// MARK: - Sample Replay

struct SampleReplaySource: ReplayDataSource {
    func summary(for period: ReplayPeriod) async -> ReplaySummary { SocialSamples.summary(period: period) }
    func memberSince() async -> String? { "03/25" }
}

enum SocialSamples {
    static func thumb(_ id: String) -> String { "https://i.ytimg.com/vi/\(id)/hqdefault.jpg" }

    static func summary(period: ReplayPeriod = .thisYear) -> ReplaySummary {
        let songs: [(String, String, String, Int64, Int)] = [
            ("khnokW3Mw24", "Instant Crush", "Daft Punk", 7_320_000, 61),
            ("5NV6Rdv1a3I", "Get Lucky", "Daft Punk", 5_880_000, 48),
            ("fJ9rUzIMcZQ", "Bohemian Rhapsody", "Queen", 4_210_000, 21),
            ("JGwWNGJdvx8", "Shape of You", "Ed Sheeran", 3_300_000, 38),
            ("kJQP7kiw5Fk", "Despacito", "Luis Fonsi", 2_760_000, 27),
        ]
        let ranked = songs.map { ReplayRankedSong(song: Song(videoId: $0.0, title: $0.1, artist: $0.2, thumbnailUrl: thumb($0.0)), ms: $0.3, plays: $0.4) }
        let artists = [
            ReplayRankedEntry(title: "Daft Punk", artworkUrl: thumb("5NV6Rdv1a3I"), ms: 13_200_000, plays: 109),
            ReplayRankedEntry(title: "Queen", artworkUrl: thumb("fJ9rUzIMcZQ"), ms: 4_210_000, plays: 21),
            ReplayRankedEntry(title: "Ed Sheeran", artworkUrl: nil, ms: 3_300_000, plays: 38),
            ReplayRankedEntry(title: "Luis Fonsi", artworkUrl: nil, ms: 2_760_000, plays: 27),
        ]
        let albums = [
            ReplayRankedEntry(title: "Random Access Memories", subtitle: "Daft Punk", artworkUrl: thumb("khnokW3Mw24"), ms: 13_200_000, plays: 109),
            ReplayRankedEntry(title: "A Night at the Opera", subtitle: "Queen", artworkUrl: thumb("fJ9rUzIMcZQ"), ms: 4_210_000, plays: 21),
            ReplayRankedEntry(title: "÷", subtitle: "Ed Sheeran", artworkUrl: thumb("JGwWNGJdvx8"), ms: 3_300_000, plays: 38),
        ]
        let genres = [
            ReplayRankedEntry(title: "Electronic", ms: 13_200_000, plays: 109),
            ReplayRankedEntry(title: "Rock", ms: 4_210_000, plays: 21),
            ReplayRankedEntry(title: "Pop", ms: 6_060_000, plays: 65),
        ]
        var hours = Array(repeating: Int64(0), count: 24)
        hours[21] = 9_000_000
        hours[8] = 4_000_000
        return ReplaySummary(
            period: period, label: "2026", totalMs: 23_470_000, totalPlays: 195,
            songs: ranked, artists: artists, albums: albums, genres: genres, hourOfDay: hours,
            busiestDay: "2026-08-14", busiestDayMs: 5_400_000,
            distinctSongs: 42, distinctArtists: 17, distinctAlbums: 23, since: "2025-03"
        )
    }

    static let members = [
        PartyMember(memberId: "m1", userId: "u1", displayName: "Alex", isHost: true, connected: true),
        PartyMember(memberId: "m2", userId: "u2", displayName: "Kushagra", connected: true),
        PartyMember(memberId: "m3", userId: "u3", displayName: "Sam", connected: false),
    ]

    static func partyState(youAreHost: Bool) -> PartySessionState {
        let you = youAreHost ? members[0] : members[1]
        return PartySessionState(
            code: "K7Q2XD", you: you, members: members, maxMembers: 5, hostOnlyControl: true,
            playback: PartyPlayback(seq: 3, track: PartyTrack(videoId: "khnokW3Mw24", title: "Instant Crush", artist: "Daft Punk",
                                                              thumbnailUrl: thumb("khnokW3Mw24"), durationMs: 337_000),
                                    isPlaying: true, positionMs: 83_000),
            connection: .live, clockSynced: true, roundTripMs: 42
        )
    }

    static let activity = [
        PartyActivity(action: "skip", by: "Kushagra", atMs: 1_790_000_000_000, detail: "skipped to Instant Crush"),
        PartyActivity(action: "queue_add", by: "Sam", atMs: 1_789_999_940_000, detail: "added Get Lucky"),
        PartyActivity(action: "join", by: "Sam", atMs: 1_789_999_900_000),
    ]
}

// MARK: - Sample party

/// A party layer that answers from memory: the screens' states without a server.
@MainActor
@Observable
final class SampleListenTogetherService: ListenTogetherService {
    var state: PartySessionState
    var activity: [PartyActivity]
    var signedIn: Bool
    var myAvatarUrl: String?
    let defaultServer = "https://party.default.example"
    var customServer = ""
    var nickname = "Alex"

    init(mode: String) {
        signedIn = mode != "signedOut"
        switch mode {
        case "party":
            state = SocialSamples.partyState(youAreHost: true)
            activity = SocialSamples.activity
        case "partyGuest":
            state = SocialSamples.partyState(youAreHost: false)
            activity = SocialSamples.activity
        default:
            state = PartySessionState()
            activity = []
        }
    }

    func setNickname(_ value: String) { nickname = value }
    func hasServer() async -> Bool { true }
    func serverConnection() async -> PartyServerConnectionState { .defaultOnline(latencyMs: 38) }
    func activePartyServer() async -> String? { state.inParty ? defaultServer : nil }
    func effectiveIdleServer() async -> String { defaultServer }
    func refreshServerHealth() async {}
    func ensureConnected() async {}
    func partyPositionMs() async -> Int64? { state.playback.track == nil ? nil : state.playback.positionMs }

    func preview(code: String, server: String?) async -> Result<PartyPreview, PartyClientError> {
        .success(PartyPreview(code: code, hostName: "Kushagra", memberCount: 3, maxMembers: 5,
                              members: SocialSamples.members.map { PartyPreviewMember(displayName: $0.displayName, isHost: $0.isHost) }))
    }

    func createParty(nickname: String, maxMembers: Int) async -> Result<String, PartyClientError> {
        state = SocialSamples.partyState(youAreHost: true)
        return .success("K7Q2XD")
    }

    func joinParty(code: String, nickname: String) async -> Result<String, PartyClientError> {
        state = SocialSamples.partyState(youAreHost: false)
        return .success(code)
    }

    func switchParty(server: String, code: String, nickname: String) async -> PartySwitchResult {
        state = SocialSamples.partyState(youAreHost: false)
        return .success(partyCode: code)
    }

    func leaveParty() async { state = PartySessionState() }
    func kick(memberId: String) { state.members.removeAll { $0.memberId == memberId } }
    func setHostOnlyControl(_ enabled: Bool) { state.hostOnlyControl = enabled }
    func setMaxMembers(_ value: Int) { state.maxMembers = value }
    func setCustomServer(_ normalizedUrl: String) async -> PartyServerConnectionState {
        customServer = normalizedUrl
        return normalizedUrl.isEmpty ? .defaultOnline(latencyMs: 38) : .customOnline(latencyMs: 55)
    }
    func probe(_ normalizedUrl: String) async -> PartyProbeResult { PartyProbeResult(isOnline: true, latencyMs: 55) }
}
#endif
