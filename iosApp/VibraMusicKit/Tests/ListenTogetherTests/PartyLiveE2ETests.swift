// These live end-to-end tests launch local servers with Process, which only exists on the
// Mac host; on the iOS Simulator they compile out (they could never start a server there).
#if os(macOS)
import VibraMusicCore
import Foundation
import XCTest
@testable import ListenTogether

/// Live end-to-end party against the real Go server: host + guest create and join by code,
/// and play / pause / seek / skip / queue changes propagate, clocks sync, and kick and
/// host-only control work.
///
/// Needs the prebuilt server binary, named by `VIBRAMUSIC_PARTY_SERVER`, and explicit opt-in:
/// `VIBRAMUSIC_LIVE_TESTS=1 VIBRAMUSIC_PARTY_SERVER=<path> scripts/kit-test.sh --filter ListenTogetherTests`.
final class PartyLiveE2ETests: XCTestCase {
    private var server: Process?
    private var baseUrl = ""

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live party test: set VIBRAMUSIC_LIVE_TESTS=1 to run.")
        }
        guard let binary = ProcessInfo.processInfo.environment["VIBRAMUSIC_PARTY_SERVER"] else {
            throw XCTSkip("Live party test: set VIBRAMUSIC_PARTY_SERVER to the server binary's path to run.")
        }
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("Live party test: no server binary at \(binary).")
        }
        let port = try Self.freePort()
        baseUrl = "http://127.0.0.1:\(port)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.environment = ["PORT": "\(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process
        // Wait for the health check, through cold start.
        let healthy = await Self.poll(timeoutSeconds: 20) {
            await Self.isHealthy(self.baseUrl)
        }
        XCTAssertTrue(healthy, "Party server did not come up on \(self.baseUrl)")
    }

    override func tearDown() async throws {
        server?.terminate()
        server = nil
        try await super.tearDown()
    }

    func testHostAndGuestStayInSync() async throws {
        let host = try await Self.makeClient()
        let guest = try await Self.makeClient()
        let hostIdentity = PartyIdentity(
            userId: "test-host", deviceId: UUID().uuidString, displayName: "Host")
        let guestIdentity = PartyIdentity(
            userId: "test-guest", deviceId: UUID().uuidString, displayName: "Guest")

        // Create + join by code.
        let code = try await host.createParty(
            on: baseUrl, as: hostIdentity, nickname: "Host", maxMembers: 5)
        XCTAssertTrue(PartyCode.isValid(PartyCode.normalize(code)))
        let __live1 = await host.waitUntil(timeoutSeconds: 10) { $0.connection == .live }
        XCTAssertTrue(__live1)
        let __live2 = await host.waitUntil(timeoutSeconds: 10) { $0.clockSynced }
        XCTAssertTrue(__live2)

        let preview = await guest.previewParty(code: code, server: baseUrl)
        if case .success(let p) = preview {
            XCTAssertEqual(1, p.memberCount)
            XCTAssertFalse(p.isFull)
        } else {
            XCTFail("preview failed")
        }
        _ = try await guest.joinParty(on: baseUrl, code: code, as: guestIdentity, nickname: "Guest")
        let __live3 = await guest.waitUntil(timeoutSeconds: 10) { $0.connection == .live }
        XCTAssertTrue(__live3)
        let __live4 = await guest.waitUntil(timeoutSeconds: 10) { $0.clockSynced }
        XCTAssertTrue(__live4)
        let __live5 = await guest.waitUntil(timeoutSeconds: 10) {
            $0.members.count == 2
        }
        XCTAssertTrue(__live5)

        // Queue + track propagate.
        let tracks = [
            PartyTrack(videoId: "live-a", title: "A", artist: "Art", durationMs: 200_000),
            PartyTrack(videoId: "live-b", title: "B", artist: "Art", durationMs: 200_000),
            PartyTrack(videoId: "live-c", title: "C", artist: "Art", durationMs: 200_000),
        ]
        await host.setQueue(tracks, index: 0)
        await host.setTrack(tracks[0], positionMs: 0, isPlaying: true)
        let __live6 = await guest.waitUntil(timeoutSeconds: 10) {
            $0.queue.items.map(\.videoId) == ["live-a", "live-b", "live-c"]
        }
        XCTAssertTrue(__live6)
        let __live7 = await guest.waitUntil(timeoutSeconds: 10) {
            $0.playback.track?.videoId == "live-a" && $0.playback.isPlaying
        }
        XCTAssertTrue(__live7)

        // Pause / play / seek propagate.
        await host.pause(at: 5_000)
        let __live8 = await guest.waitUntil(timeoutSeconds: 10) {
            !$0.playback.isPlaying && $0.playback.positionMs == 5_000
        }
        XCTAssertTrue(__live8)
        await host.play(at: 5_000)
        let __live9 = await guest.waitUntil(timeoutSeconds: 10) { $0.playback.isPlaying }
        XCTAssertTrue(__live9)
        await host.seek(to: 60_000)
        let __live10 = await guest.waitUntil(timeoutSeconds: 10) {
            $0.playback.positionMs == 60_000
        }
        XCTAssertTrue(__live10)

        // Skip propagates.
        await host.next()
        let __live11 = await guest.waitUntil(timeoutSeconds: 10) {
            $0.playback.track?.videoId == "live-b"
        }
        XCTAssertTrue(__live11)

        // Both clocks measured: positions agree within the drift limit.
        let __live12 = await host.waitUntil(timeoutSeconds: 10) { $0.clockSynced }
        XCTAssertTrue(__live12)
        let hostPos = await host.partyPositionMs()
        let guestPos = await guest.partyPositionMs()
        XCTAssertNotNil(hostPos)
        XCTAssertNotNil(guestPos)
        XCTAssertLessThan(abs((hostPos ?? 0) - (guestPos ?? 0)), PartyLimits.driftLimitMs)

        // Host-only lock: the guest sees it, and the server refuses their control.
        await host.setHostOnlyControl(true)
        let __live13 = await guest.waitUntil(timeoutSeconds: 10) { $0.controlsLocked }
        XCTAssertTrue(__live13)
        await guest.seek(to: 10_000)
        let __live14 = await guest.waitUntil(timeoutSeconds: 10) {
            ($0.error ?? "").contains("host")
        }
        XCTAssertTrue(__live14)
        await host.setHostOnlyControl(false)
        let __live15 = await guest.waitUntil(timeoutSeconds: 10) { !$0.controlsLocked }
        XCTAssertTrue(__live15)

        // Kick: the guest is told why and leaves; rejoining is refused client-side.
        let guestId = await guest.state.you?.memberId ?? ""
        XCTAssertFalse(guestId.isEmpty)
        await host.kick(memberId: guestId)
        let __live16 = await guest.waitUntil(timeoutSeconds: 10) { !$0.inParty }
        XCTAssertTrue(__live16)
        let rejoin = await guest.previewParty(code: code, server: baseUrl)
        if case .failure(let error) = rejoin {
            XCTAssertEqual("recently_kicked", error.code)
        } else {
            XCTFail("expected a kicked guest to be refused")
        }

        await host.leaveParty()
        let hostLeft = await host.state.inParty
        XCTAssertFalse(hostLeft)
    }

    // MARK: - Harness

    private static func makeClient() async throws -> PartyClient {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PartyLive\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PartyServerStore(
            files: JSONFileStore(directory: dir),
            defaultServer: "https://default.example.com")
        return PartyClient(store: store)
    }

    private static func isHealthy(_ base: String) async -> Bool {
        guard let url = URL(string: "\(base)/healthz") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                return false
            }
            return (String(data: data, encoding: .utf8) ?? "").contains("\"ok\":true")
        } catch {
            return false
        }
    }

    private static func poll(
        timeoutSeconds: Double, intervalMs: UInt64 = 200, _ check: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await check() { return true }
            try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
        }
        return await check()
    }

    private static func freePort() throws -> Int {
        // Bind port 0 and read back what the kernel assigned, then release it. A tiny
        // TOCTOU race with another process grabbing it first is acceptable in tests.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "party-live", code: 1) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw NSError(domain: "party-live", code: 2) }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else { throw NSError(domain: "party-live", code: 3) }
        return Int(CFSwapInt16BigToHost(out.sin_port))
    }
}
#endif
