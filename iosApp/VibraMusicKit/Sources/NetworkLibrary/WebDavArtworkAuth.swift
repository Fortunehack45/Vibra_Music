import Foundation

// Ports data/webdav/WebDavCoilAuth.kt: the WebDAV credential on cover loads
// aimed at the configured server.
//
// Android needed this because Coil fetches with its own transport, which
// never passes through the app HTTP client's auth interceptor — so without
// it every in-app cover went out without `Authorization`, came back 401, and
// read as "this track has no artwork". On iOS the same applies to any image
// loader that doesn't share the app's session: the loader asks here for the
// header to attach. Runs per image request, so it decides on strings alone
// and touches nothing else.

/// Authenticated artwork loading for the configured WebDAV server.
public enum WebDavArtworkAuth {
    /// The credential for `urlString`, or nil when the request wants nothing
    /// added: it already carries an `Authorization` header, it isn't aimed
    /// at the configured host, or no credential is configured. Pure so it
    /// stays unit-testable without a request.
    public static func authHeaderFor(
        _ urlString: String?,
        credentials: WebDavCredentials,
        existingAuthorization: String? = nil
    ) -> String? {
        if existingAuthorization != nil { return nil }
        guard let urlString, urlString.lowercased().hasPrefix("http"),
              let host = URL(string: urlString)?.host,
              credentials.shouldAuthorize(requestHost: host)
        else { return nil }
        return credentials.authHeader
    }

    /// A GET request for an artwork URL with the credential attached when it
    /// applies, for loaders that fetch outside the app's session.
    public static func authorizedRequest(for urlString: String, credentials: WebDavCredentials) -> URLRequest? {
        guard let url = URL(string: urlString), url.scheme?.isEmpty == false, url.host != nil else { return nil }
        var request = URLRequest(url: url)
        if let header = authHeaderFor(urlString, credentials: credentials) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
