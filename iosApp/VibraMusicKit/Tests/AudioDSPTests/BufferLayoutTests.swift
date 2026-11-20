import CoreAudio
import XCTest
@testable import AudioDSP

/// The chain on the buffer layouts a processing tap hands over: one buffer per
/// channel (non-interleaved) or one interleaved buffer.
final class BufferLayoutTests: XCTestCase {

    private let sampleRate = 44_100.0

    /// With every stage running, non-interleaved processing is bit-identical to interleaved.
    func testNonInterleavedAndInterleavedGiveIdenticalResults() {
        let frames = 3_000
        var left = (0..<frames).map { Float(0.6 * sin(2 * .pi * 220 * Double($0) / sampleRate)) }
        var right = (0..<frames).map { Float(0.3 * sin(2 * .pi * 3_300 * Double($0) / sampleRate)) }
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            interleaved[frame * 2] = left[frame]
            interleaved[frame * 2 + 1] = right[frame]
        }

        let first = busyChain()
        let second = busyChain()
        interleaved.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            for count in [512, 7, 1_024, 1_457] {
                first.process(interleaved: buffer.baseAddress! + offset * 2, frameCount: count, channelCount: 2)
                offset += count
            }
        }
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(list.unsafeMutablePointer) }
                var offset = 0
                for count in [512, 7, 1_024, 1_457] {
                    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4),
                                          mData: UnsafeMutableRawPointer(leftBuffer.baseAddress! + offset))
                    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4),
                                          mData: UnsafeMutableRawPointer(rightBuffer.baseAddress! + offset))
                    XCTAssertTrue(second.process(bufferList: list.unsafeMutablePointer, frameCount: count))
                    offset += count
                }
            }
        }
        for frame in 0..<frames {
            XCTAssertEqual(left[frame], interleaved[frame * 2], "left, frame \(frame)")
            XCTAssertEqual(right[frame], interleaved[frame * 2 + 1], "right, frame \(frame)")
        }
        XCTAssertNotEqual(left[2_000], Float(0.6 * sin(2 * .pi * 220 * 2_000 / sampleRate)), "the chain did something")
    }

    func testASingleInterleavedBufferListIsUnderstood() {
        var samples = DSPTestSignals.stereoSine(hz: 500, amplitude: 0.5, frames: 256, sampleRate: sampleRate)
        let expected = DSPTestSignals.run(busyChain(), samples, sampleRate: sampleRate, configure: false)
        let chain = busyChain()
        samples.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(buffer.count * 4),
                                                             mData: UnsafeMutableRawPointer(buffer.baseAddress!)))
            XCTAssertTrue(chain.process(bufferList: &list, frameCount: 256))
        }
        XCTAssertEqual(samples, expected)
    }

    /// Layouts the processors can't address are refused, and the audio left alone.
    func testUnsupportedLayoutsAreLeftUntouched() {
        var data = [Float](repeating: 0.5, count: 1_024)
        data.withUnsafeMutableBufferPointer { buffer in
            let list = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(list.unsafeMutablePointer) }
            // Mixed widths: one stereo buffer and one mono.
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 2_048, mData: UnsafeMutableRawPointer(buffer.baseAddress!))
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 1_024, mData: UnsafeMutableRawPointer(buffer.baseAddress! + 512))
            XCTAssertNil(DSPChannels(bufferList: list.unsafeMutablePointer, frameCount: 128))
            XCTAssertFalse(busyChain().process(bufferList: list.unsafeMutablePointer, frameCount: 128))

            // Too short for the frame count asked for.
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 256, mData: UnsafeMutableRawPointer(buffer.baseAddress!))
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 256, mData: UnsafeMutableRawPointer(buffer.baseAddress! + 512))
            XCTAssertNil(DSPChannels(bufferList: list.unsafeMutablePointer, frameCount: 128))

            // No data at all: the second buffer is whole, so only the missing pointer can refuse it.
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 512, mData: UnsafeMutableRawPointer(buffer.baseAddress! + 512))
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 512, mData: UnsafeMutableRawPointer(buffer.baseAddress!))
            XCTAssertNotNil(DSPChannels(bufferList: list.unsafeMutablePointer, frameCount: 128), "the same pair with its data is understood")
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 512, mData: nil)
            XCTAssertNil(DSPChannels(bufferList: list.unsafeMutablePointer, frameCount: 128))
        }
        XCTAssertEqual(data, [Float](repeating: 0.5, count: 1_024))
    }

    /// A buffer whose channel count isn't what the chain was configured for is
    /// passed through rather than mis-addressed.
    func testAChannelCountMismatchPassesThrough() {
        let chain = busyChain() // configured for stereo
        var mono = (0..<512).map { Float($0) / 512 }
        let before = mono
        mono.withUnsafeMutableBufferPointer { buffer in
            chain.process(interleaved: buffer.baseAddress!, frameCount: 512, channelCount: 1)
        }
        XCTAssertEqual(mono, before)
    }

    func testTheChainReportsItsConfiguredFormat() {
        let chain = DSPChain()
        XCTAssertNil(chain.configuredFormat)
        chain.configure(sampleRate: 48_000, channelCount: 2)
        XCTAssertEqual(chain.configuredFormat?.sampleRate, 48_000)
        XCTAssertEqual(chain.configuredFormat?.channelCount, 2)
        chain.reset()
        XCTAssertNil(chain.configuredFormat)
    }

    private func busyChain() -> DSPChain {
        let chain = DSPChain()
        chain.apply(AudioDSPSettings(equalizer: EqualizerSettings(isEnabled: true, mode: .manual, balance: 0.2,
                                                                  bandsDb: EqualizerPreset.electronic.bandsDb),
                                     spatialAudio: true, loudnessNormalization: true, skipSilence: true))
        chain.loudness.setTrackLoudness(-1.5)
        chain.transition.setCutoffs(lowPassHz: 9_000, highPassHz: 80)
        chain.configure(sampleRate: sampleRate, channelCount: 2)
        return chain
    }
}
