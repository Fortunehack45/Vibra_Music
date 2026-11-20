@testable import AudioDSP

/// A line-by-line port of Media3 1.11's `SilenceSkippingAudioProcessor`
/// (16-bit little-endian bytes, `ByteBuffer` positions and all), used only as a
/// reference to check that `SilenceDetector`'s frame-level model reaches the
/// same decisions. It counts output and skipped frames; it doesn't reproduce
/// the fades, which change levels but not lengths.
///
/// Media3 mixes frames and bytes in two places: it sizes the "maybe silence"
/// buffer by passing a frame count through a byte-alignment helper
/// (`onFlush`), and `calculateShortenedSilenceLength` subtracts that byte
/// length from a frame count. `Arithmetic.media3` keeps both lines verbatim —
/// what an Android phone really does. `Arithmetic.intended` converts both to
/// the units the names say, which is the model `SilenceDetector` implements
/// (see its doc comment for why).
final class Media3SilenceSkipperReference {
    enum Arithmetic {
        /// Media3 1.11 verbatim, unit mix-ups included.
        case media3
        /// Buffer and keep-limit measured in the frames Vibra Music's durations describe.
        case intended
    }

    private let arithmetic: Arithmetic
    private let silenceRetentionRatio: Float
    private let maxSilenceToKeepFrames: Int
    private let silenceThresholdLevel: Int16
    private let bytesPerFrame: Int

    private var maybeSilenceBuffer: [UInt8]
    private var maybeSilenceBufferStartIndex = 0
    private var maybeSilenceBufferContentsSize = 0
    private var shortening = false
    private var outputSilenceFramesSinceNoise = 0

    private(set) var skippedFrames = 0
    private(set) var outputBytes = 0

    init(configuration: SilenceSkipConfiguration, sampleRate: Int, channelCount: Int, arithmetic: Arithmetic) {
        let bufferBytes: Int
        switch arithmetic {
        case .media3:
            bufferBytes = Self.mediaThreeBufferBytes(minimumSilence: configuration.minimumSilenceDuration,
                                                     sampleRate: sampleRate, channelCount: channelCount)
        case .intended:
            bufferBytes = Self.intendedBufferBytes(minimumSilence: configuration.minimumSilenceDuration,
                                                   sampleRate: sampleRate, channelCount: channelCount)
        }
        self.arithmetic = arithmetic
        silenceRetentionRatio = configuration.silenceRetentionRatio
        maxSilenceToKeepFrames = SilenceDetector.frames(for: configuration.maxSilenceToKeepDuration, sampleRate: sampleRate)
        silenceThresholdLevel = configuration.silenceThresholdLevel
        bytesPerFrame = channelCount * 2
        maybeSilenceBuffer = [UInt8](repeating: 0, count: bufferBytes)
    }

    /// Media3's `onFlush` sizing: `alignToBytePerFrameBoundary(durationUsToFrames(min) / 2) * 2`,
    /// which feeds a frame count to a byte-alignment helper and uses the result as bytes.
    static func mediaThreeBufferBytes(minimumSilence: Double, sampleRate: Int, channelCount: Int) -> Int {
        let bytesPerFrame = channelCount * 2
        let frames = SilenceDetector.frames(for: minimumSilence, sampleRate: sampleRate)
        return (frames / 2 / bytesPerFrame) * bytesPerFrame * 2
    }

    /// The same buffer measured in frames, as Vibra Music's duration intends.
    static func intendedBufferBytes(minimumSilence: Double, sampleRate: Int, channelCount: Int) -> Int {
        let frames = SilenceDetector.frames(for: minimumSilence, sampleRate: sampleRate)
        return (frames / 2) * 2 * channelCount * 2
    }

    func queueInput(_ input: [UInt8]) {
        var position = 0
        while position < input.count {
            if shortening {
                shortenSilenceSilenceUntilNoise(input, &position)
            } else {
                processNoisy(input, &position)
            }
        }
    }

    func queueEndOfStream() {
        if maybeSilenceBufferContentsSize > 0 {
            outputShortenedSilenceBuffer(shouldTransitionToNoisyState: true)
            outputSilenceFramesSinceNoise = 0
        }
    }

    private func processNoisy(_ input: [UInt8], _ position: inout Int) {
        let windowLimit = min(input.count, position + maybeSilenceBuffer.count)
        let noiseLimit = findNoiseLimit(input, from: position, to: windowLimit)
        if noiseLimit == position {
            shortening = true
        } else {
            outputBytes += noiseLimit - position
            position = noiseLimit
        }
    }

    private func shortenSilenceSilenceUntilNoise(_ input: [UInt8], _ position: inout Int) {
        precondition(maybeSilenceBufferStartIndex < maybeSilenceBuffer.count)
        let limit = input.count
        let noisePosition = findNoisePosition(input, from: position, to: limit)
        let silenceInputSize = noisePosition - position

        let indexToWriteTo: Int
        let contiguousBufferRemaining: Int
        if maybeSilenceBufferStartIndex + maybeSilenceBufferContentsSize < maybeSilenceBuffer.count {
            contiguousBufferRemaining = maybeSilenceBuffer.count - (maybeSilenceBufferContentsSize + maybeSilenceBufferStartIndex)
            indexToWriteTo = maybeSilenceBufferStartIndex + maybeSilenceBufferContentsSize
        } else {
            let amountInUpperPartOfBuffer = maybeSilenceBuffer.count - maybeSilenceBufferStartIndex
            indexToWriteTo = maybeSilenceBufferContentsSize - amountInUpperPartOfBuffer
            contiguousBufferRemaining = maybeSilenceBufferStartIndex - indexToWriteTo
        }

        let noiseFound = noisePosition < limit
        let bytesOfInput = min(silenceInputSize, contiguousBufferRemaining)
        for offset in 0..<bytesOfInput {
            maybeSilenceBuffer[indexToWriteTo + offset] = input[position + offset]
        }
        position += bytesOfInput
        maybeSilenceBufferContentsSize += bytesOfInput
        precondition(maybeSilenceBufferContentsSize <= maybeSilenceBuffer.count)

        let shouldTransitionToNoisyState = noiseFound && silenceInputSize < contiguousBufferRemaining
        outputShortenedSilenceBuffer(shouldTransitionToNoisyState: shouldTransitionToNoisyState)
        if shouldTransitionToNoisyState {
            shortening = false
            outputSilenceFramesSinceNoise = 0
        }
    }

    private func outputShortenedSilenceBuffer(shouldTransitionToNoisyState: Bool) {
        let sizeBeforeOutput = maybeSilenceBufferContentsSize
        let half = maybeSilenceBuffer.count / 2
        guard maybeSilenceBufferContentsSize == maybeSilenceBuffer.count || shouldTransitionToNoisyState else { return }
        let bytesToOutput: Int
        let bytesConsumed: Int
        if outputSilenceFramesSinceNoise == 0 {
            if shouldTransitionToNoisyState {
                bytesToOutput = maybeSilenceBufferContentsSize // DO_NOT_CHANGE_VOLUME
                bytesConsumed = bytesToOutput
            } else {
                precondition(maybeSilenceBufferContentsSize >= half)
                bytesToOutput = half // FADE_OUT
                bytesConsumed = bytesToOutput
            }
        } else if shouldTransitionToNoisyState {
            let remaining = maybeSilenceBufferContentsSize - half // FADE_IN
            bytesConsumed = remaining + half
            bytesToOutput = half + calculateShortenedSilenceLength(remaining)
        } else {
            bytesConsumed = maybeSilenceBufferContentsSize - half // MUTE
            bytesToOutput = calculateShortenedSilenceLength(bytesConsumed)
        }
        precondition(bytesConsumed % bytesPerFrame == 0)
        precondition(sizeBeforeOutput >= bytesToOutput)
        outputBytes += bytesToOutput
        maybeSilenceBufferContentsSize -= bytesConsumed
        maybeSilenceBufferStartIndex = (maybeSilenceBufferStartIndex + bytesConsumed) % maybeSilenceBuffer.count
        outputSilenceFramesSinceNoise += bytesToOutput / bytesPerFrame
        skippedFrames += (bytesConsumed - bytesToOutput) / bytesPerFrame
    }

    private func calculateShortenedSilenceLength(_ silenceToShortenBytes: Int) -> Int {
        let bytesNeededToReachMax: Int
        switch arithmetic {
        case .media3:
            // Verbatim: a frame count minus a byte count, used as bytes.
            bytesNeededToReachMax = (maxSilenceToKeepFrames - outputSilenceFramesSinceNoise) - maybeSilenceBuffer.count / 2
        case .intended:
            bytesNeededToReachMax = (maxSilenceToKeepFrames - outputSilenceFramesSinceNoise) * bytesPerFrame -
                maybeSilenceBuffer.count / 2
        }
        precondition(bytesNeededToReachMax >= 0)
        let value = min(Float(silenceToShortenBytes) * silenceRetentionRatio + 0.5, Float(bytesNeededToReachMax))
        return (Int(value) / bytesPerFrame) * bytesPerFrame
    }

    private func findNoisePosition(_ buffer: [UInt8], from position: Int, to limit: Int) -> Int {
        var index = position + 1
        while index < limit {
            if isNoise(buffer[index], buffer[index - 1]) { return bytesPerFrame * (index / bytesPerFrame) }
            index += 2
        }
        return limit
    }

    private func findNoiseLimit(_ buffer: [UInt8], from position: Int, to limit: Int) -> Int {
        var index = limit - 1
        while index >= position {
            if isNoise(buffer[index], buffer[index - 1]) { return bytesPerFrame * (index / bytesPerFrame) + bytesPerFrame }
            index -= 2
        }
        return position
    }

    private func isNoise(_ mostSignificantByte: UInt8, _ leastSignificantByte: UInt8) -> Bool {
        let sample = Int16(bitPattern: UInt16(mostSignificantByte) << 8 | UInt16(leastSignificantByte))
        return abs(Int(sample)) > Int(silenceThresholdLevel)
    }
}
