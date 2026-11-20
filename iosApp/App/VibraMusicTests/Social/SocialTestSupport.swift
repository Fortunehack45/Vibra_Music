import VibraMusicCore
import InnerTube
import ListenTogether
import Observation
import Replay
import SwiftUI
import XCTest
@testable import VibraMusic

// Fakes and hosts for the Social tests: a party layer that records what it was asked, fixed
// Replay data, and a window to lay a screen out in.

@MainActor
@Observable
final class FakePartyService: ListenTogetherService {
    var state = PartySessionState()
    var activity: [PartyActivity] = []
    var signedIn = true
    var myAvatarUrl: String?
    let defaultServer = "https://default.example"
    var customServer = ""
    var nickname = "Tester"
    var active: String?
    var idle = "https://default.example"
    var connection: PartyServerConnectionState = .defaultOnline(latencyMs: 20)

    var previewResult: Result<PartyPreview, PartyClientError> = .success(PartyPreview(code: "ABC123", hostName: "Host", memberCount: 2, maxMembers: 5))
    var joinResult: Result<String, PartyClientError> = .success("ABC123")
    var createResult: Result<String, PartyClientError> = .success("NEW123")
    var switchResult: PartySwitchResult = .success(partyCode: "ABC123")
    var probeResult = PartyProbeResult(isOnline: true, latencyMs: 33)

    private(set) var previews: [(code: String, server: String?)] = []
    private(set) var joins: [String] = []
    private(set) var switches: [(server: String, code: String)] = []
    private(set) var creates: [Int] = []
    private(set) var kicked: [String] = []
    private(set) var sizes: [Int] = []
    private(set) var hostOnly: [Bool] = []
    private(set) var savedServers: [String] = []
    private(set) var left = 0

    func setNickname(_ value: String) { nickname = value }
    func hasServer() async -> Bool { true }
    func serverConnection() async -> PartyServerConnectionState { connection }
    /// How long the server lookups take, so tests can overlap two calls.
    var lookupDelay: Duration?
    func activePartyServer() async -> String? {
        if let lookupDelay { try? await Task.sleep(for: lookupDelay) }
        return active
    }
    func effectiveIdleServer() async -> String { idle }
    func refreshServerHealth() async {}
    func ensureConnected() async {}
    func partyPositionMs() async -> Int64? { 61_000 }

    /// How long a preview takes, so a test can land an invite while one is running.
    var previewDelay: Duration?
    func preview(code: String, server: String?) async -> Result<PartyPreview, PartyClientError> {
        previews.append((code, server))
        if let previewDelay { try? await Task.sleep(for: previewDelay) }
        return previewResult
    }

    func createParty(nickname: String, maxMembers: Int) async -> Result<String, PartyClientError> {
        creates.append(maxMembers)
        if case .success(let code) = createResult { state = Self.party(code: code, host: true) }
        return createResult
    }

    func joinParty(code: String, nickname: String) async -> Result<String, PartyClientError> {
        joins.append(code)
        if case .success = joinResult { state = Self.party(code: code, host: false) }
        return joinResult
    }

    func switchParty(server: String, code: String, nickname: String) async -> PartySwitchResult {
        switches.append((server, code))
        return switchResult
    }

    func leaveParty() async {
        left += 1
        state = PartySessionState()
    }

    func kick(memberId: String) { kicked.append(memberId) }
    func setHostOnlyControl(_ enabled: Bool) { hostOnly.append(enabled) }
    func setMaxMembers(_ value: Int) { sizes.append(value) }

    func setCustomServer(_ normalizedUrl: String) async -> PartyServerConnectionState {
        savedServers.append(normalizedUrl)
        customServer = normalizedUrl
        return normalizedUrl.isEmpty ? .defaultOnline(latencyMs: 20) : .customOnline(latencyMs: 40)
    }

    func probe(_ normalizedUrl: String) async -> PartyProbeResult { probeResult }

    static func party(code: String, host: Bool, members: Int = 2) -> PartySessionState {
        let all = (0..<members).map { PartyMember(memberId: "m\($0)", displayName: "Member \($0)", isHost: $0 == 0, connected: true) }
        return PartySessionState(code: code, you: host ? all[0] : all[min(1, members - 1)], members: all, maxMembers: 5,
                                 connection: .live, clockSynced: true, roundTripMs: 12)
    }
}

struct FixedReplaySource: ReplayDataSource {
    var summaries: [ReplayPeriod: ReplaySummary]
    var since: String? = "01/26"

    func summary(for period: ReplayPeriod) async -> ReplaySummary {
        summaries[period] ?? ReplaySummary(period: period, label: "")
    }

    func memberSince() async -> String? { since }
}

/// An app container that never touches the network, for the screens' environment.
@MainActor
func makeSocialApp() -> AppModel {
    var launch = AppLaunchOptions()
    launch.restoresQueue = false
    launch.integratesWithSystem = false
    launch.isUITest = true
    let suite = "vibramusic.social.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let settings = AppSettings(defaults: defaults, credentials: InMemoryCredentialStore())
    return AppModel(settings: settings, likeState: LikeState(),
                    searchHistory: SearchHistory(defaults: UserDefaults(suiteName: suite + ".h")!),
                    network: NetworkMonitor(), innerTube: InnerTubeClient(), audioCache: nil, launch: launch)
}

extension View {
    @MainActor
    func socialEnvironment(_ app: AppModel) -> some View {
        environment(app)
            .environment(app.player)
            .environment(app.router)
            .environment(app.settings)
            .environment(app.likeState)
            .environment(app.searchHistory)
    }
}

/// Hosts `view` in a window, forces layout, and lets SwiftUI settle.
@MainActor
@discardableResult
func hostSocial<V: View>(_ view: V, size: CGSize = CGSize(width: 393, height: 852), settle: TimeInterval = 0.4) -> UIHostingController<V> {
    let host = UIHostingController(rootView: view)
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.frame = window.bounds
    host.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    host.view.layoutIfNeeded()
    return host
}

@MainActor
func assertSocialRendered<V: View>(_ host: UIHostingController<V>, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNotNil(host.view.window, file: file, line: line)
    XCTAssertGreaterThan(host.view.bounds.height, 0, file: file, line: line)
    let drew = !(host.view.layer.sublayers ?? []).isEmpty || !host.view.subviews.isEmpty
    XCTAssertTrue(drew, "nothing was drawn", file: file, line: line)
}

/// Writes what `host` drew to `$UI_SNAPSHOT_DIR/<name>.png` when that is set, so a UI change
/// can be looked at as images after a test run.
/// Locally, pass `TEST_RUNNER_UI_SNAPSHOT_DIR=…` to xcodebuild. Does nothing when unset.
@MainActor
func uiSnapshot<V: View>(_ host: UIHostingController<V>, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["UI_SNAPSHOT_DIR"], !dir.isEmpty else { return }
    let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
    let image = renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
    try? image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
}
