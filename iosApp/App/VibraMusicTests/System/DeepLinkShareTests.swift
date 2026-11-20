import VibraMusicCore
import UniformTypeIdentifiers
import XCTest
@testable import Vibra Music

/// PORTING.md "Deep links and sharing into the app", the Share Extension half: a YouTube Music link
/// shared from another app opens the right screen (MainActivity's `ACTION_SEND`).
@MainActor
final class DeepLinkShareTests: XCTestCase {
    private let albumShare = URL(string: "https://music.youtube.com/playlist?list=OLAK5uy_kVyE3BHXL4Tzp7hVUbSgcUhOZpcj2GkpY&si=abc")!

    func testASharedAlbumLinkOpensThatAlbum() throws {
        let handoff = try XCTUnwrap(SharedLinkHandoff.appURL(link: albumShare, text: nil))
        XCTAssertEqual(handoff.scheme, "vibramusic")
        XCTAssertEqual(DeepLink.parse(handoff), .page(browseId: "VLOLAK5uy_kVyE3BHXL4Tzp7hVUbSgcUhOZpcj2GkpY"))
    }

    func testSharedTextWithALinkInItOpensTheSong() throws {
        let text = "Get Lucky - Daft Punk\nhttps://youtu.be/5NV6Rdv1a3I?si=x"
        let handoff = try XCTUnwrap(SharedLinkHandoff.appURL(link: nil, text: text))
        XCTAssertEqual(DeepLink.parse(handoff), .track(videoId: "5NV6Rdv1a3I"))
        XCTAssertNil(SharedLinkHandoff.appURL(link: nil, text: "   "), "nothing to hand over")
    }

    func testTheExtensionReadsTheSharedLinkAndText() async {
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(object: albumShare as NSURL)]
        item.attributedContentText = NSAttributedString(string: "Random Access Memories")
        let (link, text) = await SharedLinkHandoff.readShared([item])
        XCTAssertEqual(link, albumShare)
        XCTAssertEqual(text, "Random Access Memories")
    }

    /// A share the system wouldn't open the app for waits in the App Group, is served once when the
    /// app comes to the front, and goes stale after a while.
    func testAWaitingShareIsServedOnceWhenTheAppOpens() throws {
        let suite = "vibramusic.system.share.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let handoff = try XCTUnwrap(SharedLinkHandoff.appURL(link: albumShare, text: nil))

        SharedLinkHandoff.save(handoff, to: defaults, now: Date(timeIntervalSince1970: 0))
        XCTAssertNil(SharedLinkHandoff.take(from: defaults, now: Date(timeIntervalSince1970: SharedLinkHandoff.lifetime + 1)), "stale")
        XCTAssertNil(SharedLinkHandoff.take(from: defaults, now: Date(timeIntervalSince1970: 0)), "and gone: even a clock inside its lifetime finds nothing")

        SharedLinkHandoff.save(handoff, to: defaults)
        let app = makeNowPlayingApp(settings: makeTestSettings())
        XCTAssertTrue(SharedLinkInbox.shared.drain(defaults: defaults, model: app))
        XCTAssertEqual(app.router.path(for: app.router.selectedTab).last, AppRoute.browse("VLOLAK5uy_kVyE3BHXL4Tzp7hVUbSgcUhOZpcj2GkpY"))
        XCTAssertFalse(SharedLinkInbox.shared.drain(defaults: defaults, model: app), "served once")
    }

    /// The app coming to the front before the window has built its model still serves the share.
    func testAWaitingShareIsServedEvenBeforeTheWindowBuiltItsApp() throws {
        let suite = "vibramusic.system.share.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        SharedLinkHandoff.save(try XCTUnwrap(SharedLinkHandoff.appURL(link: albumShare, text: nil)), to: defaults)
        let app = makeNowPlayingApp(settings: makeTestSettings())
        SystemAppAccess.override = app
        addTeardownBlock { SystemAppAccess.override = nil }

        XCTAssertTrue(SharedLinkInbox.shared.drain(defaults: defaults))
        XCTAssertEqual(app.router.path(for: app.router.selectedTab).last, AppRoute.browse("VLOLAK5uy_kVyE3BHXL4Tzp7hVUbSgcUhOZpcj2GkpY"))
    }
}

/// PORTING.md "Haptics": named patterns, each mirrored by its opposite (Haptics.kt).
@MainActor
final class HapticNamedPatternTests: XCTestCase {
    func testOppositePatternsMirrorEachOther() {
        func shape(_ haptic: Haptic) -> [CGFloat] { haptic.beats.map(\.intensity) }
        XCTAssertEqual(shape(.toggleOff), shape(.toggleOn).reversed(), "switching off is switching on backwards")
        XCTAssertEqual(Haptic.skipPrevious.beats.map(\.style), Haptic.skipNext.beats.map(\.style).reversed())
        XCTAssertEqual(shape(.skipPrevious), shape(.skipNext).reversed())
        XCTAssertTrue(Haptic.toggleOn.beats.allSatisfy { $0.style == .light }, "liking a song is a light tap")
    }
}
