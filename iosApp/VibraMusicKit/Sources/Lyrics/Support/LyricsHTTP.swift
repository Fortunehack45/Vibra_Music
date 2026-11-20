import Foundation

/// Shared plumbing for the lyric providers (Android: `LyricsHttp.kt`).
///
/// They are all raced against each other by `LyricsRepository`, so a provider that hangs
/// holds up the whole lookup. `standardDeadline` is deliberately far shorter than a
/// stream-oriented timeout: a lyric that arrives after the second chorus is of no use to
/// anyone, and the fallbacks behind it are the better answer.
///
/// iOS difference: OkHttp's `callTimeout` bounds the whole call, which `URLRequest`'s
/// `timeoutInterval` does not (it is an idle timeout). Every request here is therefore
/// also raced against a task that throws when the deadline passes — see `withLyricsDeadline`.
/// OkHttp's separate connect timeout has no per-request equivalent and is not reproduced.
struct LyricsHTTP: Sendable {
    static let agent = "Vibra Music (https://github.com/vibramusic)"

    /// `LYRICS_TIMEOUT_SECONDS`.
    static let standardDeadline: TimeInterval = 6
    /// PaxSenix's authenticated routes often have to query an upstream catalogue before
    /// answering; this matches its own client timeout so valid requests are not dropped.
    static let authenticatedDeadline: TimeInterval = 15

    let session: URLSession

    /// Body of a successful GET, or nil for any failure at all (Android: `lyricsGet`).
    func get(_ url: URL?) async -> String? {
        await get(url, headers: ["User-Agent": Self.agent, "Accept": "application/json"])
    }

    /// `lyricsGetBearer`: an authenticated provider GET without service-specific headers.
    func getBearer(_ url: URL?, bearer: String) async -> String? {
        guard !bearer.kIsBlank else { return nil }
        return await get(
            url,
            headers: [
                "User-Agent": Self.agent,
                "Accept": "application/json, text/plain, */*",
                "Authorization": "Bearer \(bearer)",
            ],
            deadline: Self.authenticatedDeadline
        )
    }

    /// `lyricsGetAuthorized`: a bearer token plus the headers Apple's own web player sends
    /// with one — `amp-api.music.apple.com` answers a token with no `Origin` at all the same
    /// way it answers a wrong one, with a 403.
    func getAuthorized(_ url: URL?, bearer: String) async -> String? {
        await get(
            url,
            headers: [
                "User-Agent": Self.agent,
                "Accept": "application/json",
                "Authorization": "Bearer \(bearer)",
                "Origin": "https://music.apple.com",
                "Referer": "https://music.apple.com/",
            ]
        )
    }

    /// A GET with exactly [headers]; nil for a non-2xx answer, a network error or the deadline.
    func get(_ url: URL?, headers: [String: String], deadline: TimeInterval = standardDeadline) async -> String? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try? await send(request, deadline: deadline)
    }

    /// A form POST (OkHttp's `FormBody`). Throws on any failure, so a caller can tell a
    /// failed request from an empty answer the way Android's `IOException` does.
    func postForm(
        _ url: URL,
        form: [(String, String)],
        headers: [String: String],
        deadline: TimeInterval
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(LyricsURL.formEncoded(form).utf8)
        return try await send(request, deadline: deadline)
    }

    /// A JSON POST; nil-free like `postForm`.
    func postJSON(_ url: URL, body: Data, headers: [String: String], deadline: TimeInterval) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await send(request, deadline: deadline)
    }

    private func send(_ request: URLRequest, deadline: TimeInterval) async throws -> String {
        var request = request
        request.timeoutInterval = deadline
        let session = session
        let sent = request
        let (data, response) = try await withLyricsDeadline(deadline) {
            try await session.data(for: sent)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LyricsHTTPError.status((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return Self.decode(data)
    }

    /// UTF-8, with a leading byte-order mark consumed the way OkHttp's `body.string()` does.
    static func decode(_ data: Data) -> String {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum LyricsHTTPError: Error, Equatable {
    case status(Int)
}

struct LyricsDeadlineExceeded: Error {}

/// Runs [operation], throwing `LyricsDeadlineExceeded` if it has not finished within
/// [seconds]. The operation is cancelled when the deadline wins.
func withLyricsDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw LyricsDeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

/// URL assembly with OkHttp's query encoding, so a signed URL (Musixmatch) is signed over
/// exactly the bytes that are sent.
enum LyricsURL {
    /// What `HttpUrl.Builder.addQueryParameter` leaves unescaped: letters, digits and `*-._`.
    private static let queryAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._"
    )

    static func encodeQueryComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }

    /// `base?name=value&...`, encoded the way OkHttp encodes it.
    static func string(_ base: String, _ query: [(String, String)]) -> String {
        guard !query.isEmpty else { return base }
        let joined = query.map { encodeQueryComponent($0.0) + "=" + encodeQueryComponent($0.1) }
            .joined(separator: "&")
        return base + (base.contains("?") ? "&" : "?") + joined
    }

    static func make(_ base: String, _ query: [(String, String)]) -> URL? {
        URL(string: string(base, query))
    }

    /// `application/x-www-form-urlencoded`, as OkHttp's `FormBody` and Java's `URLEncoder`
    /// write it: space as `+`, everything but letters, digits and `*-._` percent-encoded.
    static func formComponent(_ value: String) -> String {
        value.split(separator: " ", omittingEmptySubsequences: false)
            .map { encodeQueryComponent(String($0)) }
            .joined(separator: "+")
    }

    static func formEncoded(_ form: [(String, String)]) -> String {
        form.map { formComponent($0.0) + "=" + formComponent($0.1) }.joined(separator: "&")
    }
}
