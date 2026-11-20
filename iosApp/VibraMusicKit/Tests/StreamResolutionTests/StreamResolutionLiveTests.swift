import AVFoundation
import XCTest
@testable import StreamResolution

/// Against the real YouTube. Skipped unless VIBRAMUSIC_LIVE_TESTS=1.
///
/// These are the ground truth the offline tests cannot be: whether the catalog, the cipher tier
/// and the PoToken tier produce URLs googlevideo serves *today*, and whether AVPlayer accepts them.
final class StreamResolutionLiveTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamResolutionLiveTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    private func makeResolver(
        catalog: [StreamClientProfile] = StreamClientProfile.defaultCatalog,
        poTokens: StreamPoTokenProvider? = nil,
        ceiling: Int = Int.max
    ) -> StreamResolver {
        let visitor = StreamVisitorDataStore()
        let cipher = StreamCipherSolver(
            cacheDirectory: cacheDirectory, fallbackHash: { await visitor.musicShell()?.playerHash }
        )
        var configuration = StreamResolver.Configuration()
        configuration.catalog = catalog
        configuration.playbackCeilingKbps = { ceiling }
        return StreamResolver(configuration: configuration, visitorData: visitor, cipher: cipher, poTokens: poTokens)
    }

    /// Real song ids from a live, signed-out YouTube Music search (songs filter).
    private func searchSongIds(_ queries: [String], perQuery: Int) async throws -> [String] {
        var ids: [String] = []
        for query in queries {
            var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(StreamPlayerClient.webUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
            request.setValue(StreamClientProfile.webRemix.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "context": ["client": [
                    "clientName": "WEB_REMIX", "clientVersion": StreamClientProfile.webRemix.clientVersion,
                    "hl": "en", "gl": "US",
                ]],
                "query": query,
                "params": "EgWKAQIIAWoKEAoQCRADEAQQBQ%3D%3D",
            ])
            let (data, _) = try await URLSession.shared.data(for: request)
            let text = String(decoding: data, as: UTF8.self)
            let regex = try NSRegularExpression(pattern: #""videoId":"([A-Za-z0-9_-]{11})""#)
            var found: [String] = []
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let id = String(text[Range(match.range(at: 1), in: text)!])
                if !found.contains(id) && !ids.contains(id) { found.append(id) }
                if found.count == perQuery { break }
            }
            ids += found
        }
        return ids
    }

    private func fetchRange(_ stream: ResolvedYouTubeStream, _ range: ClosedRange<Int64>) async throws -> (Int, Data) {
        var request = URLRequest(url: stream.url)
        for (name, value) in stream.mediaHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// The whole-file check the orchestrator's 64 KB probe missed: the last 64 KB must be served too.
    private func assertWholeFileServed(_ stream: ResolvedYouTubeStream, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (status, head) = try await fetchRange(stream, 0...65_535)
        XCTAssertEqual(status, 206, "\(stream.videoId) head", file: file, line: line)
        XCTAssertEqual(String(decoding: head.prefix(8).suffix(4), as: UTF8.self), "ftyp", "\(stream.videoId) is not MP4", file: file, line: line)
        if let length = stream.contentLength, length > 200_000 {
            let (tailStatus, tail) = try await fetchRange(stream, (length - 65_536)...(length - 1))
            XCTAssertEqual(tailStatus, 206, "\(stream.videoId) tail refused", file: file, line: line)
            XCTAssertEqual(tail.count, 65_536, file: file, line: line)
        }
    }

    func testResolvesTenLiveSearchResultsToWholeMP4Streams() async throws {
        try requireLiveTests()
        let ids = try await searchSongIds(["Daft Punk", "Taylor Swift", "Arijit Singh", "The Weeknd", "Billie Eilish"], perQuery: 3)
        XCTAssertGreaterThanOrEqual(ids.count, 10, "search returned too few songs: \(ids)")
        let resolver = makeResolver()
        var resolved = 0
        for id in ids {
            let started = Date()
            let stream = try await resolver.resolve(id)
            let seconds = Date().timeIntervalSince(started)
            XCTAssertTrue(stream.isAVPlayerCompatible, "\(id): \(stream.mimeType)")
            XCTAssertTrue([139, 140, 141].contains(stream.itag), "\(id): itag \(stream.itag)")
            XCTAssertNotNil(stream.contentLength)
            // The probe already passed inside resolve; this repeats it from outside.
            let verdict = await StreamURLProbe(session: .shared).probe(stream.url, headers: stream.mediaHeaders)
            XCTAssertEqual(verdict, .ok, id)
            try await assertWholeFileServed(stream)
            print("LIVE resolved \(id) via \(stream.profileId) itag \(stream.itag) \(stream.kbps)kbps loudness \(stream.loudnessDb.map { "\($0)" } ?? "-") in \(String(format: "%.2f", seconds))s")
            resolved += 1
        }
        XCTAssertGreaterThanOrEqual(resolved, 10)
    }

    func testLowCeilingPicksTheSmallAACRung() async throws {
        try requireLiveTests()
        let stream = try await makeResolver(ceiling: StreamAudioQuality.low.maxKbps).resolve("dQw4w9WgXcQ")
        XCTAssertEqual(stream.itag, 139)
        XCTAssertLessThanOrEqual(stream.kbps, 64)
    }

    #if os(macOS)
    /// AVPlayer's own loader, with the minting client's headers, accepts the URL: this is what
    /// "playable" means on iOS.
    func testAVURLAssetLoadsAResolvedStreamWithAPositiveDuration() async throws {
        try requireLiveTests()
        let stream = try await makeResolver().resolve("dQw4w9WgXcQ")
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.mediaHeaders])
        let (duration, playable) = try await asset.load(.duration, .isPlayable)
        XCTAssertTrue(playable)
        XCTAssertGreaterThan(duration.seconds, 60)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty)
        print("LIVE AVURLAsset duration \(duration.seconds)s via \(stream.profileId)")
    }

    /// AVFoundation doubles the duration of YouTube's fragmented AAC; the init-segment patch
    /// fixes it. Proven on the whole real file, fetched in client-sized ranges.
    func testInitSegmentPatchGivesAVFoundationTheTrueDuration() async throws {
        try requireLiveTests()
        let stream = try await makeResolver().resolve("dQw4w9WgXcQ")
        let length = try XCTUnwrap(stream.contentLength)
        let expected = Double(try XCTUnwrap(stream.approxDurationMs)) / 1000
        var file = Data()
        while Int64(file.count) < length {
            let start = Int64(file.count)
            let end = min(start + stream.rangeChunkBytes, length) - 1
            let (status, chunk) = try await fetchRange(stream, start...end)
            XCTAssertEqual(status, 206)
            file.append(chunk)
        }
        func duration(of data: Data) async throws -> Double {
            let url = cacheDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: url)
            return try await AVURLAsset(url: url).load(.duration).seconds
        }
        let unpatched = try await duration(of: file)
        var patched = file
        XCTAssertEqual(YouTubeMP4InitSegment.patchDurations(in: &patched), 3)
        let fixed = try await duration(of: patched)
        print("LIVE duration: catalogue \(expected)s, AVFoundation unpatched \(unpatched)s, patched \(fixed)s")
        XCTAssertEqual(unpatched, expected * 2, accuracy: 2, "the quirk this patch exists for")
        XCTAssertEqual(fixed, expected, accuracy: 1)
    }
    #endif

    /// Tier 1: the web identities alone, with signatures and `n` solved in JavaScriptCore.
    func testCipherTierAloneYieldsWholePlayableStreams() async throws {
        try requireLiveTests()
        for profile in [StreamClientProfile.webRemix, .tvSimply, .mweb] {
            let resolver = makeResolver(catalog: [profile])
            let stream = try await resolver.resolve("dQw4w9WgXcQ")
            XCTAssertEqual(stream.profileId, profile.id)
            XCTAssertNotEqual(stream.url.streamQueryValue("n"), nil)
            try await assertWholeFileServed(stream)
            print("LIVE cipher tier \(profile.id): itag \(stream.itag) OK")
        }
    }

    /// Tier 2: a BotGuard PoToken minted in a hidden WKWebView, attached to WEB_REMIX.
    @MainActor
    func testPoTokenTierMintsTokensThatUnlockWebRemix() async throws {
        try requireLiveTests()
        let visitor = StreamVisitorDataStore()
        let visitorData = await visitor.visitorData()
        let provider = WebViewPoTokenProvider(timeout: 45)
        let token = try await provider.poToken(videoId: "dQw4w9WgXcQ", visitorData: XCTUnwrap(visitorData))
        let minted = try XCTUnwrap(token, "provider could not mint")
        XCTAssertGreaterThan(minted.playerRequestToken.count, 60)
        XCTAssertGreaterThan(minted.streamingDataToken.count, 60)
        XCTAssertNotNil(minted.streamingDataToken.range(of: #"^[A-Za-z0-9_=-]+$"#, options: .regularExpression))
        print("LIVE PoTokens: player \(minted.playerRequestToken.count) chars, streaming \(minted.streamingDataToken.count) chars")

        let cipher = StreamCipherSolver(cacheDirectory: cacheDirectory)
        var configuration = StreamResolver.Configuration()
        configuration.catalog = [.webRemix]
        let resolver = StreamResolver(configuration: configuration, visitorData: visitor, cipher: cipher, poTokens: provider)
        let stream = try await resolver.resolve("dQw4w9WgXcQ")
        XCTAssertNotNil(stream.url.streamQueryValue("pot"))
        try await assertWholeFileServed(stream)
        await provider.close()
    }

    /// Whatever Google decides about ANDROID_VR on a given day, the probe must agree with a real
    /// read past the first minute. Today (2026-09-26) that read is refused and so is the probe.
    func testProbeVerdictMatchesAReadPastTheFirstMegabyte() async throws {
        try requireLiveTests()
        let visitor = StreamVisitorDataStore()
        let extractor = InnerTubeStreamExtractor(
            session: .shared, catalog: [.androidVR], visitorData: visitor, cipher: nil, poTokens: nil, auth: nil,
            language: { "en" }, now: { Date() }
        )
        guard case .found(let found) = await extractor.extract(videoId: "dQw4w9WgXcQ", selection: .playback(maxKbps: .max), skip: []) else {
            return XCTFail("ANDROID_VR offered nothing")
        }
        let stream = found.resolved
        let length = try XCTUnwrap(stream.contentLength)
        let (lateStatus, _) = try await fetchRange(stream, (length - 65_536)...(length - 1))
        let verdict = await StreamURLProbe(session: .shared).probe(stream.url, headers: stream.mediaHeaders)
        print("LIVE ANDROID_VR late range HTTP \(lateStatus), probe \(verdict)")
        XCTAssertEqual(verdict == .ok, lateStatus == 206)
    }

    func testVisitorDataAndPlayerAreReadableToday() async throws {
        try requireLiveTests()
        let visitor = StreamVisitorDataStore()
        let value = await visitor.visitorData()
        XCTAssertTrue(StreamVisitorDataStore.looksLikeVisitorData(try XCTUnwrap(value)))
        let shell = await visitor.musicShell()
        XCTAssertNotNil(shell?.clientVersion)
        XCTAssertNotNil(shell?.playerHash)
        let cipher = StreamCipherSolver(cacheDirectory: cacheDirectory)
        let sts = await cipher.signatureTimestamp()
        XCTAssertGreaterThan(try XCTUnwrap(sts), 20_000)
        print("LIVE player \(try await cipher.playerHash()) sts \(sts ?? 0), WEB_REMIX \(shell?.clientVersion ?? "-")")
    }
}
