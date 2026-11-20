import Foundation

/// A pair of BotGuard proof-of-origin tokens for one play. Port of `PoTokenResult`.
public struct StreamPoToken: Sendable, Hashable {
    /// Sent in the `player` request as `serviceIntegrityDimensions.poToken`.
    public var playerRequestToken: String
    /// Appended to googlevideo URLs as `pot=`.
    public var streamingDataToken: String

    public init(playerRequestToken: String, streamingDataToken: String) {
        self.playerRequestToken = playerRequestToken
        self.streamingDataToken = streamingDataToken
    }
}

/// Mints PoTokens for web clients. A protocol so the WebKit implementation
/// (`WebViewPoTokenProvider`) can be left out, replaced, or faked in tests: the resolver works
/// without one, it just walks the web identities without tokens.
public protocol StreamPoTokenProvider: Sendable {
    /// Tokens bound to `visitorData` (the session) and `videoId`, or nil when this provider
    /// cannot mint at all (a broken web engine). Throws for a failure worth retrying later.
    func poToken(videoId: String, visitorData: String) async throws -> StreamPoToken?
    /// Releases the web view and anything else held.
    func close() async
    /// Does the expensive once-per-session work (BotGuard) ahead of the first track.
    func prewarm(visitorData: String) async
}

extension StreamPoTokenProvider {
    public func prewarm(visitorData: String) async {}
}

public enum StreamPoTokenError: Error, LocalizedError, Equatable {
    /// The web engine itself cannot run the BotGuard page (a `SyntaxError` before init
    /// finished). Permanent for the process, like Android's `BadWebViewException`.
    case badWebView(String)
    /// Anything else — Google's remotely served BotGuard code failing, a timeout, a dead web
    /// content process. Transient.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .badWebView(let detail): return "this web view cannot mint PoTokens: \(detail)"
        case .failed(let detail): return "PoToken generation failed: \(detail)"
        }
    }

    /// Port of `buildExceptionForJsError`: only a syntax error in our own static page means
    /// the engine is unusable.
    static func fromJavaScriptError(_ message: String) -> StreamPoTokenError {
        message.contains("SyntaxError") ? .badWebView(message) : .failed(message)
    }
}
