import XCTest
@testable import StreamResolution

/// The embedded player (WEB_EMBEDDED_PLAYER): its `player` request is built from the embed page's
/// own config, and claims a third-party embed.
final class EmbeddedPlayerClientTests: XCTestCase {
    private let page = """
    <html><script>ytcfg.set({"INNERTUBE_CONTEXT":{"client":{"hl":"en","gl":"IN","visitorData":"Cgt2aXNpdG9y","clientName":"WEB_EMBEDDED_PLAYER",\
    "clientVersion":"2.20260925.01.00","platform":"DESKTOP","note":"a } brace and a \\" quote"},"thirdParty":{"embeddedPlayerContext":\
    {"embeddedPlayerEncryptedContext":"AJi0ctx","ancestorOriginsSupported":false}}},"INNERTUBE_CLIENT_VERSION":"2.20260925.01.00"});</script>
    <script>ytcfg.set({"WEB_PLAYER_CONTEXT_CONFIGS":{"WEB_PLAYER_CONTEXT_CONFIG_ID_EMBEDDED_PLAYER":{"encryptedHostFlags":"AJi0flags"}}});</script></html>
    """

    func testTheEmbedPagesConfigIsRead() throws {
        let config = try XCTUnwrap(InnerTubeStreamExtractor.parseEmbedConfig(page))
        XCTAssertEqual(config.clientVersion, "2.20260925.01.00")
        XCTAssertEqual(config.visitorData, "Cgt2aXNpdG9y")
        XCTAssertEqual(config.encryptedHostFlags, "AJi0flags")
        XCTAssertNotNil(config.thirdParty["embeddedPlayerContext"])
        XCTAssertEqual(config.client["note"] as? String, "a } brace and a \" quote")
    }

    func testAPageWithoutAConfigIsNoConfig() {
        XCTAssertNil(InnerTubeStreamExtractor.parseEmbedConfig("<html>nothing here</html>"))
    }

    func testThePlayerRequestCarriesTheEmbedContextAndHostFlags() throws {
        let config = try XCTUnwrap(InnerTubeStreamExtractor.parseEmbedConfig(page))
        let request = try InnerTubeStreamExtractor.playerRequest(
            profile: .webEmbedded, clientVersion: "2.20260925.01.00", videoId: "khnokW3Mw24", visitorData: "Cgt2aXNpdG9y",
            signatureTimestamp: 20717, auth: nil, poToken: nil, language: "en", cpn: "cpn", now: Date(), embed: config
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let context = try XCTUnwrap(body["context"] as? [String: Any])
        let client = try XCTUnwrap(context["client"] as? [String: Any])
        XCTAssertEqual(client["clientName"] as? String, "WEB_EMBEDDED_PLAYER")
        XCTAssertEqual(client["platform"] as? String, "DESKTOP", "the page's client block is used as is")
        let thirdParty = try XCTUnwrap(context["thirdParty"] as? [String: Any])
        XCTAssertEqual(thirdParty["embedUrl"] as? String, "https://www.reddit.com/")
        XCTAssertNotNil(thirdParty["embeddedPlayerContext"])
        let playback = try XCTUnwrap((body["playbackContext"] as? [String: Any])?["contentPlaybackContext"] as? [String: Any])
        XCTAssertEqual(playback["encryptedHostFlags"] as? String, "AJi0flags")
        XCTAssertEqual(playback["signatureTimestamp"] as? Int, 20717)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "56")
        XCTAssertNil(body["serviceIntegrityDimensions"], "no PoToken")
    }
}
