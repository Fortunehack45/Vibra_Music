import XCTest
@testable import Lyrics

/// The small JSON, XML and HTML readers the providers are built on.
final class LyricsParsingSupportTests: XCTestCase {

    func testJSONKeepsKeyOrderAndNumberLiterals() throws {
        let json = try XCTUnwrap(LyricsJSON.parse(#"{"b":1,"a":248.0,"c":[true,null,"xé🎵"],"d":{"e":"\n"}}"#))
        XCTAssertEqual(json.object?.keys, ["b", "a", "c", "d"])
        XCTAssertEqual(json["a"]?.content, "248.0")
        XCTAssertNil(json["a"]?.long, "a fractional literal is not a whole number")
        XCTAssertEqual(json["a"]?.double, 248)
        XCTAssertEqual(json["b"]?.long, 1)
        XCTAssertEqual(json["c"]?.array?[2].content, "xé🎵")
        XCTAssertEqual(json["c"]?.array?[1].content, nil)
        XCTAssertEqual(json["d"]?["e"]?.content, "\n")
        XCTAssertEqual(LyricsJSON.string("15030").long, 15_030, "a numeric string reads as a number, as longOrNull does")
    }

    func testJSONRoundTripsThroughItsSerialisedForm() throws {
        let text = #"{"lyrics":["[00:01.00]a\nb",{"k":"\"q\""}],"n":-1.5e3}"#
        let json = try XCTUnwrap(LyricsJSON.parse(text))
        XCTAssertEqual(LyricsJSON.parse(json.serialized), json)
    }

    func testNotJSONIsNil() {
        for text in ["", "[00:01.00] lyric", "{\"a\":}", "[1,]", "tru", "<tt>", "{} trailing"] {
            XCTAssertNil(LyricsJSON.parse(text), text)
        }
    }

    func testXMLKeepsPrefixedNamesAndMergesTextAroundEntities() throws {
        let document = try XCTUnwrap(LyricsXMLNode.parse(#"<tt xmlns:ttm="x"><p ttm:agent="v1">a &amp; b<![CDATA[c]]></p></tt>"#))
        let paragraph = try XCTUnwrap(document.elements(named: "p").first)
        XCTAssertEqual(paragraph.attribute("ttm:agent"), "v1")
        XCTAssertEqual(paragraph.children.filter(\.isText).count, 1)
        XCTAssertEqual(paragraph.textContent, "a & bc")
        XCTAssertNil(LyricsXMLNode.parse("<tt><p>"))
    }

    func testHTMLReaderToleratesRealWorldMarkup() {
        let root = LyricsHTMLNode.parse("""
        <!DOCTYPE html><html><head><script>if (a < b) { document.write("<div class='lyrics'>x</div>") }</script>
        <style>div{}</style></head><body>
        <div data-lyrics-container="TRUE" class="a lyrics b">one<br/>two&nbsp;&amp;&#x27;three&#39;<svg><path d="M0"/></svg>
        <p>para<span>graph</div></span><img src=x alt=y>
        <!-- <div data-lyrics-container="true">comment</div> -->
        </body></html>
        """)
        let containers = root.select { $0.tagName == "div" && $0.attribute("data-lyrics-container", equals: "true") }
        XCTAssertEqual(containers.count, 1)
        XCTAssertTrue(containers[0].hasClass("lyrics"))
        XCTAssertFalse(containers[0].hasClass("lyric"))
        let text = containers[0].wholeText
        XCTAssertTrue(text.hasPrefix("onetwo\u{00A0}&'three'"), text)
        XCTAssertTrue(text.contains("paragraph"))
        XCTAssertFalse(root.wholeText.contains("document.write"))
    }

    func testHTMLEntitiesDecodeNumericAndNamedReferences() {
        XCTAssertEqual(LyricsHTMLEntities.decode("don&#x27;t &amp; won&#39;t &hellip; &unknown; &copy;"), "don't & won't … &unknown; ©")
    }

    // MARK: HTTP plumbing

    func testQueriesAreEncodedTheWayOkHttpEncodesThem() {
        XCTAssertEqual(LyricsURL.string("https://x.test/y", [("q", "a b+c/é*-._~")]), "https://x.test/y?q=a%20b%2Bc%2F%C3%A9*-._%7E")
        XCTAssertEqual(LyricsURL.formEncoded([("q", "a b&c"), ("tl", "zh-TW")]), "q=a+b%26c&tl=zh-TW")
    }

    func testAProviderRequestGivesUpAtItsDeadline() async throws {
        let (session, _) = StubURLProtocol.session { _ in .ok("late", delay: 3) }
        let start = Date()
        let body = await LyricsHTTP(session: session).get(URL(string: "https://slow.test/"), headers: [:], deadline: 0.3)
        XCTAssertNil(body)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testOnlyASuccessfulAnswerIsABodyAndItsByteOrderMarkIsConsumed() async throws {
        let (session, _) = StubURLProtocol.session { request in
            request.url?.path == "/ok" ? .ok(Data([0xEF, 0xBB, 0xBF]) + Data("{}".utf8)) : .status(403, "blocked")
        }
        let http = LyricsHTTP(session: session)
        let ok = await http.get(URL(string: "https://x.test/ok"))
        XCTAssertEqual(ok, "{}")
        let blocked = await http.get(URL(string: "https://x.test/blocked"))
        XCTAssertNil(blocked)
    }

    /// The word walk leans on Kotlin's `indexOf`, so its edge cases are pinned: offsets are
    /// UTF-16, a search past the end misses, and an empty needle is found at the clamped start.
    func testIndexOfBehavesLikeKotlins() {
        XCTAssertEqual("a😀b b".kIndexOf("b", from: 0), 3)
        XCTAssertEqual("a😀b b".kIndexOf("b", from: 4), 5)
        XCTAssertNil("abc".kIndexOf("c", from: 3))
        XCTAssertNil("abc".kIndexOf("x", from: 0))
        XCTAssertEqual("abc".kIndexOf("", from: 1), 1)
        XCTAssertEqual("abc".kIndexOf("", from: 10), 3)
        XCTAssertEqual("abc".kIndexOf("a", from: -4), 0)
    }
}
