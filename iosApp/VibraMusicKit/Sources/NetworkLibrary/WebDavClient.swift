import VibraMusicCore
import Foundation
import os

// Ports data/webdav/WebDavClient.kt: a minimal WebDAV client — PROPFIND
// directory listings over an injected URLSession, with HTTP Basic auth.
//
// Depth 1 is used per directory with manual recursion rather than
// `Depth: infinity`, which many servers (notably Nextcloud) reject. XML is
// parsed with Foundation's XMLParser so the parser stays pure and
// unit-testable.

private let webdavLog = Logger(subsystem: "com.fortune.vibramusic.ios", category: "NetworkLibrary")

/// A minimal WebDAV client over an injected `URLSession` (so tests can stub
/// it with `URLProtocolStub` from VibraMusicTestSupport).
public struct WebDavClient: Sendable {
    /// One row of a PROPFIND answer.
    public struct Entry: Hashable, Sendable {
        public var url: String
        public var displayName: String
        public var isCollection: Bool
        public var contentType: String?

        public init(url: String, displayName: String, isCollection: Bool, contentType: String? = nil) {
            self.url = url
            self.displayName = displayName
            self.isCollection = isCollection
            self.contentType = contentType
        }
    }

    /// Everything a library view needs: the audio plus the pictures filed
    /// beside it. Covers travel as `cover.jpg`/`folder.jpg` next to the music
    /// on every conventional server layout, and the listing that finds the
    /// tracks already walks past them — a second pass would pay the whole
    /// traversal again for files already in hand.
    public struct Listing: Sendable {
        public var audio: [Entry]
        public var images: [Entry]

        public init(audio: [Entry], images: [Entry]) {
            self.audio = audio
            self.images = images
        }
    }

    /// The outcome of a non-overwriting PUT.
    public enum PutResult: Sendable {
        case uploaded
        /// The server refused a non-overwriting PUT because the file is there.
        case alreadyExists
    }

    private static let propfindBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:displayname/>
            <d:resourcetype/>
            <d:getcontenttype/>
          </d:prop>
        </d:propfind>
        """

    private let session: URLSession

    public init(session: URLSession = VibraMusicHTTP.session) {
        self.session = session
    }

    // MARK: - Listing

    public func testConnection(_ credentials: WebDavCredentials) async throws {
        let target = credentials.rootUrl
        guard WebDavConfig.isConfigured(target) else { throw WebDavError("Enter a http(s) server URL") }
        let (_, response) = try await session.data(for: propfindRequest(url: target, depth: "0", credentials: credentials))
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) || code == 207 else {
            throw WebDavError("Server answered \(code)")
        }
    }

    public func listLibrary(_ credentials: WebDavCredentials, maxFiles: Int = 10_000) async throws -> Listing {
        let root = credentials.rootUrl
        guard WebDavConfig.isConfigured(root) else { throw WebDavError("WebDAV is not configured") }
        var foundAudio: [String: Entry] = [:]
        var foundImages: [String: Entry] = [:]
        var orderAudio: [String] = []
        var orderImages: [String] = []
        var dirs = [root]
        var visited = Set<String>()
        while let dir = dirs.popLast(), foundAudio.count < maxFiles {
            guard visited.insert(dir.lowercased()).inserted else { continue }
            let entries = try await propfind(dirUrl: dir, credentials: credentials)
            for entry in entries {
                if entry.isCollection {
                    if !visited.contains(entry.url.lowercased()) { dirs.append(entry.url) }
                } else {
                    let name = entry.displayName.isEmpty ? entry.url : entry.displayName
                    if WebDavConfig.isAudioFile(name) {
                        if foundAudio[entry.url] == nil {
                            foundAudio[entry.url] = entry
                            orderAudio.append(entry.url)
                        }
                    } else if Self.isImageFile(name) {
                        if foundImages[entry.url] == nil {
                            foundImages[entry.url] = entry
                            orderImages.append(entry.url)
                        }
                    }
                }
            }
        }
        return Listing(
            audio: orderAudio.compactMap { foundAudio[$0] },
            images: orderImages.compactMap { foundImages[$0] }
        )
    }

    public func listAudioFiles(_ credentials: WebDavCredentials, maxFiles: Int = 10_000) async throws -> [Entry] {
        try await listLibrary(credentials, maxFiles: maxFiles).audio
    }

    public static func isImageFile(_ name: String) -> Bool {
        let ext = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
        return ext == "jpg" || ext == "jpeg" || ext == "png" || ext == "webp"
    }

    private func propfindRequest(url: String, depth: String, credentials: WebDavCredentials) throws -> URLRequest {
        // A collection's href is the server's word, and the root is the user's typing.
        guard let target = URL(string: url) else { throw WebDavError("Bad URL: \(url)") }
        var request = URLRequest(url: target)
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)
        if let auth = credentials.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func propfind(dirUrl: String, credentials: WebDavCredentials) async throws -> [Entry] {
        let (data, response) = try await session.data(for: propfindRequest(url: dirUrl, depth: "1", credentials: credentials))
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 207 || (200...299).contains(code) else {
            throw WebDavError("Listing failed with \(code)")
        }
        let body = String(decoding: data, as: UTF8.self)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Self.parseMultistatus(xml: body, dirUrl: dirUrl)
    }

    // MARK: - Existence, upload, collections

    /// Whether `fileUrl` already exists. Any answer other than 200/404 is a
    /// failure rather than a guess — treating a 500 as "absent" is how an
    /// upload silently eats a file it was told not to touch.
    public func exists(fileUrl: String, credentials: WebDavCredentials) async throws -> Bool {
        guard let url = URL(string: fileUrl) else { throw WebDavError("Bad URL: \(fileUrl)") }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        if let auth = credentials.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return true
        case 404: return false
        case let code: throw WebDavError("Exists check failed with \(code ?? -1)")
        }
    }

    /// Streams `data` to `fileUrl`.
    ///
    /// Without `overwrite`, `If-None-Match: *` makes the absence check
    /// atomic: a 412 comes back instead of a clobbered file when something
    /// else won the race between `exists` and this call.
    ///
    /// Progress is coarse by design: `URLSession`'s async upload has no
    /// byte callback, and a delegate session would break stub injection, so
    /// `onProgress` fires with 0 up front and the full length on completion.
    /// Uploads run in the foreground and the per-track state still flips
    /// Queued → Running → Done around the transfer.
    public func putFile(
        fileUrl: String,
        data: Data,
        mimeType: String,
        credentials: WebDavCredentials,
        overwrite: Bool,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> PutResult {
        guard let url = URL(string: fileUrl) else { throw WebDavError("Bad URL: \(fileUrl)") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        if !overwrite { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        if let auth = credentials.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        onProgress?(0)
        let (_, response) = try await session.upload(for: request, from: data)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch code {
        case 200...299:
            onProgress?(Int64(data.count))
            return .uploaded
        case 412:
            return .alreadyExists
        default:
            throw WebDavError("Upload failed with \(code)")
        }
    }

    /// Streams the local file at `fileURL` to `targetUrl` without holding
    /// it in memory. Prefer this over `putFile(fileUrl:data:…)` for music
    /// files; a FLAC can be a hundred megabytes.
    public func putFile(
        targetUrl: String,
        fileURL: URL,
        mimeType: String,
        credentials: WebDavCredentials,
        overwrite: Bool,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> PutResult {
        guard let url = URL(string: targetUrl) else { throw WebDavError("Bad URL: \(targetUrl)") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        if !overwrite { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        if let auth = credentials.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let total = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? -1
        onProgress?(0)
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch code {
        case 200...299:
            if total > 0 { onProgress?(total) }
            return .uploaded
        case 412:
            return .alreadyExists
        default:
            throw WebDavError("Upload failed with \(code)")
        }
    }

    /// Creates the collection at `dirUrl`, if it isn't one already. 405
    /// means something is already there, which is the happy path wearing an
    /// error code; anything else out of 2xx is a real failure.
    public func ensureCollection(dirUrl: String, credentials: WebDavCredentials) async throws {
        guard let url = URL(string: dirUrl) else { throw WebDavError("Bad URL: \(dirUrl)") }
        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        if let auth = credentials.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) || code == 405 else {
            throw WebDavError("Could not create folder (\(code))")
        }
    }

    // MARK: - PROPFIND parsing

    /// Parses a PROPFIND multistatus response. Pure function of the XML and
    /// the directory it was asked of — the entry the server echoes back for
    /// the directory itself is dropped.
    public static func parseMultistatus(xml: String, dirUrl: String) -> [Entry] {
        guard !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let parser = MultistatusParser(dirUrl: dirUrl)
        guard parser.parse(Data(xml.utf8)) else {
            webdavLog.error("PROPFIND XML did not parse for \(dirUrl, privacy: .public)")
            return []
        }
        return parser.entries
    }

    public static func resolveHref(baseUrl: String, href: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return trimmed }
        let base = WebDavConfig.normalizeUrl(baseUrl)
        guard let components = URLComponents(string: base),
              let scheme = components.scheme, let host = components.host
        else { return trimmed }
        var schemeHost = "\(scheme)://\(host)"
        if let port = components.port { schemeHost += ":\(port)" }
        if trimmed.hasPrefix("/") { return schemeHost + trimmed }
        return base + "/" + trimmed
    }

    /// `root/<segment>`, with the segment percent-encoded. `/`, `?` and `#`
    /// never pass through raw: a segment is one path element, never a
    /// sub-path or a query string.
    public static func joinUrl(root: String, segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
        let root = root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(root)/\(encoded)"
    }

    /// The name a track is stored under: `Artist - Title.ext`, or just the
    /// title when there is no artist worth naming. Filesystem-hostile
    /// characters never reach the server — a `/` in a title would otherwise
    /// file it into a folder nobody asked for.
    public static func uploadFileName(title: String, artist: String, fileExtension: String) -> String {
        let rawBase = (!artist.isEmpty && artist != "Unknown Artist") ? "\(artist) - \(title)" : title
        let sanitized = rawBase.map { character -> Character in
            if character == "/" || character == "\\" { return "_" }
            if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) { return "_" }
            return character
        }
        var name = String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") || name.hasSuffix(".") {
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        if name.isEmpty { name = "track" }
        if name.count > 120 { name = String(name.prefix(120)) }
        var ext = fileExtension.lowercased()
        while ext.hasPrefix(".") { ext = String(ext.dropFirst()) }
        if ext.isEmpty { ext = "mp3" }
        return "\(name).\(ext)"
    }

    /// First name in `base`, `base (1)`, `base (2)`, … that isn't in `taken`.
    /// Compared case-insensitively: servers that ignore case would otherwise
    /// hand back a "new" name that collides on disk.
    public static func resolveNumberedName(base: String, fileExtension: String, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        var candidate = "\(base).\(fileExtension)"
        var n = 1
        while lowered.contains(candidate.lowercased()), n < 1000 {
            candidate = "\(base) (\(n)).\(fileExtension)"
            n += 1
        }
        return candidate
    }
}

// MARK: - Ranged reads for streaming

/// Why a WebDAV operation failed. The message is user-presentable.
public struct WebDavError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension WebDavClient {
    /// Length and type for one file: HEAD first, falling back to a
    /// one-byte range read when the server won't answer HEAD (some
    /// servers only speak GET).
    public func audioContentInfo(fileURL: String, credentials: WebDavCredentials) async throws -> RemoteContentInfo {
        guard let url = URL(string: fileURL) else { throw WebDavError("Bad URL: \(fileURL)") }
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        if let auth = credentials.authHeader {
            head.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let info = try? await contentInfoFromHead(head, fileURL: fileURL) {
            return info
        }
        // Fallback: `bytes=0-0` answers the total in Content-Range.
        let probe = try await getRange(url: url, range: 0..<1, credentials: credentials)
        if let range = probe.response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) })
        {
            return RemoteContentInfo(
                contentLength: total,
                mimeType: probe.response.mimeType ?? RemoteMimeTypes.mimeType(forFileName: fileURL),
                fileExtension: String(fileURL.split(separator: ".").last?.lowercased() ?? "")
            )
        }
        // Servers that ignore Range answer 200 with the whole file; only
        // the first byte was kept, but the length is still unknown.
        throw WebDavError("No length for \(fileURL)")
    }

    private func contentInfoFromHead(_ request: URLRequest, fileURL: String) async throws -> RemoteContentInfo {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WebDavError("Info failed")
        }
        var length: Int64?
        if let raw = http.value(forHTTPHeaderField: "Content-Length"), let parsed = Int64(raw) {
            length = parsed
        }
        guard let length else { throw WebDavError("No length for \(fileURL)") }
        return RemoteContentInfo(
            contentLength: length,
            mimeType: http.mimeType ?? RemoteMimeTypes.mimeType(forFileName: fileURL),
            fileExtension: String(fileURL.split(separator: ".").last?.lowercased() ?? "")
        )
    }

    /// The bytes in `range`, through a Range GET. Servers that ignore Range
    /// answer 200 with the whole file; the read is sliced down rather than
    /// failing, because a cover at the front is still reachable that way.
    public func readRange(fileURL: String, range: Range<Int64>, credentials: WebDavCredentials) async throws -> Data {
        guard let url = URL(string: fileURL) else { throw WebDavError("Bad URL: \(fileURL)") }
        guard !range.isEmpty else { return Data() }
        let probe = try await getRange(url: url, range: range, credentials: credentials)
        if probe.response.statusCode == 206 { return probe.data }
        // 200 without range support: only the front is usable.
        guard range.lowerBound == 0 else { return Data() }
        return probe.data.prefix(Int(range.count))
    }

    private func getRange(url: URL, range: Range<Int64>, credentials: WebDavCredentials) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        if let auth = credentials.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDavError("Bad response") }
        guard http.statusCode == 206 || http.statusCode == 200 else {
            throw WebDavError("Range read failed with \(http.statusCode)")
        }
        return (data, http)
    }
}

// MARK: - Multistatus XML

/// Namespace-tolerant `multistatus` parser: matches elements by local name,
/// so `d:`, `D:` and default-namespace answers all parse.
private final class MultistatusParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let dirUrl: String
    private(set) var entries: [WebDavClient.Entry] = []

    private var inResponse = false
    private var elementStack: [String] = []
    private var text = ""
    private var href = ""
    private var displayName = ""
    private var contentType: String?
    private var hasCollection = false

    init(dirUrl: String) {
        self.dirUrl = dirUrl
    }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        return parser.parse()
    }

    private static func local(_ elementName: String, _ qualifiedName: String?) -> String {
        if !elementName.isEmpty { return elementName.lowercased() }
        return (qualifiedName?.split(separator: ":").last.map(String.init) ?? "").lowercased()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.local(elementName, qName)
        elementStack.append(name)
        text = ""
        if name == "response" {
            inResponse = true
            href = ""
            displayName = ""
            contentType = nil
            hasCollection = false
        } else if name == "collection", inResponse {
            hasCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.local(elementName, qName)
        if inResponse {
            switch name {
            case "href": href = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "displayname": displayName = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "getcontenttype":
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                contentType = value.isEmpty ? nil : value
            case "response":
                inResponse = false
                let url = WebDavClient.resolveHref(baseUrl: dirUrl, href: href)
                guard !href.isEmpty, !isSameUrl(url, dirUrl) else { break }
                let name = displayName.isEmpty ? decodedName(url) : displayName
                entries.append(WebDavClient.Entry(
                    url: url,
                    displayName: name,
                    isCollection: hasCollection,
                    contentType: contentType
                ))
            default: break
            }
        }
        if !elementStack.isEmpty { elementStack.removeLast() }
        text = ""
    }

    private func isSameUrl(_ left: String, _ right: String) -> Bool {
        func norm(_ value: String) -> String {
            var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
            return trimmed.lowercased()
        }
        return norm(left) == norm(right)
    }

    private func decodedName(_ url: String) -> String {
        var trimmed = url
        while trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return last.removingPercentEncoding ?? last
    }
}
