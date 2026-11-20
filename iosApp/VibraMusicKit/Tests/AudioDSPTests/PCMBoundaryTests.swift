import XCTest
@testable import AudioDSP

/// The Float32 `AudioBlock` and the PCM conversion boundary. Ported from Android's `AudioBlockTest`.
final class PCMBoundaryTests: XCTestCase {

    func testPCM16RoundTripPreservesFullScaleZeroAndSmallValues() {
        let values: [Int16] = [.min, -32767, -1000, -1, 0, 1, 1000, 32766, .max]
        let input = Self.littleEndianBytes(values)
        let block = AudioBlock(channelCount: 1, capacityFrames: values.count)
        let decoded = input.withUnsafeBytes { PCMBoundary.decode($0, encoding: .pcm16Bit, into: block) }
        XCTAssertEqual(decoded, values.count)
        XCTAssertEqual(block.frameCount, values.count)

        XCTAssertEqual(block.samples[0], -1, accuracy: 0.00001)
        XCTAssertEqual(block.samples[4], 0, accuracy: 0.00001)
        XCTAssertEqual(block.samples[8], 32767 / 32768, accuracy: 0.00001)

        var output = [UInt8](repeating: 0, count: values.count * 2)
        let encoded = output.withUnsafeMutableBytes { PCMBoundary.encode(block, encoding: .pcm16Bit, into: $0) }
        XCTAssertEqual(encoded, values.count)
        XCTAssertEqual(Self.int16s(output), values)
    }

    func testPCM24PackedRoundTripPreservesFullScaleZeroAndSmallValues() {
        let values: [Int32] = [-8_388_608, -8_388_607, -100_000, -1, 0, 1, 100_000, 8_388_606, 8_388_607]
        var input: [UInt8] = []
        for value in values {
            input += [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
                      UInt8(truncatingIfNeeded: value >> 16)]
        }
        let block = AudioBlock(channelCount: 1, capacityFrames: values.count)
        let decoded = input.withUnsafeBytes { PCMBoundary.decode($0, encoding: .pcm24BitPacked, into: block) }
        XCTAssertEqual(decoded, values.count)

        XCTAssertEqual(block.samples[0], -1, accuracy: 0.0000001)
        XCTAssertEqual(block.samples[4], 0, accuracy: 0.0000001)
        XCTAssertEqual(block.samples[8], 8_388_607 / 8_388_608, accuracy: 0.0000001)

        var output = [UInt8](repeating: 0, count: values.count * 3)
        let encoded = output.withUnsafeMutableBytes { PCMBoundary.encode(block, encoding: .pcm24BitPacked, into: $0) }
        XCTAssertEqual(encoded, values.count)
        XCTAssertEqual(Self.int24s(output), values)
    }

    func testPCM32RoundTripPreservesFullScaleZeroAndSmallValues() {
        let values: [Int32] = [.min, -1_000_000, 0, 1_000_000, .max]
        var input: [UInt8] = []
        for value in values { withUnsafeBytes(of: value.littleEndian) { input += $0 } }
        let block = AudioBlock(channelCount: 1, capacityFrames: values.count)
        let decoded = input.withUnsafeBytes { PCMBoundary.decode($0, encoding: .pcm32Bit, into: block) }
        XCTAssertEqual(decoded, values.count)

        XCTAssertEqual(block.samples[0], -1, accuracy: 0.00001)
        XCTAssertEqual(block.samples[2], 0, accuracy: 0.00001)
        XCTAssertEqual(block.samples[4], 1, accuracy: 0.00001)

        var output = [UInt8](repeating: 0, count: values.count * 4)
        let encoded = output.withUnsafeMutableBytes { PCMBoundary.encode(block, encoding: .pcm32Bit, into: $0) }
        XCTAssertEqual(encoded, values.count)
        let decodedBack = stride(from: 0, to: output.count, by: 4).map { offset in
            output.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int32.self)) }
        }
        XCTAssertEqual(decodedBack, values)
    }

    func testPCMFloatRoundTripPreservesValues() {
        let values: [Float] = [-1, -0.75, -0.25, 0, 0.25, 0.75, 1]
        var input: [UInt8] = []
        for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { input += $0 } }
        let block = AudioBlock(channelCount: 1, capacityFrames: values.count)
        let decoded = input.withUnsafeBytes { PCMBoundary.decode($0, encoding: .pcmFloat, into: block) }
        XCTAssertEqual(decoded, values.count)
        XCTAssertEqual(DSPTestSignals.contents(of: block), values)

        var output = [UInt8](repeating: 0, count: values.count * 4)
        let encoded = output.withUnsafeMutableBytes { PCMBoundary.encode(block, encoding: .pcmFloat, into: $0) }
        XCTAssertEqual(encoded, values.count)
        XCTAssertEqual(Self.floats(output), values)
    }

    func testInterleavedStereoOrderingPreservesLeftAndRight() {
        let values: [Int16] = [1000, -1000, 2000, -2000, 3000, -3000, 4000, -4000]
        let block = AudioBlock(channelCount: 2, capacityFrames: 4)
        Self.littleEndianBytes(values).withUnsafeBytes { _ = PCMBoundary.decode($0, encoding: .pcm16Bit, into: block) }

        XCTAssertEqual(block.frameCount, 4)
        XCTAssertEqual(block.sampleCount, 8)
        for (index, value) in values.enumerated() {
            XCTAssertEqual(block.samples[index], Float(value) / 32768, accuracy: 0.00001)
        }

        var output = [UInt8](repeating: 0, count: 16)
        output.withUnsafeMutableBytes { _ = PCMBoundary.encode(block, encoding: .pcm16Bit, into: $0) }
        XCTAssertEqual(Self.int16s(output), values)
    }

    func testMultiFrameBufferHandlesLargeBlocksWithoutDistortion() {
        let frames = 1_024
        var values: [Int16] = []
        for frame in 0..<frames {
            values.append(Int16(frame % 30_000))
            values.append(Int16(-(frame % 30_000)))
        }
        let block = AudioBlock(channelCount: 2, capacityFrames: frames)
        let decoded = Self.littleEndianBytes(values).withUnsafeBytes { PCMBoundary.decode($0, encoding: .pcm16Bit, into: block) }
        XCTAssertEqual(decoded, frames)

        var output = [UInt8](repeating: 0, count: frames * 4)
        let encoded = output.withUnsafeMutableBytes { PCMBoundary.encode(block, encoding: .pcm16Bit, into: $0) }
        XCTAssertEqual(encoded, frames)
        XCTAssertEqual(Self.int16s(output), values)
    }

    func testIncompleteTrailingBytesAreLeftForTheNextRead() {
        // Stereo 16-bit: 4 bytes a frame, so 7 bytes hold one frame and 3 spare.
        let input: [UInt8] = Self.littleEndianBytes([100, 200]) + [0xAA, 0xBB, 0xCC]
        let block = AudioBlock(channelCount: 2, capacityFrames: 10)
        let decoded = input.withUnsafeBytes { PCMBoundary.decode($0, encoding: .pcm16Bit, into: block) }

        XCTAssertEqual(decoded, 1)
        XCTAssertEqual(block.frameCount, 1)
        let consumed = decoded * PCMEncoding.pcm16Bit.bytesPerFrame(channelCount: 2)
        XCTAssertEqual(Array(input[consumed...]), [0xAA, 0xBB, 0xCC])
    }

    func testFewerBytesThanOneFrameDecodesNothing() {
        let block = AudioBlock(channelCount: 2, capacityFrames: 10)
        block.reset(5)
        let decoded = [UInt8]([1, 2, 3]).withUnsafeBytes { PCMBoundary.decode($0, encoding: .pcm16Bit, into: block) }
        XCTAssertEqual(decoded, 0)
        XCTAssertEqual(block.frameCount, 0)
    }

    func testNaNAndInfinityAreSanitisedAndOutOfRangeValuesClamped() {
        let block = AudioBlock(channelCount: 1, capacityFrames: 6)
        DSPTestSignals.fillBlock(block, with: [.nan, .infinity, -.infinity, 2.5, -3, 0.5])

        var buffer16 = [UInt8](repeating: 0, count: 12)
        buffer16.withUnsafeMutableBytes { _ = PCMBoundary.encode(block, encoding: .pcm16Bit, into: $0) }
        XCTAssertEqual(Self.int16s(buffer16), [0, .max, .min, .max, .min, 16_384])

        var buffer24 = [UInt8](repeating: 0, count: 18)
        buffer24.withUnsafeMutableBytes { _ = PCMBoundary.encode(block, encoding: .pcm24BitPacked, into: $0) }
        XCTAssertEqual(Array(Self.int24s(buffer24).prefix(5)), [0, 8_388_607, -8_388_608, 8_388_607, -8_388_608])

        var bufferFloat = [UInt8](repeating: 0, count: 24)
        bufferFloat.withUnsafeMutableBytes { _ = PCMBoundary.encode(block, encoding: .pcmFloat, into: $0) }
        // Finite values keep their float headroom.
        XCTAssertEqual(Self.floats(bufferFloat), [0, 1, -1, 2.5, -3, 0.5])
    }

    func testAudioBlockCopyAndFrameSlicing() {
        let source = AudioBlock(channelCount: 2, capacityFrames: 10)
        DSPTestSignals.fillBlock(source, with: (0..<20).map(Float.init))

        let destination = AudioBlock(channelCount: 2, capacityFrames: 10)
        // Source frames 2...5 into destination frames 1...4.
        destination.copy(from: source, sourceStartFrame: 2, destStartFrame: 1, frames: 4)

        XCTAssertEqual(destination.frameCount, 5)
        XCTAssertEqual(destination.samples[0], 0)
        XCTAssertEqual(destination.samples[1], 0)
        XCTAssertEqual(destination.samples[2], 4)
        XCTAssertEqual(destination.samples[3], 5)
        XCTAssertEqual(destination.samples[4], 6)
        XCTAssertEqual(destination.samples[5], 7)
    }

    func testAudioBlockReusesItsPreallocatedMemory() {
        let block = AudioBlock(channelCount: 2, capacityFrames: 256)
        let storage = block.samples
        let decoded = [UInt8](repeating: 0, count: 64 * 4).withUnsafeBytes { PCMBoundary.decode($0, encoding: .pcm16Bit, into: block) }
        XCTAssertEqual(decoded, 64)
        XCTAssertEqual(block.frameCount, 64)
        XCTAssertEqual(block.samples, storage, "Storage must not be reallocated")
        block.reset(0)
        XCTAssertEqual(block.frameCount, 0)
        XCTAssertEqual(block.samples, storage, "Storage must survive a reset")
    }

    func testClearZeroesTheValidRegionAndEmptiesTheBlock() {
        let block = AudioBlock(channelCount: 2, capacityFrames: 4)
        DSPTestSignals.fillBlock(block, with: [1, 2, 3, 4, 5, 6, 7, 8])
        block.clear()
        XCTAssertEqual(block.frameCount, 0)
        block.reset(4)
        XCTAssertEqual(DSPTestSignals.contents(of: block), [Float](repeating: 0, count: 8))
    }

    func testEncodingSizes() {
        XCTAssertEqual(PCMEncoding.pcm16Bit.bytesPerFrame(channelCount: 2), 4)
        XCTAssertEqual(PCMEncoding.pcm24BitPacked.bytesPerFrame(channelCount: 2), 6)
        XCTAssertEqual(PCMEncoding.pcmFloat.totalBytes(frames: 10, channelCount: 2), 80)
        XCTAssertEqual(PCMEncoding.pcm24BitPacked.bitDepth, 24)
    }

    /// Kotlin's `Math.round`: ties toward +infinity, which Swift's `.rounded()` doesn't do.
    func testQuantisationRoundsHalvesUpLikeTheJVM() {
        XCTAssertEqual(PCMBoundary.clamp16(0.5 / 32768), 1)
        XCTAssertEqual(PCMBoundary.clamp16(-0.5 / 32768), 0)
        XCTAssertEqual(PCMBoundary.clamp16(-1.5 / 32768), -1)
        XCTAssertEqual(JavaRounding.round(Float(0.49999997)), 0)
        XCTAssertEqual(JavaRounding.round(-12.5), -12)
        XCTAssertEqual(JavaRounding.round(12.5), 13)
    }

    // ---- Helpers ----------------------------------------------------------------

    static func littleEndianBytes(_ values: [Int16]) -> [UInt8] {
        var bytes: [UInt8] = []
        for value in values { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        return bytes
    }

    static func int16s(_ bytes: [UInt8]) -> [Int16] {
        stride(from: 0, to: bytes.count, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
    }

    static func int24s(_ bytes: [UInt8]) -> [Int32] {
        stride(from: 0, to: bytes.count, by: 3).map {
            Int32(bytes[$0]) | Int32(bytes[$0 + 1]) << 8 | Int32(Int8(bitPattern: bytes[$0 + 2])) << 16
        }
    }

    static func floats(_ bytes: [UInt8]) -> [Float] {
        stride(from: 0, to: bytes.count, by: 4).map { offset in
            bytes.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
        }
    }
}
