import VibraMusicCore
import XCTest
@testable import ListenTogether

/// A scriptable player for sync tests: holds a queue and transport, records every command.
final class FakePartyBridge: PartyPlayerBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: PartyPlayerSnapshot?
    var commands: [String] = []
    var loaded: [(tracks: [PartyTrack], index: Int, positionMs: Int64, startPlaying: Bool)] = []
    /// False makes a load change nothing and report so, as a bridge whose player is gone would.
    var appliesLoads = true

    init(snapshot: PartyPlayerSnapshot? = nil) {
        _snapshot = snapshot
    }

    var current: PartyPlayerSnapshot? {
        get { lock.withLock { _snapshot } }
        set { lock.withLock { _snapshot = newValue } }
    }

    func snapshot() async -> PartyPlayerSnapshot? { current }

    func load(tracks: [PartyTrack], index: Int, positionMs: Int64, startPlaying: Bool) async -> Bool {
        lock.withLock {
            commands.append("load")
            guard appliesLoads else { return false }
            loaded.append((tracks, index, positionMs, startPlaying))
            _snapshot = PartyPlayerSnapshot(
                songs: tracks.map(PartyTrackMapping.toSong),
                currentIndex: index, positionMs: positionMs,
                isPlaying: startPlaying, isReady: true)
            return true
        }
    }

    func play() async {
        lock.withLock {
            commands.append("play")
            _snapshot?.isPlaying = true
        }
    }

    func pause() async {
        lock.withLock {
            commands.append("pause")
            _snapshot?.isPlaying = false
        }
    }

    func seek(to positionMs: Int64) async {
        lock.withLock {
            commands.append("seek:\(positionMs)")
            _snapshot?.positionMs = positionMs
        }
    }

    func setUpcoming(_ tracks: [PartyTrack]) async {
        lock.withLock { commands.append("setUpcoming:\(tracks.count)") }
        guard var snap = current, snap.songs.indices.contains(snap.currentIndex) else { return }
        snap.songs = Array(snap.songs[...snap.currentIndex]) + tracks.map(PartyTrackMapping.toSong)
        current = snap
    }

    func appendUpcoming(_ tracks: [PartyTrack]) async {
        lock.withLock { commands.append("appendUpcoming:\(tracks.count)") }
        guard var snap = current else { return }
        snap.songs += tracks.map(PartyTrackMapping.toSong)
        current = snap
    }

    func trimUpcoming(toCount: Int) async {
        lock.withLock { commands.append("trimUpcoming:\(toCount)") }
        guard var snap = current, snap.songs.indices.contains(snap.currentIndex) else { return }
        snap.songs = Array(snap.songs[..<(snap.currentIndex + 1 + toCount)])
        current = snap
    }

    func moveUpcoming(from: Int, to: Int) async {
        lock.withLock { commands.append("moveUpcoming:\(from)->\(to)") }
    }
}

final class FakePartyStash: PartyQueueStashing, @unchecked Sendable {
    private let lock = NSLock()
    private var _stashed: (songs: [Song], index: Int)?

    var stashed: (songs: [Song], index: Int)? { lock.withLock { _stashed } }

    func stash(songs: [Song], index: Int, positionMs: Int64, isPlaying: Bool) async {
        lock.withLock { _stashed = (songs, index) }
    }

    func loadStash() async -> PartyStashedQueue? { nil }
    func clearStash() async {}
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// The sync engine against a fake player: following the party in, holding a local pause in
/// a locked party, and publishing local intents out.
final class PartySyncCoordinatorTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(videoId: id, title: "T \(id)", artist: "A")
    }

    private func setup(
        playback: PartyPlayback,
        queue: PartyQueue = PartyQueue(),
        hostOnly: Bool = false,
        bridgeSnapshot: PartyPlayerSnapshot? = nil
    ) async throws -> (PartyClient, FakePartyBridge, PartySyncCoordinator) {
        let (store, _) = try PartyTestFixtures.makeStore()
        let client = PartyTestFixtures.makeClient(store: store)
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership(
                playback: playback, queue: queue, hostOnlyControl: hostOnly))
        let bridge = FakePartyBridge(snapshot: bridgeSnapshot)
        let coordinator = PartySyncCoordinator(client: client, bridge: bridge)
        return (client, bridge, coordinator)
    }

    func testFollowsHostPause() async throws {
        let track = PartyTestFixtures.track("a")
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: track, isPlaying: false, positionMs: 5_000),
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 8_000, isPlaying: true))
        await coordinator.reconcile(party: client.state)
        XCTAssertTrue(bridge.commands.contains("pause"))
        XCTAssertTrue(bridge.commands.contains("seek:5000"))
    }

    /// A scheduled start is the server's anchor, which decoding bounds at 2^53 ms. Waiting
    /// for one past about 1.8e13 ms overflowed the conversion to nanoseconds, which traps.
    func testAStartScheduledFarAheadWaitsWithoutTrapping() async throws {
        let (store, _) = try PartyTestFixtures.makeStore()
        let clock = PartyServerClock(monotonicMs: { 0 })
        let client = PartyClient(store: store, urlSession: .shared, clock: clock)
        let track = PartyTestFixtures.track("a")
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership(
                playback: PartyPlayback(seq: 2, track: track, isPlaying: true, positionMs: 0, anchorMs: partyMaxExactInteger)))
        clock.record(sentAtLocalMs: 0, serverMs: 1_000, receivedAtLocalMs: 0)  // joining resets the clock
        let bridge = FakePartyBridge(snapshot: PartyPlayerSnapshot(
            songs: [song("a")], currentIndex: 0, positionMs: 0, isPlaying: false))
        let coordinator = PartySyncCoordinator(client: client, bridge: bridge)
        var party = await client.state
        party.clockSynced = true
        await coordinator.reconcile(party: party)
        try await Task.sleep(nanoseconds: 300_000_000)  // the wait's task runs here; it trapped
        XCTAssertFalse(bridge.commands.contains("play"), "the start is still ahead")
    }

    func testLoadsNewTrackWithPartyQueue() async throws {
        let queue = PartyQueue(seq: 1, index: 1, items: [
            PartyTestFixtures.track("a"), PartyTestFixtures.track("b"), PartyTestFixtures.track("c"),
        ])
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: PartyTestFixtures.track("b"), isPlaying: false),
            queue: queue,
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("zzz")], currentIndex: 0, positionMs: 0, isPlaying: false))
        await coordinator.reconcile(party: client.state)
        XCTAssertEqual(1, bridge.loaded.count)
        XCTAssertEqual(["a", "b", "c"], bridge.loaded[0].tracks.map(\.videoId))
        XCTAssertEqual(1, bridge.loaded[0].index)
    }

    func testALoadThePlayerCouldNotApplyIsTriedAgainOnTheNextReconcile() async throws {
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: PartyTestFixtures.track("b"), isPlaying: false),
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("zzz")], currentIndex: 0, positionMs: 0, isPlaying: false))
        bridge.appliesLoads = false
        await coordinator.reconcile(party: client.state)
        await coordinator.reconcile(party: client.state)
        XCTAssertEqual(2, bridge.commands.filter { $0 == "load" }.count, "a refused load is not left pending")

        bridge.appliesLoads = true
        await coordinator.reconcile(party: client.state)
        XCTAssertEqual("b", bridge.loaded.first?.tracks.first?.videoId)
    }

    func testLockedTransportPausesLocallyWithoutPublishing() async throws {
        let track = PartyTestFixtures.track("a")
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: track, isPlaying: true, positionMs: 1_000),
            hostOnly: true,
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 1_000, isPlaying: true))
        let published = PublishedActions()
        await client.setControlSink { published.append($0.action) }
        let handledLockedPause = await coordinator.onLockedTransport(playing: false)
        XCTAssertTrue(handledLockedPause)
        XCTAssertTrue(bridge.commands.contains("pause"))
        // And reconcile leaves the muted device alone instead of pressing play again.
        await coordinator.reconcile(party: client.state)
        XCTAssertFalse(bridge.commands.contains("play"))
        XCTAssertTrue(published.values.isEmpty)
    }

    func testPublishesLocalPause() async throws {
        let track = PartyTestFixtures.track("a")
        let (client, _, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: track, isPlaying: true, positionMs: 1_000, anchorMs: 1_000),
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 1_050, isPlaying: false))
        let published = PublishedActions()
        await client.setControlSink { published.append($0.action) }
        await coordinator.noteLocalIntent()
        let done = await client.waitUntil(timeoutSeconds: 5) { _ in !published.values.isEmpty }
        XCTAssertTrue(done)
        // The empty party queue is healed first, then the pause goes out.
        XCTAssertEqual([.setQueue, .pause], published.values)
    }

    /// Live and clock-synced, which is what lets a play press be deferred to the party's start.
    private func liveSetup() async throws -> (PartyClient, FakePartyBridge, PartySyncCoordinator) {
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: PartyTestFixtures.track("a"), isPlaying: true, positionMs: 1_000, anchorMs: 1_000),
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 1_050, isPlaying: false))
        await client.receiveForTesting(
            #"{"type":"welcome","party":{"code":"J4M001","maxMembers":5,"hostOnlyControl":false,"members":[{"memberId":"m-2","displayName":"Guest","isHost":false,"connected":true}],"playback":{"seq":2,"track":{"videoId":"a"},"queueSeq":0,"queueIndex":-1,"isPlaying":true,"positionMs":1000,"anchorMs":1000},"queue":{"seq":0,"index":-1,"items":[]}}}"#)
        await client.receiveForTesting(#"{"type":"pong","clientMs":10000,"serverMs":50000}"#)
        return (client, bridge, coordinator)
    }

    func testAPausePressedWhileAPlayIsDeferredIsPublishedAndEndsTheWait() async throws {
        let (client, _, coordinator) = try await liveSetup()
        let published = PublishedActions()
        await client.setControlSink { published.append($0.action) }
        await coordinator.notePlayPress()
        await coordinator.noteLocalIntent()
        let deferred = await coordinator.shouldDeferPlay()
        XCTAssertTrue(deferred)
        let waiting = await client.awaitingStart
        XCTAssertTrue(waiting)

        await coordinator.noteLocalIntent(paused: true)

        let done = await client.waitUntil(timeoutSeconds: 5) { _ in !published.values.isEmpty }
        XCTAssertTrue(done)
        let stillWaiting = await client.awaitingStart
        XCTAssertFalse(stillWaiting)
        XCTAssertEqual([.setQueue, .pause], published.values)
    }

    /// The two presses are separate tasks, so the pause can run to the end between the play's
    /// intent and its deferral; the pause was still the last word.
    func testAPauseThatLandsBeforeTheDeferralIsArmedLeavesNoWaitBehind() async throws {
        let (client, bridge, coordinator) = try await liveSetup()
        await coordinator.notePlayPress()
        await coordinator.noteLocalIntent()
        await coordinator.noteLocalIntent(paused: true)

        let swallowed = await coordinator.shouldDeferPlay()

        XCTAssertTrue(swallowed, "the play press is dropped, not started under the pause")
        let waiting = await client.awaitingStart
        XCTAssertFalse(waiting)
        XCTAssertFalse(bridge.commands.contains("play"))
    }

    func testALockedListenersPauseEndsADeferredPlayArmedBeforeTheLock() async throws {
        let (client, _, coordinator) = try await liveSetup()
        await coordinator.notePlayPress()
        await coordinator.noteLocalIntent()
        let deferred = await coordinator.shouldDeferPlay()
        XCTAssertTrue(deferred)
        // The host turns on host-only control while that play still waits on the party.
        await client.receiveForTesting(
            #"{"type":"members","members":[{"memberId":"m-1","displayName":"Host","isHost":true,"connected":true},{"memberId":"m-2","displayName":"Guest","isHost":false,"connected":true}],"maxMembers":5,"hostOnlyControl":true}"#)

        let handled = await coordinator.onLockedTransport(playing: false)

        XCTAssertTrue(handled)
        let waiting = await client.awaitingStart
        XCTAssertFalse(waiting)
    }

    func testPlayingAgainInALockedPartyBringsAnInterruptedDeviceBackToFollowing() async throws {
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: PartyTestFixtures.track("a"), isPlaying: false, positionMs: 1_000),
            hostOnly: true,
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 1_000, isPlaying: false))
        await coordinator.noteExternalPause()
        _ = await coordinator.onLockedTransport(playing: true)
        var party = await client.state
        party.playback.seq = 3
        party.playback.track = PartyTestFixtures.track("b")
        await coordinator.reconcile(party: party)
        XCTAssertEqual("b", bridge.loaded.first?.tracks.first?.videoId, "following the party again")
    }

    func testADeviceSilencedByAnInterruptionIsNotPlayedAgainByTheParty() async throws {
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: PartyTestFixtures.track("a"), isPlaying: true, positionMs: 1_000),
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 1_000, isPlaying: false))
        await coordinator.noteExternalPause()
        var party = await client.state
        party.clockSynced = true
        await coordinator.reconcile(party: party)
        XCTAssertFalse(bridge.commands.contains("play"))
        // The listener asking for the music back follows the party again.
        await coordinator.noteAudibleAgain()
        await coordinator.reconcile(party: party)
        XCTAssertTrue(bridge.commands.contains("play"))
    }

    func testPublishesTheDecoderDurationRatherThanTheCatalogueOne() async throws {
        let (client, _, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: PartyTestFixtures.track("b"), isPlaying: true),
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 1_050,
                currentDurationMs: 123_456, isPlaying: true))
        let published = PublishedActions()
        await client.setControlSink { published.append($0) }

        await coordinator.noteLocalIntent()
        let sent = await client.waitUntil(timeoutSeconds: 5) { _ in
            published.messages.contains { $0.action == .setTrack }
        }

        XCTAssertTrue(sent)
        XCTAssertEqual(123_456, published.messages.first { $0.action == .setTrack }?.track?.durationMs)
    }

    func testDeviceFileDecouplesBothDirections() async throws {
        let track = PartyTestFixtures.track("a")
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: track, isPlaying: true, positionMs: 1_000),
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("content://media/1")], currentIndex: 0, positionMs: 1_000, isPlaying: true))
        await coordinator.reconcile(party: client.state)
        XCTAssertFalse(bridge.commands.contains("load"))
    }

    func testEnteringAPartyStashesTheIndexOfTheCurrentSongWithDeviceFilesLeftOut() async throws {
        let (store, _) = try PartyTestFixtures.makeStore()
        let client = PartyTestFixtures.makeClient(store: store)
        let bridge = FakePartyBridge(snapshot: PartyPlayerSnapshot(
            songs: [song("content://media/1"), song("a"), song("b"), song("c")], currentIndex: 2, positionMs: 1_000, isPlaying: true))
        let stash = FakePartyStash()
        let coordinator = PartySyncCoordinator(client: client, bridge: bridge, stash: stash)
        await coordinator.notePartyCodeChanged(previous: nil, current: "J4M001")
        XCTAssertEqual(["a", "b", "c"], stash.stashed?.songs.map(\.videoId))
        XCTAssertEqual(1, stash.stashed?.index)
    }

    func testLockedListenerPausedLocallyStaysPausedWhenThePartyChangesTrack() async throws {
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: PartyTestFixtures.track("a"), isPlaying: true, positionMs: 1_000),
            hostOnly: true,
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 1_000, isPlaying: true))
        _ = await coordinator.onLockedTransport(playing: false)
        var party = await client.state
        party.playback.seq = 3
        party.playback.track = PartyTestFixtures.track("b")
        party.clockSynced = true
        await coordinator.reconcile(party: party)
        XCTAssertEqual("b", bridge.loaded.first?.tracks.first?.videoId)
        XCTAssertEqual(false, bridge.loaded.first?.startPlaying)
    }

    func testLeavingDropsALocalPauseSoTheNextLockedPartyIsFollowed() async throws {
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: PartyTestFixtures.track("a"), isPlaying: true, positionMs: 1_000),
            hostOnly: true,
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 1_000, isPlaying: true))
        _ = await coordinator.onLockedTransport(playing: false)
        await coordinator.notePartyCodeChanged(previous: "J4M001", current: nil)
        // Next locked party: its host pauses while this device plays.
        bridge.current?.isPlaying = true
        bridge.commands = []
        var party = await client.state
        party.playback.isPlaying = false
        await coordinator.reconcile(party: party)
        XCTAssertTrue(bridge.commands.contains("pause"))
    }

    func testQuietWindowLiftsOnceTheLocalControlsComeBack() async throws {
        let track = PartyTestFixtures.track("a")
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: track, isPlaying: true, positionMs: 1_000, anchorMs: 1_000),
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 1_050, isPlaying: false))
        let published = PublishedActions()
        await client.setControlSink { published.append($0.action) }
        await coordinator.noteLocalIntent()
        let sent = await client.waitUntil(timeoutSeconds: 5) { _ in published.values.count == 2 }
        XCTAssertTrue(sent)
        // Both echoes are in, and somebody else has since moved the paused party on.
        var party = await client.state
        party.queue.seq += 1
        party.playback.seq = 4
        party.playback.isPlaying = false
        party.playback.positionMs = 9_000
        // Well inside the 4.5 s quiet window an unanswered control would hold.
        for _ in 0 ..< 40 where !bridge.commands.contains("seek:9000") {
            await coordinator.reconcile(party: party)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(bridge.commands.contains("seek:9000"))
    }

    /// Polls for a command for less than one tick (`PartyLimits.tickMs`, 700 ms), by the clock
    /// rather than by iterations so a slow sleep cannot stretch it, so only a reconcile driven by
    /// the state change itself can satisfy it.
    private func commandWithinATick(_ command: String, on bridge: FakePartyBridge) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        while !bridge.commands.contains(command), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return bridge.commands.contains(command)
    }

    func testTheFirstPongStartsADeviceThatJoinedAPlayingPartyWithoutWaitingForATick() async throws {
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: PartyTestFixtures.track("a"), isPlaying: true, positionMs: 1_000, anchorMs: 1_000),
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 1_050, isPlaying: false))
        await coordinator.start()
        await client.receiveForTesting(#"{"type":"pong","clientMs":10000,"serverMs":50000}"#)
        let started = try await commandWithinATick("play", on: bridge)
        await coordinator.stop()
        XCTAssertTrue(started)
    }

    func testARemoteControlIsFollowedAtOnceAndEndsTheQuietWindowOnTheEcho() async throws {
        let (client, bridge, coordinator) = try await setup(
            playback: PartyPlayback(seq: 2, track: PartyTestFixtures.track("a"), isPlaying: true, positionMs: 1_000, anchorMs: 1_000),
            bridgeSnapshot: PartyPlayerSnapshot(
                songs: [song("a")], currentIndex: 0, positionMs: 1_050, isPlaying: false))
        let published = PublishedActions()
        await client.setControlSink { published.append($0.action) }
        await coordinator.noteLocalIntent()
        let sent = await client.waitUntil(timeoutSeconds: 5) { _ in published.values.count == 2 }
        XCTAssertTrue(sent)
        // Started only now, so the first tick is still 700 ms away when the echoes arrive.
        await coordinator.start()
        // Both echoes land, the second carrying a pause somebody else pressed: the quiet window
        // (4.5 s) would otherwise keep this device deaf to it.
        await client.receiveForTesting(#"{"type":"queue","queue":{"seq":1,"index":-1,"items":[]}}"#)
        await client.receiveForTesting(
            #"{"type":"state","playback":{"seq":4,"track":{"videoId":"a"},"queueSeq":1,"queueIndex":-1,"isPlaying":false,"positionMs":9000,"anchorMs":1000}}"#)
        let followed = try await commandWithinATick("seek:9000", on: bridge)
        await coordinator.stop()
        XCTAssertTrue(followed)
    }
}

private extension PartyClient {
    func setControlSink(_ sink: @escaping @Sendable (PartyControlMessage) -> Void) {
        controlSinkForTesting = sink
    }
}

/// Sendable action ledger for `@Sendable` control sinks.
final class PublishedActions: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [PartyControlAction] = []
    private var _messages: [PartyControlMessage] = []

    var values: [PartyControlAction] {
        lock.withLock { _values }
    }

    var messages: [PartyControlMessage] {
        lock.withLock { _messages }
    }

    func append(_ action: PartyControlAction) {
        lock.withLock { _values.append(action) }
    }

    func append(_ message: PartyControlMessage) {
        lock.withLock {
            _values.append(message.action)
            _messages.append(message)
        }
    }
}
