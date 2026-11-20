import VibraMusicCore
import VibraMusicTestSupport
import Foundation
@testable import ListenTogether

/// Shared scaffolding for client tests. The client never touches the network here:
/// memberships commit through the offline hook with the socket disabled.
enum PartyTestFixtures {
    static func makeStore(defaultServer: String = "https://default.example.com") throws -> (PartyServerStore, TemporaryDirectory) {
        let dir = try TemporaryDirectory(prefix: "PartyTests")
        let store = PartyServerStore(files: JSONFileStore(directory: dir.url), defaultServer: defaultServer)
        return (store, dir)
    }

    static func makeClient(store: PartyServerStore) -> PartyClient {
        PartyClient(store: store, urlSession: .shared, clock: PartyServerClock())
    }

    static func membership(
        code: String = "J4M001",
        token: String = "tok",
        you: PartyMember = PartyMember(memberId: "m-2", displayName: "Guest"),
        members: [PartyMember]? = nil,
        playback: PartyPlayback = PartyPlayback(),
        queue: PartyQueue = PartyQueue(),
        maxMembers: Int = 5,
        hostOnlyControl: Bool = false
    ) -> PartyMembership {
        PartyMembership(
            code: code, token: token, you: you,
            party: PartySnapshot(
                code: code, maxMembers: maxMembers, hostOnlyControl: hostOnlyControl,
                members: members ?? [
                    PartyMember(memberId: "m-1", displayName: "Host", isHost: true, connected: true),
                    you,
                ],
                playback: playback, queue: queue))
    }

    static func track(_ id: String, autoplay: Bool = false) -> PartyTrack {
        PartyTrack(videoId: id, title: "Title \(id)", artist: "Artist", fromAutoplay: autoplay)
    }
}

/// Injectable monotonic timeline without captured-var warnings.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64

    init(now: Int64) { _now = now }

    var now: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _now
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _now = newValue
        }
    }
}
