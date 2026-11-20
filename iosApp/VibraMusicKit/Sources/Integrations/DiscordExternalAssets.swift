import VibraMusicCore
import Foundation
import os

/// Artwork URL resolution for Discord activities (ports `RpcImage.kt` and
/// `ArtworkCache.kt`).
///
/// Discord only renders a `large_image` it hosts, so external artwork URLs are
/// mirrored through the application's `external-assets` endpoint first. The
/// mirrored `mp:…` path is cached per source URL: without that cache every
/// track change would re-upload, and the endpoint rate-limits.
public enum DiscordRpcImage: Hashable, Sendable {
    /// An asset Discord already hosts (`mp:…` or a raw id).
    case discord(String)
    /// An arbitrary URL mirrored onto Discord's CDN, with an optional fallback.
    case external(String, fallbackDiscordAsset: String? = nil)

    /// Resolves to the string the presence payload carries.
    public func resolve(
        cache: DiscordArtworkCache,
        resolveExternal: @Sendable (String) async -> String?
    ) async -> String? {
        switch self {
        case .discord(let image):
            return image.hasPrefix("http") ? image : "mp:\(image)"
        case .external(let image, let fallback):
            if let cached = await cache.cached(image) { return cached }
            if let asset = await resolveExternal(image) {
                let resolved = asset.hasPrefix("http") || asset.hasPrefix("mp:") ? asset : "mp:\(asset)"
                await cache.store(resolved, for: image)
                return resolved
            }
            // Mirror failed: a raw http URL still renders for some clients;
            // otherwise fall back to the bundled asset.
            if image.hasPrefix("http") { return image }
            if let fallback {
                return fallback.hasPrefix("http") ? fallback : "mp:\(fallback)"
            }
            return nil
        }
    }
}

/// In-memory cache of mirrored artwork URLs (ports `ArtworkCache.kt`).
public actor DiscordArtworkCache {
    private var cache: [String: String] = [:]

    public init() {}

    public func cached(_ key: String) -> String? { cache[key] }

    public func store(_ value: String, for key: String) {
        cache[key] = value
    }

    public func getOrFetch(key: String, fetch: @Sendable () async -> String?) async -> String? {
        if let hit = cache[key] { return hit }
        guard let value = await fetch() else { return nil }
        cache[key] = value
        return value
    }

    public func removeAll() { cache.removeAll() }
}

private struct DiscordExternalAssetResponse: Decodable {
    var url: String?
    var externalAssetPath: String?

    enum CodingKeys: String, CodingKey {
        case url
        case externalAssetPath = "external_asset_path"
    }
}

/// Mirrors `imageUrl` onto Discord's CDN (ports `fetchExternalAsset`).
///
/// Returns the `mp:…` path, or `nil` when the image is already an `mp:` path
/// (passed through untouched) or the upload fails. Never throws: artwork is
/// best-effort and must not fail a presence update.
public func fetchDiscordExternalAsset(
    session: URLSession = VibraMusicHTTP.session,
    applicationId: String,
    token: String,
    imageUrl: String,
    userAgent: String? = nil,
    superPropertiesBase64: String? = nil
) async -> String? {
    if imageUrl.hasPrefix("mp:") { return imageUrl }
    guard let url = URL(string: "https://discord.com/api/v9/applications/\(applicationId)/external-assets") else {
        return nil
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(token, forHTTPHeaderField: "Authorization")
    request.setValue(userAgent ?? DiscordSuperProperties.userAgent, forHTTPHeaderField: "User-Agent")
    if let superPropertiesBase64 {
        request.setValue(superPropertiesBase64, forHTTPHeaderField: "X-Super-Properties")
    }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["urls": [imageUrl]])
    do {
        let (data, _) = try await session.data(for: request)
        let decoder = JSONDecoder()
        let list = try decoder.decode([DiscordExternalAssetResponse].self, from: data)
        guard let path = list.first?.externalAssetPath else { return nil }
        return "mp:\(path)"
    } catch {
        return nil
    }
}
