import VibraMusicCore
import Foundation

/// Apple Music's motion artwork — the animated sleeves the web player shows on an album page,
/// exposed on the catalog API as `editorialVideo` (Android: `AppleMusicCanvas` in
/// `data/canvas/AppleMusicCanvas.kt`).
///
/// The richest of the canvas sources and the fussiest to reach. Two problems to solve: the
/// endpoint needs a bearer token, and a free-text search will return a plausible-looking
/// wrong album for almost any query.
///
/// The token is the same read-only one the web player mints for anonymous visitors, so it is
/// scraped rather than owned — see `CanvasAppleTokenStore`. The search is scored rather than
/// trusted: results are ranked on how well the artist, track and album line up, compilations
/// and radio-style playlists are dropped outright, and anything that doesn't clear the bar is
/// skipped even if it is the only hit. A wrong canvas is worse than none.
///
/// The clips are HLS, which `AVPlayer` plays natively.
public struct AppleMusicCanvas: Sendable {
    static let catalog = "https://amp-api.music.apple.com/v1/catalog"
    static let webPlayer = URL(string: "https://music.apple.com/us/browse")!

    private let http: CanvasHTTP
    private let tokens: CanvasAppleTokenStore
    private let storefront: String

    public init(
        session: URLSession = VibraMusicHTTP.session,
        storefront: String? = nil,
        tokens: CanvasAppleTokenStore? = nil
    ) {
        let session = session
        http = CanvasHTTP(session: session)
        self.tokens = tokens ?? CanvasAppleTokenStore(session: session)
        self.storefront = storefront ?? Self.deviceStorefront
    }

    /// Motion artwork is per storefront; uses the device's region when it looks sane.
    public static var deviceStorefront: String {
        let region = Locale.current.region?.identifier.lowercased() ?? ""
        return region.count == 2 ? region : "us"
    }

    public func search(title: String, artist: String, album: String?) async -> CanvasArtwork? {
        guard let bearer = await tokens.token() else { return nil }

        // The catalog search is term-based, so fold everything known into the term — an artist
        // name alone pulls in their whole discography and the scoring below then has to reject
        // all of it.
        var term = ""
        if !title.localizedCaseInsensitiveContains(artist) { term += artist + " " }
        term += title
        if let album, !album.isBlankForCanvas, !title.localizedCaseInsensitiveContains(album) {
            term += " " + album
        }

        guard let url = CanvasURL.make(Self.catalog + "/\(storefront)/search", [
            ("term", term), ("types", "songs"), ("limit", "10"),
            ("extend", "editorialVideo"), ("include", "albums"),
        ]) else { return nil }

        guard let body = await authorizedGet(url, bearer: bearer) else { return nil }
        guard let hits = Self.jsonObject(body)?["results"]?.object?["songs"]?.object?["data"]?.array
        else { return nil }

        let ranked = hits.compactMap { $0.object }
            .compactMap { song -> (Int, [String: CanvasJSON])? in
                guard let score = Self.score(song, title: title, artist: artist, album: album) else {
                    return nil
                }
                return (score, song)
            }
            .sorted { $0.0 > $1.0 }

        for (score, song) in ranked {
            if score < Self.minimumScore {
                canvasLogDebug("AppleMusicCanvas: no hit scored above \(Self.minimumScore) for '\(title)' (best was \(score))")
                break
            }
            let attributes = song["attributes"]?.object ?? [:]
            let songName = attributes["name"]?.string
            let songArtist = attributes["artistName"]?.string
            let albumName = attributes["albumName"]?.string

            // Some searches already carry the motion artwork inline, which saves the album
            // round trip entirely.
            if let video = attributes["editorialVideo"]?.object,
               let (primary, alternate, tall) = Self.motionURLs(video)
            {
                canvasLogDebug("AppleMusicCanvas: inline motion artwork for '\(songName ?? "?")'")
                return CanvasArtwork(
                    url: primary, fallbackUrl: alternate, tallUrl: tall,
                    title: songName, artist: songArtist, album: albumName)
            }

            guard let albumId = Self.albumID(song) else { continue }
            if let found = await fetchAlbum(albumId, bearer: bearer, songTitle: songName, songArtist: songArtist) {
                return found
            }
        }
        return nil
    }

    /// Motion artwork for a release rather than a track, for the album page's header artwork.
    ///
    /// Simpler than the song path: albums carry `editorialVideo` inline on the search result,
    /// so there is no second lookup to resolve an id first.
    public func searchAlbum(album: String, artist: String) async -> CanvasArtwork? {
        guard let bearer = await tokens.token() else { return nil }
        let term = album.localizedCaseInsensitiveContains(artist) ? album : "\(artist) \(album)"

        guard let url = CanvasURL.make(Self.catalog + "/\(storefront)/search", [
            ("term", term), ("types", "albums"), ("limit", "10"), ("extend", "editorialVideo"),
        ]) else { return nil }

        guard let body = await authorizedGet(url, bearer: bearer) else { return nil }
        guard let hits = Self.jsonObject(body)?["results"]?.object?["albums"]?.object?["data"]?.array
        else { return nil }

        let ranked = hits.compactMap { $0.object }
            .compactMap { record -> (Int, [String: CanvasJSON])? in
                // An album is its own "album" as far as the scoring goes, which is what keeps a
                // deluxe edition from outranking the plain one.
                guard let score = Self.score(
                    record, title: album, artist: artist, album: album, albumIsSelf: true)
                else { return nil }
                return (score, record)
            }
            .sorted { $0.0 > $1.0 }

        for (score, record) in ranked {
            if score < Self.minimumScore { break }
            let attributes = record["attributes"]?.object ?? [:]
            let name = attributes["name"]?.string
            if let name, Self.isCompilation(name) { continue }
            guard let video = attributes["editorialVideo"]?.object,
                  let (primary, alternate, tall) = Self.motionURLs(video)
            else { continue }
            canvasLogDebug("AppleMusicCanvas: motion artwork for album '\(name ?? "?")'")
            return CanvasArtwork(
                url: primary, fallbackUrl: alternate, tallUrl: tall, title: name,
                artist: attributes["artistName"]?.string, album: name)
        }
        return nil
    }

    // MARK: - Search scoring

    /// The floor a hit has to clear. An exact artist and an exact title alone reach 25, so this
    /// only ever admits a result that matched on both, or one that matched the artist plus a
    /// fuzzy title and the right album.
    static let minimumScore = 12

    /// How well a search hit lines up with what's playing, or nil to reject it outright.
    /// Artist is a gate rather than a score: a clip credited to someone else is never the
    /// right one, however well the title reads.
    static func score(
        _ song: [String: CanvasJSON],
        title: String,
        artist: String,
        album: String?,
        albumIsSelf: Bool = false
    ) -> Int? {
        let attributes = song["attributes"]?.object ?? [:]
        let hitName = attributes["name"]?.string ?? ""
        let hitArtist = attributes["artistName"]?.string ?? ""
        let hitAlbum = albumIsSelf ? hitName : (attributes["albumName"]?.string ?? "")

        if isCompilation(hitName) || isCompilation(hitAlbum) { return nil }

        let wanted = canvasSplitArtists(artist)
        let credited = canvasSplitArtists(hitArtist)
        if wanted.isEmpty || credited.isEmpty { return nil }
        if !wanted.allSatisfy({ want in credited.contains(want) }) { return nil }

        var score = 10

        let wantTitle = title.normalizedForCanvasMatch
        let hitTitle = hitName.normalizedForCanvasMatch
        if hitTitle == wantTitle {
            score += 15
        } else if hitTitle.contains(wantTitle) || wantTitle.contains(hitTitle) {
            score += 7
        } else {
            // Same artist, different song. Apple returns these freely and they are exactly the
            // mismatch that has to be kept out.
            score -= 10
        }

        if let album, !album.isBlankForCanvas, !hitAlbum.isBlankForCanvas {
            let wantAlbum = album.normalizedForCanvasMatch
            let gotAlbum = hitAlbum.normalizedForCanvasMatch
            if gotAlbum == wantAlbum {
                score += 20
            } else if gotAlbum.contains(wantAlbum) || wantAlbum.contains(gotAlbum) {
                score += 10
            }
        }

        // A "(Deluxe)" or "(Remastered)" on one side only is a different master of the same
        // track, and often a different clip.
        for word in editionWords {
            let inWanted = title.localizedCaseInsensitiveContains(word)
            let inHit = hitName.localizedCaseInsensitiveContains(word)
            if inWanted && inHit { score += 5 } else if inHit { score -= 3 }
        }

        return score
    }

    static let editionWords = ["deluxe", "expanded", "remastered", "remix", "version", "edit", "mix", "bonus"]

    /// Editorial playlists and radio mixes have motion artwork of their own, and Apple returns
    /// them alongside albums. Theirs belongs to the playlist, not to the track, so putting one
    /// behind a sleeve is always wrong.
    static func isCompilation(_ name: String) -> Bool {
        let lower = name.lowercased()
        return compilationMarkers.contains { lower.contains($0) }
    }

    static let compilationMarkers = [
        "playlist", "set list", "essentials", "dj mix", "mixed",
        "apple music", "today's hits", "session",
    ]

    // MARK: - Album lookup

    static func albumID(_ song: [String: CanvasJSON]) -> String? {
        if let fromRelationship = song["relationships"]?.object?["albums"]?.object?["data"]?.array?
            .first?.object?["id"]?.string
        {
            if fromRelationship.hasPrefix("pl.") { return nil }
            return fromRelationship
        }

        // Not every hit expands its relationships, but the web URL always ends in the album
        // id: .../album/<slug>/<id>?i=<song id>
        guard let url = song["attributes"]?.object?["url"]?.string,
              url.contains("/album/")
        else { return nil }
        let afterAlbum = url.components(separatedBy: "/album/").last ?? ""
        let beforeQuery = afterAlbum.components(separatedBy: "?").first ?? ""
        let id = beforeQuery.components(separatedBy: "/").last ?? ""
        return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
    }

    private func fetchAlbum(
        _ albumId: String, bearer: String, songTitle: String?, songArtist: String?
    ) async -> CanvasArtwork? {
        guard let url = CanvasURL.make(Self.catalog + "/\(storefront)/albums/\(albumId)", [
            ("extend", "editorialVideo"),
        ]) else { return nil }
        guard let body = await authorizedGet(url, bearer: bearer) else { return nil }
        guard let album = Self.jsonObject(body)?["data"]?.array?.first?.object else { return nil }

        let attributes = album["attributes"]?.object ?? [:]
        let albumName = attributes["name"]?.string ?? ""
        if Self.isCompilation(albumName) { return nil }

        guard let video = attributes["editorialVideo"]?.object,
              let (primary, alternate, tall) = Self.motionURLs(video)
        else { return nil }

        canvasLogDebug("AppleMusicCanvas: motion artwork on album '\(albumName)' (\(albumId))")
        return CanvasArtwork(
            url: primary, fallbackUrl: alternate, tallUrl: tall, title: songTitle,
            artist: songArtist ?? attributes["artistName"]?.string, album: albumName)
    }

    /// The square rendition first — it fills a square sleeve without cropping. The tall one is
    /// the same clip framed for a phone-shaped surface and is only worth having as the retry
    /// when the square won't play. It also comes back on its own, unless it is the primary
    /// already: the lock screen's full-screen key takes it beside the square.
    static func motionURLs(_ video: [String: CanvasJSON]) -> (primary: String, alternate: String?, tall: String?)? {
        func link(_ key: String) -> String? {
            guard let asset = video[key]?.object else { return nil }
            let url = asset["video"]?.string ?? asset["videoUrl"]?.string
                ?? asset["hlsUrl"]?.string ?? asset["url"]?.string
            return url.flatMap { $0.isEmpty ? nil : $0 }
        }

        let square = link("motionDetailSquare") ?? link("motionSquareVideo1x1")
        let raw = link("motionDetailRaw")
        let tall = link("motionDetailTall") ?? link("motionTallVideo3x4")
        guard let primary = square ?? raw ?? tall else { return nil }
        let alternate = [square, raw, tall].compactMap { $0 }.first { $0 != primary }
        return (primary, alternate, tall == primary ? nil : tall)
    }

    // MARK: - Authenticated reads

    /// An authenticated catalog read. A 401 means the token picked out of the bundle isn't the
    /// one this endpoint honours, so it is struck off and the next lookup re-scrapes and picks
    /// a different one — the alternative is being locked out until the app restarts.
    private func authorizedGet(_ url: URL, bearer: String) async -> String? {
        let (status, body) = await http.getWithStatus(url, headers: Self.authHeaders(bearer: bearer))
        if status == 200 { return body }
        if status == 401 {
            canvasLogWarning("AppleMusicCanvas: token rejected by the catalog API; will re-scrape")
            await tokens.noteRejection(bearer)
        }
        return nil
    }

    static func authHeaders(bearer: String) -> [String: String] {
        [
            "Authorization": "Bearer \(bearer)",
            "Origin": "https://music.apple.com",
            "Referer": "https://music.apple.com/",
            "User-Agent": CanvasHTTP.userAgent,
        ]
    }

    static func jsonObject(_ body: String) -> [String: CanvasJSON]? {
        CanvasJSON.parse(body)?.object
    }
}

/// The anonymous bearer token the Apple Music web player uses for catalog reads. It isn't
/// published anywhere and rotates every few weeks, so it is read the way the browser gets it:
/// load the web player, find the JS bundle it pulls in, and pick the token out of it. Held
/// until shortly before it expires (Android: `AppleMusicCanvas.token`).
///
/// The bundle ships several unrelated JWTs and only the web player's own is accepted here —
/// the others come back 401 — so this picks by issuer rather than taking the first one that
/// parses.
///
/// A failed scrape backs off for `retryInterval` rather than retrying per track: if Apple has
/// changed the page shape, hammering it on every skip fixes nothing and makes every canvas
/// lookup pay for the round trip.
public actor CanvasAppleTokenStore {
    static let retryInterval: TimeInterval = 30 * 60

    private let http: CanvasHTTP
    private var cachedToken: String?
    private var tokenExpiresAt: Date = .distantPast
    private var retryAfter: Date = .distantPast
    /// Tokens the catalog API has already turned down.
    private var rejected: Set<String> = []

    public init(session: URLSession = VibraMusicHTTP.session) {
        http = CanvasHTTP(session: session)
    }

    public func token() async -> String? {
        let now = Date()
        if let cachedToken, now < tokenExpiresAt.addingTimeInterval(-60) { return cachedToken }
        if now < retryAfter { return nil }

        guard let html = await http.get(
            AppleMusicCanvas.webPlayer, headers: ["User-Agent": CanvasHTTP.userAgent])
        else {
            retryAfter = now.addingTimeInterval(Self.retryInterval)
            return nil
        }

        let scripts = Self.scriptPaths(in: html)
        for path in scripts {
            guard let scriptURL = URL(string: "https://music.apple.com\(path)"),
                  let script = await http.get(scriptURL, headers: ["User-Agent": CanvasHTTP.userAgent])
            else { continue }
            let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
            let candidates = Self.candidateJWTs(in: script)
                .filter { !rejected.contains($0) }
                .compactMap { jwt -> (String, Int64)? in
                    guard let expiresAt = Self.jwtExpiry(jwt), expiresAt > nowMillis else { return nil }
                    return (jwt, expiresAt)
                }
            if candidates.isEmpty { continue }

            // The web player's own token first; anything else is a guess kept only so a change
            // in how Apple labels it isn't fatal.
            let (jwt, expiresAt) = candidates.first { Self.isWebPlayerToken($0.0) } ?? candidates[0]
            cachedToken = jwt
            tokenExpiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000)
            canvasLogDebug("AppleMusicCanvas: web player token good until \(self.tokenExpiresAt)")
            return jwt
        }

        canvasLogWarning("AppleMusicCanvas: no usable web player token in \(scripts.count) bundle(s); backing off")
        retryAfter = now.addingTimeInterval(Self.retryInterval)
        return nil
    }

    public func noteRejection(_ bearer: String) {
        rejected.insert(bearer)
        if cachedToken == bearer {
            cachedToken = nil
            tokenExpiresAt = .distantPast
        }
    }

    /// Test hook: pretend a scrape already succeeded.
    func seed(token: String, expiresAt: Date) {
        cachedToken = token
        tokenExpiresAt = expiresAt
    }

    static func scriptPaths(in html: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: "/assets/index(?:-legacy)?[~-][A-Za-z0-9_-]+\\.js")
        let range = NSRange(html.startIndex..., in: html)
        var seen: [String] = []
        for match in regex?.matches(in: html, range: range) ?? [] {
            guard let matchRange = Range(match.range, in: html) else { continue }
            let path = String(html[matchRange])
            if !seen.contains(path) { seen.append(path) }
        }
        return seen
    }

    static func candidateJWTs(in script: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: "ey[A-Za-z0-9_-]+\\.ey[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+")
        let range = NSRange(script.startIndex..., in: script)
        var seen: [String] = []
        for match in regex?.matches(in: script, range: range) ?? [] {
            guard let matchRange = Range(match.range, in: script) else { continue }
            let jwt = String(script[matchRange])
            if !seen.contains(jwt) { seen.append(jwt) }
        }
        return seen
    }

    /// The web player's token names itself in the header `kid` and payload `iss`.
    static func isWebPlayerToken(_ jwt: String) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3,
              let header = Self.base64URLDecode(String(parts[0])),
              let payload = Self.base64URLDecode(String(parts[1]))
        else { return false }
        return header.contains("WebPlayKid") || payload.contains("AMPWebPlay")
    }

    /// A JWT's `exp` in milliseconds since epoch, or nil if this isn't one that can be read.
    static func jwtExpiry(_ jwt: String) -> Int64? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let payload = Self.base64URLDecode(String(parts[1])) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "\"exp\"\\s*:\\s*(\\d+)"),
              let match = regex.firstMatch(
                in: payload, range: NSRange(payload.startIndex..., in: payload)),
              match.numberOfRanges == 2,
              let expRange = Range(match.range(at: 1), in: payload)
        else { return nil }
        return Int64(payload[expRange]).map { $0 * 1000 }
    }

    static func base64URLDecode(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
