import Foundation
import VibraMusicCore

// Ports playback/Autoplay.kt and the AutoPlay constants of PlaybackService.kt.

/// Where AutoPlay and "Start radio" get related songs.
///
/// Declared here because PlaybackQueue depends only on Core. The app backs it with InnerTube's
/// radio (YouTube Music's `RDAMVM<videoId>` watch queue) and, for source-backed tracks, with a
/// Sources/InnerTube search that finds the track's YouTube counterpart.
public protocol AutoplayRadioSource: Sendable {
    /// The YouTube id that should seed a station for `song`, or nil when it has none.
    ///
    /// Module tracks do not carry YouTube ids, so they are matched on YouTube before the radio
    /// request (Android's `youtubeSeedFor`). The default returns `song.videoId`, which is right for
    /// every catalogue row, and nil for a file on this device, whose id is a local URI.
    func youtubeSeed(for song: Song) async -> String?

    /// The related tracks YouTube Music's radio for `seedVideoId` lists, in order. Throws on a
    /// network or parse failure, which AutoPlay distinguishes from an empty station.
    func radio(seedVideoId: String) async throws -> [Song]
}

extension AutoplayRadioSource {
    /// Android passes a device file's `content://` id to YouTube's radio as it is, and the request
    /// fails every time the queue reaches one; there is no station to find for a local URI.
    public func youtubeSeed(for song: Song) async -> String? { song.isDeviceFile ? nil : song.videoId }
}

/// Loads, de-duplicates and tags AutoPlay batches and explicit stations.
public struct AutoplayLoader: Sendable {
    /// Most AutoPlay-suggested tracks kept queued ahead of the current one at once.
    public static let maxQueuedAutoplay = 10
    /// A full first page for an explicitly requested station ("Start radio"), before AutoPlay tops
    /// it up.
    public static let initialStationTracks = 24

    public let source: any AutoplayRadioSource

    public init(source: any AutoplayRadioSource) {
        self.source = source
    }

    /// Loads one batch related to `seedSong`: nothing already in `existing`, no recording twice, no
    /// artist taking over (see ``QueueBuilder``), at most `limit` tracks. Each comes back as a fresh
    /// AUTOPLAY entry carrying the seed's station name and "Playing from" source, so the whole
    /// station keeps naming itself after skips.
    ///
    /// An empty result (no YouTube seed, or nothing new in the mix) is not an error; a failed radio
    /// request throws.
    public func loadTracks(existing: [Song], seedSong: Song, limit: Int = maxQueuedAutoplay) async throws -> [Song] {
        guard let seed = await source.youtubeSeed(for: seedSong) else { return [] }
        let related = try await source.radio(seedVideoId: seed)
        return QueueBuilder.extend(existing: existing, candidates: related, limit: limit).map { song in
            var tagged = song
            tagged.radioName = seedSong.radioName
            tagged.playbackSource = seedSong.playbackSource
            tagged.playbackSourceType = seedSong.playbackSourceType
            tagged.playbackSourceId = seedSong.playbackSourceId
            return tagged.asQueueEntry(.autoplay)
        }
    }
}

/// What AutoPlay needs to know about a Listen Together party. The app fills it from
/// ListenTogether's state (PlaybackQueue does not depend on that module).
public struct AutoplayPartyContext: Hashable, Sendable {
    public struct Member: Hashable, Sendable {
        public var memberId: String
        public var isHost: Bool
        public var connected: Bool

        public init(memberId: String, isHost: Bool = false, connected: Bool = true) {
            self.memberId = memberId
            self.isHost = isHost
            self.connected = connected
        }
    }

    /// The party code; nil outside a party.
    public var code: String?
    /// This device's member id.
    public var yourMemberId: String?
    public var members: [Member]
    /// The party's own AutoPlay switch, which overrides this phone's while in the party.
    public var partyAutoplayEnabled: Bool
    /// The host has locked the party to their own controls.
    public var hostOnlyControl: Bool
    /// This device is a listener in a party its host controls: queue edits are refused.
    public var controlsLocked: Bool
    /// The party's canonical queue after its current track, as queue songs (manual tracks
    /// `.userQueue`, AutoPlay's `.autoplay`). A tap on a song while in a party keeps only the manual ones.
    public var upcomingTracks: [Song]

    /// Not in a party.
    public static let solo = AutoplayPartyContext()

    public init(
        code: String? = nil,
        yourMemberId: String? = nil,
        members: [Member] = [],
        partyAutoplayEnabled: Bool = true,
        hostOnlyControl: Bool = false,
        controlsLocked: Bool = false,
        upcomingTracks: [Song] = []
    ) {
        self.code = code
        self.yourMemberId = yourMemberId
        self.members = members
        self.partyAutoplayEnabled = partyAutoplayEnabled
        self.hostOnlyControl = hostOnlyControl
        self.controlsLocked = controlsLocked
        self.upcomingTracks = upcomingTracks
    }

    public var inParty: Bool { code != nil }
}

/// The questions AutoPlay asks before it does anything.
public enum AutoplayPolicy {
    /// Most tracks a party member may have queued ahead of the party's current one.
    public static let maxPartyUpcoming = 25

    /// How long a party supplier waits for its AutoPlay tracks to appear in the party's queue before
    /// treating them as refused. See ``PlaybackQueueController/partyAutoplaySupplier``.
    public static let partyQueueEchoTimeout: Duration = .seconds(5)

    /// A radio that came back empty or failed while the current track is the last one gets one
    /// more try after this long: bounded, so a radio with no usable unique songs doesn't turn into
    /// permanent background polling.
    public static let emptyRefreshDelay: Duration = .seconds(2)
    public static let maxEmptyRefreshes = 1

    /// Whether AutoPlay is on for the music this device is playing.
    ///
    /// In a party it is the party's setting and not this phone's: AutoPlay is shared there, so one
    /// member's preference can't be what decides. `localPreference` (AppSettings.autoplay) applies
    /// everywhere else. Shared by the queue and every surface that draws the toggle, because they
    /// went their own ways once and the result was a button that lied: the player read the local
    /// preference while the service obeyed the party's.
    public static func isEnabled(party: AutoplayPartyContext, localPreference: Bool) -> Bool {
        party.inParty ? party.partyAutoplayEnabled : localPreference
    }

    /// The one device in a party that tops the queue up, or nil if there is none.
    ///
    /// Everybody runs this over the same membership and gets the same answer, which is what stops
    /// five phones appending five different sets of suggestions to one queue. The host supplies
    /// while it is connected; otherwise the lowest connected member id takes over, chosen for being
    /// stable rather than for meaning anything.
    ///
    /// Except in a party locked to its host, where there is no stand-in: the server refuses a
    /// listener's `queueAdd` there (`host_only`), so electing one produced a control that was always
    /// refused. Returning nil lets AutoPlay wait for the host, which is the party's own policy.
    public static func supplierId(party: AutoplayPartyContext) -> String? {
        guard party.inParty else { return nil }
        let host = party.members.first { $0.isHost && $0.connected }?.memberId
        if party.hostOnlyControl { return host }
        return host ?? party.members.filter(\.connected).map(\.memberId).min()
    }

    /// Whether AutoPlay should forget its last seed and try the current track again.
    ///
    /// A completed load normally leaves its seed behind to de-duplicate the several callbacks one
    /// queue edit causes. If the edit leaves the current track with nothing after it, though, the
    /// seed is no longer useful: keeping it would make an enabled AutoPlay queue stay empty forever.
    public static func queueNeedsRefresh(
        enabled: Bool,
        repeatAll: Bool,
        currentIndex: Int,
        itemCount: Int,
        loadInProgress: Bool
    ) -> Bool {
        enabled && !repeatAll && !loadInProgress && currentIndex >= 0 && currentIndex == itemCount - 1
    }
}
