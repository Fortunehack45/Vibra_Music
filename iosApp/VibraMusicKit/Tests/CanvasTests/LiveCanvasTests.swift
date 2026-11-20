import VibraMusicCore
import XCTest
@testable import Canvas

/// Canvas against the real services, with well-known tracks. Skipped unless
/// `VIBRAMUSIC_LIVE_TESTS=1`.
///
/// Each test prints one `LIVE` line per track with what the service answered, so a run doubles
/// as the "which sources work today" report. Spotify is asserted to *miss cleanly* when no
/// `sp_dc` cookie is configured — it cannot work without one by design.
final class LiveCanvasTests: XCTestCase {
    override func setUp() async throws {
        try requireLiveCanvasTests()
    }

    private func report(_ source: String, track: String, _ artwork: CanvasArtwork?) {
        if let artwork {
            print("LIVE \(source) '\(track)': \(artwork.url) (fallback: \(artwork.fallbackUrl ?? "none"))")
        } else {
            print("LIVE \(source) '\(track)': no canvas")
        }
    }

    func testAppleMusicFindsMotionArtworkForPopularTracks() async {
        let canvas = AppleMusicCanvas()
        let tracks = [
            ("Blinding Lights", "The Weeknd", "After Hours"),
            ("As It Was", "Harry Styles", "Harry's House"),
            ("Levitating", "Dua Lipa", "Future Nostalgia"),
        ]
        var hits = 0
        for (title, artist, album) in tracks {
            let found = await canvas.search(title: title, artist: artist, album: album)
            report("apple", track: "\(title) — \(artist)", found)
            if found != nil { hits += 1 }
        }
        XCTAssertGreaterThanOrEqual(
            hits, 2, "Apple Music should carry motion artwork for most of these chart releases")
    }

    func testAppleMusicFindsAlbumArtwork() async {
        let canvas = AppleMusicCanvas()
        let found = await canvas.searchAlbum(album: "After Hours", artist: "The Weeknd")
        report("apple-album", track: "After Hours — The Weeknd", found)
        XCTAssertNotNil(found)
    }

    func testCommunityIndexCoversItsOwnEntries() async {
        // Fetch the live manifest, then ask for its first entries back: a healthy index must
        // find its own rows. This stays meaningful however the manifest's contents change.
        guard let manifestURL = URL(string: "https://vivimusicanvas.mkmdevilmi.workers.dev/canvas.json"),
              let (data, _) = try? await URLSession.shared.data(from: manifestURL),
              let text = String(data: data, encoding: .utf8),
              !CommunityCanvas.parse(text).isEmpty
        else {
            return XCTFail("community manifest unreachable or empty")
        }
        let entries = CommunityCanvas.parse(text)
        print("LIVE community: manifest holds \(entries.count) entries")
        let canvas = CommunityCanvas()
        var hits = 0
        for entry in entries.prefix(3) {
            let found = await canvas.search(title: entry.song, artist: entry.artist, album: entry.album)
            report("community", track: "\(entry.song) — \(entry.artist)", found)
            if found != nil { hits += 1 }
        }
        XCTAssertEqual(hits, min(3, entries.count), "the index must find its own entries")
    }

    func testTidalVideoCoversWithoutLogin() async {
        let canvas = TidalCanvas()
        let tracks = [
            ("Blinding Lights", "The Weeknd", "After Hours"),
            ("SOS", "SZA", "SOS"),
            ("As It Was", "Harry Styles", "Harry's House"),
        ]
        var hits = 0
        for (title, artist, album) in tracks {
            let found = await canvas.search(title: title, artist: artist, album: album)
            report("tidal", track: "\(title) — \(artist)", found)
            if found != nil { hits += 1 }
        }
        XCTAssertGreaterThan(hits, 0, "Tidal should have a video cover for at least one of these releases")
    }

    func testRepositoryEndToEndOverLiveServices() async {
        // No Spotify cookie: Apple, Tidal and the community index alone.
        let repository = CanvasRepository()
        let song = Song(
            videoId: "live1", title: "Blinding Lights", artist: "The Weeknd", albumName: "After Hours")
        let found = await repository.canvasFor(song)
        report("repository", track: "Blinding Lights — The Weeknd", found)
        XCTAssertNotNil(found, "at least one no-login source should cover this release")
    }

    func testSpotifyMissesCleanlyWithoutACookie() async {
        let canvas = SpotifyCanvas()
        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        print("LIVE spotify (no cookie): \(found == nil ? "clean miss, no requests" : "unexpected hit")")
        XCTAssertNil(found)
    }
}
