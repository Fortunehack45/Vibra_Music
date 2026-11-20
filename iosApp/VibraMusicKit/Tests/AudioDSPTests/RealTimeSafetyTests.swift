import CoreAudio
import XCTest
@testable import AudioDSP

/// The render path's promise: no heap allocation while processing, even with
/// every stage busy, settings changing between blocks and events being raised.
/// Allocations are counted through libmalloc's logger hook on this thread.
final class RealTimeSafetyTests: XCTestCase {

    private let sampleRate = 48_000.0

    func testProcessingAllocatesNothing() throws {
        let chain = DSPChain()
        chain.apply(AudioDSPSettings(equalizer: EqualizerSettings(isEnabled: true, mode: .manual,
                                                                  bandsDb: EqualizerPreset.rock.bandsDb),
                                     spatialAudio: true, loudnessNormalization: true, skipSilence: true))
        chain.loudness.setTrackLoudness(-2)
        chain.transition.setCutoffs(lowPassHz: 5_000, highPassHz: 60)
        chain.configure(sampleRate: sampleRate, channelCount: 2)

        let frames = 512
        let tone = (0..<frames).map { Float(0.5 * sin(Double($0) * 0.07)) }
        var left = tone
        var right = tone
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }

        let settings: [EqualizerSettings] = EqualizerPreset.selectable.map {
            EqualizerSettings(isEnabled: true, mode: .manual, bandsDb: $0.bandsDb)
        }
        var allocations = 0
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                      mData: UnsafeMutableRawPointer(leftBuffer.baseAddress!))
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                      mData: UnsafeMutableRawPointer(rightBuffer.baseAddress!))
                let pointer = list.unsafeMutablePointer
                // Warm up once so lazily initialised statics are in place, as they
                // would be after the first render callback.
                chain.process(bufferList: pointer, frameCount: frames, sourceFramePosition: 0)
                for block in 1..<400 {
                    // Settings and input change on the control side, outside the counted region.
                    chain.equalizer.apply(settings[block % settings.count])
                    chain.transition.setCutoffs(lowPassHz: Float(2_000 + block * 10), highPassHz: 40)
                    // Stretches of sound and of silence long enough for the detector to report.
                    let loud = (block / 150) % 2 == 0
                    for frame in 0..<frames {
                        leftBuffer[frame] = loud ? tone[frame] : 0
                        rightBuffer[frame] = loud ? tone[frame] : 0
                    }
                    let counted = AllocationCounter.allocations {
                        chain.process(bufferList: pointer, frameCount: frames, sourceFramePosition: Int64(block * frames))
                        if block % 97 == 0 { chain.flush() }
                    }
                    guard let counted else { return }
                    allocations += counted
                }
            }
        }
        guard AllocationCounter.allocations(during: {}) != nil else {
            throw XCTSkip("libmalloc's logger hook is not available")
        }
        XCTAssertEqual(allocations, 0, "the render path must not allocate")
        XCTAssertFalse(chain.silenceDetector.drainEvents().isEmpty, "the detector raised events while being counted")
    }

    func testDecodingAndEncodingAllocateNothing() throws {
        let block = AudioBlock(channelCount: 2, capacityFrames: 1_024)
        var bytes = [UInt8](repeating: 0x40, count: 1_024 * 4)
        var output = [UInt8](repeating: 0, count: 1_024 * 6)
        var total = 0
        bytes.withUnsafeMutableBytes { input in
            output.withUnsafeMutableBytes { out in
                // The loop over encodings stays outside the counted region: iterating
                // an array is itself an allocation in an unoptimised build.
                for encoding in PCMEncoding.allCases {
                    let counted = AllocationCounter.allocations {
                        PCMBoundary.decode(UnsafeRawBufferPointer(input), encoding: encoding, into: block)
                        PCMBoundary.encode(block, encoding: encoding, into: out)
                    }
                    guard let counted else {
                        total = -1
                        return
                    }
                    total += counted
                }
            }
        }
        if total < 0 { throw XCTSkip("libmalloc's logger hook is not available") }
        XCTAssertEqual(total, 0)
    }

    /// Settings published from another thread while the audio thread renders:
    /// no crash, no torn curve (every output sample stays finite and bounded).
    func testSettingsChangesFromAnotherThreadAreSafe() {
        let chain = DSPChain()
        chain.configure(sampleRate: sampleRate, channelCount: 2)
        let done = expectation(description: "writer finished")
        let presets = EqualizerPreset.selectable
        DispatchQueue.global().async {
            for index in 0..<2_000 {
                chain.apply(AudioDSPSettings(equalizer: EqualizerSettings(isEnabled: index % 3 != 0, mode: .manual,
                                                                          balance: Float(index % 5) / 5 - 0.4,
                                                                          bandsDb: presets[index % presets.count].bandsDb),
                                             spatialAudio: index % 2 == 0, skipSilence: index % 7 == 0))
                chain.loudness.setTrackLoudness(Double(index % 12) - 6)
                chain.transition.setCutoffs(lowPassHz: Float(500 + index), highPassHz: Float(index % 300))
            }
            done.fulfill()
        }
        var samples = DSPTestSignals.stereoSine(hz: 440, amplitude: 0.8, frames: 256, sampleRate: sampleRate)
        for _ in 0..<2_000 {
            samples.withUnsafeMutableBufferPointer { buffer in
                chain.process(interleaved: buffer.baseAddress!, frameCount: 256, channelCount: 2)
            }
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) < 8 })
            samples = DSPTestSignals.stereoSine(hz: 440, amplitude: 0.8, frames: 256, sampleRate: sampleRate)
        }
        wait(for: [done], timeout: 30)
    }
}
