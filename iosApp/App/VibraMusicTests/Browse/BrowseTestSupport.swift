import VibraMusicCore
import Foundation
import InnerTube
import SwiftUI
import UIKit
import XCTest
@testable import Vibra Music

// Test doubles for the Browse screens: recorded InnerTube answers served through a URLProtocol
// (so the real InnerTubeClient and YTMusicRepository run end to end), a scripted catalogue for the
// view-model rules, and a host for render smoke tests.

enum BrowseFixtures {
    static func data(_ name: String) throws -> Data {
        let url = Bundle(for: BrowseFixtureToken.self).url(forResource: name, withExtension: nil)
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)")
        return try Data(contentsOf: url)
    }
}

private final class BrowseFixtureToken {}

/// Answers `youtubei/v1/*` requests from fixtures, chosen by endpoint and body.
final class InnerTubeStub: URLProtocol {
    /// What a request is answered with: a fixture file name, or an HTTP status to fail with.
    enum Answer { case fixture(String), status(Int) }

    struct Route {
        let matches: @Sendable (_ path: String, _ body: [String: Any]) -> Bool
        let answer: Answer
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [Route] = []
    nonisolated(unsafe) private static var log: [String] = []

    static func install(_ newRoutes: [Route]) {
        lock.withLock { routes = newRoutes; log = [] }
    }

    /// Paths (plus browseId / query) of every request seen, in order.
    static var requests: [String] { lock.withLock { log } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InnerTubeStub.self]
        return URLSession(configuration: configuration)
    }

    /// The standard signed-out world: home, its supplements and continuation, moods, search.
    static func standardRoutes() -> [Route] {
        [
            Route(matches: { path, body in path.hasSuffix("/browse") && body["continuation"] != nil }, answer: .fixture("home_continuation_signed_in.json")),
            browse("FEmusic_home", "home.json"),
            browse("FEmusic_new_releases", "new_releases.json"),
            browse("FEmusic_explore", "explore.json"),
            browse("FEmusic_moods_and_genres", "moods_and_genres.json"),
            Route(matches: { path, body in path.hasSuffix("/browse") && (body["browseId"] as? String) == "FEmusic_moods_and_genres_category" },
                  answer: .fixture("mood_chill.json")),
            Route(matches: { path, _ in path.hasSuffix("get_search_suggestions") }, answer: .fixture("search_suggestions.json")),
            Route(matches: { path, body in path.hasSuffix("/search") && body["continuation"] != nil }, answer: .fixture("search_songs_continuation.json")),
            Route(matches: { path, body in path.hasSuffix("/search") && (body["params"] as? String) == SearchFilter.albums.params },
                  answer: .fixture("search_albums.json")),
            Route(matches: { path, body in path.hasSuffix("/search") && body["params"] != nil }, answer: .fixture("search_songs.json")),
            Route(matches: { path, _ in path.hasSuffix("/search") }, answer: .fixture("search_all.json")),
        ]
    }

    static func browse(_ browseId: String, _ fixture: String) -> Route {
        Route(matches: { path, body in path.hasSuffix("/browse") && (body["browseId"] as? String) == browseId }, answer: .fixture(fixture))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = Self.body(of: request)
        let label = path + " " + ((body["browseId"] as? String) ?? (body["query"] as? String) ?? (body["input"] as? String) ?? "")
        let route = Self.lock.withLock { () -> Route? in
            Self.log.append(label)
            return Self.routes.first { $0.matches(path, body) }
        }
        let url = request.url ?? URL(string: "https://music.youtube.com")!
        switch route?.answer {
        case .fixture(let name)?:
            do {
                let data = try BrowseFixtures.data(name)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        case .status(let status)?:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// The real repository over the stubbed transport.
@MainActor
func makeStubbedRepository(routes: [InnerTubeStub.Route] = InnerTubeStub.standardRoutes()) -> YTMusicRepository {
    InnerTubeStub.install(routes)
    let client = InnerTubeClient(session: InnerTubeStub.session(), language: { "en" }, retryBaseDelay: .milliseconds(1))
    return YTMusicRepository(client: client, likeState: LikeState())
}

/// A catalogue whose every answer the test scripts. Unscripted calls fail.
final class ScriptedCatalog: BrowseCatalog, @unchecked Sendable {
    var homeAnswer: () async throws -> HomeFeed = { throw URLError(.badServerResponse) }
    var recentAnswer: () async throws -> HomeShelf? = { nil }
    var supplementAnswers: [String: () async throws -> [HomeShelf]] = [:]
    var moreAnswer: (String) async throws -> HomeFeed = { _ in HomeFeed(shelves: [], continuation: nil) }
    var moodsAnswer: () async throws -> [MoodGenreSection] = { [] }
    var moodShelvesAnswer: (String) async throws -> [HomeShelf] = { _ in [] }
    var artworkAnswer: (String) async throws -> String? = { _ in nil }
    var searchAnswer: (String, SearchFilter) async throws -> InnerTubeParser.SearchPage = { _, _ in .init(rows: [], continuation: nil) }
    var continuationAnswer: (String) async throws -> InnerTubeParser.SearchPage = { _ in .init(rows: [], continuation: nil) }
    var suggestionsAnswer: (String) async throws -> [String] = { _ in [] }
    var typeaheadAnswer: (String) async throws -> InnerTubeParser.SearchPage = { _ in .init(rows: [], continuation: nil) }

    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func home() async throws -> HomeFeed { record("home"); return try await homeAnswer() }
    func homeRecentlyPlayed() async throws -> HomeShelf? { record("recent"); return try await recentAnswer() }
    func homeSupplement(browseId: String) async throws -> [HomeShelf] {
        record("supplement:\(browseId)")
        return try await (supplementAnswers[browseId] ?? { [] })()
    }
    func moreHome(token: String) async throws -> HomeFeed { record("more:\(token)"); return try await moreAnswer(token) }
    func moodAndGenres() async throws -> [MoodGenreSection] { record("moods"); return try await moodsAnswer() }
    func moodGenreShelves(browseId: String, params: String?) async throws -> [HomeShelf] {
        record("mood:\(browseId)")
        return try await moodShelvesAnswer(browseId)
    }
    func moodGenreArtwork(browseId: String, params: String?) async throws -> String? {
        record("artwork:\(params ?? browseId)")
        return try await artworkAnswer(params ?? browseId)
    }
    func searchPage(query: String, filter: SearchFilter) async throws -> InnerTubeParser.SearchPage {
        record("search:\(filter.rawValue):\(query)")
        return try await searchAnswer(query, filter)
    }
    func searchContinuation(token: String, filter: SearchFilter) async throws -> InnerTubeParser.SearchPage {
        record("continuation:\(token)")
        return try await continuationAnswer(token)
    }
    func searchSuggestions(input: String) async throws -> [String] { record("suggest:\(input)"); return try await suggestionsAnswer(input) }
    func searchTypeahead(input: String) async throws -> InnerTubeParser.SearchPage {
        record("typeahead:\(input)")
        return try await typeaheadAnswer(input)
    }
}

func shelf(_ title: String, _ ids: [String], subtitle: String = "") -> HomeShelf {
    HomeShelf(title: title, items: ids.map { ShelfItem(title: "Song \($0)", subtitle: "Song • Artist \($0)", thumbnailUrl: nil, videoId: $0, browseId: nil) }, subtitle: subtitle)
}

func track(_ id: String) -> SearchResult {
    .track(Song(videoId: id, title: "Song \(id)", artist: "Artist"))
}

/// An app built for tests: stubbed InnerTube, throwaway settings and history, no system hooks.
@MainActor
func makeBrowseTestApp(repositoryRoutes: [InnerTubeStub.Route] = InnerTubeStub.standardRoutes()) -> AppModel {
    InnerTubeStub.install(repositoryRoutes)
    let client = InnerTubeClient(session: InnerTubeStub.session(), language: { "en" }, retryBaseDelay: .milliseconds(1))
    let suite = "vibramusic.browse.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return AppModel(
        settings: makeTestSettings(),
        likeState: LikeState(),
        searchHistory: SearchHistory(defaults: defaults),
        network: NetworkMonitor(),
        innerTube: client,
        audioCache: nil,
        launch: AppLaunchOptions(restoresQueue: false, integratesWithSystem: false, isUITest: false)
    )
}

extension XCTestCase {
    /// Hosts `view` with the app's environment in a window, lays it out, and keeps the run loop
    /// turning until `until` holds (or `timeout`), so tasks and network stubs get to answer.
    @MainActor
    @discardableResult
    func host<V: View>(_ view: V, app: AppModel, colorScheme: ColorScheme = .dark,
                       size: CGSize = CGSize(width: 393, height: 852),
                       timeout: TimeInterval = 5, until: @escaping @MainActor () -> Bool = { true }) async -> UIHostingController<AnyView> {
        let root = AnyView(
            NavigationStack { view }
                .environment(app)
                .environment(app.router)
                .environment(app.player)
                .environment(app.settings)
                .environment(app.likeState)
                .environment(app.searchHistory)
                .environment(\.colorScheme, colorScheme)
        )
        let controller = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(timeout)
        while !until(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            controller.view.layoutIfNeeded()
        }
        controller.view.layoutIfNeeded()
        XCTAssertGreaterThan(controller.view.bounds.height, 0)
        addTeardownBlock { @MainActor in window.isHidden = true }
        return controller
    }
}
