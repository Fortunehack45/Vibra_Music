import AVFoundation
import VibraMusicTestSupport
import ImageIO
import MediaPlayer
import UniformTypeIdentifiers
import XCTest
@testable import Playback

/// Lock-screen controls: remote commands reach the delegate (or the engine's defaults).
@MainActor
final class RemoteCommandTests: EngineTestCase {
    func testTheEngineRegistersAndReleasesItsHandler() {
        let h = harness()
        XCTAssertTrue(h.remote.isActive)
        h.engine.shutdown()
        XCTAssertFalse(h.remote.isActive)
    }

    func testCommandsAreForwardedToTheDelegate() async throws {
        let item = try tone(6, name: "remote-forward")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }

        h.delegate.commandResult = .success
        for command: RemoteCommand in [.pause, .play, .togglePlayPause, .nextTrack, .previousTrack,
                                       .changePlaybackPosition(3), .like(wasActive: false), .dislike(wasActive: true)] {
            XCTAssertEqual(h.remote.send(command), .success)
        }
        XCTAssertEqual(h.delegate.commands, [.pause, .play, .togglePlayPause, .nextTrack, .previousTrack,
                                             .changePlaybackPosition(3), .like(wasActive: false), .dislike(wasActive: true)])
        // The delegate took them all over, so the engine did nothing on its own.
        XCTAssertTrue(h.engine.playWhenReady)
        XCTAssertLessThan(h.engine.position, 2.5)
    }

    func testTheDefaultActionsDriveTheEngine() async throws {
        let first = try tone(6, name: "remote-default-1")
        let second = try tone(3, frequency: 550, name: "remote-default-2")
        let h = harness(queue: [first, second])
        h.engine.load(first, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }

        XCTAssertEqual(h.remote.send(.pause), .success)
        XCTAssertFalse(h.engine.playWhenReady)
        XCTAssertEqual(h.remote.send(.togglePlayPause), .success)
        XCTAssertTrue(h.engine.playWhenReady)
        XCTAssertEqual(h.remote.send(.changePlaybackPosition(4)), .success)
        XCTAssertEqual(h.engine.position, 4, accuracy: 0.01)
        XCTAssertEqual(h.remote.send(.skipBackward(15)), .success)
        XCTAssertEqual(h.engine.position, 0, accuracy: 0.01)
        XCTAssertEqual(h.remote.send(.changePlaybackRate(1.25)), .success)
        XCTAssertEqual(h.engine.rate, 1.25)
        XCTAssertEqual(h.remote.send(.like(wasActive: false)), .commandFailed, "rating needs the app")
        XCTAssertEqual(h.remote.send(.nextTrack), .success)
        XCTAssertEqual(h.engine.currentItem?.id, second.id)
        XCTAssertEqual(h.remote.send(.nextTrack), .noSuchContent, "nothing after the last track")
        XCTAssertEqual(h.delegate.commands.count, 8, "the recording delegate saw each one and fell back to the default")
    }

    func testWithoutADelegateTheEngineHandlesCommandsItself() async throws {
        let item = try tone(4, name: "remote-nodelegate")
        let h = harness(queue: [item])
        h.engine.delegate = nil
        XCTAssertEqual(h.remote.send(.play), .noActionableNowPlayingItem, "nothing loaded")
        h.engine.load(item, playWhenReady: true)
        XCTAssertEqual(h.remote.send(.pause), .success)
        XCTAssertFalse(h.engine.playWhenReady)
        XCTAssertEqual(h.remote.send(.play), .success)
        XCTAssertTrue(h.engine.playWhenReady)
    }

    func testFeedbackLightsTheLikeButtons() {
        let h = harness()
        h.engine.setFeedback(.like)
        XCTAssertEqual(h.remote.feedback.liked, true)
        XCTAssertEqual(h.remote.feedback.disliked, false)
        h.engine.setFeedback(.dislike)
        XCTAssertEqual(h.remote.feedback.liked, false)
        XCTAssertEqual(h.remote.feedback.disliked, true)
        h.engine.setFeedback(.indifferent)
        XCTAssertEqual(h.remote.feedback.liked, false)
        XCTAssertEqual(h.remote.feedback.disliked, false)
    }

    func testTheSystemCommandCenterMapsResults() {
        XCTAssertEqual(RemoteCommandResult.success.status, .success)
        XCTAssertEqual(RemoteCommandResult.noSuchContent.status, .noSuchContent)
        XCTAssertEqual(RemoteCommandResult.noActionableNowPlayingItem.status, .noActionableNowPlayingItem)
        XCTAssertEqual(RemoteCommandResult.commandFailed.status, .commandFailed)
        // Registering against the real center enables the commands and leaves skip-interval
        // buttons off (on iOS they would replace next/previous).
        let center = SystemRemoteCommandCenter()
        center.activate { _ in .success }
        let shared = MPRemoteCommandCenter.shared()
        XCTAssertTrue(shared.playCommand.isEnabled)
        XCTAssertTrue(shared.nextTrackCommand.isEnabled)
        XCTAssertTrue(shared.changePlaybackPositionCommand.isEnabled)
        XCTAssertTrue(shared.likeCommand.isEnabled)
        XCTAssertFalse(shared.skipForwardCommand.isEnabled)
        center.updateFeedback(isLiked: true, isDisliked: false)
        XCTAssertTrue(shared.likeCommand.isActive)
        center.deactivate()
        XCTAssertFalse(shared.playCommand.isEnabled)

        // Feedback commands can be left off to keep previous-track on the iPhone lock screen.
        let plain = SystemRemoteCommandCenter(showsFeedbackCommands: false)
        plain.activate { _ in .success }
        XCTAssertTrue(shared.previousTrackCommand.isEnabled)
        XCTAssertFalse(shared.likeCommand.isEnabled)
        XCTAssertFalse(shared.dislikeCommand.isEnabled)
        plain.deactivate()
    }
}

/// What the lock screen, Control Center and CarPlay show.
@MainActor
final class NowPlayingInfoTests: EngineTestCase {
    func testTheInfoDescribesTheItemAndItsProgress() async throws {
        let url = try ToneFile.tone(4, in: directory, name: "np-info")
        let item = PlayableItem(id: "np-1", title: "Song Title", artist: "The Artist", album: "The Album", source: .file(url))
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        await waitUntil("duration published") { h.nowPlaying.info?[MPMediaItemPropertyPlaybackDuration] != nil }

        let info = try XCTUnwrap(h.nowPlaying.info)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Song Title")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "The Artist")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "The Album")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0, 4, accuracy: 0.05)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String, "np-1")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyMediaType] as? UInt, MPNowPlayingInfoMediaType.audio.rawValue)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyAssetURL] as? URL, url)
        XCTAssertEqual(h.nowPlaying.lastState?.isPlaying, true)
        XCTAssertEqual(h.nowPlaying.lastState?.hasItem, true)

        // Paused: rate 0 so the lock screen clock stops, and the elapsed time is where it stopped.
        h.engine.pause()
        await waitUntil("paused") { !h.engine.isPlaying }
        let paused = try XCTUnwrap(h.nowPlaying.info)
        XCTAssertEqual(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(paused[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1, h.engine.position, accuracy: 0.15)
        XCTAssertEqual(h.nowPlaying.lastState?.isPlaying, false)

        // A seek is published at once.
        h.engine.seek(to: 2.5)
        XCTAssertEqual(h.nowPlaying.info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1, 2.5, accuracy: 0.01)
    }

    func testALyricLineCanStandInForTheArtist() async throws {
        let item = try tone(3, name: "np-lyric")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: false)
        h.engine.nowPlayingSubtitle = "♪ la la la"
        XCTAssertEqual(h.nowPlaying.info?[MPMediaItemPropertyArtist] as? String, "♪ la la la")
        h.engine.nowPlayingSubtitle = nil
        XCTAssertEqual(h.nowPlaying.info?[MPMediaItemPropertyArtist] as? String, "Test Artist")
    }

    func testArtworkIsFetchedAndAttached() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "art.example", path: "/cover.png", response: .data(try Self.png(width: 8, height: 6)))
        let url = try ToneFile.tone(3, in: directory, name: "np-art")
        let item = PlayableItem(id: "np-art", title: "T", artist: "A", artworkURL: URL(string: "https://art.example/cover.png"), source: .file(url))
        let h = harness(queue: [item], artworkSession: stub.makeSession())
        h.engine.load(item, playWhenReady: false)
        await waitUntil("artwork published") { h.nowPlaying.info?[MPMediaItemPropertyArtwork] != nil }
        let artwork = try XCTUnwrap(h.nowPlaying.info?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        XCTAssertEqual(artwork.bounds.size, CGSize(width: 8, height: 6))
    }

    func testStoppingClearsTheLockScreen() async throws {
        let item = try tone(3, name: "np-stop")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        XCTAssertNotNil(h.nowPlaying.info)
        h.engine.stop()
        XCTAssertNil(h.nowPlaying.info)
        XCTAssertEqual(h.nowPlaying.lastState?.hasItem, false)
    }

    func testTheBuilderOmitsWhatIsUnknown() {
        let item = PlayableItem(id: "x", title: "T", artist: "A", source: .asset { throw CancellationError() })
        let info = NowPlayingInfoBuilder.info(.init(item: item, position: -1, duration: 0, isPlaying: true, rate: 2, subtitleOverride: "", artwork: nil))
        XCTAssertNil(info[MPMediaItemPropertyAlbumTitle])
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration], "no duration until one is known")
        XCTAssertNil(info[MPNowPlayingInfoPropertyAssetURL])
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "A", "an empty override shows the artist")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 2)
    }

    /// System Now Playing surfaces must never receive a web URL or a server name. WebDAV, SMB and
    /// Files ids embed one (`webdav:https://…`, `smb:host/share/…`, `file://…`), and `AssetURL` is
    /// only ever a local file; a stream URL published there would be the other leak. Every
    /// non-YouTube id is published as a short stable hash, YouTube ids as they are.
    func testTheBuilderNeverPublishesAWebURL() {
        let fileURL = URL(fileURLWithPath: "/tmp/np-web-safe.mp3")
        let youtubeID = "abcdef12345|dQw4w9WgXcQ"
        let cases: [(id: String, hashed: Bool)] = [
            (youtubeID, false),
            ("dQw4w9WgXcQ", false),
            ("5d2f9c3e-8a41-4b6e-9f10-3c7a1e2b4d5f|dQw4w9WgXcQ#hifi-2", false),
            ("5d2f9c3e-8a41-4b6e-9f10-3c7a1e2b4d5f", false),
            ("file:///tmp/np-web-safe.mp3", true),
            ("webdav:https://host/a.mp3|webdav:https://host/a.mp3", true),
            ("smb:nas.local/Music/Artist/song.flac", true),
            ("content://media/external/audio/media/42", true),
            ("ipod-library://item/item.mp3?id=1", true),
        ]
        for (id, hashed) in cases {
            let source: PlayableItem.Source = id.hasPrefix("file:") ? .file(fileURL) : .asset { throw CancellationError() }
            let item = PlayableItem(id: id, title: "T", artist: "A", source: source)
            let info = NowPlayingInfoBuilder.info(.init(
                item: item, position: 0, duration: 0, isPlaying: true, rate: 1, subtitleOverride: nil, artwork: nil
            ))
            let published = info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String
            if hashed {
                let digits = published?.dropFirst(2) ?? ""
                XCTAssertTrue(published?.hasPrefix("h-") == true && digits.count == 16
                              && digits.allSatisfy(\.isHexDigit), "\(id) is published hashed, got \(published ?? "nil")")
                // A literal, so a change to the hash (it would orphan every id the system holds) fails.
                if id == "smb:nas.local/Music/Artist/song.flac" {
                    XCTAssertEqual(published, "h-a2206b6ea1b5f879", "the hash is stable")
                }
            } else {
                XCTAssertEqual(published, id, "a YouTube id is published unchanged")
            }
            for value in info.values {
                let text = (value as? String) ?? (value as? URL)?.absoluteString
                if let text {
                    XCTAssertFalse(text.contains("http://"), "web URL leaked into the info dictionary: \(text)")
                    XCTAssertFalse(text.contains("https://"), "web URL leaked into the info dictionary: \(text)")
                    XCTAssertFalse(text.contains("nas.local"), "server name leaked into the info dictionary: \(text)")
                }
            }
            if let asset = info[MPNowPlayingInfoPropertyAssetURL] {
                XCTAssertEqual((asset as? URL)?.isFileURL, true, "AssetURL must be a local file URL")
            }
        }
    }

    static func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// Interruptions and "headphones unplugged" — the iOS forms of Android's audio focus and
/// becoming-noisy handling. The events are fed by hand; on iOS the engine's session controller
/// feeds the same method from `AVAudioSession` notifications.
@MainActor
final class AudioSessionEventTests: EngineTestCase {
    func testAnInterruptionPausesAndResumesWhenTheSystemSaysSo() async throws {
        let item = try tone(6, name: "session-interrupt")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }

        h.engine.handleAudioSessionEvent(.interruptionBegan)
        XCTAssertFalse(h.engine.playWhenReady)
        await waitUntil("stopped") { !h.engine.isPlaying }
        h.engine.handleAudioSessionEvent(.interruptionEnded(shouldResume: true))
        XCTAssertTrue(h.engine.playWhenReady)
        await waitUntil("resumed") { h.engine.isPlaying }
    }

    func testEveryAudioSessionEventIsAlsoHandedToTheHost() async throws {
        let item = try tone(6, name: "session-host")
        let h = harness(queue: [item])
        var seen: [AudioSessionEvent] = []
        h.engine.onAudioSessionEvent = { seen.append($0) }
        h.engine.handleAudioSessionEvent(.interruptionBegan)
        h.engine.handleAudioSessionEvent(.interruptionEnded(shouldResume: false))
        XCTAssertEqual(seen, [.interruptionBegan, .interruptionEnded(shouldResume: false)])
    }

    func testAnInterruptionEndingWithoutTheHintStaysPaused() async throws {
        let item = try tone(6, name: "session-noresume")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        h.engine.handleAudioSessionEvent(.interruptionBegan)
        h.engine.handleAudioSessionEvent(.interruptionEnded(shouldResume: false))
        XCTAssertFalse(h.engine.playWhenReady)
    }

    func testAnInterruptionWhilePausedDoesNotStartPlayback() async throws {
        let item = try tone(6, name: "session-paused")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: false)
        h.engine.handleAudioSessionEvent(.interruptionBegan)
        h.engine.handleAudioSessionEvent(.interruptionEnded(shouldResume: true))
        XCTAssertFalse(h.engine.playWhenReady, "the listener had paused; an ended call must not start music")
    }

    func testPullingTheHeadphonesPausesForGood() async throws {
        let item = try tone(6, name: "session-noisy")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        h.engine.handleAudioSessionEvent(.outputDeviceUnavailable)
        XCTAssertFalse(h.engine.playWhenReady)
        await waitUntil("stopped") { !h.engine.isPlaying }
        // An interruption ending afterwards is no reason to start blaring out of the speaker.
        h.engine.handleAudioSessionEvent(.interruptionEnded(shouldResume: true))
        XCTAssertFalse(h.engine.playWhenReady)
    }

    func testAMediaServicesResetRebuildsThePlayersAndCarriesOn() async throws {
        let item = try tone(8, name: "session-reset")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying && h.engine.position > 1 }
        let before = h.engine.deck(.a).player
        h.engine.handleAudioSessionEvent(.mediaServicesReset)
        XCTAssertFalse(h.engine.deck(.a).player === before, "new players")
        XCTAssertEqual(h.engine.currentItem?.id, item.id)
        await waitUntil("playing again") { h.engine.isPlaying }
        XCTAssertGreaterThan(h.engine.position, 0.9, "from where it was, not from the top")
        XCTAssertEqual(h.delegate.changes.count, 1, "the same item, not announced again")
    }

    /// What AVFoundation does when media services restart: the item says so, as if it had failed.
    private func report(_ code: Int, on entry: DeckEntry) {
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: entry.playerItem,
                                        userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(domain: AVFoundationErrorDomain, code: code)])
    }

    /// Observed on an iPad: the playing and the queued item fail with `-11819` in the same
    /// millisecond, and the session's notification follows seconds later. The copy is opened again
    /// where it was, on new players, as one recovery that spends nothing.
    func testAResetTheItemsReportReopensTheSameItemWhereItWasOnNewPlayers() async throws {
        let item = try tone(10, name: "reset-items")
        let next = try tone(4, name: "reset-items-next")
        let h = harness(queue: [item, next])
        var reasons: [RecoveryReason] = []
        h.engine.sourceRecovery = { _, reason in
            reasons.append(reason)
            return nil
        }
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing, the next one queued") { h.engine.isPlaying && h.engine.position > 1 && h.engine.active.queued != nil }
        let reached = h.engine.position
        let before = h.engine.deck(.a).player

        // Read first: the first report empties the deck, and with it goes the second's listener.
        let current = try XCTUnwrap(h.engine.active.current)
        let queued = try XCTUnwrap(h.engine.active.queued)
        report(-11819, on: current)
        report(-11819, on: queued)

        await waitUntil("new players, playing") { h.engine.deck(.a).player !== before && h.engine.isPlaying }
        XCTAssertEqual(reasons, [.systemFault], "one recovery for both items, and never a retry")
        XCTAssertGreaterThanOrEqual(h.engine.position, reached - 0.5, "from where it was, not from the top")
        XCTAssertEqual(h.engine.currentItem?.id, item.id)
        XCTAssertEqual(h.delegate.changes.count, 1, "the same item, not announced again")
        XCTAssertEqual(h.engine.recovery.attemptCount(for: item.id), 0, "a reset spends none of the item's retries")
        XCTAssertTrue(h.delegate.failures.isEmpty, "nothing failed as far as the listener goes")
        XCTAssertNil(h.engine.lastError)
        await waitUntil("the next item queued again") { h.engine.active.queued?.item.id == next.id }

        // The notification arriving late finds the players it has to replace, and costs a reopen.
        let rebuilt = h.engine.deck(.a).player
        h.engine.handleAudioSessionEvent(.mediaServicesReset)
        await waitUntil("playing on again") { h.engine.deck(.a).player !== rebuilt && h.engine.isPlaying }
        XCTAssertGreaterThanOrEqual(h.engine.position, reached - 0.5)
        XCTAssertEqual(reasons, [.systemFault, .systemFault])
        XCTAssertEqual(h.engine.recovery.attemptCount(for: item.id), 0)
    }

    /// Which item says so first is chance. The queued one saying so isn't a fault in that item: the
    /// playing one's player is just as dead.
    func testAResetTheQueuedItemReportsFirstRebuildsThePlayersToo() async throws {
        let item = try tone(10, name: "reset-queued")
        let next = try tone(4, name: "reset-queued-next")
        let h = harness(queue: [item, next])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing, the next one queued") { h.engine.isPlaying && h.engine.position > 1 && h.engine.active.queued != nil }
        let reached = h.engine.position
        let before = h.engine.deck(.a).player

        report(-11819, on: try XCTUnwrap(h.engine.active.queued))

        await waitUntil("new players, playing") { h.engine.deck(.a).player !== before && h.engine.isPlaying }
        XCTAssertEqual(h.engine.currentItem?.id, item.id)
        XCTAssertGreaterThanOrEqual(h.engine.position, reached - 0.5)
    }

    #if os(iOS)
    /// A reset takes the session's set-up with it. The notification may come much later or not at
    /// all, so the items' report sets it up and activates it again itself.
    func testAResetTheItemsReportSetsTheAudioSessionUpAgain() async throws {
        let item = try tone(8, name: "reset-session")
        let h = harness(queue: [item])
        let session = FakeAudioSession()
        h.engine.audioSession = session
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying && h.engine.position > 0.3 }
        let activations = session.activations
        let before = h.engine.deck(.a).player

        report(-11819, on: try XCTUnwrap(h.engine.active.current))

        await waitUntil("playing again") { h.engine.deck(.a).player !== before && h.engine.isPlaying }
        XCTAssertEqual(session.resets, 1)
        XCTAssertEqual(session.activations, activations + 1)
    }
    #endif

    /// A decoder taken away for now is the system's fault as well, with no player lost: an ordinary
    /// retry on the item's budget, which doesn't ask for the copy to be thrown away.
    func testAnotherSystemErrorRetriesTheSameCopyOnTheItemsBudget() async throws {
        let item = try tone(8, name: "system-decoder")
        let h = harness(queue: [item])
        var reasons: [RecoveryReason] = []
        h.engine.sourceRecovery = { _, reason in
            reasons.append(reason)
            return nil
        }
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying && h.engine.position > 1 }
        let reached = h.engine.position
        // As a failing item's player is. One still playing isn't retried.
        h.engine.active.player.pause()
        await waitUntil("stopped") { !h.engine.active.isPlaying }

        report(-11839, on: try XCTUnwrap(h.engine.active.current))

        await waitUntil("retried") { !reasons.isEmpty }
        await waitUntil("playing again") { h.engine.isPlaying && h.engine.position >= reached - 0.5 }
        XCTAssertEqual(reasons, [.systemFault])
        XCTAssertEqual(h.engine.recovery.attemptCount(for: item.id), 1)
    }
}
