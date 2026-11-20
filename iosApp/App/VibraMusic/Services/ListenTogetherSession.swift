import VibraMusicCore
import Foundation
import ListenTogether
import Observation
import Playback
import PlaybackQueue

// Ports the app side of Listen Together that MainActivity.kt and PlaybackService.kt spread
// between them: the party's state drives the queue's party context and the player, the sync
// coordinator starts on joining and stops on leaving, and the personal queue is put aside for the
// party and given back after it.

/// Listen Together for the UI: one observable over the party client and its sync coordinator.
///
/// The Social screens read ``state`` (code, members, host, playback, connection) and call the
/// operations here; everything else — the queue's party context, the player's party mode, starting
/// and stopping the sync, the personal-queue stash — follows from the state stream by itself, so a
/// party ended by the server (kicked, the party closed) cleans up exactly like a leave.
@MainActor
@Observable
final class ListenTogetherSession {
    /// The party as the client last reported it.
    private(set) var state = PartySessionState()
    /// The party's recent events (joins, leaves, skips), newest first.
    private(set) var activity: [PartyActivity] = []
    /// A create/join/leave is in flight.
    private(set) var isBusy = false
    /// The last create/join failure, for the screen to show; cleared by the next attempt.
    private(set) var lastError: PartyClientError?

    @ObservationIgnored let client: PartyClient
    @ObservationIgnored let sync: PartySyncCoordinator
    @ObservationIgnored private weak var player: PlayerController?
    @ObservationIgnored private var queue: PlaybackQueueController? { player?.queue }
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var lastCode: String?
    /// Whether the sync coordinator is running (tests).
    @ObservationIgnored private(set) var isSyncing = false

    init(client: PartyClient, sync: PartySyncCoordinator, player: PlayerController) {
        self.client = client
        self.sync = sync
        self.player = player
        bindPlayer(player)
    }

    // MARK: What the UI reads

    var inParty: Bool { state.inParty }
    var code: String? { state.code }
    var members: [PartyMember] { state.members }
    var you: PartyMember? { state.you }
    var isHost: Bool { state.you?.isHost == true }
    var host: PartyMember? { state.members.first { $0.isHost } }
    /// A listener in a party its host has locked: transport and queue edits are refused.
    var controlsLocked: Bool { state.controlsLocked }
    var connection: PartyConnection { state.connection }
    var isFull: Bool { state.isFull }

    // MARK: Lifecycle

    /// Follows the client's state for the life of the app. Call once at launch.
    func start() {
        guard stateTask == nil else { return }
        let client = self.client
        stateTask = Task { @MainActor [weak self] in
            await client.start()
            for await state in await client.stateStream() {
                guard let self else { return }
                await self.apply(state)
            }
        }
    }

    // MARK: Membership

    @discardableResult
    func createParty(nickname: String? = nil, maxMembers: Int = PartyLimits.defaultMaxMembers, autoplayEnabled: Bool? = nil) async -> Result<String, PartyClientError> {
        await run { [client, player] in
            await client.createParty(nickname: nickname, maxMembers: maxMembers,
                                     autoplayEnabled: autoplayEnabled ?? player?.settings.autoplay ?? true)
        }
    }

    @discardableResult
    func joinParty(code: String, nickname: String? = nil) async -> Result<String, PartyClientError> {
        await run { [client] in await client.joinParty(code: code, nickname: nickname) }
    }

    /// Moves to another party (an invite while already in one): the current membership is kept
    /// if the target refuses.
    func switchParty(server: String, code: String, nickname: String? = nil) async -> PartySwitchResult {
        isBusy = true
        defer { isBusy = false }
        let result = await client.switchParty(targetServer: server, targetCode: code, nickname: nickname)
        await apply(await client.state)
        return result
    }

    func leaveParty() async {
        isBusy = true
        defer { isBusy = false }
        await client.leaveParty()
        await apply(await client.state)
    }

    /// Who is in a party, before joining it (the invite sheet).
    func preview(code: String, server: String? = nil) async -> Result<PartyPreview, PartyClientError> {
        await client.previewParty(code: code, server: server)
    }

    private func run(_ body: @escaping () async -> Result<String, PartyClientError>) async -> Result<String, PartyClientError> {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        let result = await body()
        if case .failure(let error) = result { lastError = error }
        // The stream will say the same a moment later; applying it now means the screen that
        // awaited this sees the party at once.
        await apply(await client.state)
        return result
    }

    // MARK: Host controls

    func kick(_ member: PartyMember) { Task { [client] in await client.kick(memberId: member.memberId) } }
    func setHostOnlyControl(_ enabled: Bool) { Task { [client] in await client.setHostOnlyControl(enabled) } }
    func setMaxMembers(_ value: Int) { Task { [client] in await client.setMaxMembers(value) } }
    func setAutoplay(_ enabled: Bool) { Task { [client] in await client.setAutoplay(enabled) } }
    func setNickname(_ value: String) { Task { [client] in await client.setNickname(value) } }

    /// A row of the queue is being dragged: its moves are published once, when it lands.
    func beginQueueDrag() { Task { [sync] in await sync.beginQueueDrag() } }
    func endQueueDrag() { Task { [sync] in await sync.endQueueDrag() } }

    // MARK: State → queue and player

    /// The state being applied, so the next waits for it (see ``apply(_:)``).
    @ObservationIgnored private var applying: Task<Void, Never>?

    /// Applies one party state: the queue's party context, the player's party mode, and on a
    /// change of party the stash hand-off and the sync coordinator's start or stop.
    ///
    /// States are applied one at a time, in order. Entering and leaving each await the
    /// coordinator, and the stream and a create/join/leave both apply states: interleaved, a kick
    /// arriving while the join was still stashing the personal queue would stop the sync first
    /// and then have the join start it again, leaving the phone in party mode outside any party.
    func apply(_ state: PartySessionState) async {
        let before = applying
        let task = Task { @MainActor [weak self] in
            await before?.value
            await self?.applyInOrder(state)
        }
        applying = task
        await task.value
    }

    private func applyInOrder(_ state: PartySessionState) async {
        self.state = state
        let previous = lastCode
        let current = state.code
        lastCode = current
        activity = await client.activity

        if previous == nil, current != nil {
            // Entering: the personal queue is put aside before the party's is installed (the
            // coordinator's first reconcile installs it), then the party is followed.
            await sync.notePartyCodeChanged(previous: previous, current: current)
            queue?.party = Self.context(from: state)
            player?.isInParty = true
            await sync.start()
            isSyncing = true
        } else if previous != nil, current == nil {
            await sync.stop()
            isSyncing = false
            await sync.notePartyCodeChanged(previous: previous, current: nil)
            // Out of the party first, so the returning queue becomes the restart snapshot again.
            queue?.party = .solo
            player?.isInParty = false
            _ = queue?.restorePersonalQueueAfterParty()
        } else if current != nil {
            if previous != current {
                // Switched straight from one party to another.
                await sync.notePartyCodeChanged(previous: previous, current: current)
            }
            queue?.party = Self.context(from: state)
            player?.isInParty = true
        } else {
            if queue?.party.inParty == true { queue?.party = .solo }
            player?.isInParty = false
        }
    }

    /// The party as AutoPlay and the queue need it: membership for the supplier election, the
    /// party's own AutoPlay switch, the host lock, and the party's queue after its current track.
    static func context(from state: PartySessionState) -> AutoplayPartyContext {
        guard state.inParty else { return .solo }
        let upcoming: [Song]
        let items = state.queue.items
        if items.indices.contains(state.queue.index) {
            upcoming = items[(state.queue.index + 1)...].map(PartyTrackMapping.toSong)
        } else if state.queue.index < 0 {
            upcoming = items.map(PartyTrackMapping.toSong)
        } else {
            upcoming = []
        }
        return AutoplayPartyContext(
            code: state.code,
            yourMemberId: state.you?.memberId,
            members: state.members.map { AutoplayPartyContext.Member(memberId: $0.memberId, isHost: $0.isHost, connected: $0.connected) },
            partyAutoplayEnabled: state.playback.autoplayEnabled,
            hostOnlyControl: state.hostOnlyControl,
            controlsLocked: state.controlsLocked,
            upcomingTracks: upcoming
        )
    }

    // MARK: Player hooks

    private func bindPlayer(_ player: PlayerController) {
        let client = self.client
        let sync = self.sync
        // Every queue edit the listener makes is published to the party (debounced there).
        player.queue.onLocalIntent = { Task { await sync.noteLocalIntent() } }
        player.queue.partyAutoplayToggle = { enabled in Task { await client.setAutoplay(enabled) } }
        // AutoPlay's tracks go to the party, and count as taken once the party's queue shows them.
        player.queue.partyAutoplaySupplier = { songs in
            let tracks = songs.map { song -> PartyTrack in
                var track = PartyTrackMapping.toPartyTrack(song, playerDurationMs: 0)
                track.fromAutoplay = true
                return track
            }
            await client.queueAdd(tracks)
            let wanted = Set(tracks.map(\.videoId))
            let seconds = Double(AutoplayPolicy.partyQueueEchoTimeout.components.seconds)
            return await client.waitUntil(timeoutSeconds: seconds) { state in
                !wanted.isDisjoint(with: state.queue.items.map(\.videoId))
            }
        }
        // Play, pause and seek (Android's SessionPlayer): a locked listener's press moves only
        // this device; anyone else's is published, and a play waits for the party's start.
        player.partyTransport = { playing in
            if playing { await sync.notePlayPress() }
            if await sync.onLockedTransport(playing: playing) { return true }
            await sync.noteLocalIntent(paused: !playing)
            if playing, await sync.shouldDeferPlay() { return true }
            return false
        }
        player.partySeekIntent = { Task { await sync.noteLocalIntent() } }
        // A call, Siri or unplugged headphones pausing the engine is not the listener's press: stop following until they
        // ask back (and not resume a device the system chose to leave silent), as Android does.
        player.engine.onAudioSessionEvent = { event in
            switch event {
            case .interruptionBegan, .outputDeviceUnavailable: Task { await sync.noteExternalPause() }
            case .interruptionEnded(shouldResume: true): Task { await sync.noteAudibleAgain() }
            default: break
            }
        }
        player.playedBy = { [weak self] song in
            guard let self, self.state.inParty else { return nil }
            let playback = self.state.playback
            guard playback.track?.videoId == song.videoId, playback.startedBy != self.state.you?.memberId else { return nil }
            return playback.startedByName
        }
    }
}
