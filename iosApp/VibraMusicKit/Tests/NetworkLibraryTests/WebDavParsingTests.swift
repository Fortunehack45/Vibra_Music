import VibraMusicTestSupport
import XCTest
@testable import NetworkLibrary

/// PROPFIND multistatus parsing: ports the WebDavTest.kt XML cases against
/// the fixture responses.
final class WebDavParsingTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        try FixtureLoader(bundle: .module).string(name)
    }

    func testParsesMultistatus() throws {
        let xml = try fixture("propfind-library.xml")
        let entries = WebDavClient.parseMultistatus(xml: xml, dirUrl: "https://cloud.example.com/remote.php/dav/files/user/Music")
        // The directory itself is dropped.
        XCTAssertEqual(entries.count, 3)
        let audio = try XCTUnwrap(entries.first { $0.displayName == "Artist - Title.mp3" })
        XCTAssertFalse(audio.isCollection)
        XCTAssertEqual(audio.contentType, "audio/mpeg")
        XCTAssertTrue(audio.url.hasSuffix("Artist%20-%20Title.mp3"))
        let folder = try XCTUnwrap(entries.first { $0.displayName == "Live" })
        XCTAssertTrue(folder.isCollection)
    }

    func testParsesDefaultNamespaceAndAbsoluteHrefs() throws {
        let xml = try fixture("propfind-live.xml")
        let entries = WebDavClient.parseMultistatus(
            xml: xml,
            dirUrl: "https://cloud.example.com/remote.php/dav/files/user/Music/Live/"
        )
        XCTAssertEqual(entries.count, 1)
        let file = try XCTUnwrap(entries.first)
        // No displayname: the decoded href names the row.
        XCTAssertEqual(file.displayName, "take.flac")
        XCTAssertEqual(file.contentType, "audio/flac")
        XCTAssertFalse(file.isCollection)
    }

    func testBlankXmlYieldsNoEntries() {
        XCTAssertEqual(WebDavClient.parseMultistatus(xml: "  ", dirUrl: "https://cloud.example.com/Music"), [])
        XCTAssertEqual(WebDavClient.parseMultistatus(xml: "not xml at all", dirUrl: "https://cloud.example.com/Music"), [])
    }

    func testDirectoryEchoWithTrailingSlashIsDropped() {
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/Music</d:href>
                <d:propstat><d:prop>
                  <d:displayname>Music</d:displayname>
                  <d:resourcetype><d:collection/></d:resourcetype>
                </d:prop></d:propstat>
              </d:response>
            </d:multistatus>
            """
        XCTAssertEqual(
            WebDavClient.parseMultistatus(xml: xml, dirUrl: "https://cloud.example.com/Music/"),
            []
        )
    }
}
