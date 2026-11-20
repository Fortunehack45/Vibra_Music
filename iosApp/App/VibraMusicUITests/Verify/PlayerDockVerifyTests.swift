import XCTest

/// Verifies that the player moves between the mini player and open by a tap, a pull and the close
/// button, with the mini player's cover hidden while the player is in flight. Run it from the
/// folder that holds `VibraMusic.xcworkspace`:
/// `xcodebuild test -workspace VibraMusic.xcworkspace -scheme VibraMusic -testPlan VibraMusicE2E
/// -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VibraMusicUITests/PlayerDockVerifyTests`.
/// A song comes from the live YouTube Music; the mini player appears whether or not it streams.
final class PlayerDockVerifyTests: XCTestCase {
    func testTappingPullingAndClosingMovesThePlayerBetweenTheMiniPlayerAndOpen() throws {
        continueAfterFailure = false
        let app = launchForVerify()
        try playASong(app)
        capture(app, "1-mini-player")

        mini(app).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(screen(app).waitForExistence(timeout: 10), "a tap on the mini player did not open Now Playing")
        XCTAssertTrue(waitForProbe(app, "presented=1 t=1.000"), "the player never came to rest open: \(probe(app))")
        capture(app, "2-tap-opened")

        app.buttons["nowPlaying.close"].firstMatch.tap()
        XCTAssertTrue(waitForProbe(app, "presented=0"), "the handle did not close the player: \(probe(app))")
        XCTAssertTrue(screen(app).waitForNonExistence(timeout: 5), "the cover is still up")
        capture(app, "3-handle-closed")

        let shots = ShotBox()
        shots.sample(everyMilliseconds: 300, after: 800, upTo: 8)
        let from = mini(app).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        from.press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)),
            withVelocity: .slow,
            thenHoldForDuration: 0.6
        )
        for (index, shot) in shots.stop().enumerated() {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "4-held-half-pull-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let afterHold = probe(app)
        let holds = try XCTUnwrap(number("holds", in: afterHold), "no holds in \(afterHold)")
        let low = try XCTUnwrap(number("low", in: afterHold))
        let high = try XCTUnwrap(number("high", in: afterHold))
        XCTAssertGreaterThan(holds, 5, "the pull stopped reaching the dock once the cover was up (risk 1): \(afterHold)")
        XCTAssertGreaterThan(high - low, 0.1, "t did not change after the cover appeared: \(afterHold)")
        XCTAssertTrue(waitForProbe(app, "presented=0"), "a released half pull should dock again: \(probe(app))")
        capture(app, "5-half-pull-released")

        from.press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.72)),
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )
        XCTAssertTrue(waitForProbe(app, "presented=0"), "a pull below half should spring back: \(probe(app))")
        XCTAssertTrue(screen(app).waitForNonExistence(timeout: 5), "the cover is still up")
        capture(app, "6-slow-pull-sprang-back")

        from.press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.3)),
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        XCTAssertTrue(screen(app).waitForExistence(timeout: 10), "a fast pull did not open the player")
        XCTAssertTrue(waitForProbe(app, "presented=1 t=1.000"), "the player never came to rest open: \(probe(app))")
        capture(app, "7-fast-pull-opened")
    }

    func testATapOpenInSlowMotionPassesThroughTheFractionsBetween() throws {
        continueAfterFailure = false
        let app = launchForVerify(["-dockTimeScale", "8"])
        try playASong(app)
        mini(app).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()

        var seen: [Double] = []
        for step in 0..<8 {
            Thread.sleep(forTimeInterval: 0.7)
            if let t = number("t", in: probe(app)) { seen.append(t) }
            capture(app, "slow-open-\(step)")
        }
        XCTAssertEqual(seen, seen.sorted(), "an open went backwards: \(seen)")
        XCTAssertTrue(seen.contains { $0 > 0.02 && $0 < 0.98 }, "no frame between the mini player and open was seen: \(seen)")
    }

    func testTheArtworkFliesFromTheMiniCoverToItsCardAndBackWhileTheCoverStandsAside() throws {
        continueAfterFailure = false
        let app = launchForVerify(["-dockTimeScale", "8", "-nowPlayingFullBleed", "NO"])
        try playASong(app)
        try assertFlightsOnOpenAndClose(app, label: "card")
    }

    func testTheArtworkFliesToTheCollapsedThumbWhenTheLyricsAreUp() throws {
        continueAfterFailure = false
        let app = launchForVerify(["-dockTimeScale", "8", "-nowPlayingFullBleed", "NO"])
        try playASong(app)
        mini(app).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(waitForProbe(app, "presented=1 t=1.000", timeout: 20), "the player never came to rest open: \(probe(app))")
        app.buttons["nowPlaying.lyrics"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        capture(app, "lyrics-up")
        app.buttons["nowPlaying.close"].firstMatch.tap()
        XCTAssertTrue(waitForProbe(app, "presented=0", timeout: 20), "the handle did not close the player: \(probe(app))")

        let landing = try assertFlightsOnOpenAndClose(app, label: "thumb")
        mini(app).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(waitForProbe(app, "presented=1 t=1.000", timeout: 20), "the player never came to rest open: \(probe(app))")
        app.buttons["nowPlaying.thumbnail"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 3)
        app.buttons["nowPlaying.close"].firstMatch.tap()
        XCTAssertTrue(waitForProbe(app, "presented=0", timeout: 30), "the handle did not close the player: \(probe(app))")
        XCTAssertEqual(landing[2], 54, accuracy: 3, "the artwork did not land on the 54 pt thumb: \(landing)")
    }

    func testTheFullBleedBannerFliesEdgeToEdgeToTheMiniCover() throws {
        continueAfterFailure = false
        let app = launchForVerify(["-dockTimeScale", "8", "-nowPlayingFullBleed", "YES"])
        try playASong(app)
        mini(app).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(waitForProbe(app, "presented=1 t=1.000", timeout: 20), "the player never came to rest open: \(probe(app))")
        Thread.sleep(forTimeInterval: 3)
        if app.buttons["nowPlaying.thumbnail"].exists {
            app.buttons["nowPlaying.thumbnail"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 3)
        }
        capture(app, "banner-at-rest")
        let landing = try XCTUnwrap(DockSample(probe(app)).art, "no art at rest: \(probe(app))")
        XCTAssertEqual(landing[1], 0, accuracy: 3, "the banner does not start at the top of the window: \(landing)")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(landing[2], window.width, accuracy: 3, "the banner is not edge to edge: \(landing)")

        app.buttons["nowPlaying.close"].firstMatch.tap()
        let closing = sampleFlight(app, label: "banner-close", until: "presented=0")
        try assertSamplesLieBetweenTheCoverAndTheLanding(closing)
    }

    func testTheArtworkFliesInLandscape() throws {
        continueAfterFailure = false
        let app = launchForVerify(["-dockTimeScale", "8", "-nowPlayingFullBleed", "NO"])
        try playASong(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(mini(app).waitForExistence(timeout: 10), "no mini player in landscape")
        capture(app, "landscape-mini")
        let landing = try assertFlightsOnOpenAndClose(app, label: "landscape")
        XCTAssertGreaterThan(landing[3], 150, "the landscape sleeve is too small: \(landing)")
    }

    func testUnderReduceAnimationNothingFliesAndTheCoverNeverStandsAside() throws {
        continueAfterFailure = false
        let app = launchForVerify(["-dockTimeScale", "8", "-dockReduce", "YES", "-nowPlayingFullBleed", "NO"])
        try playASong(app)
        mini(app).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        let opening = sampleFlight(app, label: "reduced-open", until: "presented=1 fraction=1.000")
        XCTAssertTrue(opening.contains { $0.fraction > 0.02 && $0.fraction < 0.98 }, "the player did not slide: \(opening.map(\.raw))")
        XCTAssertNotNil(opening.last?.art, "no art at rest: \(probe(app))")
        for sample in opening {
            XCTAssertFalse(sample.covered, "the mini cover stood aside under Reduce animation: \(sample.raw)")
            XCTAssertEqual(sample.t, 1, accuracy: 0.001, "the artwork was docking under Reduce animation: \(sample.raw)")
            if let art = sample.art, let place = sample.open {
                XCTAssertEqual(art[2], place[2], accuracy: 2, "the artwork was resized under Reduce animation: \(sample.raw)")
            }
        }
        app.buttons["nowPlaying.close"].firstMatch.tap()
        let closing = sampleFlight(app, label: "reduced-close", until: "presented=0")
        XCTAssertTrue(closing.last?.raw.contains("presented=0") == true, "the handle did not close the player: \(closing.last?.raw ?? "")")
        XCTAssertTrue(closing.contains { $0.fraction > 0.02 && $0.fraction < 0.98 }, "the player did not slide shut: \(closing.map(\.raw))")
        for sample in closing {
            XCTAssertFalse(sample.covered, "the mini cover stood aside under Reduce animation: \(sample.raw)")
            XCTAssertEqual(sample.t, 1, accuracy: 0.001, "the artwork was docking under Reduce animation: \(sample.raw)")
        }
    }

    // MARK: Flights

    /// Opens from the mini player and closes by the handle, sampling the probe and the screen along
    /// the way, and returns the artwork's place at rest.
    @discardableResult
    private func assertFlightsOnOpenAndClose(_ app: XCUIApplication, label: String) throws -> [Double] {
        let closed = DockSample(probe(app))
        XCTAssertFalse(closed.covered, "the mini cover was hidden with the player down: \(closed.raw)")
        mini(app).coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        let opening = sampleFlight(app, label: "\(label)-open", until: "presented=1 t=1.000")
        let landing = try XCTUnwrap(opening.last?.art, "no art at rest: \(probe(app))")
        XCTAssertTrue(opening.last?.covered == true, "the mini cover was visible under the open player: \(opening.last?.raw ?? "")")
        try assertSamplesLieBetweenTheCoverAndTheLanding(opening)

        app.buttons["nowPlaying.close"].firstMatch.tap()
        let closing = sampleFlight(app, label: "\(label)-close", until: "presented=0")
        try assertSamplesLieBetweenTheCoverAndTheLanding(closing)
        XCTAssertFalse(DockSample(probe(app)).covered, "the mini cover stayed hidden after the player docked: \(probe(app))")
        return landing
    }

    private func assertSamplesLieBetweenTheCoverAndTheLanding(_ samples: [DockSample]) throws {
        let flying = samples.filter { $0.t > 0.04 && $0.t < 0.96 }
        print("DOCKSAMPLES", samples.map(\.raw).joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(flying.count, 1, "no frame between the cover and open was sampled: \(samples.map(\.raw))")
        for sample in flying {
            XCTAssertTrue(sample.covered, "the mini cover was visible mid-flight: \(sample.raw)")
            let mini = try XCTUnwrap(sample.mini, "no mini rect: \(sample.raw)")
            let art = try XCTUnwrap(sample.art, "no artwork rect mid-flight: \(sample.raw)")
            let landing = try XCTUnwrap(sample.open, "no open rect mid-flight: \(sample.raw)")
            // The place it was given moves while the cover's safe area arrives; the curve is to that place.
            // y(t) = mini.y - tÂ² (mini.y - landing.y); the probe's t and its rect are a frame apart.
            let t = sample.t
            let x = mini[0] + t * (landing[0] - mini[0])
            let width = mini[2] + t * (landing[2] - mini[2])
            let y = mini[1] - t * t * (mini[1] - landing[1])
            let shown = try XCTUnwrap(sample.shown, "no drawn frame: \(sample.raw)")
            XCTAssertEqual(shown[1] + shown[3] / 2, art[1] + art[3] / 2, accuracy: 6, "the artwork is drawn \(shown) where the dock placed it \(art): \(sample.raw)")
            XCTAssertEqual(art[2], width, accuracy: 12, "the artwork's size left the way from the cover \(mini) to its place \(landing): \(sample.raw)")
            XCTAssertEqual(art[0], x, accuracy: 8, "the artwork left its x on the way from the cover \(mini) to its place \(landing): \(sample.raw)")
            XCTAssertEqual(art[1], y, accuracy: 14, "the artwork left its y on the way from the cover \(mini) to its place \(landing): \(sample.raw)")
        }
    }

    /// Reads the probe and captures the screen until `end` shows up in the probe (or about 20 s).
    private func sampleFlight(_ app: XCUIApplication, label: String, until end: String) -> [DockSample] {
        var samples: [DockSample] = []
        for step in 0..<40 {
            let sample = DockSample(probe(app))
            samples.append(sample)
            capture(app, "\(label)-\(step)")
            if end.split(separator: " ").allSatisfy({ sample.raw.contains($0) }) { break }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return samples
    }

    // MARK: Helpers

    private func mini(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "miniPlayer").firstMatch
    }

    private func screen(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "screen.nowPlaying").firstMatch
    }

    private func probe(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any).matching(identifier: "dock.probe").firstMatch
        return element.exists ? (element.value as? String ?? "") : ""
    }

    private func waitForProbe(_ app: XCUIApplication, _ needle: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = probe(app)
            if needle.split(separator: " ").allSatisfy({ value.contains($0) }) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// A probe value such as `t=0.430 mini=28,700,40,40 art=30,120,330,330 covered=1 presented=1 â€¦`.
    private struct DockSample {
        let raw: String
        init(_ raw: String) { self.raw = raw }
        var t: Double { token("t").flatMap(Double.init) ?? -1 }
        var fraction: Double { token("fraction").flatMap(Double.init) ?? -1 }
        var covered: Bool { token("covered") == "1" }
        var mini: [Double]? { rect("mini") }
        var art: [Double]? { rect("art") }
        var open: [Double]? { rect("open") }
        var shown: [Double]? { rect("shown") }

        private func token(_ key: String) -> String? {
            raw.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }

        private func rect(_ key: String) -> [Double]? {
            let numbers = token(key)?.split(separator: ",").compactMap { Double($0) }
            return numbers?.count == 4 ? numbers : nil
        }
    }

    /// The number after `key=` in a probe value such as `t=0.430 mini=â€¦ presented=1 holds=12`.
    private func number(_ key: String, in value: String) -> Double? {
        value.split(separator: " ").first { $0.hasPrefix(key + "=") }.flatMap { Double($0.dropFirst(key.count + 1)) }
    }

    private func playASong(_ app: XCUIApplication) throws {
        let searchTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15), "no Search tab")
        searchTab.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "search.field is missing")
        field.typeText("daft punk\n")
        let row = app.descendants(matching: .any).matching(identifier: "songRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no song row 30 s after searching")
        row.tap()
        XCTAssertTrue(mini(app).waitForExistence(timeout: 30), "the mini player never appeared")
        let reported = NSPredicate { _, _ in
            let value = self.probe(app)
            return value.contains("mini=") && !value.contains("mini=none")
        }
        wait(for: [XCTNSPredicateExpectation(predicate: reported, object: nil)], timeout: 10)
        XCTAssertFalse(probe(app).contains("mini=none"), "the mini cover was never reported: \(probe(app))")
    }
}

/// Screenshots taken from a second thread while the finger is held, since a held press blocks the
/// test's own.
private final class ShotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var shots: [XCUIScreenshot] = []
    private var stopped = false

    func sample(everyMilliseconds interval: Int, after delay: Int, upTo count: Int) {
        DispatchQueue.global().async { [self] in
            Thread.sleep(forTimeInterval: Double(delay) / 1000)
            while !isStopped, taken < count {
                let shot = XCUIScreen.main.screenshot()
                lock.lock(); shots.append(shot); lock.unlock()
                Thread.sleep(forTimeInterval: Double(interval) / 1000)
            }
        }
    }

    func stop() -> [XCUIScreenshot] {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        return shots
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private var taken: Int { lock.lock(); defer { lock.unlock() }; return shots.count }
}
