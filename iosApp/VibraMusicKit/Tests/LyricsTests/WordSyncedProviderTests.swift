import XCTest
@testable import Lyrics

/// The wire formats the smaller providers use (ported from Android's `ProviderLyricsTest`).
final class ProviderLyricsFormatTests: XCTestCase {

    func testAllSixteenProvidersAreExposed() {
        XCTAssertEqual(LyricsSource.allCases.count, 16)
        for source in [LyricsSource.betterLyricsPortato, .megalobiz, .paxSenixSpotify, .paxSenixMusixmatch, .youtubeTranscript, .youtubeMusic] {
            XCTAssertTrue(LyricsSource.allCases.contains(source))
        }
    }

    func testJSONWrappedTTMLKeepsAppleWordTiming() throws {
        let raw = #"{"content":"<tt><body><div><p begin=\"1.0\" end=\"2.0\"><span begin=\"1.0\" end=\"1.4\">sing </span><span begin=\"1.4\" end=\"2.0\">along</span></p></div></body></tt>"}"#
        let line = try XCTUnwrap(ProviderLyrics.parse(raw)?.sung.first)
        XCTAssertEqual(line.text, "sing along")
        XCTAssertEqual(line.words.count, 2)
        XCTAssertEqual(line.words.last?.endMs, 2_000)
    }

    func testNetEasePrefixYRCGetsAppleStyleWordAnimation() throws {
        let line = try XCTUnwrap(KaraokeLRC.parse("[1000,900](1000,400,0)sing(1400,500,0)along").sung.first)
        XCTAssertEqual(line.text, "singalong")
        XCTAssertEqual(line.words.map(\.startMs), [1_000, 1_400])
        XCTAssertEqual(line.words.last?.endMs, 1_900)
    }

    func testQQSuffixQRCGetsAppleStyleWordAnimation() throws {
        let line = try XCTUnwrap(KaraokeLRC.parse("[1000,900]sing (1000,400,0)along(1400,500,0)").sung.first)
        XCTAssertEqual(line.text, "sing along")
        XCTAssertEqual(line.words.count, 2)
        XCTAssertTrue(line.isWordSynced)
    }

    func testQQXMLEnvelopeIsRecognisedAsKaraokeRatherThanTTML() throws {
        let qrc = #"<QrcInfos><LyricInfo LyricContent="[1000,900]sing (1000,400,0)along(1400,500,0)"/></QrcInfos>"#
        let line = try XCTUnwrap(ProviderLyrics.parse(qrc)?.sung.first)
        XCTAssertEqual(line.text, "sing along")
        XCTAssertEqual(line.words.count, 2)
    }

    func testStructuredPaxSenixAppleResponseKeepsWordTiming() throws {
        let raw = """
        {"type":"Word","content":[
          {"timestamp":1000,"text":[{"text":"sing","timestamp":1000},{"text":"along","timestamp":1400}]},
          {"timestamp":2200,"text":[{"text":"again","timestamp":2200}]}
        ]}
        """
        let lines = try XCTUnwrap(PaxSenixProvider.parseTimedApple(raw)).sung
        XCTAssertEqual(lines.first?.text, "sing along")
        XCTAssertEqual(lines.first?.words[1].startMs, 1_400)
        XCTAssertEqual(lines.first?.words[1].endMs, 2_200)
    }

    func testPaxSenixAcceptsBareAndBearerPrefixedAPIKeys() {
        XCTAssertEqual(PaxSenixProvider.normalizeAPIKey(" secret "), "secret")
        XCTAssertEqual(PaxSenixProvider.normalizeAPIKey("Bearer secret"), "secret")
        XCTAssertEqual(PaxSenixProvider.normalizeAPIKey("bearer   secret "), "secret")
    }

    func testPaxSenixGeneralFallbackSelectsOneCandidateInsteadOfRepeatingAll() throws {
        let raw = """
        {"lyrics":[
          {"id":"wrong","trackName":"Out of Touch","artistName":"Other","duration":201,
           "syncedLyrics":"[00:01.00]wrong line\\n[00:02.00]wrong again"},
          {"id":"right","trackName":"Out of Time","artistName":"The Weeknd","duration":201,
           "syncedLyrics":"[00:01.00]first line\\n[00:02.00]second line"},
          {"id":"duplicate","trackName":"Out of Time (Remix)","artistName":"The Weeknd","duration":240,
           "syncedLyrics":"[00:01.00]first line\\n[00:02.00]second line"}
        ]}
        """
        let lines = try XCTUnwrap(PaxSenixProvider.parseLrcGet(raw, title: "Out of Time", artist: "The Weeknd", durationMs: 201_000)).sung
        XCTAssertEqual(lines.map(\.text), ["first line", "second line"])
        XCTAssertEqual(lines.map(\.timeMs), [1_000, 2_000])
    }

    func testPaxSenixGeneralFallbackTreatsStringArrayEntriesAsSeparateLRCDocuments() throws {
        let raw = """
        {"lyrics":[
          "[00:01.00]wrong first\\n[00:40.00]wrong last",
          "[00:01.00]right first\\n[03:19.00]right last",
          "[00:01.00]right first\\n[03:19.00]right last"
        ]}
        """
        let lines = try XCTUnwrap(PaxSenixProvider.parseLrcGet(raw, title: "Song", artist: "Artist", durationMs: 200_000)).sung
        XCTAssertEqual(lines.map(\.text), ["right first", "right last"])
        XCTAssertEqual(lines.map(\.timeMs), [1_000, 199_000])
    }

    func testYouTubeNestedTextObjectsAreTraversedWithoutCrashing() throws {
        let response = try XCTUnwrap(LyricsJSON.parse(#"{"text":{"runs":[{"text":"Lyrics"}]}}"#))
        XCTAssertEqual(response.youtubeStrings, ["Lyrics"])
    }

    func testAnErrorEnvelopeIsNotLyrics() {
        XCTAssertNil(ProviderLyrics.parse(#"{"error":"qq: no songs found for: Get Lucky - Daft Punk","provider":"qq"}"#))
        XCTAssertNil(ProviderLyrics.parse(#"{"isError":true,"lyrics":"x"}"#))
        XCTAssertNil(ProviderLyrics.parse("Lyrics not found"))
        XCTAssertNil(ProviderLyrics.parse("   "))
    }

    func testPlainTextBecomesUnsyncedLinesWithoutTags() throws {
        let lines = try XCTUnwrap(ProviderLyrics.parse("```\n[ar:Someone]\nfirst\n\nsecond\n```"))
        XCTAssertEqual(lines.map(\.text), ["first", "second"])
        XCTAssertTrue(lines.allSatisfy { $0.timeMs == 0 })
    }

    func testEscapedTTMLInsideJSONIsUnescaped() throws {
        let raw = #"{"lyrics":"&lt;tt&gt;&lt;body&gt;&lt;p begin=&quot;1&quot; end=&quot;2&quot;&gt;&lt;span begin=&quot;1&quot; end=&quot;2&quot;&gt;hi&lt;/span&gt;&lt;/p&gt;&lt;/body&gt;&lt;/tt&gt;"}"#
        XCTAssertEqual(try XCTUnwrap(ProviderLyrics.parse(raw)).sung.first?.words.map(\.text), ["hi"])
    }
}

/// Each Apple-catalogue host against the answer it actually gave for "Get Lucky".
final class AppleCatalogueProviderTests: XCTestCase {

    func testBetterLyricsServesWordTimedTTMLInAJSONEnvelope() throws {
        let lines = try XCTUnwrap(ProviderLyrics.parse(Fixture.text("betterlyrics-get-lucky.json")))
        XCTAssertGreaterThan(lines.sung.count, 40)
        XCTAssertTrue(lines.sung.allSatisfy(\.isWordSynced))
        XCTAssertEqual(lines.sung.first?.text, "Tile press soft fast press hang, shadow")
    }

    func testPortatosRefusalIsAMissNotLyrics() throws {
        XCTAssertNil(ProviderLyrics.parse(try Fixture.text("betterlyrics-portato-401.json")))
        XCTAssertNil(ProviderLyrics.parse(try Fixture.text("betterlyrics-portato-404.json")))
    }

    func testBetterLyricsSendsTitleArtistDurationAndAlbum() async throws {
        let body = try Fixture.data("betterlyrics-get-lucky.json")
        let (session, id) = StubURLProtocol.session { _ in .ok(body) }
        let lines = await BetterLyricsProvider(session: session).lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_500, album: "Random Access Memories")
        XCTAssertNotNil(lines)
        let request = try XCTUnwrap(StubURLProtocol.requests(id).first)
        XCTAssertEqual(request.url?.host, "lyrics-api.boidu.dev")
        XCTAssertEqual(request.query("s"), "Get Lucky")
        XCTAssertEqual(request.query("a"), "Daft Punk")
        XCTAssertEqual(request.query("d"), "248")
        XCTAssertEqual(request.query("al"), "Random Access Memories")
    }

    func testReadsABiniLyricsSearchHit() throws {
        let hit = try XCTUnwrap(BiniLyricsProvider.firstHit(Fixture.text("binilyrics-search-get-lucky.json")))
        XCTAssertEqual(hit.isrc, "USQX91300809")
        XCTAssertEqual(hit.timingType, "word")
        XCTAssertEqual(hit.duration, 248)
        XCTAssertEqual(hit.lyricsURL, "https://lrc.red/s/USQX91300809.ttml")
        XCTAssertNil(BiniLyricsProvider.firstHit(#"{"total":0}"#))
    }

    func testBiniLyricsIdentifiesOnceAndReusesTheHitForTheWords() async throws {
        let search = try Fixture.data("binilyrics-search-get-lucky.json")
        let ttml = try Fixture.data("binilyrics-USQX91300809.ttml")
        let (session, id) = StubURLProtocol.session { request in
            request.url?.host == "lrc.red" ? .ok(ttml) : .ok(search)
        }
        let bini = BiniLyricsProvider(session: session)
        let request = LyricsProviderRequest(videoId: "4D7u5KF7SP8", title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)
        let isrc = try await bini.identify(request)
        XCTAssertEqual(isrc, "USQX91300809")
        var withISRC = request
        withISRC.isrc = isrc
        let answer = try await XCTUnwrapAsync(try await bini.lyrics(for: withISRC))
        XCTAssertEqual(answer.isrc, "USQX91300809")
        XCTAssertGreaterThan(answer.lines.sung.count, 40)
        // One search, one document: the hit found by identify was reused.
        XCTAssertEqual(StubURLProtocol.requests(id).map { $0.url?.host }, ["lyrics-api.binimum.org", "lrc.red"])
        XCTAssertEqual(StubURLProtocol.requests(id).first?.query("duration"), "248")
    }

    func testBiniLyricsAsksByRecordingWhenTheISRCIsKnown() async throws {
        let (session, id) = StubURLProtocol.session { _ in .status(404) }
        let request = LyricsProviderRequest(videoId: "x", title: "Dracula", artist: "Tame Impala", durationMs: 205_000, isrc: "AUUM72500001")
        _ = try await BiniLyricsProvider(session: session).lyrics(for: request)
        let sent = try XCTUnwrap(StubURLProtocol.requests(id).first)
        XCTAssertEqual(sent.query("isrc"), "AUUM72500001")
        XCTAssertNil(sent.query("track"))
    }

    func testPaxSenixPicksTheAppleCandidateByTitleArtistAndLength() throws {
        let root = try XCTUnwrap(LyricsJSON.parse(Fixture.text("paxsenix-apple-search-get-lucky.json")))
        // Title-exact album cut and length-exact radio edit tie; the first listed wins, as on Android.
        XCTAssertEqual(PaxSenixProvider.bestCandidate(root, title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)?.id, "617154366")
        XCTAssertEqual(PaxSenixProvider.bestCandidate(root, title: "Get Lucky (Radio Edit)", artist: "Daft Punk", durationMs: 248_000)?.id, "1459540658")
        XCTAssertNil(PaxSenixProvider.bestCandidate(root, title: "Something Else Entirely", artist: "Nobody", durationMs: 1_000))
    }

    func testPaxSenixAppleLyricsAreWordTimedTTML() throws {
        let lines = try XCTUnwrap(PaxSenixProvider.parseResponse(Fixture.text("paxsenix-apple-lyrics-1459540658.json")))
        XCTAssertGreaterThan(lines.sung.count, 40)
        XCTAssertTrue(lines.sung.allSatisfy(\.isWordSynced))
    }

    func testPaxSenixAuthenticatedRoutesStayQuietWithoutAKey() async throws {
        let (session, id) = StubURLProtocol.session { _ in .ok("{}") }
        let pax = PaxSenixProvider(session: session)
        let spotify = await pax.spotifyLyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)
        XCTAssertNil(spotify)
        XCTAssertTrue(StubURLProtocol.requests(id).isEmpty, "no key, no request")

        pax.setAPIKey("Bearer abc123")
        _ = await pax.musixmatchLyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)
        let sent = try XCTUnwrap(StubURLProtocol.requests(id).first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
        XCTAssertEqual(sent.url?.path, "/lyrics/musixmatch")
        XCTAssertEqual(sent.query("d"), "248")
    }

    func testReadsTheRealLyricsPlusAnswer() throws {
        let response = try XCTUnwrap(LyricsPlusProvider.Response(json: Fixture.text("lyricsplus-get-lucky.json")))
        let lines = LyricsPlusProvider.parse(response)
        XCTAssertEqual(lines.sung.count, 87)
        XCTAssertEqual(lines.sung.first?.text, "Tile press soft fast press hang, shadow")
        XCTAssertEqual(lines.sung.first?.words.map(\.text).prefix(4), ["Tile", "press", "soft", "fast"])
        XCTAssertEqual(lines.sung.first?.words[2].startMs, 15_526)
        XCTAssertEqual(lines.sung.first?.words[2].endMs, 16_014)
    }

    func testLyricsPlusTakesTheFirstMirrorWithLyricsAndRemembersIt() async throws {
        let body = try Fixture.data("lyricsplus-get-lucky.json")
        let broke = try Fixture.data("lyricsplus-mirror-402.json")
        let (session, id) = StubURLProtocol.session { request in
            switch request.url?.host {
            case "lyricsplus.binimum.org": return .ok(body, delay: 0.05)
            case "lyricsplus.atomix.one": return .ok(#"{"lyrics":[]}"#)
            default: return .init(status: 402, body: broke)
            }
        }
        let provider = LyricsPlusProvider(session: session)
        let lines = await provider.lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000, isrc: "USQX91300809")
        XCTAssertEqual(lines?.sung.count, 87)
        XCTAssertEqual(StubURLProtocol.requests(id).count, 6)
        XCTAssertTrue(StubURLProtocol.requests(id).allSatisfy { $0.query("isrc") == "USQX91300809" && $0.query("title") == "Get Lucky" })
        // Next time the host that answered goes first in line. Every mirror is still started, and
        // concurrent tasks give no order to assert, so this only proves the second lookup works.
        _ = await provider.lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)
        XCTAssertEqual(StubURLProtocol.requests(id).count, 12)
    }

}

/// The community databases and the YouTube sources, against real (or, for SimpMusic,
/// schema-faithful) answers.
final class CommunityProviderTests: XCTestCase {

    func testReadsALineSyncedUnisonEntry() throws {
        let root = try XCTUnwrap(LyricsJSON.parse(Fixture.text("unison-golden-hour.json"))?.object)
        XCTAssertEqual(root["success"], .bool(true))
        let lines = try XCTUnwrap(UnisonProvider.lines(of: XCTUnwrap(UnisonProvider.Entry(root["data"])))).sung
        XCTAssertEqual(lines.prefix(2).map(\.text), ["Throw quiet flag pocket bridge", "Pepper' train press silver, shadow shadow Shake, tablet' cover print sunny"])
        XCTAssertEqual(lines[0].timeMs, 15_460)
        XCTAssertFalse(lines.contains(where: \.isWordSynced))
    }

    func testReadsAWordSyncedUnisonEntryAsTTML() throws {
        let lines = try XCTUnwrap(UnisonProvider.lines(of: .init(
            lyrics: #"<tt><body><div><p begin="1.0" end="2.0"><span begin="1.0" end="1.4">hold</span> <span begin="1.4" end="2.0">on</span></p></div></body></tt>"#,
            format: "ttml",
            syncType: "wordsync"
        )))
        let line = try XCTUnwrap(lines.sung.first)
        XCTAssertEqual(line.text, "hold on")
        XCTAssertTrue(line.isWordSynced)
        XCTAssertEqual(line.words[0].endMs, 1_400)
    }

    func testReadsAnUnsyncedUnisonEntryAsPlainLines() throws {
        let lines = try XCTUnwrap(UnisonProvider.lines(of: .init(lyrics: "  first line \n\n second line \n", format: "lrc", syncType: "plain")))
        XCTAssertEqual(lines.map(\.text), ["first line", "second line"])
        XCTAssertTrue(lines.allSatisfy { $0.timeMs == 0 })
    }

    func testAnEntryWithNoLyricsInItIsNotAMatch() {
        XCTAssertNil(UnisonProvider.lines(of: .init(format: "lrc", syncType: "linesync")))
        XCTAssertNil(UnisonProvider.lines(of: .init(lyrics: "  ", format: "lrc", syncType: "linesync")))
    }

    func testUnisonsNotFoundIsAMiss() async throws {
        let body = try Fixture.text("unison-404.json")
        let (session, _) = StubURLProtocol.session { _ in .status(404, body) }
        let lines = await UnisonProvider(session: session).lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)
        XCTAssertNil(lines)
    }

    func testSimpMusicPrefersRichSyncFromTheCutClosestInLength() throws {
        let body = try Fixture.text("simpmusic-get-lucky-constructed.json")
        let lines = try XCTUnwrap(SimpMusicProvider.parse(body, durationMs: 248_000)).sung
        XCTAssertTrue(lines.allSatisfy(\.isWordSynced))
        XCTAssertEqual(lines.first?.text, "Tile press soft fast press hang")
        // The escaped apostrophe is decoded.
        XCTAssertTrue(lines.contains { $0.text == "Tool't chilly fresh pickle" })
        // The 369s album entry is outside the tolerance for a 248s video.
        XCTAssertFalse(lines.contains { $0.text == "album cut line" })
    }

    func testSimpMusicReadsEitherSuccessEnvelopeAndNothingElse() throws {
        let entry = #"{"durationSeconds": 248, "syncedLyrics": "[00:15.03]Tile press soft fast press hang"}"#
        // The published schema's envelope, and the `type` spelling other clients read.
        XCTAssertEqual(SimpMusicProvider.parse(#"{"success": true, "data": [\#(entry)]}"#, durationMs: 248_000)?.sung.first?.text, "Tile press soft fast press hang")
        XCTAssertEqual(SimpMusicProvider.parse(#"{"type": "success", "data": [\#(entry)]}"#, durationMs: 248_000)?.sung.first?.text, "Tile press soft fast press hang")
        // A failed lookup carries an error rather than data, and anything else is not an answer.
        XCTAssertNil(SimpMusicProvider.parse(#"{"success": false, "error": {"code": 404, "reason": "Not found"}}"#, durationMs: 248_000))
        XCTAssertNil(SimpMusicProvider.parse(#"{"type": "error", "data": [\#(entry)]}"#, durationMs: 248_000))
        XCTAssertNil(SimpMusicProvider.parse(#"{"data": [\#(entry)]}"#, durationMs: 248_000))
    }

    func testSimpMusicsCloudflareBlockIsAMiss() throws {
        XCTAssertNil(SimpMusicProvider.parse(try Fixture.text("simpmusic-403.html"), durationMs: 248_000))
    }

    func testFindsTheLyricsTabAndReadsItsText() throws {
        let next = LyricsJSON.parse(try Fixture.text("youtube-next-4D7u5KF7SP8.json"))
        let endpoint = try XCTUnwrap(YouTubeMusicLyricsProvider.lyricsBrowseEndpoint(inNext: next))
        XCTAssertEqual(endpoint.browseId, "MPLYt_K8qWMWVqXGi-8")
        let lines = try XCTUnwrap(YouTubeMusicLyricsProvider.lines(inBrowse: LyricsJSON.parse(try Fixture.text("youtube-browse-lyrics-4D7u5KF7SP8.json"))))
        XCTAssertEqual(lines.first?.text, "Tile press soft fast press hang")
        XCTAssertTrue(lines.allSatisfy { $0.timeMs == 0 && !$0.text.contains("\r") })
    }

    func testReadsTranscriptCuesAsTimedLines() throws {
        let response = LyricsJSON.parse("""
        {"actions":[{"updateEngagementPanelAction":{"content":{"transcriptRenderer":{"body":{"transcriptBodyRenderer":{"cueGroups":[
          {"transcriptCueGroupRenderer":{"cues":[{"transcriptCueRenderer":{"cue":{"simpleText":"♪ Tile press soft fast press hang ♪"},"startOffsetMs":"15030","durationMs":"4000"}}]}},
          {"transcriptCueGroupRenderer":{"cues":[{"transcriptCueRenderer":{"cue":{"runs":[{"text":"Leaf gate"},{"text":" drawer scrub"}]},"startOffsetMs":"19550"}}]}},
          {"transcriptCueGroupRenderer":{"cues":[{"transcriptCueRenderer":{"cue":{"simpleText":"♪"},"startOffsetMs":"1000"}}]}}
        ]}}}}}}]}
        """)
        let lines = try XCTUnwrap(YouTubeTranscriptLyricsProvider.lines(inTranscript: response))
        XCTAssertEqual(lines.map(\.text), ["Tile press soft fast press hang", "Leaf gate drawer scrub"])
        XCTAssertEqual(lines.map(\.timeMs), [15_030, 19_550])
    }

    func testTheYouTubeSourcesAskTheInnerTubeClientForTheExactVideo() async throws {
        let next = try Fixture.data("youtube-next-4D7u5KF7SP8.json")
        let browse = try Fixture.data("youtube-browse-lyrics-4D7u5KF7SP8.json")
        let (session, id) = StubURLProtocol.session { request in
            request.url?.path.hasSuffix("/next") == true ? .ok(next) : .ok(browse)
        }
        let client = LyricsWebRemixClient(session: session)
        let lines = await YouTubeMusicLyricsProvider(client: client).lyrics(videoId: "4D7u5KF7SP8")
        XCTAssertGreaterThan(lines?.count ?? 0, 20)
        let requests = StubURLProtocol.requests(id)
        XCTAssertEqual(requests.map { $0.url?.path }, ["/youtubei/v1/next", "/youtubei/v1/browse"])
        let nextBody = try XCTUnwrap(requests[0].httpBody.flatMap { LyricsJSON.parse(String(decoding: $0, as: UTF8.self)) })
        XCTAssertEqual(nextBody["videoId"]?.content, "4D7u5KF7SP8")
        XCTAssertEqual(nextBody["playlistId"]?.content, "RDAMVM4D7u5KF7SP8")
        XCTAssertEqual(nextBody["context"]?["client"]?["clientName"]?.content, "WEB_REMIX")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-YouTube-Client-Name"), "67")
        let browseBody = try XCTUnwrap(requests[1].httpBody.flatMap { LyricsJSON.parse(String(decoding: $0, as: UTF8.self)) })
        XCTAssertEqual(browseBody["browseId"]?.content, "MPLYt_K8qWMWVqXGi-8")
        // A malformed id is never sent.
        let none = await YouTubeMusicLyricsProvider(client: client).lyrics(videoId: "not-an-id")
        XCTAssertNil(none)
    }

    func testTranscriptParamsAreTheOneFieldProtobufAndroidSends() {
        XCTAssertEqual(LyricsWebRemixClient.transcriptParams("4D7u5KF7SP8"), "Cgs0RDd1NUtGN1NQOA==")
    }
}
