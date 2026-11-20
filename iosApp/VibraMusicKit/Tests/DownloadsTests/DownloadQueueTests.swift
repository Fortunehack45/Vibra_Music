import Foundation
import Observation
import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Downloads

// The queue end to end: resolver → ranged googlevideo transfers through URLSession download tasks
// (URLProtocolStub standing in for the network) → part file → tags → library. No Android unit
// test covers DownloadService or Downloads.run; these pin the behaviour those files describe.

private let youTubeHost = "rr1---sn-test.googlevideo.com"

private final class LookupCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

private func pattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
}

private func ranges(_ stub: URLProtocolStub) -> [String] {
    stub.requests.filter { $0.url?.host() == youTubeHost }.compactMap { $0.value(forHTTPHeaderField: "Range") }
}

@MainActor
private func fraction(_ manager: DownloadManager, _ id: String) -> Double? {
    if case .running(let fraction) = manager.active[id] { return fraction }
    return nil
}

/// Progress, cancel, retry: what a download does between the tap and the file.
@MainActor
final class DownloadTransferTests: XCTestCase {
    /// Bounded ranges, each carrying the client's own headers, progress in step with the bytes, and
    /// the file byte-for-byte what the server holds.
    func testARangedDownloadReportsProgressAndSavesEveryByte() async throws {
        let body = pattern(5_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        harness.serveYouTube(body)
        let gate = Gate()
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=2000-2999" { gate.wait() }
            return try rangeResponder(body)(request)
        }

        harness.manager.enqueue(song("p", title: "Progress"))
        XCTAssertEqual(harness.manager.active["p"], .queued)
        await waitUntil("two ranges in") { (fraction(harness.manager, "p") ?? 0) >= 0.4 }
        XCTAssertEqual(try XCTUnwrap(fraction(harness.manager, "p")), 0.4, accuracy: 0.001)
        XCTAssertEqual(harness.manager.session.item("p")?.progress, .running(fraction: 0.4))
        XCTAssertEqual(harness.manager.session.state.fraction, 0.4, accuracy: 0.001)
        XCTAssertEqual(harness.partFiles.count, 1, "the bytes so far sit in a hidden part file")
        XCTAssertNil(harness.library.savedFileURL(for: "p"), "nothing is published before the last byte")
        gate.open()
        await harness.manager.waitUntilIdle()

        XCTAssertEqual(ranges(harness.stub), ["bytes=0-999", "bytes=1000-1999", "bytes=2000-2999", "bytes=3000-3999", "bytes=4000-4999"])
        for request in harness.stub.requests where request.url?.host() == youTubeHost {
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "com.google.android.apps.youtube.vr.oculus/1.65.10")
        }
        let file = try XCTUnwrap(harness.library.savedFileURL(for: "p"))
        XCTAssertEqual(file.lastPathComponent, "Artist - Progress.m4a")
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertNil(harness.manager.active["p"], "a saved track leaves the active map; the library answers for it")
        XCTAssertEqual(harness.manager.session.item("p")?.progress, .done)
        XCTAssertFalse(harness.manager.session.state.busy)
        XCTAssertEqual(harness.library.songs().first?.downloadFormat, "AAC · 130 kbps")
        XCTAssertTrue(harness.partFiles.isEmpty)
    }

    /// A running download called off stops, leaves no part file and no row behind.
    func testCancellingARunningDownloadDeletesItsPartFileAndItsRow() async throws {
        let body = pattern(3_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        harness.serveYouTube(body)
        let gate = Gate()
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=1000-1999" { gate.wait() }
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("c"))
        await waitUntil("the second range to be asked for") { ranges(harness.stub).count == 2 }
        XCTAssertEqual(harness.partFiles.count, 1)

        harness.manager.cancel("c")
        gate.open()
        await harness.manager.waitUntilIdle()
        // The cancelled task cleans up after the queue has already let it go.
        await waitUntil("the part file to go") { harness.partFiles.isEmpty }

        XCTAssertNil(harness.manager.active["c"])
        XCTAssertNil(harness.manager.session.item("c"), "a cancelled download isn't a row to check on")
        XCTAssertNil(harness.library.savedFileURL(for: "c"))
        XCTAssertTrue(harness.partFiles.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: harness.library.store.tracksDirectory.path(percentEncoded: false))
        XCTAssertTrue(names.isEmpty, "\(names)")
        XCTAssertFalse(ranges(harness.stub).contains("bytes=2000-2999"))
    }

    /// Cancelling a track still waiting its turn means it is never resolved at all.
    func testCancellingAQueuedTrackNeverFetchesIt() async throws {
        let body = pattern(2_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000, workers: 1)
        harness.serveYouTube(body)
        let gate = Gate()
        harness.stub.register(host: youTubeHost) { request in
            gate.wait()
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("first"))
        harness.manager.enqueue(song("second"))
        await waitUntil("the first track's transfer") { !ranges(harness.stub).isEmpty }
        XCTAssertEqual(harness.manager.active["second"], .queued)
        harness.manager.cancel("second")
        gate.open()
        await harness.manager.waitUntilIdle()

        XCTAssertEqual(harness.resolver.songs.map(\.videoId), ["first"])
        XCTAssertNotNil(harness.library.savedFileURL(for: "first"))
        XCTAssertNil(harness.library.savedFileURL(for: "second"))
        XCTAssertEqual(harness.manager.session.state.items.map(\.videoId), ["first"])
    }

    /// A dropped connection is retried; the file comes out whole, with no range written twice.
    func testATransientFailureIsRetriedAndTheFileIsWhole() async throws {
        let body = pattern(3_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        harness.serveYouTube(body)
        let dropped = LockedFlag()
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=1000-1999", dropped.set() {
                return .failure(.networkConnectionLost)
            }
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("t"))
        await harness.manager.waitUntilIdle()

        XCTAssertEqual(ranges(harness.stub), ["bytes=0-999", "bytes=1000-1999", "bytes=1000-1999", "bytes=2000-2999"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(harness.library.savedFileURL(for: "t"))), body)
        XCTAssertEqual(harness.resolver.requests.count, 1, "a network blip is not a reason to resolve again")
    }

    /// A URL that served its opening and then refuses has had its identity stood down: resolve once
    /// more and carry on from the same byte.
    func testARefusedRangeReResolvesOnceAndCarriesOn() async throws {
        let body = pattern(3_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        harness.serveYouTube(body)
        let refused = LockedFlag()
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=1000-1999", refused.set() { return .status(403) }
            return try rangeResponder(body)(request)
        }
        // The resolver is told before it is asked again, so it doesn't hand the same identity back.
        let told = LockedList<String>()
        let asked = harness.resolver
        harness.manager.refusalHandler = { url, status in
            told.append("\(status) \(url.host() ?? "") after \(asked.requests.count) resolve(s)")
        }
        harness.manager.enqueue(song("r"))
        await harness.manager.waitUntilIdle()

        XCTAssertEqual(told.values, ["403 \(youTubeHost) after 1 resolve(s)"])
        XCTAssertEqual(harness.resolver.requests.count, 2)
        XCTAssertEqual(ranges(harness.stub), ["bytes=0-999", "bytes=1000-1999", "bytes=1000-1999", "bytes=2000-2999"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(harness.library.savedFileURL(for: "r"))), body)
    }

    /// The second refusal is a failure, said in words, with nothing half-written left behind.
    func testASecondRefusalFailsTheRowWithAReadableReason() async throws {
        let body = pattern(3_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        harness.serveYouTube(body)
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") != "bytes=0-999" { return .status(403) }
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("f"))
        await harness.manager.waitUntilIdle()

        XCTAssertEqual(harness.manager.active["f"], .failed(reason: "Download refused after 1000B (HTTP 403)"))
        XCTAssertEqual(harness.manager.session.state.failed, 1)
        XCTAssertTrue(harness.manager.session.state.visible, "a failure is something to be told about")
        XCTAssertNil(harness.library.savedFileURL(for: "f"))
        XCTAssertTrue(harness.partFiles.isEmpty)
    }

    /// A failure a user can read says which fault it was, not one message for every network error.
    func testANetworkFaultIsNamedByItsCode() {
        XCTAssertTrue(DownloadManager.friendly(URLError(.notConnectedToInternet)).contains("(-1009)"))
        XCTAssertTrue(DownloadManager.friendly(URLError(.timedOut)).contains("(-1001)"))
    }

    /// A transfer the app couldn't keep is a storage fault, said as one — not as a network error
    /// that would send a user chasing a connection problem that isn't there.
    func testAStagingFailureIsNamedForStorageNotTheNetwork() async throws {
        let root = try makeTemporaryDirectory()
        // The transport's staging directory is occupied by a file, so no finished transfer can be
        // kept. (Named to avoid colliding with the store's own Staging folder on a case-blind
        // file system.)
        let blocked = root.appending(path: "occupied")
        try Data([0x00]).write(to: blocked)
        let stub = URLProtocolStub()
        let body = pattern(1_500)
        stub.register(host: youTubeHost, rangeResponder(body))

        let defaults = EphemeralDefaults()
        let settings = AppSettings(defaults: defaults.defaults, credentials: InMemoryCredentialStore())
        let manager = DownloadManager(
            settings: settings,
            resolver: FakeResolver { song, _ in
                ResolvedStream(url: googleVideoURL(song.videoId, length: body.count), origin: .youtube,
                               mimeType: "audio/mp4; codecs=\"mp4a.40.2\"", format: StreamFormat(codec: "aac", kbps: 130))
            },
            network: FakeNetworkMonitor(.wifi),
            transport: URLSessionDownloadTransport(configuration: stub.makeConfiguration(), stagingDirectory: blocked),
            library: DownloadLibrary(store: DownloadStore(root: root)),
            http: stub.makeSession()
        )
        manager.enqueue(song("s"))
        await manager.waitUntilIdle()

        XCTAssertEqual(manager.active["s"], .failed(reason: "Couldn't save the download to this device's storage"))
        XCTAssertFalse(ranges(stub).isEmpty, "the transfer itself was fine; the fault was in keeping it")
    }

    /// A failure, and the steps that led to it, are filed against the track in the shareable
    /// in-app log ("Copy log"), so a user can send why their device failed.
    func testAFailureAndItsPathLandInTheShareableTrackLog() async throws {
        let body = pattern(3_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        TrackLog.shared.clear()
        harness.serveYouTube(body)
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") != "bytes=0-999" { return .status(403) }
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("f"))
        await harness.manager.waitUntilIdle()

        XCTAssertEqual(harness.manager.active["f"], .failed(reason: "Download refused after 1000B (HTTP 403)"))
        let lines = TrackLog.shared.heldLines.filter { $0.track == "f" }.map(\.text)
        XCTAssertTrue(lines.contains { $0.contains("downloading f") && $0.contains(".m4a") },
                      "the chosen route is in the log: \(lines)")
        XCTAssertTrue(lines.contains { $0.contains("HTTP 403") }, "the refused range is in the log: \(lines)")
        XCTAssertTrue(lines.contains { $0.contains("download failed for f") && $0.contains("HTTP 403") },
                      "the failure itself is in the log: \(lines)")
    }

    /// Resolving again can land on another format; splicing it onto the first would be a file of
    /// the right length that doesn't play.
    func testAStreamWhoseLengthMovesOnReResolveFails() async throws {
        let body = pattern(3_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        let calls = LockedCounter()
        harness.resolver.answer { song, _ in
            let length = calls.next() == 1 ? body.count : body.count + 500
            return ResolvedStream(url: googleVideoURL(song.videoId, length: length), origin: .youtube, mimeType: "audio/mp4",
                                  format: StreamFormat(codec: "aac", kbps: 130))
        }
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=1000-1999" { return .status(403) }
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("m"))
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(harness.manager.active["m"], .failed(reason: "The stream changed mid-download — try again"))
    }

    /// Retrying a failed track from the manager is the same errand: one row, reset, then done.
    func testRetryingAFailedTrackReplacesItsRowAndFinishes() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.manager.enqueue(song("again", title: "Again"))
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(harness.manager.active["again"], .failed(reason: "No downloadable audio for this track"))

        harness.serveYouTube(pattern(1_500))
        harness.manager.retry("again")
        XCTAssertEqual(harness.manager.session.item("again")?.progress, .queued)
        await harness.manager.waitUntilIdle()

        XCTAssertEqual(harness.manager.session.state.items.count, 1)
        XCTAssertEqual(harness.manager.session.item("again")?.progress, .done)
        XCTAssertNotNil(harness.library.savedFileURL(for: "again"))
        harness.manager.dismissFailure("again")
        XCTAssertNil(harness.manager.active["again"])
    }

    /// A second tap on a track already queued or running is a no-op, not a second download.
    func testTappingTwiceQueuesOnce() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.serveYouTube(pattern(1_000))
        harness.manager.enqueue(song("twice"))
        harness.manager.enqueue(song("twice"))
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(harness.resolver.requests.count, 1)
        XCTAssertEqual(harness.manager.session.state.items.count, 1)
    }

    /// Four tracks at a time, as on Android; the rest wait their turn.
    func testNoMoreThanTheConfiguredNumberOfTracksRunAtOnce() async throws {
        let body = pattern(1_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), workers: 2)
        harness.serveYouTube(body)
        let gate = Gate()
        harness.stub.register(host: youTubeHost) { request in
            gate.wait()
            return try rangeResponder(body)(request)
        }
        func runningCount() -> Int { harness.manager.active.values.filter { if case .running = $0 { return true } else { return false } }.count }
        for id in ["w1", "w2", "w3"] { harness.manager.enqueue(song(id)) }
        await waitUntil("two running") { runningCount() == 2 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(runningCount(), 2)
        XCTAssertEqual(harness.manager.active["w3"], .queued)
        XCTAssertEqual(Set(harness.resolver.songs.map(\.videoId)), ["w1", "w2"], "the third isn't even looked up yet")
        gate.open()
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(harness.library.songs().count, 3)
    }
}

/// The Wi-Fi-only setting: PORTING.md's "with Wi-Fi only on, downloads wait while on cellular".
@MainActor
final class DownloadWiFiOnlyTests: XCTestCase {
    /// Android's `wifi-only refuses metered connections and nothing else`, including the case that
    /// is easiest to get backwards: offline is not this setting's business.
    func testWifiOnlyRefusesMeteredConnectionsAndNothingElse() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), network: .cellular)
        harness.settings.wifiOnlyDownloads = true
        XCTAssertFalse(harness.manager.downloadsAllowed)

        harness.network.send(.wifi)
        await waitUntil { harness.manager.networkStatus == .wifi }
        XCTAssertTrue(harness.manager.downloadsAllowed)

        harness.network.send(.offline)
        await waitUntil { harness.manager.networkStatus == .offline }
        XCTAssertTrue(harness.manager.downloadsAllowed, "refusing offline would blame a Wi-Fi setting for an outage")

        let hotspot = NetworkStatus(interface: .wifi, isExpensive: true, isConstrained: false)
        harness.network.send(hotspot)
        await waitUntil { harness.manager.networkStatus == hotspot }
        XCTAssertFalse(harness.manager.downloadsAllowed, "a phone's hotspot is metered however it arrives")

        harness.settings.wifiOnlyDownloads = false
        harness.network.send(.cellular)
        await waitUntil { harness.manager.networkStatus == .cellular }
        XCTAssertTrue(harness.manager.downloadsAllowed)
    }

    /// A playlist that lists a track twice queues it once, and the notice counts it once.
    func testATrackListedTwiceIsCountedOnce() throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), network: .cellular)
        let outcome = harness.manager.download([song("twice"), song("twice")])
        XCTAssertEqual(outcome, DownloadRequestOutcome(queued: 1, waitingForWiFi: true))
    }

    /// Queued on cellular: it waits (not fails), says why, and starts itself on Wi-Fi.
    func testADownloadWaitsOnCellularAndStartsOnWifi() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), network: .cellular)
        harness.serveYouTube(pattern(1_500))
        let outcome = harness.manager.download([song("wait")])
        XCTAssertEqual(outcome, DownloadRequestOutcome(queued: 1, waitingForWiFi: true))

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(harness.stub.requests.isEmpty, "not a byte on cellular")
        XCTAssertTrue(harness.resolver.requests.isEmpty, "not even the lookup")
        XCTAssertEqual(harness.manager.active["wait"], .queued)
        XCTAssertTrue(harness.manager.isWaitingForWiFi)

        harness.network.send(.wifi)
        await waitUntil("the file") { harness.library.isDownloaded("wait") }
        await harness.manager.waitUntilIdle()
        XCTAssertFalse(harness.manager.isWaitingForWiFi)
        XCTAssertNotNil(harness.library.savedFileURL(for: "wait"))
    }

    /// Switching the setting off lets a waiting queue go on the connection in hand.
    func testTurningWifiOnlyOffReleasesAWaitingQueue() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), network: .cellular)
        harness.serveYouTube(pattern(1_500))
        harness.manager.enqueue(song("released"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(harness.manager.isWaitingForWiFi)

        harness.settings.wifiOnlyDownloads = false
        await waitUntil("the file") { harness.library.isDownloaded("released") }
        await harness.manager.waitUntilIdle()
        let request = try XCTUnwrap(harness.stub.requests.first { $0.url?.host() == youTubeHost })
        XCTAssertTrue(request.allowsExpensiveNetworkAccess)
    }

    /// Wi-Fi lost halfway: the transfer holds at its next range rather than failing, and carries on
    /// from there when Wi-Fi is back.
    func testLosingWifiMidDownloadPausesAtTheNextRangeInsteadOfFailing() async throws {
        let body = pattern(3_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        harness.serveYouTube(body)
        let gate = Gate()
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=0-999" { gate.wait() }
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("roam"))
        await waitUntil("the first range") { ranges(harness.stub).count == 1 }

        harness.network.send(.cellular)
        await waitUntil("the gate to see cellular") { !harness.manager.downloadsAllowed }
        gate.open()
        await waitUntil("the first range to land") { (fraction(harness.manager, "roam") ?? 0) > 0.3 }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(ranges(harness.stub), ["bytes=0-999"], "nothing more on cellular")
        XCTAssertNotNil(fraction(harness.manager, "roam"), "still running, not failed")
        XCTAssertTrue(harness.manager.isWaitingForWiFi)
        XCTAssertEqual(harness.stub.requests.first?.allowsExpensiveNetworkAccess, false,
                       "under Wi-Fi only every request is kept off expensive networks, even one the system runs on its own")

        harness.network.send(.wifi)
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(ranges(harness.stub), ["bytes=0-999", "bytes=1000-1999", "bytes=2000-2999"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(harness.library.savedFileURL(for: "roam"))), body)
    }
}

/// Background URLSession downloads outlive the process; the queue has to pick them back up.
@MainActor
final class DownloadRelaunchTests: XCTestCase {
    /// Under Wi-Fi only, a download resumed on cellular asks the lyric services nothing until
    /// Wi-Fi is back, the same as its bytes.
    func testAResumedDownloadLooksUpNoLyricsOnCellular() async throws {
        let body = pattern(3_000)
        let lookups = LookupCount()
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000,
                                      lyrics: { _ in lookups.add(); return nil })
        harness.serveYouTube(body)
        let gate = Gate()
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=1000-1999" { gate.wait() }
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("lyrics"))
        await waitUntil("the second range to be in flight") { ranges(harness.stub).count == 2 }
        await waitUntil("the first lookup") { lookups.count == 1 }

        harness.terminate()
        harness.network.send(.cellular)
        harness.launch()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(lookups.count, 1, "no lyric lookup on cellular")

        harness.network.send(.wifi)
        gate.open()
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(lookups.count, 2)
        XCTAssertNotNil(harness.library.savedFileURL(for: "lyrics"))
    }

    /// Killed mid-track: the next launch resumes at the last whole range, and a range that finished
    /// while nothing was running is collected from disk rather than fetched again.
    func testARelaunchResumesFromTheLastWholeRangeAndCollectsWhatLandedMeanwhile() async throws {
        let body = pattern(3_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        harness.serveYouTube(body)
        let gate = Gate()
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=1000-1999" { gate.wait() }
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("resume", title: "Resume"))
        await waitUntil("the second range to be in flight") { ranges(harness.stub).count == 2 }

        harness.terminate()
        // The transfer the dead process started finishes on its own.
        gate.open()
        let staging = harness.library.store.stagingDirectory
        await waitUntil("the orphaned range to be kept") {
            ((try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? []).contains { $0.hasSuffix(".json") }
        }
        XCTAssertEqual(harness.partFiles.count, 1, "the part file survives the process")

        harness.launch()
        XCTAssertEqual(harness.manager.active["resume"], .queued)
        XCTAssertEqual(harness.manager.session.item("resume")?.song.title, "Resume")
        await harness.manager.waitUntilIdle()

        XCTAssertEqual(ranges(harness.stub), ["bytes=0-999", "bytes=1000-1999", "bytes=2000-2999"],
                       "no range fetched twice, and none started over")
        XCTAssertEqual(harness.resolver.requests.count, 1, "the checkpoint carries the stream; no second lookup")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(harness.library.savedFileURL(for: "resume"))), body)
        XCTAssertTrue(harness.partFiles.isEmpty)
        let staged = try FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))
        XCTAssertTrue(staged.isEmpty, "\(staged)")
    }

    /// The part file is gone by the next launch (a restore from backup, a purge): the track is
    /// fetched again from the start, not saved with a hole where the lost bytes were.
    func testARelaunchWithoutThePartFileStartsTheTrackOver() async throws {
        let body = pattern(3_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        harness.serveYouTube(body)
        let gate = Gate()
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=1000-1999" { gate.wait() }
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("lost", title: "Lost"))
        await waitUntil("the second range to be in flight") { ranges(harness.stub).count == 2 }

        harness.terminate()
        let tracks = harness.library.store.tracksDirectory
        for part in harness.partFiles {
            try FileManager.default.removeItem(at: tracks.appending(path: part, directoryHint: .notDirectory))
        }
        gate.open()
        let staging = harness.library.store.stagingDirectory
        await waitUntil("the orphaned range to be kept") {
            ((try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? []).contains { $0.hasSuffix(".json") }
        }

        harness.launch()
        await harness.manager.waitUntilIdle()

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(harness.library.savedFileURL(for: "lost"))), body)
    }

    /// Tracks that were still waiting their turn are queued again after a relaunch, in order.
    func testQueuedTracksSurviveARelaunch() async throws {
        let body = pattern(1_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), workers: 1)
        harness.serveYouTube(body)
        let gate = Gate()
        harness.stub.register(host: youTubeHost) { request in
            gate.wait()
            return try rangeResponder(body)(request)
        }
        for id in ["q1", "q2", "q3"] { harness.manager.enqueue(song(id)) }
        await waitUntil("the first transfer") { !ranges(harness.stub).isEmpty }
        harness.terminate()
        gate.open()

        harness.launch()
        XCTAssertEqual(harness.manager.session.state.items.map(\.videoId), ["q1", "q2", "q3"])
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(harness.library.songs().map(\.videoId), ["q1", "q2", "q3"])
    }

    /// A cancelled job leaves nothing a relaunch would resume.
    func testACancelledDownloadIsNotResumedAfterARelaunch() async throws {
        let body = pattern(2_000)
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        harness.serveYouTube(body)
        let gate = Gate()
        harness.stub.register(host: youTubeHost) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=1000-1999" { gate.wait() }
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("gone"))
        await waitUntil { ranges(harness.stub).count == 2 }
        harness.manager.cancel("gone")
        gate.open()
        await harness.manager.waitUntilIdle()

        harness.launch()
        await harness.manager.waitUntilIdle()
        XCTAssertNil(harness.manager.active["gone"])
        XCTAssertTrue(harness.manager.session.state.items.isEmpty)
        XCTAssertNil(harness.library.savedFileURL(for: "gone"))
    }
}

/// "Download all" for an album or playlist.
@MainActor
final class DownloadAllTests: XCTestCase {
    func testDownloadAllSkipsWhatIsSavedOrQueuedAndRecordsTheRelease() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.serveYouTube(pattern(1_200))
        harness.serveArtwork()
        harness.manager.enqueue(song("t1", title: "One"))
        await harness.manager.waitUntilIdle()

        let cover = "https://lh3.googleusercontent.com/album=w544-h544"
        let target = DownloadTarget(id: "MPREb_album", title: "The Album", subtitle: "Artist", thumbnailUrl: cover)
        // A track that is already waiting its turn when the release is asked for.
        harness.manager.enqueue(song("t4", title: "Four"))
        let tracks = [song("t1", title: "One"), song("t2", title: "Two"), song("t3", title: "Three"), song("t4", title: "Four")]
        let outcome = harness.manager.download(tracks, as: target)
        XCTAssertEqual(outcome, DownloadRequestOutcome(queued: 2, alreadyDownloaded: 1, alreadyQueued: 1))
        XCTAssertEqual(harness.library.requested["MPREb_album"], ["t2", "t3"])
        XCTAssertEqual(harness.manager.session.item("t2")?.from, "The Album")
        await harness.manager.waitUntilIdle()

        XCTAssertEqual(harness.library.collectionSongs("MPREb_album").map(\.videoId), ["t1", "t2", "t3", "t4"])
        // An album page's rows carry no artwork; the release's cover is stamped on the way in.
        XCTAssertEqual(harness.library.records["t2"]?.thumbnailUrl, cover)
        XCTAssertNotNil(harness.library.records["t2"]?.artworkPath)
        await waitUntil("the release cover to be cached") { harness.library.collections["MPREb_album"]?.artworkPath != nil }
        let collection = try XCTUnwrap(harness.library.collectionsAmong(harness.library.songs()).first)
        XCTAssertEqual(collection.songs.count, 4)
        XCTAssertTrue(try XCTUnwrap(collection.thumbnailUrl).hasPrefix("file://"), "the release draws offline")

        let albums = LocalLibraryListing.albums(in: harness.library.songs(), collections: harness.library.collectionsAmong(harness.library.songs()))
        XCTAssertEqual(albums.map(\.title), ["The Album"])
        XCTAssertTrue(albums[0].asked)
    }

    /// A playlist downloaded whole gets its own card on the On Device shelf once a track lands.
    func testADownloadedPlaylistGetsACardOnceATrackIsSaved() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.serveYouTube(pattern(1_000))
        let target = DownloadTarget(id: "VLPL123", title: "Road Trip", playlist: true)
        harness.manager.download([song("p1"), song("p2")], as: target)
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(harness.library.savedPlaylists().map(\.id), ["VLPL123"])
        XCTAssertEqual(DownloadLibrary.recordId(of: DownloadLibrary.pageId(for: "VLPL123")), "VLPL123")
        XCTAssertEqual(harness.library.collectionSongs("VLPL123").map(\.videoId), ["p1", "p2"])
    }

    /// The Library page asks for the shelf on every pass of its body, so the answer is kept until the
    /// record changes. A change still shows up the next time it is asked, and a page drawing
    /// the kept answer still hears of it.
    func testTheOnDeviceShelfFollowsTheRecordOnceItHasBeenRead() async throws {
        final class Watch: @unchecked Sendable { var fired = false }
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.serveYouTube(pattern(1_000))
        XCTAssertTrue(harness.library.savedPlaylists().isEmpty)
        harness.manager.download([song("p1"), song("p2")], as: DownloadTarget(id: "VLPL123", title: "Road Trip", playlist: true))
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(harness.library.savedPlaylists().map(\.id), ["VLPL123"])

        let watch = Watch()
        withObservationTracking { _ = harness.library.savedPlaylists() } onChange: { watch.fired = true }
        _ = harness.library.deleteCollection("VLPL123")
        XCTAssertTrue(watch.fired, "the kept answer still registers the record")
        XCTAssertTrue(harness.library.savedPlaylists().isEmpty)
    }
}

/// What goes into the file besides the audio.
@MainActor
final class DownloadEmbeddingTests: XCTestCase {
    /// YouTube's AAC is fragmented MP4 whose header declares the whole duration; saved as-is,
    /// AVFoundation reads it at twice its length. The saved file reads true, and carries its tags,
    /// cover and both lyrics fields.
    func testAYouTubeShapedDownloadReadsAtItsTrueLengthWithItsTags() async throws {
        let dir = try makeTemporaryDirectory()
        let body = try await TestAudio.youtubeShaped(seconds: 4, in: dir)
        let unpatched = dir.appending(path: "unpatched.m4a")
        try body.write(to: unpatched)
        let before = await EmbeddedTags.read(from: unpatched).durationSeconds ?? 0

        let harness = DownloadHarness(root: dir.appending(path: "store"), chunkBytes: 64 * 1024,
                                      lyrics: { _ in DownloadLyrics(plain: "[00:01.00]hello", enhanced: "[00:01.00]<00:01.00>hello") })
        harness.serveYouTube(body)
        harness.serveArtwork(TestImages.image(width: 1_600, height: 1_600, type: .png))
        harness.manager.enqueue(song("yt", title: "Shaped", artist: "Uploader", album: "Record",
                                     thumbnail: "https://lh3.googleusercontent.com/cover=w120-h120"))
        await harness.manager.waitUntilIdle()

        let file = try XCTUnwrap(harness.library.savedFileURL(for: "yt"))
        let tags = await EmbeddedTags.read(from: file)
        XCTAssertTrue(tags.isPlayable)
        let duration = try XCTUnwrap(tags.durationSeconds)
        XCTAssertEqual(duration, 4, accuracy: 0.25, "declared \(before)s before the patch")
        XCTAssertEqual(tags.title, "Shaped")
        XCTAssertEqual(tags.artist, "Uploader")
        XCTAssertEqual(tags.album, "Record")
        XCTAssertEqual(tags.lyrics, "[00:01.00]hello")
        XCTAssertEqual(tags.wordLyrics, "[00:01.00]<00:01.00>hello")
        XCTAssertEqual(tags.artworkMime, "image/jpeg")
        let cover = try XCTUnwrap(tags.artwork)
        XCTAssertEqual(TestImages.size(of: cover), CGSize(width: 1_000, height: 1_000), "scaled to the cover ceiling")
        // The cover the Downloads page draws is a sidecar, so it doesn't re-read every file.
        XCTAssertTrue(try XCTUnwrap(harness.library.songs().first?.thumbnailUrl).hasPrefix("file://"))
        // The cover request asked for the 1200 px rendition.
        XCTAssertTrue(harness.stub.requests.contains { $0.url?.absoluteString.contains("w1200-h1200") == true })
    }

    /// The lyric services are only asked when the user allows lyric lookups at all.
    func testLyricsAreNotLookedUpWhenSyncedLyricsAreOff() async throws {
        let asked = LockedCounter()
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), lyrics: { _ in
            _ = asked.next()
            return DownloadLyrics(plain: "[00:01.00]words")
        })
        harness.settings.syncedLyrics = false
        harness.serveYouTube(pattern(1_000))
        harness.manager.enqueue(song("quiet"))
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(asked.value, 0)
        XCTAssertNotNil(harness.library.savedFileURL(for: "quiet"))
    }

    /// A lyrics server that never answers costs the lyrics, not the download.
    func testALyricsLookupThatHangsCostsTheLyricsNotTheDownload() async throws {
        let dir = try makeTemporaryDirectory()
        let body = try await TestAudio.youtubeShaped(seconds: 2, in: dir)
        let harness = DownloadHarness(root: dir.appending(path: "store"), lyricsTimeout: 0.3, lyrics: { _ in
            try await Task.sleep(for: .seconds(30))
            return DownloadLyrics(plain: "[00:01.00]too late")
        })
        harness.serveYouTube(body)
        let started = Date()
        harness.manager.enqueue(song("slow", title: "Slow"))
        await harness.manager.waitUntilIdle()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let tags = await EmbeddedTags.read(from: try XCTUnwrap(harness.library.savedFileURL(for: "slow")))
        XCTAssertEqual(tags.title, "Slow")
        XCTAssertNil(tags.lyrics)
    }

    /// Timestamps with no words (an instrumental) and oversized answers aren't lyrics to keep.
    func testLyricsWithoutWordsOrPastTheCeilingAreNotEmbedded() {
        XCTAssertNil(LyricsEmbedding.sanitized(DownloadLyrics(plain: "[00:01.00]\n[00:02.00]  ")))
        XCTAssertNil(LyricsEmbedding.sanitized(DownloadLyrics(plain: "[00:01.00]" + String(repeating: "a", count: 64_001))))
        let kept = LyricsEmbedding.sanitized(DownloadLyrics(plain: "[ar:x]\n[00:01.00]la", enhanced: "   "))
        XCTAssertEqual(kept, DownloadLyrics(plain: "[ar:x]\n[00:01.00]la", enhanced: nil))
    }

    /// A file already sitting under the name this download would write is adopted, not fetched again.
    func testAFileAlreadySavedUnderTheNameIsAdoptedNotFetchedAgain() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.serveYouTube(pattern(1_000))
        try harness.library.store.prepare()
        let existing = harness.library.store.tracksDirectory.appending(path: "Artist - Adopted.m4a")
        try Data("already here".utf8).write(to: existing)

        harness.manager.enqueue(song("adopt", title: "Adopted"))
        await harness.manager.waitUntilIdle()
        XCTAssertTrue(ranges(harness.stub).isEmpty)
        XCTAssertEqual(harness.library.savedFileURL(for: "adopt")?.lastPathComponent, existing.lastPathComponent)
        XCTAssertEqual(harness.manager.session.item("adopt")?.progress, .done)
    }

    /// Two tracks with one artist and title (two albums' "Intro") each keep a file of their own:
    /// the second neither adopts the first one's audio nor overwrites it.
    func testASecondTrackWithTheSameNameGetsItsOwnFile() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.serveYouTube(pattern(1_000))
        harness.manager.enqueue(song("first", title: "Intro"))
        await harness.manager.waitUntilIdle()
        harness.manager.enqueue(song("second", title: "Intro"))
        await harness.manager.waitUntilIdle()

        let first = try XCTUnwrap(harness.library.savedFileURL(for: "first"))
        let second = try XCTUnwrap(harness.library.savedFileURL(for: "second"))
        XCTAssertEqual(first.lastPathComponent, "Artist - Intro.m4a")
        XCTAssertEqual(second.lastPathComponent, "Artist - Intro [second].m4a")
        harness.library.delete("second")
        XCTAssertNotNil(harness.library.savedFileURL(for: "first"), "deleting one leaves the other's file")
    }

    /// The same, with both downloading at once: neither has finished to claim the name.
    func testTwoSameNameTracksDownloadingTogetherGetTheirOwnFiles() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.serveYouTube(pattern(1_000))
        harness.manager.enqueue(song("first", title: "Intro"))
        harness.manager.enqueue(song("second", title: "Intro"))
        await harness.manager.waitUntilIdle()

        let first = try XCTUnwrap(harness.library.savedFileURL(for: "first"))
        let second = try XCTUnwrap(harness.library.savedFileURL(for: "second"))
        XCTAssertNotEqual(first, second)
    }

    /// At Lossless, a `.flac` already saved answers the whole question before any lookup; an
    /// `.m4a` can't, since it may be the AAC a High download wrote.
    func testALosslessRequestAdoptsAnExistingFlacWithoutAskingTheResolver() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.settings.downloadQuality = .lossless
        try harness.library.store.prepare()
        try Data("fLaC".utf8).write(to: harness.library.store.tracksDirectory.appending(path: "Artist - Lossless.flac"))
        harness.manager.enqueue(song("ll", title: "Lossless"))
        await harness.manager.waitUntilIdle()
        XCTAssertTrue(harness.resolver.requests.isEmpty)
        XCTAssertEqual(harness.library.savedFileURL(for: "ll")?.pathExtension, "flac")
    }

    /// WebM can't be played by AVPlayer, so a resolver that hands one over fails the row in words
    /// instead of saving a file nothing on the device opens.
    func testAWebmStreamIsRefusedRatherThanSaved() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory())
        harness.resolver.answer { song, _ in
            ResolvedStream(url: URL(string: "https://rr1---sn-test.googlevideo.com/videoplayback?id=\(song.videoId)&itag=251&clen=10&c=WEB_REMIX")!,
                           origin: .youtube, mimeType: "audio/webm; codecs=\"opus\"", format: StreamFormat(codec: "opus", kbps: 160))
        }
        harness.manager.enqueue(song("webm"))
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(harness.manager.active["webm"], .failed(reason: "Can't save WebM audio on this device — try again"))
        XCTAssertTrue(ranges(harness.stub).isEmpty)
    }
}

final class LockedList<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) { lock.withLock { items.append(item) } }
    var values: [Element] { lock.withLock { items } }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increments and returns the new count.
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

/// What a download does when the network isn't really there.
final class DownloadNetworkFailureTests: XCTestCase {
    /// A captive portal answers a source's plain-HTTP URL with its sign-in page: a 200 whose body
    /// passed every check (status, stated length, not empty). Saved, it became a finished track
    /// that can't play, and nothing would ever fetch it again.
    @MainActor
    func testACaptivePortalPageIsNeverSavedAsTheSong() async throws {
        // Labelled as a page, and (as some portals send it) labelled as a binary, opening with a comment.
        let answers: [(type: String, body: String)] = [
            ("text/html", "<!DOCTYPE html><html><body>Sign in to the Wi-Fi</body></html>"),
            ("application/octet-stream", "<!-- portal -->\n<html><body>Sign in to the Wi-Fi</body></html>"),
        ]
        for (index, answer) in answers.enumerated() {
            let id = "portal\(index)"
            let dir = try makeTemporaryDirectory()
            let harness = DownloadHarness(root: dir.appending(path: "store"), resolver: FakeResolver { _, _ in
                ResolvedStream(url: URL(string: "http://cdn.example/track.mp3")!, origin: .module,
                               mimeType: "audio/mpeg", format: StreamFormat(codec: "mp3"))
            })
            harness.stub.register(host: "cdn.example") { _ in .text(answer.body, headers: ["Content-Type": answer.type]) }
            harness.manager.enqueue(song(id, title: "Behind a portal"))
            await harness.manager.waitUntilIdle()
            XCTAssertNil(harness.library.savedFileURL(for: id), "\(answer.type): a web page is not the song")
            XCTAssertEqual(harness.manager.active[id],
                           .failed(reason: "The network sent a web page, not the song. Sign in to the Wi-Fi, then try again"),
                           answer.type)
        }

        // The other direction: real audio, sent with no Content-Type at all, still downloads.
        let dir = try makeTemporaryDirectory()
        let harness = DownloadHarness(root: dir.appending(path: "store"), resolver: FakeResolver { _, _ in
            ResolvedStream(url: URL(string: "http://cdn.example/track.mp3")!, origin: .module,
                           mimeType: "audio/mpeg", format: StreamFormat(codec: "mp3"))
        })
        let audio = Data("ID3".utf8) + Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) + Data(repeating: 0x55, count: 4_000)
        harness.stub.register(host: "cdn.example") { _ in .data(audio) }
        harness.manager.enqueue(song("audio1", title: "Real audio"))
        await harness.manager.waitUntilIdle()
        XCTAssertNotNil(harness.library.savedFileURL(for: "audio1"), "a body that opens like audio is saved")
    }

    /// A background session retries a stalled or cut-off transfer on its own until its resource
    /// timeout, seven days by default: a download behind a stalled connection sat on "running"
    /// for a week with no error. The bound is what lets the downloader's own retries, and then a
    /// visible failure, happen. (A real background transfer can't run in a unit test; the
    /// session's configuration is the contract.)
    func testABackgroundTransferGivesUpWithinAnHour() {
        let configuration = URLSessionDownloadTransport.backgroundConfiguration(identifier: "tests.\(UUID().uuidString)")
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60 * 60)
    }
}
