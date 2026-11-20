import VibraMusicCore
import InnerTube
import SwiftUI
import Theming
import XCTest
@testable import Vibra Music

// Helpers for the Now Playing tests: an app container that never touches the network, the
// environment the player's views read, and a host that lays a view out in a real window.

@MainActor
func makeNowPlayingApp(settings: AppSettings) -> AppModel {
    var launch = AppLaunchOptions()
    launch.restoresQueue = false
    launch.integratesWithSystem = false
    launch.isUITest = true
    let suite = "vibramusic.nowplaying.history.\(UUID().uuidString)"
    return AppModel(
        settings: settings,
        likeState: LikeState(),
        searchHistory: SearchHistory(defaults: UserDefaults(suiteName: suite)!),
        network: NetworkMonitor(),
        innerTube: InnerTubeClient(),
        audioCache: nil,
        launch: launch
    )
}

extension View {
    /// The environment ``NowPlayingScreen`` and its parts read, with the harness's player standing
    /// in for the app's.
    @MainActor
    func nowPlayingEnvironment(app: AppModel, harness: PlayerHarness) -> some View {
        environment(app)
            .environment(harness.player)
            .environment(app.router)
            .environment(harness.settings)
            .environment(app.likeState)
            .environment(app.searchHistory)
    }
}

/// Hosts `view` in a window of `size`, forces layout, and lets SwiftUI settle for a moment.
@MainActor
@discardableResult
func hostAndLayOut<V: View>(_ view: V, size: CGSize = CGSize(width: 393, height: 852)) -> UIHostingController<V> {
    let host = UIHostingController(rootView: view)
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.frame = window.bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    host.view.layoutIfNeeded()
    return host
}

/// Hosts `view` in a window on the app's own scene, where (unlike a free-standing window) SwiftUI
/// can present sheets. Hidden again at the end of the test.
@MainActor
func hostInScene<V: View>(_ view: V, test: XCTestCase, size: CGSize = CGSize(width: 393, height: 852)) -> UIHostingController<V> {
    let host = UIHostingController(rootView: view)
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
    window.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    test.addTeardownBlock { @MainActor in
        host.dismiss(animated: false)
        window.isHidden = true
    }
    return host
}

/// SwiftUI builds its accessibility tree only while an assistive technology is on; switching on
/// UI automation (as accessibility snapshot tools do) lets a test read the labels a screen drew.
@MainActor
private var accessibilityTreeEnabled = false

@MainActor
func enableAccessibilityTree() async {
    guard !accessibilityTreeEnabled else { return }
    accessibilityTreeEnabled = true
    enableAutomation()
    // The switch is delivered through the main queue: let it through before hosting anything.
    try? await Task.sleep(for: .milliseconds(500))
}

@MainActor
private func enableAutomation() {
    guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
          let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
    typealias SetEnabled = @convention(c) (Int32) -> Void
    unsafeBitCast(symbol, to: SetEnabled.self)(1)
}

/// SwiftUI draws most of a screen into layers rather than views, so "rendered" is: the host is in
/// a window, has a size, and put something on screen.
@MainActor
func assertRendered<V: View>(_ host: UIHostingController<V>, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNotNil(host.view.window, message, file: file, line: line)
    XCTAssertGreaterThan(host.view.bounds.width, 0, message, file: file, line: line)
    let drew = !(host.view.layer.sublayers ?? []).isEmpty || !host.view.allSubviews.isEmpty
    XCTAssertTrue(drew, "nothing was drawn \(message)", file: file, line: line)
}

extension UIView {
    /// Every view under this one, depth first.
    var allSubviews: [UIView] {
        subviews + subviews.flatMap(\.allSubviews)
    }
}

/// Artwork that "downloads" a solid colour per URL, so a mesh can be read without a network.
struct SolidColourArtworkLoader: ArtworkImageLoading {
    /// Keyed by the URL's last path component ("red", "blue").
    let colours: [String: UInt32]

    func loadArtwork(from url: URL, fittingLongestSide side: Int) async throws -> ArtworkPixels {
        let colour = colours[url.lastPathComponent] ?? 0xFF80_8080
        let edge = 24
        return ArtworkPixels(width: edge, height: edge, argb: Array(repeating: colour, count: edge * edge))
    }
}

extension PlayerHarness {
    /// A song as the player's own copy carries it, with album and artist ids so the song menu has
    /// nothing to look up over the network.
    func playerSong(_ id: String, seconds: Double = 8) throws -> Song {
        var song = try self.song(id, seconds: seconds)
        song.albumId = "MPREb_\(id)"
        song.artistId = "UC\(id)"
        return song
    }
}

/// The accessibility labels of the shipped song menu (Features/Collections/SongActionsSheet) for
/// `song`, as it renders with the router's current state: opened from the player when
/// `app.router.nowPlaying.isPresented` and `song` is the player's track.
@MainActor
func songMenuLabels(_ song: Song, app: AppModel, harness: PlayerHarness) async -> [String] {
    await enableAccessibilityTree()
    let host = hostAndLayOut(SongActionsSheet(song: song).nowPlayingEnvironment(app: app, harness: harness))
    defer { host.view.window?.isHidden = true }
    return await renderedLabelsSettling(host)
}

/// The labels `host` drew, giving SwiftUI's accessibility tree a moment to come up: the first
/// screen after the tree is switched on can take a few run-loop turns to report any.
@MainActor
func renderedLabelsSettling<V: View>(_ host: UIHostingController<V>) async -> [String] {
    for _ in 0..<20 {
        let labels = host.view.renderedLabels
        if !labels.isEmpty { return labels }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return host.view.renderedLabels
}

extension UIView {
    /// The smallest rectangle holding every pixel of what this view draws inside `area` that
    /// `matches` (red, green, blue), in points.
    func drawnBounds(in area: CGRect, where matches: (UInt8, UInt8, UInt8) -> Bool) -> CGRect? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in max(Int(area.minY), 0)..<min(Int(area.maxY), height) {
            for x in max(Int(area.minX), 0)..<min(Int(area.maxX), width) {
                let offset = (y * width + x) * 4
                guard matches(pixels[offset], pixels[offset + 1], pixels[offset + 2]) else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
