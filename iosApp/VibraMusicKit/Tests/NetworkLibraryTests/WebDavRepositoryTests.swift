import VibraMusicTestSupport
import XCTest
@testable import NetworkLibrary

/// WebDavRepository rows and artwork matching against stubbed PROPFIND.
final class WebDavRepositoryTests: XCTestCase {
    /// The stub must outlive the repository: sessions find their stub
    /// through a weak registry, so a helper-local stub would deallocate on
    /// return and every request would miss.
    private func repository(xmlByPath: @escaping (String) -> String) -> (WebDavRepository, URLProtocolStub) {
        let stub = URLProtocolStub()
        stub.register(host: "cloud.example.com", method: "PROPFIND") { request in
            .text(xmlByPath(request.url?.path(percentEncoded: false) ?? ""), status: 207)
        }
        return (
            WebDavRepository(
                credentials: WebDavCredentials(url: "https://cloud.example.com/Music"),
                client: WebDavClient(session: stub.makeSession())
            ),
            stub
        )
    }

    private func multistatus(_ rows: String...) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<d:multistatus xmlns:d=\"DAV:\">\n\(rows.joined(separator: "\n"))\n</d:multistatus>"
    }

    private func collection(href: String) -> String {
        """
          <d:response>
            <d:href>/\(href)/</d:href>
            <d:propstat><d:prop>
              <d:displayname>\(href.split(separator: "/").last.map(String.init) ?? href)</d:displayname>
              <d:resourcetype><d:collection/></d:resourcetype>
            </d:prop></d:propstat>
          </d:response>
        """
    }

    private func file(href: String, mime: String, display: String? = nil) -> String {
        let name = display ?? (href.split(separator: "/").last.map(String.init) ?? href)
        return """
          <d:response>
            <d:href>/\(href)</d:href>
            <d:propstat><d:prop>
              <d:displayname>\(name)</d:displayname>
              <d:resourcetype/>
              <d:getcontenttype>\(mime)</d:getcontenttype>
            </d:prop></d:propstat>
          </d:response>
        """
    }

    func testSongsSplitTitleAndParentAlbum() async throws {
        let root = multistatus(
            collection(href: "Music"),
            file(href: "Music/Artist%20-%20Title.mp3", mime: "audio/mpeg", display: "Artist - Title.mp3"),
            file(href: "Music/cover.jpg", mime: "image/jpeg")
        )
        let (repository, stubHolder) = repository { _ in root }
        let songs = await repository.getSongs()
        XCTAssertEqual(songs.count, 1)
        XCTAssertGreaterThan(stubHolder.requests.count, 0)
        let song = try XCTUnwrap(songs.first)
        XCTAssertEqual(song.title, "Title")
        XCTAssertEqual(song.artist, "Artist")
        XCTAssertEqual(song.albumName, "Music")
        XCTAssertEqual(song.thumbnailUrl, "https://cloud.example.com/Music/cover.jpg")
        XCTAssertEqual(song.playbackSource, "WebDAV")
    }

    func testArtworkForPrefersConventionalCovers() {
        func img(_ name: String) -> WebDavClient.Entry {
            WebDavClient.Entry(
                url: "https://cloud.example.com/Music/Album/\(name)",
                displayName: name,
                isCollection: false,
                contentType: "image/jpeg"
            )
        }
        let siblings = [img("IMG_1234.jpg"), img("cover.jpg"), img("back.jpg")]
        XCTAssertEqual(
            WebDavRepository.artworkFor(fileUrl: "https://cloud.example.com/Music/Album/song.mp3", siblings: siblings),
            "https://cloud.example.com/Music/Album/cover.jpg"
        )
    }

    func testArtworkForFallsBackToFirstAlphabetical() {
        func img(_ name: String) -> WebDavClient.Entry {
            WebDavClient.Entry(
                url: "https://cloud.example.com/Music/Album/\(name)",
                displayName: name,
                isCollection: false,
                contentType: "image/jpeg"
            )
        }
        XCTAssertEqual(
            WebDavRepository.artworkFor(
                fileUrl: "https://cloud.example.com/Music/Album/song.mp3",
                siblings: [img("z.jpg"), img("a.jpg")]
            ),
            "https://cloud.example.com/Music/Album/a.jpg"
        )
        XCTAssertNil(WebDavRepository.artworkFor(fileUrl: "https://cloud.example.com/Music/Album/song.mp3", siblings: []))
    }

    func testDerivesParentFolder() {
        XCTAssertEqual(
            WebDavRepository.parentFolderName("https://cloud.example.com/Music/Artist/Album/song.mp3"),
            "Album"
        )
        XCTAssertNil(WebDavRepository.parentFolderName("https://cloud.example.com/song.mp3"))
    }

    func testUnconfiguredYieldsNoSongs() async {
        let stub = URLProtocolStub()
        let repository = WebDavRepository(
            credentials: WebDavCredentials(url: ""),
            client: WebDavClient(session: stub.makeSession())
        )
        XCTAssertFalse(repository.isConfigured)
        let songs = await repository.getSongs()
        XCTAssertEqual(songs, [])
        XCTAssertEqual(stub.requests.count, 0)
    }
}
