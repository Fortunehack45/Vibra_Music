import VibraMusicCore
import Foundation
import InnerTube
import Sources
import SwiftUI
import XCTest
@testable import Vibra Music

// Helpers for the Settings tests. Names carry "Settings" so they can't collide with helpers other
// areas keep in the same test bundle.

/// Settings on a throwaway defaults suite with credentials in memory.
@MainActor
func makeSettingsTestSettings() -> AppSettings {
    let suite = "vibramusic.settings.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return AppSettings(defaults: defaults, credentials: InMemoryCredentialStore())
}

/// An app container that never restores a queue, integrates with the system or touches the network
/// on its own.
@MainActor
func makeSettingsTestApp(settings: AppSettings) -> AppModel {
    var launch = AppLaunchOptions()
    launch.restoresQueue = false
    launch.integratesWithSystem = false
    launch.isUITest = true
    return AppModel(
        settings: settings,
        likeState: LikeState(),
        searchHistory: SearchHistory(defaults: UserDefaults(suiteName: "vibramusic.settings.history.\(UUID().uuidString)")!),
        network: NetworkMonitor(),
        innerTube: InnerTubeClient(),
        audioCache: nil,
        launch: launch
    )
}

extension View {
    /// Everything the Settings screens read from the environment.
    @MainActor
    func settingsTestEnvironment(_ app: AppModel) -> some View {
        environment(app)
            .environment(app.router)
            .environment(app.player)
            .environment(app.settings)
            .environment(app.likeState)
            .environment(app.searchHistory)
    }
}

/// Hosts `view` in a window, forces layout, lets SwiftUI settle, and checks something was drawn.
@MainActor
@discardableResult
func settingsHostAndLayOut<V: View>(_ view: V, size: CGSize = CGSize(width: 393, height: 852),
                                    file: StaticString = #filePath, line: UInt = #line) -> UIHostingController<V> {
    let host = UIHostingController(rootView: view)
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.frame = window.bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    host.view.layoutIfNeeded()
    XCTAssertNotNil(host.view.window, file: file, line: line)
    XCTAssertEqual(host.view.bounds.size, size, file: file, line: line)
    let fitting = host.sizeThatFits(in: size)
    XCTAssertGreaterThan(fitting.height, 0, file: file, line: line)
    XCTAssertFalse(host.view.subviews.isEmpty, "nothing was rendered", file: file, line: line)
    return host
}

/// A source registry held in memory, with the given sources stored, and a session that answers
/// from `SettingsStubURLProtocol`.
@MainActor
func makeSettingsTestRegistry(_ extra: [SourceConfig] = []) -> SourceRegistry {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SettingsStubURLProtocol.self]
    let environment = SourceEnvironment(
        session: URLSession(configuration: configuration),
        deviceCodecs: .fixed(true),
        dolbyAtmosEnabled: { true },
        manifestFiles: SourceManifestFiles(directory: FileManager.default.temporaryDirectory
            .appending(path: "settings-manifests-\(UUID().uuidString)", directoryHint: .isDirectory))
    )
    let registry = SourceRegistry(store: nil, environment: environment)
    extra.forEach(registry.add)
    return registry
}

/// Answers requests by host + path from a table; anything else is a 404.
final class SettingsStubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body: Data
        var contentType = "application/json"
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]

    static func reply(_ hostAndPath: String, json: String) {
        lock.withLock { replies[hostAndPath] = Reply(body: Data(json.utf8)) }
    }

    static func reset() {
        lock.withLock { replies = [:] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let key = (url.host() ?? "") + url.path(percentEncoded: true)
        let reply = Self.lock.withLock { Self.replies[key] } ?? Reply(status: 404, body: Data())
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension UIView {
    /// Every accessibility value in the hierarchy SwiftUI built, such as a slider's reading.
    var renderedValues: [String] {
        var found: [String] = []
        func walk(_ element: Any) {
            if let object = element as? NSObject {
                if let value = object.accessibilityValue, !value.isEmpty { found.append(value) }
                for child in object.accessibilityElements ?? [] { walk(child) }
            }
            if let view = element as? UIView { view.subviews.forEach(walk) }
        }
        walk(self)
        return found
    }
}

/// The accessibility values `host` drew, giving SwiftUI's accessibility tree (and a re-render after
/// a setting changed) a moment to report `expected`.
@MainActor
func settledRenderedValues<V: View>(_ host: UIHostingController<V>, until expected: String) async -> [String] {
    for _ in 0..<20 {
        host.view.layoutIfNeeded()
        let values = host.view.renderedValues
        if values.contains(expected) { return values }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return host.view.renderedValues
}
