import VibraMusicCore
import Foundation

/// Tidal's "video cover" — a square looping clip some albums ship instead of a still sleeve
/// (Android: `TidalCanvas` in `data/canvas/TidalCanvas.kt`).
///
/// Read through the same public search endpoint Tidal's own embeddable player uses, which
/// needs no account: a track search returns the album object, the album object carries a
/// `videoCover` id, and that id expands into a fixed URL on Tidal's CDN. Square and 1280px,
/// so it drops into the sleeve without cropping — the best-shaped source of the canvas set.
public struct TidalCanvas: Sendable {
    static let searchEndpoint = URL(string: "https://api.tidal.com/v1/search")!

    /// The token Tidal's public embed player ships; read-only, no account.
    static let embedToken = "vNVdglQOjFJJGG2U"

    private let http: CanvasHTTP
    private let countryCode: String

    public init(session: URLSession = VibraMusicHTTP.session, countryCode: String? = nil) {
        http = CanvasHTTP(session: session)
        self.countryCode = countryCode ?? Self.deviceCountryCode
    }

    /// Tidal's catalogue is regional, and so is which albums have a cover.
    public static var deviceCountryCode: String {
        let region = Locale.current.region?.identifier.uppercased() ?? ""
        return region.count == 2 ? region : "US"
    }

    public func search(title: String, artist: String, album: String?) async -> CanvasArtwork? {
        let query = album.isNullOrBlankForCanvas ? "\(artist) \(title)" : "\(album!) \(artist) \(title)"
        guard let url = CanvasURL.make(Self.searchEndpoint.absoluteString, [
            ("query", query), ("limit", "10"), ("types", "TRACKS"), ("countryCode", countryCode),
        ]) else { return nil }

        guard let body = await get(url) else { return nil }
        guard let root = CanvasJSON.parse(body)?.object else { return nil }

        // The response carries a section per result type even when only one was asked for —
        // artists, albums and playlists all come back with an empty `items`, so this has to
        // name the section rather than hunt for the first array that fits.
        guard let items = root["tracks"]?.object?["items"]?.array else { return nil }

        for item in items {
            guard let track = item.object else { continue }
            guard let trackTitle = track["title"]?.string else { continue }

            // Tidal credits artists as separate objects, so this is the one service with no
            // separator to guess.
            let artists = track["artists"]?.array?.compactMap { $0.object?["name"]?.string } ?? []

            // Checked here rather than left to the caller's validation: a search for one song
            // returns ten, and taking the first that has a cover would settle on the wrong
            // track and stop looking — the right one is often further down the list.
            if !Self.isMatch(gotName: trackTitle, gotArtists: artists, wantName: title, wantArtist: artist) {
                continue
            }

            let albumObject = track["album"]?.object
            guard let videoCover = albumObject?["videoCover"]?.string,
                  !videoCover.isEmpty,
                  let videoURL = Self.coverURL(videoCover)
            else { continue }

            canvasLogDebug("TidalCanvas: video cover for '\(trackTitle)' by \(artists.joined(separator: ", "))")
            return CanvasArtwork(
                url: videoURL,
                title: trackTitle,
                artist: artists.joined(separator: ", ").nilIfBlank ?? artist,
                album: albumObject?["title"]?.string)
        }
        return nil
    }

    /// The album's own video cover, for a release page rather than a track.
    ///
    /// Cheaper and more reliable than going via a track: the cover belongs to the album in
    /// Tidal's model, so this asks for it directly instead of finding a song that happens to
    /// sit on the right record.
    public func searchAlbum(album: String, artist: String) async -> CanvasArtwork? {
        guard let url = CanvasURL.make(Self.searchEndpoint.absoluteString, [
            ("query", "\(album) \(artist)"), ("limit", "10"),
            ("types", "ALBUMS"), ("countryCode", countryCode),
        ]) else { return nil }

        guard let body = await get(url) else { return nil }
        guard let items = CanvasJSON.parse(body)?.object?["albums"]?.object?["items"]?.array
        else { return nil }

        for item in items {
            guard let record = item.object else { continue }
            guard let recordTitle = record["title"]?.string else { continue }
            let artists = record["artists"]?.array?.compactMap { $0.object?["name"]?.string } ?? []

            // Without this a search for "SOS" settles on "Ctrl", which also has a cover and is
            // also by SZA.
            if !Self.isMatch(gotName: recordTitle, gotArtists: artists, wantName: album, wantArtist: artist) {
                continue
            }

            guard let videoCover = record["videoCover"]?.string,
                  !videoCover.isEmpty,
                  let videoURL = Self.coverURL(videoCover)
            else { continue }

            canvasLogDebug("TidalCanvas: video cover for album '\(recordTitle)' by \(artists.joined(separator: ", "))")
            return CanvasArtwork(
                url: videoURL,
                title: recordTitle,
                artist: artists.joined(separator: ", ").nilIfBlank ?? artist,
                album: recordTitle)
        }
        return nil
    }

    /// Exact on the name, and every credited artist asked for present.
    static func isMatch(
        gotName: String, gotArtists: [String], wantName: String, wantArtist: String
    ) -> Bool {
        if gotName.normalizedForCanvasMatch != wantName.normalizedForCanvasMatch { return false }
        let wanted = canvasSplitArtists(wantArtist)
        let credited = gotArtists.map(\.normalizedForCanvasMatch).filter { !$0.isBlankForCanvas }
        if wanted.isEmpty || credited.isEmpty { return false }
        return wanted.allSatisfy { want in credited.contains(want) }
    }

    /// A cover id is five dash-separated segments that spell out its path on the CDN. Anything
    /// shaped differently is a format this doesn't know how to address, so treat it as no cover
    /// at all rather than build a 404.
    static func coverURL(_ id: String) -> String? {
        let parts = id.split(separator: "-")
        guard parts.count == 5 else { return nil }
        return "https://resources.tidal.com/videos/\(parts.joined(separator: "/"))/1280x1280.mp4"
    }

    private func get(_ url: URL) async -> String? {
        await http.get(url, headers: ["X-Tidal-Token": Self.embedToken, "User-Agent": CanvasHTTP.userAgent])
    }
}

private extension String {
    var nilIfBlank: String? {
        isBlankForCanvas ? nil : self
    }
}
