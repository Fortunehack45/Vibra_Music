import Foundation

/// How Spotify's web player asks for a track's Canvas today: the `canvas` GraphQL query on
/// Pathfinder v2, rather than the `canvaz-cache` protobuf endpoint (Android:
/// `SpotifyCanvasQuery` in `shared/.../data/canvas/SpotifyCanvasQuery.kt`).
///
/// This is the request/response half only, free of any HTTP client so it can be tested without a
/// network. Like every Pathfinder operation the query is named by a persisted-query hash that
/// changes when Spotify rebuilds the web player: `knownCanvasHash` is the last one known to work,
/// and `CanvasQueryHashes` reads the live one out of the web player's own scripts.
enum SpotifyCanvasQuery {
    static let endpoint = "https://api-partner.spotify.com/pathfinder/v2/query"
    static let operation = "canvas"

    /// The `canvas` query's hash as of January 2026.
    static let knownCanvasHash = "575138ab27cd5c1b3e54da54d0a7cc8d85485402de26340c2145f0f6bb5e7a9f"

    /// What an answer to the query said.
    enum Answer: Equatable {
        /// The track has a canvas at `url`.
        case found(url: String, type: String?)
        /// Spotify answered without a video URL this can play; `detail` is for the log.
        case noCanvas(detail: String)
        /// The query itself didn't work (unparseable, GraphQL errors and no data). A stale hash
        /// reads as "PersistedQueryNotFound"; `staleHash` tells the caller to look it up again.
        case failed(reason: String, staleHash: Bool = false)
    }

    /// The JSON body for `POST endpoint`.
    static func requestBody(trackURI: String, hash: String) -> Data {
        let body: [String: Any] = [
            "operationName": operation,
            "variables": ["trackUri": trackURI],
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Reads `data.trackUnion.canvas.url` out of an answer.
    static func parse(_ body: String) -> Answer {
        guard let root = CanvasJSON.parse(body)?.object else { return .failed(reason: "not JSON") }
        let errors = root["errors"]?.array?.compactMap { $0.object?["message"]?.string } ?? []
        guard let data = root["data"]?.object else {
            let reason = errors.joined(separator: "; ")
            return .failed(
                reason: reason.isEmpty ? "no data" : reason,
                staleHash: errors.contains { $0.localizedCaseInsensitiveContains("PersistedQueryNotFound") })
        }
        guard let canvas = data["trackUnion"]?.object?["canvas"]?.object else {
            // What came back, for the log: a track with no canvas and an answer in another shape read
            // the same here, and only the body tells them apart. It holds no credentials.
            return .noCanvas(detail: "canvas null; answer: \(body.prefix(400))")
        }
        // The web player plays video canvases from `fileId` through its own player and only reads
        // `url` for images and GIFs, so a video canvas can come back without a plain MP4 URL.
        // Describe it rather than collapse it into "none".
        let detail = "type=\(canvas["type"]?.string ?? "null") fileId=\(canvas["fileId"]?.string ?? "null") "
            + "url=\(canvas["url"]?.string ?? "null")"
        guard let url = canvas["url"]?.string, url.hasPrefix("https://") else { return .noCanvas(detail: detail) }
        // Some canvases are still images; this plays video only.
        guard url.range(of: #"\.mp4(?:[?#]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return .noCanvas(detail: detail)
        }
        return .found(url: url, type: canvas["type"]?.string)
    }

    // MARK: - The live hash

    /// `"canvas","query","<64 hex>"`, the way the web player's bundle declares its operations.
    private static let operationDeclaration = try! NSRegularExpression(
        pattern: #"["'](\w+)["']\s*,\s*["']query["']\s*,\s*["']([0-9a-f]{64})["']"#)

    private static let webPlayerScript = try! NSRegularExpression(
        pattern: #"https://open\.spotifycdn\.com/cdn/build/web-player/[A-Za-z0-9._~-]+\.js"#)

    /// `operation`'s hash as declared in a piece of the web player's JavaScript, if it's there.
    static func findQueryHash(in script: String, operation: String = operation) -> String? {
        let range = NSRange(script.startIndex..., in: script)
        for match in operationDeclaration.matches(in: script, range: range) {
            guard let name = Range(match.range(at: 1), in: script),
                  let hash = Range(match.range(at: 2), in: script),
                  script[name] == operation else { continue }
            return String(script[hash])
        }
        return nil
    }

    /// The web player's own script bundles, as linked from open.spotify.com's page.
    static func webPlayerScripts(in html: String) -> [String] {
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        return webPlayerScript.matches(in: html, range: range).compactMap { match in
            Range(match.range, in: html).map { String(html[$0]) }
        }.filter { seen.insert($0).inserted }
    }
}

/// The current `canvas` hash, read off the web player's scripts and remembered for a while.
/// `fetch` is the app's own GET (URL in, body out, nil on failure). Falls back to the known hash
/// whenever the scripts can't be read, and doesn't retry a failed lookup on every track.
actor CanvasQueryHashes {
    private static let foundTTL: TimeInterval = 12 * 60 * 60
    private static let missedTTL: TimeInterval = 30 * 60

    private let fetch: @Sendable (String) async -> String?
    private let maxScripts: Int
    private var hash: String?
    private var checkedAt: Date?

    init(maxScripts: Int = 8, fetch: @escaping @Sendable (String) async -> String?) {
        self.fetch = fetch
        self.maxScripts = maxScripts
    }

    func canvasHash(forceRefresh: Bool = false) async -> String {
        if !forceRefresh, let checkedAt,
           Date().timeIntervalSince(checkedAt) < (hash != nil ? Self.foundTTL : Self.missedTTL) {
            return hash ?? SpotifyCanvasQuery.knownCanvasHash
        }
        checkedAt = Date()
        if let found = await lookUp() { hash = found }
        return hash ?? SpotifyCanvasQuery.knownCanvasHash
    }

    private func lookUp() async -> String? {
        guard let html = await fetch("https://open.spotify.com/") else { return nil }
        for script in SpotifyCanvasQuery.webPlayerScripts(in: html).prefix(maxScripts) {
            guard let body = await fetch(script) else { continue }
            if let found = SpotifyCanvasQuery.findQueryHash(in: body) { return found }
        }
        return nil
    }
}
