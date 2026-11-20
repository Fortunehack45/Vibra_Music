import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Sources

/// Telling one JSON document from another: whether a paste on the Sources screen becomes a working
/// source, a useful refusal, or a shrug. Ported from Android's SourceFormatsTest (payloads captured
/// from live servers or reduced from them), plus the fetching passes of `identify`.
final class SourceFormatDetectionTests: XCTestCase {

    private func reason(_ format: DetectedSourceFormat, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .unsupported(let reason) = format else {
            XCTFail("expected a refusal, got \(format)", file: file, line: line)
            return ""
        }
        return reason
    }

    /// Captured from a live addon.
    func testARealAddonManifestIsRecognisedAndItsNameRead() {
        let body = """
        {"id":"com.unified.music.quality","name":"Unified · Quality First","version":"1.0.0",
         "description":"Tidal + Qobuz + YouTube Music + JioSaavn in one addon.",
         "icon":"https://unified-addon.netlify.app/icon.png",
         "resources":["search","stream","catalog"],
         "types":["track","album","artist","playlist"],"contentType":"music"}
        """
        guard case .addon(let manifest, let baseUrl) = SourceFormats.detect(body, url: "https://host/tok/quality/manifest.json") else {
            return XCTFail("expected an addon")
        }
        XCTAssertEqual(manifest.displayName, "Unified · Quality First")
        // The manifest filename comes off; the token-bearing path does not.
        XCTAssertEqual(baseUrl, "https://host/tok/quality")
    }

    func testAManifestServedAsSomeOtherJsonFilenameStillResolvesItsBase() {
        guard case .addon(_, let baseUrl) = SourceFormats.detect(#"{"id":"x","name":"X","resources":["search","stream"]}"#, url: "https://host/addon.json") else {
            return XCTFail("expected an addon")
        }
        XCTAssertEqual(baseUrl, "https://host")
    }

    func testAModuleIndexIsRecognisedByItsCategoryKeys() {
        let body = """
        {"category:music":[
          {"id":"m1","name":"One","download":"one.js"},
          {"id":"m2","name":"Two","download":"two.js"}]}
        """
        XCTAssertEqual(SourceFormats.detect(body, url: "https://host/index.json"), .moduleIndex(moduleCount: 2, url: "https://host/index.json"))
    }

    /// A row may carry its own streamURL, so a search-only addon can still play.
    func testAnAddonThatDeclaresSearchButNotStreamIsAccepted() {
        guard case .addon = SourceFormats.detect(#"{"id":"x","name":"X","resources":["search","catalog"]}"#) else {
            return XCTFail("expected an addon")
        }
    }

    func testAnAddonThatCannotBeSearchedIsRefusedAndSaysWhatItDeclared() {
        let text = reason(SourceFormats.detect(#"{"id":"x","name":"X","resources":["stream","catalog"]}"#))
        XCTAssertTrue(text.contains("stream, catalog"), text)
        XCTAssertTrue(text.contains("needs search"), text)
    }

    func testAManifestDeclaringNoResourcesIsStillAnAddon() {
        guard case .addon = SourceFormats.detect(#"{"id":"x","name":"X","version":"1.0.0"}"#) else {
            return XCTFail("expected an addon")
        }
    }

    func testAModuleIndexListingNothingIsRefused() {
        XCTAssertTrue(reason(SourceFormats.detect(#"{"category:music":[]}"#)).contains("listed no modules"))
    }

    func testAPageThatIsNotJSONSaysSo() {
        XCTAssertTrue(reason(SourceFormats.detect("<!doctype html><html><body>Not found</body></html>")).contains("did not return JSON"))
    }

    func testABareJSONArrayIsRefused() {
        XCTAssertTrue(reason(SourceFormats.detect(#"[{"id":"a"}]"#)).contains("list"))
    }

    func testAnUnknownIndexNamesTheListItHolds() {
        XCTAssertTrue(reason(SourceFormats.detect(#"{"schemaVersion":2,"providers":[{"id":"a"},{"id":"b"}]}"#)).contains("providers"))
    }

    func testAnExtensionRegistryFallsToTheGenericUnrecognisedAnswer() {
        let body = """
        {"version":1,"updated_at":"2026-08-30T00:00:00Z","extensions":[
          {"id":"deezer","display_name":"Deezer","download_url":"https://x/deezer.sflx"},
          {"id":"qobuz-web","display_name":"Qobuz","download_url":"https://x/qobuz-web.sflx"}]}
        """
        let text = reason(SourceFormats.detect(body, url: "https://host/registry.json"))
        XCTAssertTrue(text.contains("extensions"), text)
        XCTAssertTrue(text.contains("not a format Vibra Music reads"), text)
    }

    func testAnObjectWithNothingInItListsWhatItDidHold() {
        let text = reason(SourceFormats.detect(#"{"hello":"world","count":3}"#))
        XCTAssertTrue(text.contains("hello"), text)
        XCTAssertTrue(text.hasSuffix("hello, count"), "document order is kept: \(text)")
    }

    // MARK: identify(), against a stubbed server

    func testIdentifyFindsTheManifestUnderABareAddress() async throws {
        let stub = URLProtocolStub()
        stub.register(url: URL(string: "https://addon.example/tok/manifest.json")!, response: .json(#"{"id":"a","name":"A","resources":["search","stream"]}"#))
        let found = try await SourceFormats.identify("https://addon.example/tok/", session: stub.makeSession())
        guard case .addon(let manifest, let baseUrl) = found else { return XCTFail("\(found)") }
        XCTAssertEqual(manifest.name, "A")
        XCTAssertEqual(baseUrl, "https://addon.example/tok")
    }

    /// No manifest anywhere, but `/search` answers: the endpoints are the addon.
    func testIdentifyAcceptsAnAddonWithNoManifestWhenItsSearchAnswers() async throws {
        let stub = URLProtocolStub()
        stub.register(matching: { _ in true }) { _ in .status(404) }
        stub.register(host: "bare.example", path: "/search", response: .json(#"{"tracks":[]}"#))
        let found = try await SourceFormats.identify("https://bare.example", session: stub.makeSession())
        guard case .addon(let manifest, let baseUrl) = found else { return XCTFail("\(found)") }
        XCTAssertEqual(manifest.name, "bare.example")
        XCTAssertEqual(manifest.resources, ["search", "stream"])
        XCTAssertEqual(baseUrl, "https://bare.example")
    }

    func testIdentifyReportsWhatItFoundOverATransportError() async throws {
        let stub = URLProtocolStub()
        stub.register(matching: { _ in true }) { _ in .status(404) }
        stub.register(url: URL(string: "https://host.example/registry.json")!, response: .json(#"{"extensions":[{"id":"x"}]}"#))
        let found = try await SourceFormats.identify("https://host.example/registry.json", session: stub.makeSession())
        XCTAssertTrue(reason(found).contains("extensions"))
    }

    func testIdentifyRefusesSomethingThatIsNotAWebAddress() async throws {
        let found = try await SourceFormats.identify("ftp://files.example/x", session: URLProtocolStub().makeSession())
        XCTAssertTrue(reason(found).contains("not a web address"))
    }

    /// PORTING Q4: a module index can't be *added* on iOS; an existing custom-module config can be
    /// re-pointed at one.
    @MainActor
    func testTheRegistryRefusesToAddANewModuleIndexButKeepsEditingAnExistingOne() async throws {
        let stub = URLProtocolStub()
        stub.register(matching: { _ in true }) { _ in .status(404) }
        stub.register(url: URL(string: "https://modules.example/index.json")!, response: .json(#"{"category:music":[{"id":"m","name":"M","download":"m.js"}]}"#))
        let registry = SourceRegistry(store: nil, environment: SourceEnvironment(session: stub.makeSession(), deviceCodecs: .fixed(false), dolbyAtmosEnabled: { false }))
        do {
            _ = try await registry.identify("https://modules.example/index.json")
            XCTFail("a new module index was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no longer supported"), error.localizedDescription)
        }
        let existing = SourceConfig(kind: .customModule, label: "Mine", baseUrl: "https://old.example/index.json")
        let edited = try await registry.identify("https://modules.example/index.json", editing: existing)
        XCTAssertEqual(edited.id, existing.id)
        XCTAssertEqual(edited.kind, .customModule)
        XCTAssertEqual(edited.baseUrl, "https://modules.example/index.json")
    }
}
