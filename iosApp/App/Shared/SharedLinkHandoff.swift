import Foundation
import UniformTypeIdentifiers

/// How a link shared into Vibra Music reaches the app (Android's `ACTION_SEND` into MainActivity).
///
/// The Share Extension wraps what it was given in the app's own scheme — `vibramusic://open?url=…`
/// for a link, `vibramusic://open?text=…` for text — which the app's `DeepLink` reads like any other
/// link, and opens it. If the system refuses to open the app from the extension, the link is left
/// in the App Group instead and served the next time the app comes to the front.
enum SharedLinkHandoff {
    static let defaultsKey = "shared_link_pending"
    static let savedAtKey = "shared_link_pending_at"
    /// A share left waiting longer than this is stale: opening the app an hour later shouldn't
    /// start a song somebody shared and forgot about.
    static let lifetime: TimeInterval = 10 * 60

    /// The `vibramusic://open` URL for a shared link or text; nil when there is nothing to hand over.
    static func appURL(link: URL?, text: String?) -> URL? {
        var components = URLComponents()
        components.scheme = SharedConstants.urlScheme
        components.host = "open"
        if let link, ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
            components.queryItems = [URLQueryItem(name: "url", value: link.absoluteString)]
        } else if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        } else {
            return nil
        }
        return components.url
    }

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: SharedConstants.appGroup) }

    static func save(_ url: URL, to defaults: UserDefaults? = sharedDefaults, now: Date = Date()) {
        defaults?.set(url.absoluteString, forKey: defaultsKey)
        defaults?.set(now.timeIntervalSince1970, forKey: savedAtKey)
    }

    /// The waiting share, removed as it is read (it is served once); nil when there is none or it
    /// has gone stale.
    static func take(from defaults: UserDefaults? = sharedDefaults, now: Date = Date()) -> URL? {
        guard let defaults, let raw = defaults.string(forKey: defaultsKey) else { return nil }
        let savedAt = defaults.double(forKey: savedAtKey)
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: savedAtKey)
        guard now.timeIntervalSince1970 - savedAt <= lifetime else { return nil }
        return URL(string: raw)
    }

    /// The first web link among the attachments, and the shared text (which often carries the link
    /// after a title, the way YouTube Music shares).
    static func readShared(_ items: [NSExtensionItem]) async -> (URL?, String?) {
        var link: URL?
        var text: String?
        for item in items {
            if text == nil, let content = item.attributedContentText?.string, !content.isEmpty { text = content }
            for provider in item.attachments ?? [] {
                if link == nil, provider.canLoadObject(ofClass: URL.self) {
                    link = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                }
                if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let string = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    text = string
                }
            }
        }
        return (link, text)
    }
}
