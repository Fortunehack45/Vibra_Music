import XCTest
@testable import Lyrics

/// KuGou's header/footer credit stripping (ported from Android's `KuGouTest`), and the whole
/// three-call KuGou chain against its recorded answers.
final class KuGouCreditStrippingTests: XCTestCase {

    /// A live `lyrics.kugou.com/download` response for "Heartbreak Anniversary" (Giveon):
    /// an unstamped tag preamble, then the title and two credits carrying real stamps.
    private let fixture = """
    [id:$00000000]
    [ti:Heartbreak Anniversary]
    [ar:Giveon]
    [al:Heartbreak Anniversary]
    [by:]
    [00:00.00]Heartbreak Anniversary - GIVĒON
    [00:04.12]Lyrics by：Giveon Evans/Varren Wade/Sevn Thomas
    [00:08.24]Composed by：Giveon Evans/Varren Wade/Sevn Thomas/Maneesh
    [00:12.36]Hammer
    [00:15.90]Calm mirror draw
    [00:19.73]Signal chop bake fountain tile listen
    [03:04.12]'Print Paint brave fast pencil brave fast pencil
    [03:07.90]Hammer hammer hammer-hammer
    """

    func testDropsTheUnstampedHeaderTagsEntirely() {
        let stripped = KuGouProvider.stripCredits(fixture)
        XCTAssertFalse(stripped.contains("[id:"))
        XCTAssertFalse(stripped.contains("[ti:"))
        XCTAssertFalse(stripped.contains("[by:]"))
    }

    func testCutsEverythingThroughTheLastCreditLineTitleRestatedAndAll() {
        let stripped = KuGouProvider.stripCredits(fixture)
        XCTAssertFalse(stripped.contains("GIVĒON"), "title-as-lyric line")
        XCTAssertFalse(stripped.contains("Lyrics by"))
        XCTAssertFalse(stripped.contains("Composed by"))
        XCTAssertTrue(stripped.hasPrefix("[00:12.36]Hammer"), "first real line survives")
    }

    func testRealSungLinesAfterTheHeaderSurviveUntouched() {
        let stripped = KuGouProvider.stripCredits(fixture)
        XCTAssertTrue(stripped.contains("[00:15.90]Calm mirror draw"))
        XCTAssertTrue(stripped.contains("[00:19.73]Signal chop bake fountain tile listen"))
    }

    func testTheOutroIsNotMistakenForACreditAndCut() {
        XCTAssertTrue(KuGouProvider.stripCredits(fixture).contains("[03:07.90]Hammer hammer hammer-hammer"))
    }

    func testALyricWithNoCreditBlockAnywhereIsLeftWhole() {
        let clean = "[00:01.00]first line\n[00:05.00]second line"
        XCTAssertEqual(KuGouProvider.stripCredits(clean), clean)
    }

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertEqual(KuGouProvider.stripCredits(""), "")
    }

    func testTheKeywordDropsParentheticalsAndAddsTheAlbum() {
        XCTAssertEqual(KuGouProvider.keyword(title: "Get Lucky (Radio Edit)", artist: "Daft Punk", album: "RAM"), "Get Lucky - Daft Punk RAM")
        XCTAssertEqual(KuGouProvider.keyword(title: "晴天（Live）", artist: "周杰伦", album: nil), "晴天 - 周杰伦")
    }

    func testSongSearchKeepsCutsWithinEightSecondsClosestFirst() throws {
        let hashes = KuGouProvider.songHashes(try Fixture.text("kugou-search-song-get-lucky.json"), seconds: 248)
        XCTAssertEqual(hashes.first, "4667d6b91ce6fe1d91809fc05f2895e1")
        // The 369s album cut and the 413s remix are filtered out.
        XCTAssertFalse(hashes.contains("6e2bddf655888a52a6f193088de4ce3a"))
        XCTAssertFalse(hashes.contains("71dd9edd8d03e817117071ade0afdf96"))
        // Nor are the 268s remix (20s away) and the 230s Starboy (18s away).
        XCTAssertFalse(hashes.contains("bfe83c74b6d17e55fd46676e843fe366"))
        XCTAssertFalse(hashes.contains("072b3f6163b79609b754c1549f173ebd"))
    }

    /// The edge itself: eight seconds off is kept, nine is not, whichever side it falls on.
    func testSongSearchToleranceEndsBetweenEightAndNineSeconds() {
        func entry(_ hash: String, _ seconds: Int) -> String { #"{"hash":"\#(hash)","duration":\#(seconds)}"# }
        let body = #"{"data":{"info":["# + [entry("short9", 239), entry("short8", 240), entry("long8", 256), entry("long9", 257)].joined(separator: ",") + "]}}"
        XCTAssertEqual(Set(KuGouProvider.songHashes(body, seconds: 248)), ["short8", "long8"])
    }

    func testTheWholeChainAgainstRecordedAnswers() async throws {
        let song = try Fixture.data("kugou-search-song-get-lucky.json")
        let candidates = try Fixture.data("kugou-search-lyrics-get-lucky.json")
        let download = try Fixture.data("kugou-download-get-lucky.json")
        let (session, id) = StubURLProtocol.session { request in
            switch request.url?.path {
            case "/api/v3/search/song": return .ok(song)
            case "/search": return .ok(candidates)
            case "/download": return .ok(download)
            default: return nil
            }
        }
        let lines = try await XCTUnwrapAsync(await KuGouProvider(session: session).lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000))
        XCTAssertTrue(lines.sung.contains { $0.text == "Tile press soft fast press hang" })
        XCTAssertEqual(lines.sung.first(where: { $0.text == "Tile press soft fast press hang" })?.timeMs, 15_030)
        let requests = StubURLProtocol.requests(id)
        XCTAssertEqual(requests.first?.query("keyword"), "Get Lucky - Daft Punk")
        XCTAssertEqual(requests[1].query("hash"), "4667d6b91ce6fe1d91809fc05f2895e1")
        XCTAssertEqual(requests.last?.query("accesskey"), "A90EA796C11ABDAC9D1EA88BE51F8726")
    }
}

/// LRCLIB's two calls, through a stubbed session.
final class LrcLibLookupTests: XCTestCase {
    func testFallsBackToTheFuzzySearchWhenTheExactMatchMisses() async throws {
        let search = try Fixture.data("lrclib-search-get-lucky.json")
        let (session, id) = StubURLProtocol.session { request in
            request.url?.path == "/api/search" ? .ok(search) : .status(404, #"{"code":404}"#)
        }
        let lines = try await XCTUnwrapAsync(try await LrcLibProvider(session: session).lyrics(title: "Get Lucky (Official Audio)", artist: "Daft Punk", durationMs: 248_000))
        XCTAssertGreaterThan(lines.sung.count, 20)
        let requests = StubURLProtocol.requests(id)
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/get", "/api/search"])
        // YouTube's noise is cleaned before asking.
        XCTAssertEqual(requests[0].query("track_name"), "Get Lucky")
        XCTAssertEqual(requests[0].query("duration"), "248")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "User-Agent"), "Vibra Music (https://github.com/vibramusic)")
    }
}

/// Musixmatch's rich sync and its signed API (ported from Android's `MusixmatchTest`, plus
/// the recorded "Get Lucky" answers).
final class MusixmatchRichSyncTests: XCTestCase {

    func testRichSyncKeepsWordTimingAndMergesSyllableFragments() throws {
        let body = """
        [{
          "ts":48.502, "te":50.813, "x":"Paint stair harbor print narrow throw PARK",
          "l":[
            {"c":"Paint","o":0.000},{"c":" ","o":0.120},
            {"c":"stair ","o":0.180},{"c":"harbor ","o":0.520},
            {"c":"print ","o":0.870},{"c":"nar","o":1.080},
            {"c":"row ","o":1.240},{"c":"throw ","o":1.560},
            {"c":"PARK","o":1.820}
          ]
        }]
        """
        let line = try XCTUnwrap(MusixmatchProvider.parseRichSyncBody(body).sung.first)
        XCTAssertTrue(line.isWordSynced)
        XCTAssertEqual(line.text, "Paint stair harbor print narrow throw PARK")
        XCTAssertEqual(line.words.map(\.text), ["Paint", "stair", "harbor", "print", "narrow", "throw", "PARK"])
        XCTAssertEqual(line.timeMs, 48_502)
        XCTAssertEqual(line.words[4].startMs, 49_582)
        XCTAssertEqual(line.words.last?.endMs, 50_813)
    }

    func testRichSyncNeverEmitsBackwardWordTimes() throws {
        let body = """
        [{"ts":10.0,"te":12.0,"x":"one two three","l":[
          {"c":"one ","o":0.0},{"c":"two ","o":0.7},{"c":"three","o":0.65}
        ]}]
        """
        let words = try XCTUnwrap(MusixmatchProvider.parseRichSyncBody(body).sung.first).words
        XCTAssertEqual(words.map(\.startMs), [10_000, 10_700, 10_700])
        XCTAssertTrue(zip(words, words.dropFirst()).allSatisfy { $0.startMs <= $1.startMs })
        XCTAssertTrue(words.allSatisfy { $0.endMs >= $0.startMs })
    }

    func testMalformedRichSyncIsIgnored() {
        XCTAssertEqual(MusixmatchProvider.parseRichSyncBody("not json"), [])
    }

    func testRecordedGetLuckyRichSyncIsWordSynced() throws {
        let envelope = try Fixture.text("musixmatch-richsync-get-lucky.json")
        let body = try XCTUnwrap(LyricsJSON.parse(envelope)?["message"]?["body"]?["richsync"]?["richsync_body"]?.content)
        let lines = MusixmatchProvider.parseRichSyncBody(body)
        XCTAssertGreaterThan(lines.sung.count, 40)
        XCTAssertTrue(lines.sung.allSatisfy(\.isWordSynced))
        XCTAssertEqual(lines.sung.first?.words.first?.text, "Tile")
    }

    func testRecordedSubtitleBecomesLineSyncedLRC() throws {
        let envelope = try Fixture.text("musixmatch-subtitle-get-lucky.json")
        let body = try XCTUnwrap(LyricsJSON.parse(envelope)?["message"]?["body"]?["subtitle"]?["subtitle_body"]?.content)
        let lrc = MusixmatchProvider.subtitleToLRC(body)
        XCTAssertTrue(lrc.hasPrefix("["))
        let lines = LRCFormat.parse(lrc)
        XCTAssertGreaterThan(lines.sung.count, 40)
        XCTAssertFalse(lines.contains(where: \.isWordSynced))
    }

    func testScoringPrefersTheCutClosestInLengthAmongEqualNames() throws {
        let tracks = try XCTUnwrap(MusixmatchProvider.tracks(inSearch: Fixture.text("musixmatch-search-get-lucky.json")))
        XCTAssertGreaterThan(tracks.count, 3)
        let best = tracks.kMaxBy { MusixmatchProvider.score($0, title: "Get Lucky", artist: "Daft Punk", seconds: 248) }
        XCTAssertEqual(best?.trackLength, 248)
        let album = tracks.kMaxBy { MusixmatchProvider.score($0, title: "Get Lucky", artist: "Daft Punk", seconds: 370) }
        XCTAssertEqual(album?.trackName, "Get Lucky")
    }

    func testAnExpiredTokenIsRecognisedInsideASuccessfulResponse() {
        XCTAssertTrue(MusixmatchProvider.looksUnauthorized(#"{"message":{"header":{"status_code":401}}}"#))
        XCTAssertFalse(MusixmatchProvider.looksUnauthorized(#"{"message":{"header":{"status_code":200}}}"#))
        XCTAssertFalse(MusixmatchProvider.looksUnauthorized("<html>"))
    }

    /// The signature is HMAC-SHA256 over the URL (spaces as `+`) and the UTC date — the value
    /// below was computed independently with Python's `hmac`.
    func testSignsTheURLAndDateTheWayTheWebClientDoes() {
        let date = Date(timeIntervalSince1970: 1_790_380_800) // 2026-09-26T00:00:00Z
        let signed = MusixmatchProvider.sign(
            "https://apic.musixmatch.com/ws/1.1/track.search?app_id=mobile-app-v1.0&q_track=Get%20Lucky",
            secret: MusixmatchProvider.fallbackSigningSecret,
            date: date
        )
        XCTAssertTrue(signed.hasPrefix("https://apic.musixmatch.com/ws/1.1/track.search?app_id=mobile-app-v1.0&q_track=Get+Lucky&signature="))
        XCTAssertTrue(signed.hasSuffix("&signature_protocol=sha256"))
        XCTAssertTrue(signed.contains("&signature=OS5fd95l7ZW3jDK9sfxFN5OboxLtDGCehXuIF0oSIsw%3D&"))
    }
}

/// Genius search and scraping (ported from Android's `GeniusTest`, with the recorded page).
final class GeniusScrapingTests: XCTestCase {
    private let sampleGeniusHTML = """
    <!DOCTYPE html>
    <html>
    <head><title>Queen - Bohemian Rhapsody Lyrics | Genius Lyrics</title></head>
    <body>
      <div data-lyrics-container="true" class="Lyrics__Container">
        <div data-exclude-from-selection="true" class="LyricsHeader__Container">
          <button>523 Contributors</button>
          <div class="SongBioPreview__Container">Song Bio</div>
        </div>
        [Intro]<br>
        Tulip pour press drawer summer?<br>
        Tulip pour flag train?<br>
        <br>
        [Verse 1]<br>
        Fetch, flag deep garden dry<br>
        Glad garden sit helmet step teapot, slide shop warm, mitten steady've honey<br>
        15You might also like<br>
      </div>
      <div data-lyrics-container="true" class="Lyrics__Container">
        [Chorus]<br>
        Fetch, summer gate flag square<br>
        Candle mitten Slow'n nest laugh rusty throw leaf scrub<br>
        42Embed
      </div>
    </body>
    </html>
    """

    func testDetectsSectionHeadersCorrectly() {
        XCTAssertTrue(GeniusProvider.isSectionHeader("[Verse 1]"))
        XCTAssertTrue(GeniusProvider.isSectionHeader("[Chorus]"))
        XCTAssertTrue(GeniusProvider.isSectionHeader("[Guitar Solo]"))
        XCTAssertTrue(GeniusProvider.isSectionHeader("[Bridge: Freddie Mercury]"))
        XCTAssertFalse(GeniusProvider.isSectionHeader("Tulip pour press drawer summer?"))
        XCTAssertFalse(GeniusProvider.isSectionHeader("[short"))
        XCTAssertFalse(GeniusProvider.isSectionHeader("]short["))
    }

    func testParsesGeniusHTMLAndExtractsCleanLyricsAndSections() throws {
        let texts = try XCTUnwrap(GeniusProvider.parseHTML(sampleGeniusHTML)).map(\.text)
        XCTAssertFalse(texts.contains { $0.contains("Contributors") })
        XCTAssertFalse(texts.contains { $0.contains("Song Bio") })
        XCTAssertFalse(texts.contains { $0.contains("You might also like") })
        XCTAssertFalse(texts.contains { $0.contains("Embed") })
        for expected in [
            "[Intro]", "Tulip pour press drawer summer?", "Tulip pour flag train?", "[Verse 1]", "Fetch, flag deep garden dry",
            "[Chorus]", "Fetch, summer gate flag square", "Candle mitten Slow'n nest laugh rusty throw leaf scrub",
        ] {
            XCTAssertTrue(texts.contains(expected), expected)
        }
    }

    func testStripsArtifactsLikeEmbedCountersAndUnicodeSpaces() {
        let cleaned = GeniusProvider.stripArtifacts("Some lyric line\u{00A0}with non-breaking spaces\n12You might also like\nAnother line\n345Embed")
        XCTAssertFalse(cleaned.contains("You might also like"))
        XCTAssertFalse(cleaned.contains("Embed"))
        XCTAssertFalse(cleaned.contains("\u{00A0}"))
        XCTAssertTrue(cleaned.contains("Some lyric line with non-breaking spaces"))
        XCTAssertTrue(cleaned.contains("Another line"))
    }

    func testConvertsMultiLineTextIntoLyricLinesWithProperStanzaSeparation() {
        let lines = GeniusProvider.textToLyricLines("[Verse 1]\nLine 1\nLine 2\n\n[Chorus]\nLine 3")
        XCTAssertEqual(lines.map(\.text), ["[Verse 1]", "Line 1", "Line 2", "", "[Chorus]", "Line 3"])
        XCTAssertTrue(lines[3].isGap)
    }

    func testReadsTheRecordedGetLuckyPage() throws {
        let lines = try XCTUnwrap(GeniusProvider.parseHTML(Fixture.text("genius-page-get-lucky.html")))
        let texts = lines.map(\.text)
        XCTAssertTrue(texts.contains("Tile press soft fast press hang, shadow"), texts.prefix(8).joined(separator: " / "))
        XCTAssertTrue(texts.contains { GeniusProvider.isSectionHeader($0) })
        XCTAssertFalse(texts.contains { $0.contains("Contributors") || $0.contains("Translations") })
        XCTAssertTrue(lines.allSatisfy { $0.timeMs == 0 })
        XCTAssertFalse(lines.first?.isGap ?? true)
        XCTAssertFalse(lines.last?.isGap ?? true)
    }

    func testPicksTheOriginalSongOverRemixesAndTranslations() throws {
        let body = try Fixture.text("genius-search-get-lucky.json")
        XCTAssertEqual(
            GeniusProvider.songURL(inSearch: body, targetTitle: "Get Lucky", targetArtist: "Daft Punk"),
            "https://genius.com/Daft-punk-get-lucky-lyrics"
        )
    }

    func testSearchAttemptsSplitArtistTitleUploads() {
        let attempts = GeniusProvider.searchAttempts(title: "♪ GEJLON - USA [OFFICIAL MUSIC VIDEO] Prod. Jake Angel Beats ♪", artist: "Gejlon")
        XCTAssertEqual(attempts.first?.query, "Gejlon USA")
        XCTAssertEqual(attempts.first?.title, "USA")
        XCTAssertEqual(Set(attempts.map(\.query)).count, attempts.count)
        XCTAssertEqual(GeniusProvider.searchAttempts(title: "Bohemian Rhapsody (Official Video)", artist: "Queen").first?.query, "Queen Bohemian Rhapsody")
    }
}

/// Megalobiz: the page parser Android wrote, against a real (archived) page and search.
final class MegalobizScrapingTests: XCTestCase {
    func testReadsTheLRCOffAnLRCPage() throws {
        let lines = try XCTUnwrap(MegalobizProvider.parsePage(Fixture.text("megalobiz-lrc-all-out-of-love-archived.html")))
        XCTAssertEqual(lines.sung.first?.text, "Jacket'd quilt' swim drawer shop teapot pillow press wave")
        XCTAssertEqual(lines.sung.first?.timeMs, 22_420)
        XCTAssertTrue(lines.sung.contains { $0.text == "Jacket'd leaf early fast honest" })
        XCTAssertFalse(lines.contains { $0.text.contains("<") || $0.text.contains("[ti:") })
    }

    func testFindsTheFirstResultOnTheSearchPage() throws {
        XCTAssertEqual(MegalobizProvider.pagePath(inSearch: try Fixture.text("megalobiz-search-thriller-archived.html")), "/lrc/maker/Thriller.55507088")
        XCTAssertEqual(MegalobizProvider.pagePath(inSearch: #"<a href="/lrc/maker/download/1.2?x=1&amp;y=2">"#), "/lrc/maker/download/1.2?x=1&y=2")
        XCTAssertNil(MegalobizProvider.pagePath(inSearch: try Fixture.text("megalobiz-searchall-404.json")))
    }
}

/// `XCTUnwrap` for an async expression's value.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
