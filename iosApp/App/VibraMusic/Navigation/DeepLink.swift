import VibraMusicCore
import Foundation
import InnerTube
import ListenTogether

// Ports MainActivity.kt's intent handling (`handleIntent`): links into the app, shared text and
// party invites, routed to the screen that shows them.

/// What a URL opened into the app asks for.
enum DeepLink: Hashable {
    /// Play a track (a `watch?v=`, `youtu.be` or Shorts link).
    case track(videoId: String)
    /// Open an album, playlist or artist page.
    case page(browseId: String)
    /// Run a search; `play` starts the best match (a spoken request) instead of showing the list.
    case search(query: String, play: Bool)
    /// "Play music" with nothing named: carry on with what was playing.
    case resume
    /// Open the full player (the widget's tap target, `vibramusic://player`).
    case player
    /// Join a Listen Together party.
    case party(code: String, server: String?)
    /// A screen of the app itself (`vibramusic://settings`, `vibramusic://downloads`, …).
    case route(AppRoute)

    /// Reads a URL from `onOpenURL`, a Universal Link or the Share Extension. Nil for a link the
    /// app has nothing to show for (it has opened, which is the right answer).
    static func parse(_ url: URL) -> DeepLink? {
        if PlayerDeepLink.isOpenPlayer(url) { return .player }
        if let invite = JamInviteLink.parseInvite(url.absoluteString) {
            return .party(code: invite.code, server: invite.serverUrl)
        }
        if url.scheme?.lowercased() == "vibramusic" {
            return parseAppScheme(url)
        }
        return MusicLink.parse(url).map(DeepLink.init(request:))
    }

    /// A link in shared text ("Listen to X on YouTube Music: https://…").
    static func parse(sharedText: String) -> DeepLink? {
        if let invite = JamInviteLink.parseInvite(sharedText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .party(code: invite.code, server: invite.serverUrl)
        }
        if let found = sharedText.firstHTTPURL, let link = parse(found) { return link }
        return MusicLink.parse(sharedText: sharedText).map(DeepLink.init(request:))
    }

    init(request: MusicLinkRequest) {
        switch request {
        case .track(let videoId): self = .track(videoId: videoId)
        case .page(let browseId): self = .page(browseId: browseId)
        case .search(let query, let play): self = .search(query: query, play: play)
        case .resume: self = .resume
        }
    }

    /// `vibramusic://` links the app writes itself: the widget, the Share Extension handing a link
    /// over (`vibramusic://open?url=…`), shortcuts to screens.
    private static func parseAppScheme(_ url: URL) -> DeepLink? {
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func query(_ name: String) -> String? {
            components?.queryItems?.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let path = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch host {
        case "open":
            if let raw = query("url"), let inner = URL(string: raw), inner.scheme?.lowercased() != "vibramusic" { return parse(inner) }
            if let text = query("text") { return parse(sharedText: text) }
            return nil
        case "watch", "track", "play":
            let id = query("v") ?? query("id") ?? (path.isEmpty ? nil : path)
            return id.map { .track(videoId: $0) }
        case "browse", "album", "playlist", "artist", "page":
            let id = query("id") ?? (path.isEmpty ? nil : path)
            guard let id, !id.isEmpty else { return nil }
            if host == "playlist", !id.hasPrefix("VL") { return .page(browseId: "VL\(id)") }
            return .page(browseId: id)
        case "search":
            guard let q = query("q") ?? (path.isEmpty ? nil : path), !q.isEmpty else { return nil }
            return .search(query: q, play: query("play") == "1" || query("play") == "true")
        case "resume": return .resume
        case "settings": return .route(.settings)
        case "equalizer": return .route(.equalizer)
        case "downloads": return .route(.downloads)
        case "history": return .route(.history)
        case "replay": return .route(.replay)
        case "listen-together", "listentogether": return .route(.listenTogether)
        case "sources": return .route(.sources)
        case "account": return .route(.account)
        default: return nil
        }
    }
}

private extension String {
    /// The first http(s) URL in the text.
    var firstHTTPURL: URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(startIndex..., in: self)
        return detector.matches(in: self, range: range)
            .compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }
}
