import VibraMusicCore
import Foundation
import InnerTube
import SwiftUI
import XCTest
@testable import VibraMusic

// Helpers for the Account tests. Names carry "Account" so they can't collide with helpers other
// areas keep in the same test bundle.

/// Settings on a throwaway defaults suite with credentials in memory.
@MainActor
func makeAccountTestSettings() -> AppSettings {
    let suite = "vibramusic.account.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return AppSettings(defaults: defaults, credentials: InMemoryCredentialStore())
}

/// An app container that never restores a queue, integrates with the system or touches the
/// network on its own.
@MainActor
func makeAccountTestApp(settings: AppSettings? = nil) -> AppModel {
    var launch = AppLaunchOptions()
    launch.restoresQueue = false
    launch.integratesWithSystem = false
    launch.isUITest = true
    return AppModel(
        settings: settings ?? makeAccountTestSettings(),
        likeState: LikeState(),
        searchHistory: SearchHistory(defaults: UserDefaults(suiteName: "vibramusic.account.history.\(UUID().uuidString)")!),
        network: NetworkMonitor(),
        innerTube: InnerTubeClient(session: makeAccountOfflineSession()),
        audioCache: nil,
        launch: launch
    )
}

/// A session every request fails on, so nothing in these tests reaches the network.
func makeAccountOfflineSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AccountOfflineURLProtocol.self]
    return URLSession(configuration: configuration)
}

final class AccountOfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// Two Google logins — the first with a Personal and a Brand profile — as the account store holds
/// them.
func makeAccountTestSessions() -> [GoogleAccountSession] {
    let personal = YouTubeProfile(profileId: "p-personal", name: "Maya", handle: "@maya", dataSyncId: "ds-personal")
    let brand = YouTubeProfile(profileId: "p-brand", name: "Night Drive", pageId: "page-brand", dataSyncId: "page-brand",
                               isBrandAccount: true)
    let work = YouTubeProfile(profileId: "p-work", name: "Maya Work", dataSyncId: "ds-work")
    return [
        GoogleAccountSession(accountId: "acct-a", cookie: "SAPISID=a; __Secure-3PAPISID=a", name: "Maya",
                             email: "maya@example.com", profiles: [personal, brand], activeProfileId: personal.profileId),
        GoogleAccountSession(accountId: "acct-b", cookie: "SAPISID=b; __Secure-3PAPISID=b", name: "Maya Work",
                             email: "", profiles: [work], activeProfileId: work.profileId),
    ]
}

/// An account manager over an in-memory store holding `sessions`, the first one active, restored.
@MainActor
func makeAccountTestManager(_ sessions: [GoogleAccountSession] = makeAccountTestSessions()) async -> YouTubeAccountManager {
    let store = YouTubeAuthStore(credentials: InMemoryCredentialStore())
    store.replaceSessions(sessions)
    if let first = sessions.first {
        store.select(accountId: first.accountId, profileId: first.activeProfileId)
    }
    let client = InnerTubeClient(session: makeAccountOfflineSession())
    let manager = YouTubeAccountManager(client: client, repository: YTMusicRepository(client: client), store: store)
    await manager.restore()
    return manager
}

extension View {
    /// Everything the account screens read from the environment.
    @MainActor
    func accountTestEnvironment(_ app: AppModel) -> some View {
        environment(app)
            .environment(app.router)
            .environment(app.player)
            .environment(app.settings)
            .environment(app.likeState)
            .environment(app.searchHistory)
            // The alerts fade their card in from zero opacity on appear; a hosted test window may never
            // tick that animation, so land every change at once and draw the card as it settles.
            .transaction { $0.disablesAnimations = true }
    }
}

/// Hosts `view` in a window, forces layout, lets SwiftUI settle, and checks something was drawn.
@MainActor
@discardableResult
func accountHostAndLayOut<V: View>(_ view: V, size: CGSize = CGSize(width: 393, height: 852), settle: TimeInterval = 0.4,
                                   file: StaticString = #filePath, line: UInt = #line) -> UIHostingController<V> {
    let host = UIHostingController(rootView: view)
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.frame = window.bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    host.view.layoutIfNeeded()
    XCTAssertNotNil(host.view.window, file: file, line: line)
    XCTAssertGreaterThan(host.sizeThatFits(in: size).height, 0, file: file, line: line)
    // Drawn, not just laid out: a snapshot of the window must hold more than one colour. (SwiftUI
    // may draw plain text and shapes without a subview or sublayer per element, so counting those
    // says nothing.)
    XCTAssertTrue(accountSnapshotHasContent(host.view), "nothing was rendered", file: file, line: line)
    return host
}

/// Whether a snapshot of `view` holds more than one colour.
@MainActor
func accountSnapshotHasContent(_ view: UIView) -> Bool {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return false }
    let length = CFDataGetLength(data)
    let stride = max(cgImage.bitsPerPixel / 8, 1)
    guard length >= stride else { return false }
    for offset in Swift.stride(from: stride, to: length - stride + 1, by: stride * 7) {
        for channel in 0..<stride where bytes[offset + channel] != bytes[channel] {
            return true
        }
    }
    return false
}

/// Runs the main run loop until `condition` holds or `timeout` passes.
@MainActor
func accountWait(timeout: TimeInterval = 3, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
