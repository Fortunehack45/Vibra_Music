import AVFoundation
import XCTest
@testable import AudioDSP

/// The chain behind a real `MTAudioProcessingTap`, the way Playback attaches
/// it: an `AVAudioMix` input parameter on the item's audio track. Run through
/// `AVAssetReaderAudioMixOutput`, which drives taps the same way `AVPlayer`
/// does but offline, so no audio device or simulator is needed.
final class AudioProcessingTapTests: XCTestCase {

    private let sampleRate = 44_100.0
    private var fileURL: URL!

    override func setUpWithError() throws {
        // 1.5 s of tone, 3 s of silence, 1 s of tone.
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioDSP-tap-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * 5.5)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let seconds = Double(frame) / sampleRate
            let audible = seconds < 1.5 || seconds >= 4.5
            let value = audible ? Float(0.5 * sin(2 * .pi * 1_000 * seconds)) : 0
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        try file.write(from: buffer)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testTheTapRunsTheChainOverTheItemsAudio() async throws {
        let chain = DSPChain()
        chain.apply(AudioDSPSettings(equalizer: EqualizerSettings(isEnabled: true, mode: .manual, balance: -1),
                                     loudnessNormalization: false, skipSilence: true))

        let (left, right) = try await read(through: chain)

        XCTAssertEqual(left.count, Int(sampleRate * 5.5), accuracy: 2_048)
        let leftLevel = DSPTestSignals.rms(of: left, channel: 0, channelCount: 1, from: 11_025, to: 55_125)
        let rightLevel = DSPTestSignals.rms(of: right, channel: 0, channelCount: 1, from: 11_025, to: 55_125)
        XCTAssertEqual(leftLevel, 0.5 / 2.0.squareRoot(), accuracy: 0.01, "hard-left balance keeps the left channel")
        XCTAssertEqual(rightLevel, 0, accuracy: 1e-6, "and mutes the right one")

        // The silence detector saw the item's own timeline through the tap.
        let spans = chain.silenceDetector.drainEvents().filter { $0.kind == .ended }.map(\.span)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.startTime ?? 0, 1.5, accuracy: 0.01)
        XCTAssertEqual(spans.first?.endTime ?? 0, 4.5, accuracy: 0.01)
        XCTAssertEqual(spans.first?.skippedDuration ?? 0, 3 - 1.4, accuracy: 0.01)
    }

    func testAnIdleChainLeavesTheAudioBitExact() async throws {
        let chain = DSPChain()
        chain.apply(AudioDSPSettings(loudnessNormalization: false))
        let (processed, _) = try await read(through: chain)
        let (untouched, _) = try await read(through: nil)
        // Not XCTAssertEqual: on a mismatch it prints the first few hundred samples of one array,
        // which is all zeros and says nothing. CI saw this fail about 1 run in 20 and pass on retry.
        if processed != untouched {
            let shared = min(processed.count, untouched.count)
            let differing = (0..<shared).filter { processed[$0] != untouched[$0] }
            let first = differing.first
            XCTFail("\(processed.count) samples through the tap against \(untouched.count) without; \(differing.count) differ, first at \(first.map(String.init) ?? "none") (\(first.map { "\(processed[$0]) against \(untouched[$0])" } ?? "-")), last at \(differing.last.map(String.init) ?? "none")")
        }
    }

    func testTheTapKeepsTheChainAliveAndReleasesItAfterwards() async throws {
        weak var released: DSPChain?
        do {
            let chain = DSPChain()
            released = chain
            _ = try await read(through: chain)
        }
        // AVFoundation tears its processing graph down on its own schedule.
        var waited = 0
        while released != nil && waited < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        XCTAssertNil(released, "the tap's retain is balanced when the tap goes away")
    }

    // ---- Harness ------------------------------------------------------------------

    /// Reads the file as de-interleaved Float32 through an audio mix carrying
    /// [chain]'s tap (or no tap at all).
    private func read(through chain: DSPChain?) async throws -> ([Float], [Float]) {
        let asset = AVURLAsset(url: fileURL)
        let track = try await asset.loadTracks(withMediaType: .audio).first!
        return try autoreleasepool { try read(asset: asset, track: track, through: chain) }
    }

    private func read(asset: AVURLAsset, track: AVAssetTrack, through chain: DSPChain?) throws -> ([Float], [Float]) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ])
        if let chain {
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = try chain.makeAudioProcessingTap()
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            output.audioMix = mix
        }
        reader.add(output)
        XCTAssertTrue(reader.startReading())

        var left: [Float] = []
        var right: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
            bytes.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                for frame in 0..<(floats.count / 2) {
                    left.append(floats[frame * 2])
                    right.append(floats[frame * 2 + 1])
                }
            }
        }
        XCTAssertEqual(reader.status, .completed, reader.error.map(String.init(describing:)) ?? "")
        return (left, right)
    }
}
