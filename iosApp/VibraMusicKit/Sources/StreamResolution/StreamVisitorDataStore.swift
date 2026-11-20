import VibraMusicCore
import Foundation

/// The facts this module reads out of the signed-out music.youtube.com shell (`ytcfg`).
///
/// Read by regex rather than by evaluating the config blob: it is one script assignment among
/// hundreds of kilobytes of app JavaScript, and the values wanted are flat strings in it. A key
/// that moves reads as absent, which is the same as not having asked.
struct MusicShellFacts: Sendable, Equatable {
    var visitorData: String?
    var clientVersion: String?
    /// e.g. `/s/player/7460dd14/player_es6.vflset/en_US/base.js`
    var playerJsPath: String?
    var loggedIn: Bool?

    /// The 8-hex player hash out of `playerJsPath`.
    var playerHash: String? { playerJsPath.flatMap(PlayerScriptLocator.hash(inPath:)) }

    static func parse(_ html: String) -> MusicShellFacts {
        MusicShellFacts(
            visitorData: firstMatch(#""VISITOR_DATA"\s*:\s*"([^"]+)""#, in: html),
            clientVersion: firstMatch(#""INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)""#, in: html),
            playerJsPath: firstMatch(#""jsUrl"\s*:\s*"([^"]+)""#, in: html)
                ?? firstMatch(#""PLAYER_JS_URL"\s*:\s*"([^"]+)""#, in: html),
            loggedIn: firstMatch(#""LOGGED_IN"\s*:\s*(true|false)"#, in: html).map { $0 == "true" }
        )
    }
}

/// First capture group of `pattern` in `text`.
func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
          let captured = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[captured])
}

/// Google's per-session visitor id, fetched deliberately rather than hoped for.
///
/// Far more load-bearing than "an id for stats". A `player` request with no visitor id is
/// treated as a client with no session at all and answered in one of two ways: honestly
/// (`LOGIN_REQUIRED`, measured for ANDROID_VR today) or quietly, with URLs that serve a byte and
/// then refuse every real read. Port of `Innertube.ensureVisitorData` and friends.
///
/// Acquisition: the music.youtube.com shell's `VISITOR_DATA` first (the same page also names the
/// live `WEB_REMIX` version and the player script, which the resolver wants anyway), then the
/// service-worker bootstrap `sw.js_data` Android used. Cached in memory, persisted with a time
/// stamp so a relaunch does not pay for it, and replaced on `refresh`.
public actor StreamVisitorDataStore {
    private let session: URLSession
    private let defaults: UserDefaults?
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date

    private var visitorData: String?
    private var fetchedAt: Date?
    /// Whether `visitorData` came from a signed-in shell. A session-bound id outranks an
    /// anonymous one and must not be replaced by it: both are fetched near startup and nothing
    /// orders them, so without this the better id was lost to whichever finished second.
    private var isSessionBound = false
    private var shell: MusicShellFacts?
    private var inFlight: Task<String?, Never>?

    static let defaultsValueKey = "streamresolution.visitorData"
    static let defaultsDateKey = "streamresolution.visitorDataFetchedAt"
    static let shellURL = URL(string: "https://music.youtube.com/")!
    static let serviceWorkerURL = URL(string: "https://www.youtube.com/sw.js_data")!

    /// - Parameters:
    ///   - defaults: where to persist the anonymous id across launches; nil keeps it in memory.
    ///   - maxAge: how long a persisted id is trusted. Ids live far longer than this; the bound
    ///     is there so a burned one cannot survive forever across relaunches.
    public init(
        session: URLSession = VibraMusicHTTP.session, defaults: UserDefaults? = nil, maxAge: TimeInterval = 24 * 3600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.defaults = defaults
        self.maxAge = maxAge
        self.now = now
        if let stored = defaults?.string(forKey: Self.defaultsValueKey),
           let at = defaults?.object(forKey: Self.defaultsDateKey) as? Date,
           now().timeIntervalSince(at) < maxAge, Self.looksLikeVisitorData(stored) {
            visitorData = stored
            fetchedAt = at
        }
    }

    /// A visitor id for this session, minting one if there isn't one yet.
    ///
    /// - Parameter refresh: discard the current id and take a fresh one — worth doing exactly
    ///   once when a request comes back accusing us of being a bot.
    public func visitorData(refresh: Bool = false) async -> String? {
        if !refresh, let visitorData, !isExpired { return visitorData }
        let task: Task<String?, Never>
        if let inFlight {
            task = inFlight
        } else {
            task = Task { await self.fetchFresh() }
            inFlight = task
        }
        let fresh = await task.value
        if inFlight == task { inFlight = nil }
        if let fresh, refresh || !isSessionBound {
            visitorData = fresh
            fetchedAt = now()
            isSessionBound = false
            defaults?.set(fresh, forKey: Self.defaultsValueKey)
            defaults?.set(fetchedAt, forKey: Self.defaultsDateKey)
        }
        return visitorData
    }

    /// The id already in hand, without fetching.
    public var current: String? { visitorData }

    /// Adopt the visitor id of a signed-in shell. Strictly better than the anonymous one: the
    /// stats pings are attributed against the visitor the player response was issued to.
    public func adoptSessionBound(_ value: String) {
        guard !value.isEmpty else { return }
        visitorData = value
        fetchedAt = now()
        isSessionBound = true
    }

    /// Forget the id (sign-in or sign-out: it belonged to the session that just left).
    public func invalidate() {
        visitorData = nil
        fetchedAt = nil
        isSessionBound = false
        defaults?.removeObject(forKey: Self.defaultsValueKey)
        defaults?.removeObject(forKey: Self.defaultsDateKey)
    }

    /// The last shell read, fetching one if none has been.
    func musicShell() async -> MusicShellFacts? {
        if let shell { return shell }
        _ = await visitorData(refresh: visitorData == nil)
        if shell == nil { _ = try? await fetchShell() }
        return shell
    }

    /// The live WEB_REMIX version, if a shell has been read.
    var shellClientVersion: String? { shell?.clientVersion }

    private var isExpired: Bool {
        guard let fetchedAt, !isSessionBound else { return false }
        return now().timeIntervalSince(fetchedAt) >= maxAge
    }

    private func fetchFresh() async -> String? {
        do {
            if let fromShell = try await fetchShell()?.visitorData, Self.looksLikeVisitorData(fromShell) {
                return fromShell
            }
        } catch {
            streamLog.warning("music.youtube.com shell fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            if let fromWorker = try await fetchServiceWorkerData() { return fromWorker }
        } catch {
            streamLog.warning("could not mint a visitor id: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    private func fetchShell() async throws -> MusicShellFacts? {
        var request = URLRequest(url: Self.shellURL)
        request.setValue(StreamPlayerClient.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let facts = MusicShellFacts.parse(String(decoding: data, as: UTF8.self))
        shell = facts
        return facts
    }

    /// The service worker bootstrap the web player loads before anything else. It answers with
    /// an anti-hijacking prefix and then plain nested arrays, so the id is found by shape rather
    /// than by a path that would rot.
    private func fetchServiceWorkerData() async throws -> String? {
        var request = URLRequest(url: Self.serviceWorkerURL)
        request.setValue(StreamPlayerClient.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, _) = try await session.data(for: request)
        return Self.visitorData(fromServiceWorkerData: String(decoding: data, as: UTF8.self))
    }

    static func visitorData(fromServiceWorkerData body: String) -> String? {
        let payload: Substring
        if let newline = body.firstIndex(of: "\n") {
            payload = body[body.index(after: newline)...]
        } else {
            payload = body.dropFirst(5)
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8), options: [.fragmentsAllowed])
        else { return nil }
        return findVisitorData(json)
    }

    private static func findVisitorData(_ element: Any) -> String? {
        if let array = element as? [Any] {
            for child in array { if let found = findVisitorData(child) { return found } }
        } else if let text = element as? String, looksLikeVisitorData(text) {
            return text
        }
        return nil
    }

    /// Protobuf-in-base64; always this shape, and nothing else in there is.
    static func looksLikeVisitorData(_ text: String) -> Bool {
        text.range(of: #"^Cg[A-Za-z0-9_%-]{40,}$"#, options: .regularExpression) != nil
    }
}
