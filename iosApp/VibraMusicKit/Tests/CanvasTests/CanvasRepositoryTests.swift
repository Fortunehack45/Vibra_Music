import VibraMusicCore
import VibraMusicTestSupport
import XCTest
@testable import Canvas

/// Source order, caching and the provisional-miss rule (ported from
/// `data/canvas/CanvasRepository.kt`).
final class CanvasRepositoryTests: XCTestCase {
    private func repository(
        _ stub: URLProtocolStub,
        appleFixture: String? = "apple-search-inline.json"
    ) async -> (CanvasRepository, CanvasAppleTokenStore) {
        let session = stub.makeSession()
        let appleTokens = CanvasAppleTokenStore(session: session)
        await appleTokens.seed(token: "test-bearer", expiresAt: .distantFuture)
        if let appleFixture {
            stub.register(host: "amp-api.music.apple.com", response: .text(try! CanvasFixture.text(appleFixture)))
        } else {
            stub.register(host: "amp-api.music.apple.com", response: .status(404))
        }
        stub.register(host: "api.tidal.com", response: .status(404))
        stub.register(host: "vivimusicanvas.mkmdevilmi.workers.dev", response: .status(404))
        let repository = CanvasRepository(session: session, appleTokens: appleTokens)
        return (repository, appleTokens)
    }

    private var blindingLights: Song {
        Song(videoId: "vid123", title: "Blinding Lights", artist: "The Weeknd", albumName: "After Hours")
    }

    func testFirstHitWinsAndHitsAreCached() async throws {
        let stub = URLProtocolStub()
        let (repository, _) = await self.repository(stub)

        let firstAwaited = await repository.canvasFor(blindingLights)
        let first = try XCTUnwrap(firstAwaited)
        XCTAssertTrue(first.url.contains("blinding-lights-square"))
        let requestsAfterFirst = stub.requests.count
        XCTAssertGreaterThan(requestsAfterFirst, 0)

        let second = await repository.canvasFor(blindingLights)
        XCTAssertEqual(second, first)
        XCTAssertEqual(stub.requests.count, requestsAfterFirst, "the second visit is answered from the cache")

        let peeked = await repository.cached(blindingLights)
        XCTAssertEqual(peeked, first, "reopening the player paints what it knows without waiting")
    }

    func testFallsThroughToTidalWhenAppleAnswersWithTheWrongRecord() async throws {
        let stub = URLProtocolStub()
        let session = stub.makeSession()
        let appleTokens = CanvasAppleTokenStore(session: session)
        await appleTokens.seed(token: "test-bearer", expiresAt: .distantFuture)
        stub.register(host: "amp-api.music.apple.com", response: .text(try CanvasFixture.text("apple-search-wrong-artist.json")))
        stub.register(host: "api.tidal.com", response: .text(try CanvasFixture.text("tidal-tracks.json")))
        stub.register(host: "vivimusicanvas.mkmdevilmi.workers.dev", response: .status(404))
        let repository = CanvasRepository(session: session, appleTokens: appleTokens)

        let foundAwaited = await repository.canvasFor(blindingLights)
        let found = try XCTUnwrap(foundAwaited)
        XCTAssertTrue(found.url.contains("resources.tidal.com"), "Apple's tribute-act clip is rejected; Tidal's cover wins")
    }

    func testMissesAreCachedToo() async throws {
        let stub = URLProtocolStub()
        let (repository, _) = await self.repository(stub, appleFixture: nil)

        let awaited1 = await repository.canvasFor(blindingLights)
        XCTAssertNil(awaited1)
        let requestsAfterFirst = stub.requests.count
        XCTAssertGreaterThan(requestsAfterFirst, 0, "nothing having a canvas still costs the lookups once")

        let awaited2 = await repository.canvasFor(blindingLights)
        XCTAssertNil(awaited2)
        XCTAssertEqual(stub.requests.count, requestsAfterFirst)
    }

    func testSpotifyPriorityIsPartOfTheCacheKey() async throws {
        let stub = URLProtocolStub()
        let (repository, _) = await self.repository(stub, appleFixture: nil)

        let awaited3 = await repository.canvasFor(blindingLights, spotifyFirst: false)
        XCTAssertNil(awaited3)
        let afterDefault = stub.requests.count
        let awaited4 = await repository.canvasFor(blindingLights, spotifyFirst: true)
        XCTAssertNil(awaited4)
        XCTAssertGreaterThan(stub.requests.count, afterDefault, "toggling the order never reuses the other order's answer")
        let awaited5 = await repository.cached(blindingLights, spotifyFirst: false)
        XCTAssertNil(awaited5)
        let cachedMiss = await repository.cached(blindingLights, spotifyFirst: true)
        XCTAssertNil(cachedMiss, "a miss is cached, but only under the order that produced it")
        XCTAssertEqual(CanvasRepository.cacheKey(base: "song|x", spotifyFirst: false),
                       "song|x|spotifyFirst=false")
        XCTAssertNotEqual(
            CanvasRepository.cacheKey(base: "song|x", spotifyFirst: false),
            CanvasRepository.cacheKey(base: "song|x", spotifyFirst: true))
    }

    func testLocalFileWithoutCatalogueIdentitySkipsTheNetwork() async {
        let stub = URLProtocolStub()
        let (repository, _) = await self.repository(stub)
        let local = Song(videoId: "", title: "Home Recording", artist: "Me", localPath: "/music/take1.mp3")
        let awaited6 = await repository.canvasFor(local)
        XCTAssertNil(awaited6, "there is nothing to search on")
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testBlankTitleOrArtistSkipsTheNetwork() async {
        let stub = URLProtocolStub()
        let (repository, _) = await self.repository(stub)
        let awaited7 = await repository.canvasFor(Song(videoId: "x", title: "", artist: "Me"))
        XCTAssertNil(awaited7)
        let awaited8 = await repository.canvasFor(Song(videoId: "x", title: "Song", artist: ""))
        XCTAssertNil(awaited8)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testALateAlbumReopensAProvisionalMissButNeverAHit() async throws {
        let stub = URLProtocolStub()
        let (repository, _) = await self.repository(stub, appleFixture: nil)

        let withoutAlbum = Song(videoId: "vid123", title: "Blinding Lights", artist: "The Weeknd")
        let awaited9 = await repository.canvasFor(withoutAlbum)
        XCTAssertNil(awaited9)
        let afterBlindMiss = stub.requests.count

        // The album resolves a beat after the track starts — the one case worth a second round.
        let awaited10 = await repository.canvasFor(blindingLights)
        XCTAssertNil(awaited10)
        XCTAssertGreaterThan(stub.requests.count, afterBlindMiss)

        // ...but a hit is a hit: the album could only have confirmed it.
        let stub2 = URLProtocolStub()
        let (repository2, _) = await self.repository(stub2)
        let hitAwaited = await repository2.canvasFor(withoutAlbum)
        let hit = try XCTUnwrap(hitAwaited)
        let afterHit = stub2.requests.count
        let awaited11 = await repository2.canvasFor(blindingLights)
        XCTAssertEqual(awaited11, hit)
        XCTAssertEqual(stub2.requests.count, afterHit)
    }

    func testAskingForATrackAlreadyBeingLookedUpWaitsForThatLookup() async throws {
        let appleHost = "amp-api.music.apple.com"
        let soloStub = URLProtocolStub()
        let (solo, _) = await self.repository(soloStub)
        _ = await solo.canvasFor(blindingLights)
        let oneLookup = soloStub.requests.filter { $0.url?.host == appleHost }.count
        XCTAssertGreaterThan(oneLookup, 0)

        let stub = URLProtocolStub()
        let (repository, _) = await self.repository(stub)
        // Slow enough that the second ask arrives while the first is still on the wire.
        stub.register(host: appleHost) { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return .text(try CanvasFixture.text("apple-search-inline.json"))
        }
        async let first = repository.canvasFor(blindingLights)
        async let second = repository.canvasFor(blindingLights)
        let found = await [first, second]

        XCTAssertNotNil(found[0])
        XCTAssertEqual(found[0], found[1])
        XCTAssertEqual(stub.requests.filter { $0.url?.host == appleHost }.count, oneLookup,
                       "the second ask shares the first lookup instead of repeating its requests")
    }

    func testABlindLookupFinishingLateDoesNotEraseTheClipTheAlbumAwareOneFound() async throws {
        let stub = URLProtocolStub()
        let (repository, _) = await self.repository(stub)
        // Only a search that carries the album finds the clip; a blind one is slow and misses.
        stub.register(host: "amp-api.music.apple.com") { request in
            if request.url?.query?.contains("After") == true {
                return .text(try CanvasFixture.text("apple-search-inline.json"))
            }
            Thread.sleep(forTimeInterval: 0.4)
            return .status(404)
        }
        let withoutAlbum = Song(videoId: "vid123", title: "Blinding Lights", artist: "The Weeknd")
        let blind = Task { await repository.canvasFor(withoutAlbum) }
        try await Task.sleep(for: .milliseconds(100))

        let aware = await repository.canvasFor(blindingLights)
        XCTAssertNotNil(aware)
        let blindResult = await blind.value
        XCTAssertNil(blindResult)

        let kept = await repository.cached(blindingLights)
        XCTAssertEqual(kept, aware, "the late blind miss left the stored clip alone")
    }

    func testAlbumLookupAsksForTheReleaseDirectly() async throws {
        let stub = URLProtocolStub()
        let session = stub.makeSession()
        let appleTokens = CanvasAppleTokenStore(session: session)
        await appleTokens.seed(token: "test-bearer", expiresAt: .distantFuture)
        stub.register(host: "amp-api.music.apple.com", response: .text(try CanvasFixture.text("apple-search-albums.json")))
        let repository = CanvasRepository(session: session, appleTokens: appleTokens)

        let foundAwaited = await repository.canvasForAlbum("After Hours", artist: "The Weeknd")
        let found = try XCTUnwrap(foundAwaited)
        XCTAssertEqual(found.album, "After Hours")
        XCTAssertTrue(found.url.contains("after-hours-square"))
    }

    func testEntryReuseRule() {
        let hit = CanvasRepository.Entry(artwork: CanvasArtwork(url: "https://example.com/a.mp4"), withAlbum: false)
        XCTAssertTrue(hit.isReusable(nowWithAlbum: false))
        XCTAssertTrue(hit.isReusable(nowWithAlbum: true), "a hit is a hit")

        let blindMiss = CanvasRepository.Entry(artwork: nil, withAlbum: false)
        XCTAssertTrue(blindMiss.isReusable(nowWithAlbum: false))
        XCTAssertFalse(blindMiss.isReusable(nowWithAlbum: true), "the provisional miss is reopened once the album lands")

        let informedMiss = CanvasRepository.Entry(artwork: nil, withAlbum: true)
        XCTAssertTrue(informedMiss.isReusable(nowWithAlbum: true))
    }
}
