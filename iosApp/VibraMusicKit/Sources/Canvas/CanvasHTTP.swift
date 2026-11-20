import VibraMusicCore
import Foundation

/// Shared plumbing for the canvas providers (Android: `canvasGet` / `canvasGetWithStatus` in
/// `data/canvas/CanvasArtwork.kt`).
///
/// Canvas is decoration: no provider failure is allowed to reach the caller, so `get` answers
/// nil for anything that isn't a 2xx or that throws, and none of these hosts are ours to
/// depend on.
struct CanvasHTTP: Sendable {
    /// The browser UA these catalog endpoints expect; they 403 an unknown one.
    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/122.0.0.0 Safari/537.36"

    static let deadline: TimeInterval = 15

    let session: URLSession

    /// Body of a successful GET, or nil for any failure at all.
    func get(_ url: URL?, headers: [String: String] = [:]) async -> String? {
        await result(for: url, method: "GET", headers: headers, body: nil)?.body
    }

    /// Same as `get`, but keeps the status code even on failure — for the few callers where
    /// "it wasn't a 2xx" needs to say *which* code, rather than collapsing every kind of
    /// failure into the same nil.
    func getWithStatus(_ url: URL?, headers: [String: String] = [:]) async -> (Int, String?) {
        guard let result = await result(for: url, method: "GET", headers: headers, body: nil) else {
            return (-1, nil)
        }
        return (result.status, result.status / 100 == 2 ? result.body : nil)
    }

    /// A POST with `body`, returning the raw response bytes on 2xx, or nil otherwise.
    func post(_ url: URL?, headers: [String: String] = [:], body: Data) async -> (Int, Data?) {
        guard let result = await result(for: url, method: "POST", headers: headers, body: body) else {
            return (-1, nil)
        }
        return (result.status, result.status / 100 == 2 ? Data(result.body.utf8) : nil)
    }

    /// A POST returning raw bytes (for protobuf endpoints), on 2xx, or nil otherwise.
    func postBytes(_ url: URL?, headers: [String: String] = [:], body: Data) async -> (Int, Data?) {
        guard let url else { return (-1, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.deadline
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = body
        let sent = request
        do {
            let (data, response) = try await withCanvasDeadline(Self.deadline) {
                try await self.session.data(for: sent)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (status, status / 100 == 2 ? data : nil)
        } catch {
            return (-1, nil)
        }
    }

    private func result(
        for url: URL?, method: String, headers: [String: String], body: Data?
    ) async -> (status: Int, body: String)? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.deadline
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = body
        let sent = request
        do {
            let (data, response) = try await withCanvasDeadline(Self.deadline) {
                try await self.session.data(for: sent)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status / 100 == 2 else { return (status, "") }
            return (status, Self.decode(data))
        } catch {
            return nil
        }
    }

    /// UTF-8, with a leading byte-order mark consumed the way OkHttp's `body.string()` does.
    static func decode(_ data: Data) -> String {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct CanvasDeadlineExceeded: Error {}

/// Runs `operation`, throwing `CanvasDeadlineExceeded` if it has not finished within `seconds`.
/// `URLRequest.timeoutInterval` is an idle timeout, not OkHttp's whole-call timeout, so every
/// request here is also raced against a task that throws when the deadline passes.
func withCanvasDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw CanvasDeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

func canvasLogDebug(_ message: String) {
    DebugLog.d("Canvas", message)
}

func canvasLogWarning(_ message: String) {
    DebugLog.w("Canvas", message)
}

/// URL assembly with OkHttp's query encoding, so requests are byte-identical to Android's.
enum CanvasURL {
    private static let queryAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._"
    )

    static func encodeQueryComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }

    static func make(_ base: String, _ query: [(String, String)]) -> URL? {
        guard !query.isEmpty else { return URL(string: base) }
        let joined = query.map { encodeQueryComponent($0.0) + "=" + encodeQueryComponent($0.1) }
            .joined(separator: "&")
        return URL(string: base + (base.contains("?") ? "&" : "?") + joined)
    }
}
