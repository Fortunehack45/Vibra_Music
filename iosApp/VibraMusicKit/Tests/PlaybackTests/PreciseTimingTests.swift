import AVFoundation
import XCTest
@testable import Playback

/// A raw FLAC plays from the top as opened, which is exact and quick. Anything landing mid-song
/// opens it precisely timed, or its clock stays off from the sound.
@MainActor
final class PreciseTimingTests: EngineTestCase {
    private func flac(_ seconds: Double, name: String) throws -> PlayableItem {
        let url = directory.appendingPathComponent("\(name).flac")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
        // In a scope: the file is finished when it closes.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(seconds * 44_100)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            for channel in 0..<2 {
                for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = 0.3 * Float(sin(Double(index) * 0.06)) }
            }
            try file.write(from: buffer)
        }
        return .file(url, id: name)
    }

    func testAPlayFromTheTopOpensItPlainly() async throws {
        let song = try flac(8, name: "precise-top")
        let h = harness(queue: [song])
        h.engine.load(song, playWhenReady: true)
        await waitUntil("playing", timeout: 10) { h.engine.isPlaying }
        let entry = try XCTUnwrap(h.engine.active.current)
        XCTAssertFalse(entry.isPreciselyTimed)

        // The top is exact as it stands: no reopening for it.
        h.engine.seek(to: 0)
        XCTAssertTrue(h.engine.active.current === entry)
    }

    func testAMidSongSeekReopensItOnce() async throws {
        let song = try flac(12, name: "precise-seek")
        let h = harness(queue: [song])
        h.engine.load(song, playWhenReady: true)
        await waitUntil("playing", timeout: 10) { h.engine.isPlaying }
        let plain = try XCTUnwrap(h.engine.active.current)

        h.engine.seek(to: 6)
        XCTAssertEqual(h.engine.position, 6, "where the listener asked, through the reopening")
        await waitUntil("reopened and playing", timeout: 10) {
            h.engine.active.current !== plain && h.engine.active.current?.isPreciselyTimed == true && h.engine.isPlaying
        }
        XCTAssertEqual(h.engine.position, 6, accuracy: 1)
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested], "the same song, not a new one")

        let precise = try XCTUnwrap(h.engine.active.current)
        h.engine.seek(to: 2)
        XCTAssertTrue(h.engine.active.current === precise, "the next seek just seeks")
    }

    func testASeekInAFileThatKnowsItsTimingDoesNotReopen() async throws {
        let song = try tone(8, name: "precise-caf")
        let h = harness(queue: [song])
        h.engine.load(song, playWhenReady: true)
        await waitUntil("playing", timeout: 10) { h.engine.isPlaying }
        let entry = try XCTUnwrap(h.engine.active.current)
        h.engine.seek(to: 4)
        XCTAssertTrue(h.engine.active.current === entry)
    }

    func testASwapOpensItsCopyPreciselyTimed() async throws {
        let current = try tone(20, name: "precise-swap-current")
        let better = try flac(20, name: "precise-swap-better")
        let h = harness(queue: [current])
        h.engine.load(current, playWhenReady: true)
        await waitUntil("playing", timeout: 10) { h.engine.isPlaying && h.engine.position > 0.5 }

        h.engine.replaceCurrent(with: better)

        await waitUntil("the copy is swapped in", timeout: 20) { h.engine.currentItem?.id == better.id }
        XCTAssertEqual(h.engine.active.current?.item.id, better.id)
        XCTAssertEqual(h.engine.active.current?.isPreciselyTimed, true)
    }
}
