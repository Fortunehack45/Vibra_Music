/// Zero-allocation conversion between raw little-endian PCM bytes and `AudioBlock` Float32.
///
/// Normalisation:
/// - 16-bit: × 1/32768 (-1.0 ... +0.9999695)
/// - 24-bit: × 1/8388608 (-1.0 ... +0.99999988)
/// - 32-bit integer: × 1/2147483648 (-1.0 ... +1.0)
/// - Float32: passed through, with NaN and ±infinity sanitised
///
/// The scales are powers of two, so an integer sample survives a decode and an
/// encode unchanged — the property that lets an idle DSP chain be bit-exact.
///
/// Loops are `while` loops so that even an unoptimised build allocates nothing here.
public enum PCMBoundary {

    /// Decodes whole frames from [input] into [destination].
    ///
    /// A trailing partial frame is left alone: the number of bytes consumed is
    /// the returned frame count × `encoding.bytesPerFrame(channelCount:)`, so a
    /// streaming caller can carry the remainder into its next read — the same
    /// contract Android's version kept by leaving the `ByteBuffer` position there.
    ///
    /// - Returns: frames decoded, also written to `destination.frameCount`.
    @discardableResult
    public static func decode(_ input: UnsafeRawBufferPointer,
                              encoding: PCMEncoding,
                              into destination: AudioBlock,
                              maxFrames: Int? = nil) -> Int {
        let channelCount = destination.channelCount
        let bytesPerFrame = encoding.bytesPerFrame(channelCount: channelCount)
        let availableFrames = input.count / bytesPerFrame
        let framesToRead = min(availableFrames, maxFrames ?? destination.capacityFrames, destination.capacityFrames)
        guard framesToRead > 0, let bytes = input.baseAddress else {
            destination.reset(0)
            return 0
        }

        let totalSamples = framesToRead * channelCount
        let out = destination.samples
        switch encoding {
        case .pcm16Bit:
            let scale: Float = 1.0 / 32768.0
            var index = 0
            while index < totalSamples {
                let raw = bytes.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)
                out[index] = Float(Int16(bitPattern: UInt16(littleEndian: raw))) * scale
                index += 1
            }
        case .pcm24BitPacked:
            let scale: Float = 1.0 / 8388608.0
            var index = 0
            while index < totalSamples {
                let offset = index * 3
                let b0 = Int32(bytes.load(fromByteOffset: offset, as: UInt8.self))
                let b1 = Int32(bytes.load(fromByteOffset: offset + 1, as: UInt8.self))
                let b2 = Int32(bytes.load(fromByteOffset: offset + 2, as: Int8.self)) // sign-extended
                out[index] = Float((b2 << 16) | (b1 << 8) | b0) * scale
                index += 1
            }
        case .pcm32Bit:
            let scale = 1.0 / 2147483648.0
            var index = 0
            while index < totalSamples {
                let raw = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                out[index] = Float(Double(Int32(bitPattern: UInt32(littleEndian: raw))) * scale)
                index += 1
            }
        case .pcmFloat:
            var index = 0
            while index < totalSamples {
                let raw = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                out[index] = sanitize(Float(bitPattern: UInt32(littleEndian: raw)))
                index += 1
            }
        }
        destination.reset(framesToRead)
        return framesToRead
    }

    /// Encodes frames of [source] into [output] in [encoding], clamping so an
    /// out-of-range float can never wrap an integer sample.
    ///
    /// - Returns: whole frames written; bytes written is that × bytes per frame.
    @discardableResult
    public static func encode(_ source: AudioBlock,
                              encoding: PCMEncoding,
                              into output: UnsafeMutableRawBufferPointer,
                              startFrame: Int = 0,
                              framesToEncode: Int? = nil) -> Int {
        let channelCount = source.channelCount
        let bytesPerFrame = encoding.bytesPerFrame(channelCount: channelCount)
        precondition(startFrame >= 0 && startFrame <= source.frameCount,
                     "startFrame (\(startFrame)) out of bounds for frameCount \(source.frameCount)")
        let requested = min(framesToEncode ?? source.frameCount - startFrame, source.frameCount - startFrame)
        let framesToWrite = min(requested, output.count / bytesPerFrame)
        guard framesToWrite > 0, let bytes = output.baseAddress else { return 0 }

        let input = source.samples + startFrame * channelCount
        let totalSamples = framesToWrite * channelCount
        switch encoding {
        case .pcm16Bit:
            var index = 0
            while index < totalSamples {
                let value = UInt16(bitPattern: clamp16(input[index])).littleEndian
                bytes.storeBytes(of: value, toByteOffset: index * 2, as: UInt16.self)
                index += 1
            }
        case .pcm24BitPacked:
            var index = 0
            while index < totalSamples {
                let value = clamp24(input[index])
                let offset = index * 3
                bytes.storeBytes(of: UInt8(truncatingIfNeeded: value), toByteOffset: offset, as: UInt8.self)
                bytes.storeBytes(of: UInt8(truncatingIfNeeded: value >> 8), toByteOffset: offset + 1, as: UInt8.self)
                bytes.storeBytes(of: UInt8(truncatingIfNeeded: value >> 16), toByteOffset: offset + 2, as: UInt8.self)
                index += 1
            }
        case .pcm32Bit:
            var index = 0
            while index < totalSamples {
                let value = UInt32(bitPattern: clamp32(input[index])).littleEndian
                bytes.storeBytes(of: value, toByteOffset: index * 4, as: UInt32.self)
                index += 1
            }
        case .pcmFloat:
            var index = 0
            while index < totalSamples {
                let value = sanitize(input[index]).bitPattern.littleEndian
                bytes.storeBytes(of: value, toByteOffset: index * 4, as: UInt32.self)
                index += 1
            }
        }
        return framesToWrite
    }

    /// A normalised sample as a signed 16-bit integer, clamped, NaN as silence.
    @inlinable
    public static func clamp16(_ sample: Float) -> Int16 {
        if sample.isNaN { return 0 }
        let scaled = sample * 32768.0
        if scaled <= -32768.0 { return .min }
        if scaled >= 32767.0 { return .max }
        return Int16(JavaRounding.round(scaled))
    }

    /// A normalised sample as a signed 24-bit integer (-8388608...8388607).
    @inlinable
    public static func clamp24(_ sample: Float) -> Int32 {
        if sample.isNaN { return 0 }
        let scaled = sample * 8388608.0
        if scaled <= -8388608.0 { return -8388608 }
        if scaled >= 8388607.0 { return 8388607 }
        return Int32(JavaRounding.round(scaled))
    }

    /// A normalised sample as a signed 32-bit integer.
    @inlinable
    public static func clamp32(_ sample: Float) -> Int32 {
        if sample.isNaN { return 0 }
        let scaled = Double(sample) * 2147483648.0
        if scaled <= -2147483648.0 { return .min }
        if scaled >= 2147483647.0 { return .max }
        return Int32(JavaRounding.round(scaled))
    }

    /// NaN becomes silence and infinities become full scale; finite values,
    /// including headroom beyond ±1, pass through.
    @inlinable
    public static func sanitize(_ sample: Float) -> Float {
        if sample.isNaN { return 0 }
        if sample == .infinity { return 1 }
        if sample == -.infinity { return -1 }
        return sample
    }
}

/// `Math.round` as the JVM defines it: nearest integer, ties toward positive
/// infinity. Kept exact because loudness gains and PCM quantisation are ported
/// from code that used it, and Swift's own `.rounded()` breaks ties away from
/// zero instead (-0.5 → -1 where Java gives 0).
@usableFromInline
enum JavaRounding {
    @inlinable
    static func round(_ value: Float) -> Int64 {
        let floor = value.rounded(.down)
        return Int64(value - floor >= 0.5 ? floor + 1 : floor)
    }

    @inlinable
    static func round(_ value: Double) -> Int64 {
        let floor = value.rounded(.down)
        return Int64(value - floor >= 0.5 ? floor + 1 : floor)
    }
}
