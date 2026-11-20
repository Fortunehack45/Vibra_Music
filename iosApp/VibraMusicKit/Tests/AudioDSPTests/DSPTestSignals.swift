import Darwin
import XCTest
@testable import AudioDSP

/// Signal generation and measurement shared by the DSP tests.
enum DSPTestSignals {

    /// Interleaved stereo sine, the same value on both channels.
    static func stereoSine(hz: Double, amplitude: Float, frames: Int, sampleRate: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * Double.pi * hz * Double(frame) / sampleRate))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        return samples
    }

    /// Interleaved stereo tone built the way the Android tests build theirs:
    /// 16-bit integers (truncated toward zero), normalised by 1/32768.
    static func stereoTone16(hz: Double, amplitude: Double, frames: Int, sampleRate: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Int16(amplitude * sin(2 * Double.pi * hz * Double(frame) / sampleRate))
            samples[frame * 2] = Float(value) / 32768
            samples[frame * 2 + 1] = Float(value) / 32768
        }
        return samples
    }

    /// Amplitude of the [hz] component of one channel, by correlation over the
    /// frames from [settleFrames] on. Rejects noise and harmonics an RMS would count.
    static func amplitude(of samples: [Float], channel: Int, channelCount: Int, hz: Double,
                          sampleRate: Double, settleFrames: Int) -> Double {
        var real = 0.0
        var imaginary = 0.0
        var count = 0
        let frames = samples.count / channelCount
        for frame in settleFrames..<frames {
            let angle = 2 * Double.pi * hz * Double(frame) / sampleRate
            let value = Double(samples[frame * channelCount + channel])
            real += value * cos(angle)
            imaginary += value * sin(angle)
            count += 1
        }
        return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(count)
    }

    /// RMS of one channel over a frame range.
    static func rms(of samples: [Float], channel: Int, channelCount: Int, from start: Int = 0, to end: Int? = nil) -> Double {
        let frames = samples.count / channelCount
        let last = end ?? frames
        var sum = 0.0
        for frame in start..<last {
            let value = Double(samples[frame * channelCount + channel])
            sum += value * value
        }
        return (sum / Double(max(last - start, 1))).squareRoot()
    }

    static func decibels(_ ratio: Double) -> Double {
        20 * log10(ratio)
    }

    /// Configures, flushes, and pushes [input] through [processor] in chunks, the way a render loop would.
    static func run(_ processor: FloatAudioProcessor, _ input: [Float], channelCount: Int = 2,
                    sampleRate: Double, chunkFrames: Int = 4_096, configure: Bool = true) -> [Float] {
        if configure {
            processor.configure(sampleRate: sampleRate, channelCount: channelCount)
            processor.flush()
        }
        var output = input
        let frames = input.count / channelCount
        output.withUnsafeMutableBufferPointer { buffer in
            var frame = 0
            while frame < frames {
                let count = min(chunkFrames, frames - frame)
                processor.process(DSPChannels(interleaved: buffer.baseAddress! + frame * channelCount,
                                              channelCount: channelCount, frameCount: count))
                frame += count
            }
        }
        return output
    }

    /// Rounds to 16-bit and back, as Android's 16-bit processor output does.
    static func quantized16(_ samples: [Float]) -> [Int16] {
        samples.map(PCMBoundary.clamp16)
    }

    static func fillBlock(_ block: AudioBlock, with samples: [Float]) {
        precondition(samples.count <= block.capacityFrames * block.channelCount)
        for (index, value) in samples.enumerated() { block.samples[index] = value }
        block.reset(samples.count / block.channelCount)
    }

    static func contents(of block: AudioBlock) -> [Float] {
        Array(UnsafeBufferPointer(start: block.samples, count: block.sampleCount))
    }
}

/// Counts heap allocations made on the calling thread while [body] runs, through
/// libmalloc's `malloc_logger` hook. Nil when the hook isn't available.
///
/// The logger's state lives in raw memory rather than Swift statics: it runs
/// inside malloc, so it must not itself trigger exclusivity checks or allocate.
enum AllocationCounter {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// [0] allocations counted, [1] the watched thread (as a bit pattern), [2] re-entrancy guard.
    private static let state: UnsafeMutablePointer<UInt> = {
        let state = UnsafeMutablePointer<UInt>.allocate(capacity: 3)
        state.initialize(repeating: 0, count: 3)
        return state
    }()

    private static let logger: Logger = { type, _, _, _, _, _ in
        // Bit 1 marks an allocation (MALLOC_LOG_TYPE_ALLOCATE); frees are not counted.
        let state = AllocationCounter.state
        guard type & 2 != 0, state[2] == 0, state[1] != 0,
              UInt(bitPattern: pthread_self()) == state[1] else { return }
        state[2] = 1
        state[0] += 1
        state[2] = 0
    }

    static func allocations(during body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Optional<Logger>.self)
        guard slot.pointee == nil else { return nil }
        let state = self.state
        let installed = logger
        state[0] = 0
        state[1] = UInt(bitPattern: pthread_self())
        slot.pointee = installed
        body()
        slot.pointee = nil
        state[1] = 0
        return Int(state[0])
    }
}
