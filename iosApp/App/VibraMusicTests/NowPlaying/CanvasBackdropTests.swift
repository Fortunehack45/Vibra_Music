import AVFoundation
import VibraMusicCore
import SwiftUI
import Theming
import XCTest
@testable import VibraMusic

/// The Canvas handoff on the player: the still art holds until the clip has a frame on screen, and
/// the backdrop follows the clip's colours without ever passing through black.
@MainActor
final class CanvasBackdropTests: XCTestCase {
    private func solid(_ argb: UInt32, width: Int = 64, height: Int = 64) -> ArtworkPixels {
        ArtworkPixels(width: width, height: height, argb: [UInt32](repeating: argb, count: width * height))
    }

    private func mesh(_ argb: UInt32) -> ArtworkMesh {
        ArtworkMesh(pixels: solid(argb, width: 12, height: 12), seed: 0)!
    }

    // MARK: Black frames

    func testABlackClipFrameKeepsTheLastMesh() async throws {
        let cache = ArtworkPaletteCache(loader: SolidColourArtworkLoader(colours: ["red": 0xFFC0_2020]), retryDelay: 0)
        let model = NowPlayingModel(palettes: cache)
        await model.mesh.load(URL(string: "https://art.test/red")!, trackID: "song", artPixels: ArtworkSize.player)
        let still = try XCTUnwrap(model.mesh.mesh)

        await model.mesh.receiveCanvasFrame(solid(0xFF00_0000))
        await model.mesh.receiveCanvasFrame(solid(0xFF0A_0A0A))
        XCTAssertEqual(model.mesh.mesh, still, "a black or near-black read must leave the last mesh up")

        await model.mesh.receiveCanvasFrame(solid(0xFFE0_8020))
        XCTAssertNotEqual(model.mesh.mesh, still, "a real frame takes over")
    }

    func testTheBackdropIgnoresAMissingMeshRatherThanBlanking() {
        var fade = PlayerMeshFade()
        fade.receive(mesh(0xFFC0_2020), at: 0, reduceMotion: false)
        fade.receive(nil, at: 1, reduceMotion: false)
        XCTAssertEqual(fade.layers(at: 1).map(\.mesh), [mesh(0xFFC0_2020)])
        XCTAssertEqual(fade.layers(at: 1).map(\.opacity), [1])
    }

    // MARK: When frames are read

    func testTheFirstFrameIsReadTheMomentTheClipIsDisplayed() {
        var schedule = CanvasFrameReadSchedule()
        XCTAssertEqual(schedule.playingChanged(true), .none, "nothing is read before the clip has a frame on screen")
        XCTAssertEqual(schedule.displayChanged(true), .now, "no refresh-interval wait for the first read")
        XCTAssertEqual(schedule.readFinished(valid: true), .after(ArtworkMeshBackdropStyle.canvasRefreshInterval))
        XCTAssertEqual(schedule.readFinished(valid: true), .after(3))
    }

    func testARejectedFirstReadIsRetriedSoonThenFallsBackToTheInterval() {
        var schedule = CanvasFrameReadSchedule()
        _ = schedule.playingChanged(true)
        XCTAssertEqual(schedule.displayChanged(true), .now)
        for _ in 1..<CanvasFrameReadSchedule.firstFrameAttempts {
            XCTAssertEqual(schedule.readFinished(valid: false), .after(CanvasFrameReadSchedule.firstFrameRetry))
        }
        XCTAssertEqual(schedule.readFinished(valid: false), .after(3))
        // Once a good frame is in, a bad one just waits for the next regular read.
        XCTAssertEqual(schedule.readFinished(valid: true), .after(3))
        XCTAssertEqual(schedule.readFinished(valid: false), .after(3))
    }

    func testPausingStopsTheReads() {
        var schedule = CanvasFrameReadSchedule()
        _ = schedule.playingChanged(true)
        _ = schedule.displayChanged(true)
        _ = schedule.readFinished(valid: true)
        XCTAssertEqual(schedule.playingChanged(false), .none)
        XCTAssertEqual(schedule.readFinished(valid: true), .none, "a paused clip's frame isn't changing")
        XCTAssertEqual(schedule.playingChanged(true), .after(3))
        XCTAssertEqual(schedule.displayChanged(false), .none)
        XCTAssertEqual(schedule.readFinished(valid: true), .none, "nothing is read once the clip is gone")
    }

    // MARK: Crossfade

    func testTheCrossfadeKeepsTheOldMeshOpaqueUnderTheNewOne() {
        let red = mesh(0xFFC0_2020), blue = mesh(0xFF20_40C0)
        var fade = PlayerMeshFade()
        fade.receive(red, at: 0, reduceMotion: false)
        XCTAssertEqual(fade.layers(at: 0).map(\.opacity), [1], "the first mesh is shown at once")
        fade.receive(blue, at: 10, reduceMotion: false)
        let mid = fade.layers(at: 10.3)
        XCTAssertEqual(mid.map(\.mesh), [red, blue])
        XCTAssertEqual(mid[0].opacity, 1, "the outgoing mesh stays fully drawn: the floor never shows")
        XCTAssertEqual(mid[1].opacity, ThemingMotion.fastOutSlowIn(0.3 / 0.9), accuracy: 1e-9)
        XCTAssertEqual(fade.layers(at: 10.9).last?.opacity ?? 0, 1, accuracy: 1e-9)
        fade.settle(at: 10.9)
        XCTAssertEqual(fade.layers(at: 11).map(\.mesh), [blue])
    }

    func testAChangeMidFadeStartsFromWhatIsOnScreen() {
        let red = mesh(0xFFC0_2020), blue = mesh(0xFF20_40C0), green = mesh(0xFF20_C040)
        var fade = PlayerMeshFade()
        fade.receive(red, at: 0, reduceMotion: false)
        fade.receive(blue, at: 10, reduceMotion: false)
        let before = fade.layers(at: 10.4)
        fade.receive(green, at: 10.4, reduceMotion: false)
        let after = fade.layers(at: 10.4)
        XCTAssertEqual(Array(after.dropLast()).map(\.mesh), before.map(\.mesh))
        XCTAssertEqual(Array(after.dropLast()).map(\.opacity), before.map(\.opacity), "the half-faded mesh is frozen where it stood, not jumped to opaque")
        XCTAssertEqual(after.last?.mesh, green)
        XCTAssertEqual(after.last?.opacity, 0)
        fade.settle(at: 11.3)
        XCTAssertEqual(fade.layers(at: 11.3).map(\.mesh), [green])
    }

    func testABurstOfChangesStaysBounded() {
        var fade = PlayerMeshFade()
        for step in 0..<20 {
            fade.receive(mesh(0xFF00_0000 | UInt32(step * 10) << 16 | 0x40), at: Double(step) * 0.1, reduceMotion: false)
        }
        let layers = fade.layers(at: 2)
        XCTAssertLessThanOrEqual(layers.count, PlayerMeshFade.maxLayers + 1)
        XCTAssertEqual(layers.first?.opacity, 1, "the bottom layer is always opaque")
    }

    func testReducedMotionCuts() {
        var fade = PlayerMeshFade()
        fade.receive(mesh(0xFFC0_2020), at: 0, reduceMotion: true)
        fade.receive(mesh(0xFF20_40C0), at: 1, reduceMotion: true)
        XCTAssertEqual(fade.layers(at: 1).map(\.mesh), [mesh(0xFF20_40C0)])
    }

    func testATrackChangeFadesTheNewCoverInWithoutBlack() async throws {
        let cache = ArtworkPaletteCache(
            loader: SolidColourArtworkLoader(colours: ["red": 0xFFC0_2020, "blue": 0xFF20_40C0]),
            retryDelay: 0
        )
        let model = NowPlayingModel(palettes: cache)
        var fade = PlayerMeshFade()
        await model.mesh.load(URL(string: "https://art.test/red")!, trackID: "one", artPixels: ArtworkSize.player)
        let red = try XCTUnwrap(model.mesh.mesh)
        fade.receive(red, at: 0, reduceMotion: false)

        // The new track drops the carried mesh (nil) for the beat its cover takes to read.
        fade.receive(nil, at: 1, reduceMotion: false)
        XCTAssertEqual(fade.layers(at: 1).map(\.mesh), [red])
        await model.mesh.load(URL(string: "https://art.test/blue")!, trackID: "two", artPixels: ArtworkSize.player)
        let blue = try XCTUnwrap(model.mesh.mesh)
        fade.receive(blue, at: 2, reduceMotion: false)
        XCTAssertEqual(fade.layers(at: 2.2).map(\.mesh), [red, blue])
        XCTAssertEqual(fade.layers(at: 2.2).first?.opacity, 1)
    }

    // MARK: Still art until the clip is ready

    func testAClipThatNeverDisplaysLeavesTheStillArt() async throws {
        let view = PlayerCanvasUIView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        var rendered: [Bool] = []
        var frames = 0
        view.onRendered = { rendered.append($0) }
        view.onFrame = { _ in frames += 1 }
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-clip-\(UUID()).mp4")
        view.mount(missing, fallback: nil)
        view.setPlaying(true)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(rendered.contains(true), "no frame, no reveal: the still art stays up")
        XCTAssertEqual(frames, 0, "nothing is read off a clip that never displayed")
        view.tearDown()
    }
}
