import Foundation
import Observation

// Ports playback/MusicLink.kt and playback/PlayerDeepLink.kt.

/// What a link, a share or a voice request from outside the app turned out to be asking for.
public enum MusicLinkRequest: Hashable, Sendable {
    /// A song, by video id — `watch?v=`, a `youtu.be` short link, a Short.
    case track(videoId: String)
    /// An album, playlist or artist page, by browse id.
    case page(browseId: String)
    /// Words rather than an id: "play Blinding Lights", or a shared search URL.
    ///
    /// `play` separates the two. A spoken request is an instruction — it should start the best
    /// match, not leave a list on screen for someone whose phone is in their pocket — while a search
    /// *link* is a page somebody meant to show you.
    case search(query: String, play: Bool)
    /// "Play music", with nothing said about what.
    case resume
}

/// Reading YouTube and YouTube Music URLs, shared text and voice queries.
///
/// On iOS these arrive through `onOpenURL` (universal links and the `vibramusic://` scheme), a Share
/// Extension (URLs and text), and App Intents / SiriKit for voice. Android also had to mark an
/// intent consumed so a configuration change wouldn't replay it; `onOpenURL` fires once per open,
/// so that guard has no counterpart here.
public enum MusicLink {
    /// What a YouTube or YouTube Music URL points at, or nil for one this app has nothing to show
    /// for.
    ///
    /// Deliberately forgiving about the host: `music.youtube.com`, `www.youtube.com`,
    /// `m.youtube.com` and `youtu.be` all address the same catalogue with the same ids, and a link is
    /// as likely to arrive through a share sheet as through the browser.
    public static func parse(_ url: URL) -> MusicLinkRequest? {
        guard let rawHost = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let host = rawHost.removingPrefix("www.")
        let segments = pathSegments(of: url)
        if host == "youtu.be" {
            return segments.first.flatMap(track)
        }
        guard host == "youtube.com" || host == "music.youtube.com" || host == "m.youtube.com" else { return nil }
        let list = queryParameter("list", in: url)?.trimmedText ?? ""
        switch segments.first {
        case "watch":
            // A watch link often carries the playlist it was opened from as well. The video is what
            // was tapped, so it wins; the list only stands in when the link names no video at all,
            // which is how YT Music writes "play this album" links.
            return queryParameter("v", in: url).flatMap(track) ?? playlist(list)
        case "playlist":
            return playlist(list)
        case "shorts", "embed", "v":
            // A Short and an embed are both a bare id in the path.
            return segments.element(at: 1).flatMap(track)
        case "channel", "browse":
            // `channel/UC…` is an artist; `browse/MPREb…` is a release. Both are browse ids already.
            guard let id = segments.element(at: 1), !id.isBlankText else { return nil }
            return .page(browseId: id)
        case "search":
            guard let query = queryParameter("q", in: url)?.trimmedText, !query.isEmpty else { return nil }
            return .search(query: query, play: false)
        default:
            // A link to nothing in particular — music.youtube.com itself, an account page. Opening
            // the app is the right answer, and that has already happened.
            return list.isEmpty ? nil : playlist(list)
        }
    }

    /// The request in shared text. Share sheets rarely send the bare link: YT Music sends the song's
    /// title and a newline before it, other apps wrap it in a sentence.
    public static func parse(sharedText text: String) -> MusicLinkRequest? {
        guard let found = firstURL(in: text), let url = URL(string: found) else { return nil }
        return parse(url)
    }

    /// The assistant's "play <something>". An empty query is the whole point of ``MusicLinkRequest/resume``:
    /// "play music" names nothing, and the useful answer is to carry on with what was already on.
    public static func request(forVoiceQuery query: String?) -> MusicLinkRequest {
        let trimmed = query?.trimmedText ?? ""
        return trimmed.isEmpty ? .resume : .search(query: trimmed, play: true)
    }

    /// The first http(s) URL in text.
    static func firstURL(in text: String) -> String? {
        urlInText.firstMatch(in: text)
    }

    private static let urlInText = TextPattern(#"https?://\S+"#)

    private static func track(_ videoId: String) -> MusicLinkRequest? {
        let id = videoId.trimmedText
        return id.isEmpty ? nil : .track(videoId: id)
    }

    /// A playlist id as the browse id its page is fetched under. `VL` is the prefix every playlist
    /// browse carries — an album's `OLAK5uy_…` share id included, which is the shape a "share this
    /// album" link out of YT Music actually has.
    private static func playlist(_ listId: String) -> MusicLinkRequest? {
        guard !listId.isEmpty else { return nil }
        return .page(browseId: listId.hasPrefix("VL") ? listId : "VL\(listId)")
    }

    /// Decoded, non-empty path segments (Android's `Uri.pathSegments`).
    private static func pathSegments(of url: URL) -> [String] {
        url.path(percentEncoded: true)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }
    }

    /// The first value of `name`, decoded as a form value (`+` is a space), like Android's
    /// `Uri.getQueryParameter`.
    private static func queryParameter(_ name: String, in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let item = components.percentEncodedQueryItems?.first(where: { $0.name == name }) else { return nil }
        let raw = (item.value ?? "").replacingOccurrences(of: "+", with: "%20")
        return raw.removingPercentEncoding ?? raw
    }
}

/// Holds a link request until the part of the app that can act on it is ready.
///
/// What has to happen — start a queue, push a page, run a search — lives in the app's navigation and
/// player, which may not exist yet when a cold launch delivers the URL. The request is cleared by
/// whoever acted on it (``handled()``), not by whoever set it.
@MainActor
@Observable
public final class MusicLinkRelay {
    public static let shared = MusicLinkRelay()

    /// The outstanding request, or nil.
    public private(set) var pending: MusicLinkRequest?

    public init() {}

    /// Reads a URL and reports whether it carried a request.
    @discardableResult
    public func consume(url: URL) -> Bool {
        store(MusicLink.parse(url))
    }

    /// Reads shared text and reports whether it carried a request.
    @discardableResult
    public func consume(sharedText: String) -> Bool {
        store(MusicLink.parse(sharedText: sharedText))
    }

    /// Records a voice query (always a request: an empty one is ``MusicLinkRequest/resume``).
    public func consume(voiceQuery: String?) {
        pending = MusicLink.request(forVoiceQuery: voiceQuery)
    }

    /// Called once the request has actually been acted on.
    public func handled() {
        pending = nil
    }

    private func store(_ request: MusicLinkRequest?) -> Bool {
        guard let request else { return false }
        pending = request
        return true
    }
}

/// A request from outside the app to open the full player — tapping a widget's artwork should land
/// on Now Playing.
///
/// On iOS the widget carries ``url`` as its `widgetURL`; `onOpenURL` hands it to ``consume(url:)``,
/// and the root view opens the player sheet and calls ``handled()``. Cleared by whoever acts, so a
/// request isn't served twice when the scene is rebuilt.
@MainActor
@Observable
public final class PlayerDeepLink {
    public static let shared = PlayerDeepLink()

    /// The URL that asks for the player. Nothing else uses this host.
    public nonisolated static let url = URL(string: "vibramusic://player")!

    /// Whether a request is outstanding.
    public private(set) var pending = false

    public init() {}

    /// Whether `url` asks for the player.
    public nonisolated static func isOpenPlayer(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "vibramusic" && url.host()?.lowercased() == "player"
    }

    /// Reads an incoming URL, and reports whether it asked for the player.
    @discardableResult
    public func consume(url: URL) -> Bool {
        guard Self.isOpenPlayer(url) else { return false }
        pending = true
        return true
    }

    /// Called once the player has actually been opened.
    public func handled() {
        pending = false
    }
}
