import VibraMusicCore
import Foundation

/// A community-curated `song + artist -> looping video` index, published as one JSON file and
/// mirrored by whoever maintains it (Android: `CommunityCanvas` in
/// `data/canvas/CommunityCanvas.kt`).
///
/// The catalogue services only have motion artwork where a label paid to make some, which is a
/// thin slice of anything outside current chart releases. This fills the gaps by hand: small,
/// hit-or-miss, and the only source here that ever covers back catalogue.
///
/// One file for the whole index means one request and then local lookups, so the manifest is
/// held for `timeToLive` rather than re-fetched per track.
public actor CommunityCanvas {
    static let manifestURL = URL(string: "https://vivimusicanvas.mkmdevilmi.workers.dev/canvas.json")!
    public static let defaultTimeToLive: TimeInterval = 30 * 60

    struct Entry: Sendable {
        var song: String
        var artist: String
        var album: String
        var url: String
    }

    private let http: CanvasHTTP
    private let timeToLive: TimeInterval
    private var entries: [Entry] = []
    private var fetchedAt: Date = .distantPast

    public init(session: URLSession = VibraMusicHTTP.session, timeToLive: TimeInterval = defaultTimeToLive) {
        http = CanvasHTTP(session: session)
        self.timeToLive = timeToLive
    }

    public func search(title: String, artist: String, album: String?) async -> CanvasArtwork? {
        let index = await manifest()
        if index.isEmpty { return nil }

        let wantTitle = title.normalizedForCanvasMatch
        let wantArtist = artist.normalizedForCanvasMatch
        let wantAlbum = album?.normalizedForCanvasMatch

        // Contributors write titles as they please — "Song" against "Song (Official Video)" —
        // so this side matches on containment rather than equality. That is looser than the
        // catalogue providers get, and the album check is what keeps it honest when one is
        // known.
        guard let hit = index.first(where: { entry in
            let song = entry.song.normalizedForCanvasMatch
            let credited = entry.artist.normalizedForCanvasMatch
            let listed = entry.album.normalizedForCanvasMatch
            let titleOk = !song.isEmpty && (wantTitle.contains(song) || song.contains(wantTitle))
            let artistOk = !credited.isEmpty &&
                (wantArtist.contains(credited) || credited.contains(wantArtist))
            let albumOk = listed.isEmpty || wantAlbum.isNullOrBlankForCanvas || listed == wantAlbum
            return titleOk && artistOk && albumOk
        }) else { return nil }

        canvasLogDebug("CommunityCanvas: manifest hit for '\(hit.song)' by '\(hit.artist)'")
        return CanvasArtwork(
            url: hit.url, title: hit.song, artist: hit.artist,
            album: hit.album.isEmpty ? nil : hit.album)
    }

    /// Any clip contributed for this release, for the album page. The index is keyed by song,
    /// so this takes the first track of the album someone has covered — every clip on a
    /// release is usually the same loop anyway.
    public func searchAlbum(album: String, artist: String) async -> CanvasArtwork? {
        let index = await manifest()
        if index.isEmpty { return nil }

        let wantAlbum = album.normalizedForCanvasMatch
        let wantArtist = artist.normalizedForCanvasMatch
        if wantAlbum.isEmpty { return nil }

        guard let hit = index.first(where: { entry in
            let listed = entry.album.normalizedForCanvasMatch
            let credited = entry.artist.normalizedForCanvasMatch
            return listed == wantAlbum && !credited.isEmpty &&
                (wantArtist.contains(credited) || credited.contains(wantArtist))
        }) else { return nil }

        canvasLogDebug("CommunityCanvas: manifest hit for album '\(hit.album)' by '\(hit.artist)'")
        return CanvasArtwork(url: hit.url, title: hit.album, artist: hit.artist, album: hit.album)
    }

    private func manifest() async -> [Entry] {
        let now = Date()
        if !entries.isEmpty, now.timeIntervalSince(fetchedAt) < timeToLive { return entries }

        guard let body = await http.get(
            Self.manifestURL, headers: ["User-Agent": CanvasHTTP.userAgent])
        else {
            // Serve whatever is already held rather than losing canvas entirely for the next
            // half hour because one fetch failed.
            fetchedAt = now
            return entries
        }

        let parsed = Self.parse(body)
        if !parsed.isEmpty {
            canvasLogDebug("CommunityCanvas: manifest holds \(parsed.count) entries")
            entries = parsed
        }
        fetchedAt = now
        return entries
    }

    static func parse(_ body: String) -> [Entry] {
        guard let items = CanvasJSON.parse(body)?.object?["items"]?.array else { return [] }
        return items.compactMap { item -> Entry? in
            guard let object = item.object,
                  let song = object["song"]?.string,
                  let artist = object["artist"]?.string,
                  let url = object["url"]?.string
            else { return nil }
            return Entry(song: song, artist: artist, album: object["album"]?.string ?? "", url: url)
        }
    }

    /// Test hook: serve these entries without touching the network.
    func seed(_ entries: [Entry]) {
        self.entries = entries
        fetchedAt = Date()
    }
}
