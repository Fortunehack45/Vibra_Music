import VibraMusicCore
import Lyrics
import SwiftUI
import UIKit
import XCTest
@testable import VibraMusic

/// Hosts `view` in a window at an iPhone's size and forces a layout pass, the way a screen is
/// first shown. Returns the host so a test can look inside it.
@MainActor
@discardableResult
func renderLyricsView<V: View>(_ view: V, settings: AppSettings, size: CGSize = CGSize(width: 393, height: 852)) -> UIHostingController<some View> {
    let host = UIHostingController(rootView: view.environment(settings).environment(\.colorScheme, .dark))
    // A window from the shared scene (the runner may not have one at all): attached to a scene,
    // Core Animation actually renders the layer tree, so presentation layers sample right.
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
    window.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.frame = window.bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.view.layoutIfNeeded()
    return host
}

extension UIView {
    /// Every descendant of type `T`, depth first.
    func lyricsDescendants<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.lyricsDescendants(of: type) }
    }
}

/// A line-synced song whose rows differ in height (one row, then several), each sung for 2.5 s of
/// every 3 s, so the page's run-up before each line is the full 500 ms.
let lyricsHandoverLines: [LyricLine] = [
    (0, "Short"),
    (3_000, "A much longer line that keeps on going until it wraps onto a third row of the page"),
    (6_000, "Hey"),
    (9_000, "Another longer line that is sure to need more than one row to fit on the screen"),
    (12_000, "Oh"),
    (15_000, "Last one here"),
    (18_000, "And more"),
    (21_000, "Final"),
].map { LyricLine(timeMs: $0.0, text: $0.1, sungUntilMs: $0.0 + 2_500) }

/// Hosts the panel the way Now Playing does, with the safe area out of the way so the panel's top
/// is `panelTop` in the window.
@MainActor
func hostLyricsPanel(lines: [LyricLine], clock: LyricFrameClock, settings: AppSettings, panelTop: CGFloat = 120) -> UIHostingController<some View> {
    renderLyricsView(
        VStack(spacing: 0) {
            Color.clear.frame(height: panelTop)
            LyricsPanelContent(lines: lines, subLines: nil, looking: false, trackKey: "t", clock: clock,
                               isPlaying: false, translation: LyricsTranslationController(), onSeek: { _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.clear.frame(height: 300)
        }
        .padding(.horizontal, LyricsPanelMetrics.gutter)
        .ignoresSafeArea(),
        settings: settings
    )
}

extension UIView {
    /// Where the view is drawn now, in window coordinates: the presentation layer, so a move that
    /// Core Animation or SwiftUI is part way through is seen part way through.
    var drawnTopInWindow: CGFloat { (layer.presentation() ?? layer).convert(CGPoint.zero, to: nil).y }
}

@MainActor
extension UIHostingController {
    /// The lead voice of the row showing `text`, if it is on screen.
    func lyricsVoice(_ text: String) -> LyricLineUIView? {
        view.lyricsDescendants(of: LyricLineUIView.self)
            .first { $0.window != nil && $0.line.text == text && $0.style.room == LyricsPanelMetrics.glowRoom }
    }

    /// The window-space tops of the rows showing `texts`, sampled every few milliseconds for
    /// `seconds`: one entry per sample, in the order asked for.
    func recordLyricsTops(of texts: [String], seconds: TimeInterval) -> [[CGFloat]] {
        var frames: [[CGFloat]] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.008))
            let tops = texts.compactMap { lyricsVoice($0)?.drawnTopInWindow }
            if tops.count == texts.count { frames.append(tops) }
        }
        return frames
    }
}

/// Serves Google Translate's recorded answers for two lines of YOASOBI's 夜に駆ける (the Lyrics
/// module's fixtures), so translation runs offline.
final class RecordedTranslateURLProtocol: URLProtocol {
    static let translated = Data(base64Encoded: "W1tbIkFzIHRoZSBxdWlldCBoYXJib3IgbGlnaHRzIHVwXG4iLCLpnZnjgYvjgarmuK/jgavnga/jgorjgYzjgajjgoLjgovpoIPjgatcbiIsbnVsbCxudWxsLDMsbnVsbCxudWxsLFtbXV0sW1tbIjg2MTBkZWQ2YWUxZjljMTk2NTliZmE5YmNiNzM0NGU3IiwiamFfZW5fMjAyM3ExLm1kIl0sdHJ1ZV1dXSxbIu6AgDAwMDHugIFcbiIsIu6AgDAwMDHugIFcbiIsbnVsbCxudWxsLDMsbnVsbCxudWxsLFtbXV0sW1tbIjg2MTBkZWQ2YWUxZjljMTk2NTliZmE5YmNiNzM0NGU3IiwiamFfZW5fMjAyM3ExLm1kIl0sdHJ1ZV1dXSxbIkluIHRoZSBtb3JuaW5nLCBkaXN0YW50IHdhdmVzIGtub2NrIGF0IHRoZSB3aW5kb3ciLCLpgaDjgYTms6Ljga7pn7PjgYznqpPjgpLjgZ/jgZ/jgY/mnJ0iLG51bGwsbnVsbCwzLG51bGwsbnVsbCxbW11dLFtbWyI4NjEwZGVkNmFlMWY5YzE5NjU5YmZhOWJjYjczNDRlNyIsImphX2VuXzIwMjNxMS5tZCJdXV1dXSxudWxsLCJqYSIsbnVsbCxudWxsLG51bGwsMSxbXSxbWyJqYSJdLG51bGwsWzFdLFsiamEiXV1d")!
    static let romanized = Data(base64Encoded: "W1tbbnVsbCxudWxsLG51bGwsIlNoaXp1a2EgbmEgbWluYXRvIG5pIGFrYXJpIGdhIHRvbW9ydSBrb3JvIG5pIO6AgCAwMDAxIO6AgSB0xY1pIG5hbWkgbm8gb3RvIGdhIG1hZG8gbyB0YXRha3UgYXNhIl1dLG51bGwsImphIixudWxsLG51bGwsbnVsbCwxLFtdLFtbImphIl0sbnVsbCxbMV0sWyJqYSJdXV0=")!

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordedTranslateURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        let wantsRomanization = body.contains("dt=rm") || (request.url?.query ?? "").contains("dt=rm")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: wantsRomanization ? Self.romanized : Self.translated)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
