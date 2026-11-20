import AVFoundation
import Foundation
import XCTest

/// Deterministic test audio: drum patterns at a known tempo, tones, and file writers.
enum SyntheticAudio {

    /// SplitMix64, so every generated signal is identical on every run.
    struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in 0..<1.
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func float() -> Float { Float(unit()) }
        mutating func int(in range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
    }

    /// A drum pattern: a kick on beats 1 and 3, a snare on 2 and 4, closed hats on every eighth.
    /// Beat 1 of each bar lands on `firstBeat + 4n` beats.
    struct DrumPattern {
        var bpm: Double
        var kickGain: Float = 0.9
        var snareGain: Float = 0.5
        var hatGain: Float = 0.12
        var bassGain: Float = 0
    }

    /// Adds `pattern` into `buffer` between `start` and `end` seconds, with beat 1 at `start`.
    static func addDrums(
        _ pattern: DrumPattern,
        into buffer: inout [Float],
        sampleRate: Double,
        start: Double,
        end: Double,
        seed: UInt64 = 1
    ) {
        var random = Random(seed: seed)
        let beat = 60 / pattern.bpm
        var index = 0
        var time = start
        while time < end - 1e-9 {
            let position = index % 4
            if position == 0 || position == 2 {
                addKick(into: &buffer, at: time, sampleRate: sampleRate, gain: pattern.kickGain * (position == 0 ? 1 : 0.8))
            } else {
                addNoiseBurst(into: &buffer, at: time, sampleRate: sampleRate, seconds: 0.09, gain: pattern.snareGain, random: &random, highPass: false)
            }
            for eighth in 0..<2 {
                addNoiseBurst(
                    into: &buffer,
                    at: time + Double(eighth) * beat / 2,
                    sampleRate: sampleRate,
                    seconds: 0.03,
                    gain: pattern.hatGain,
                    random: &random,
                    highPass: true
                )
            }
            if pattern.bassGain > 0 {
                addTone(into: &buffer, frequency: position < 2 ? 55 : 65.4, start: time, seconds: beat * 0.9, sampleRate: sampleRate, gain: pattern.bassGain)
            }
            index += 1
            time = start + Double(index) * beat
        }
    }

    /// A decaying, pitch-dropping sine: what a kick drum looks like to an onset detector.
    static func addKick(into buffer: inout [Float], at time: Double, sampleRate: Double, gain: Float) {
        let start = Int(time * sampleRate)
        let length = Int(0.14 * sampleRate)
        var phase = 0.0
        for offset in 0..<length {
            let index = start + offset
            if index < 0 || index >= buffer.count { continue }
            let t = Double(offset) / sampleRate
            let frequency = 50 + 90 * exp(-t * 30)
            phase += 2 * .pi * frequency / sampleRate
            buffer[index] += gain * Float(sin(phase) * exp(-t * 22))
        }
    }

    /// A short burst of noise with a fast decay; high-passed (a crude first difference) for hats.
    static func addNoiseBurst(
        into buffer: inout [Float],
        at time: Double,
        sampleRate: Double,
        seconds: Double,
        gain: Float,
        random: inout Random,
        highPass: Bool
    ) {
        let start = Int(time * sampleRate)
        let length = Int(seconds * sampleRate)
        var previous: Float = 0
        for offset in 0..<length {
            let index = start + offset
            if index < 0 || index >= buffer.count { continue }
            let white = random.float() * 2 - 1
            let sample = highPass ? (white - previous) * 0.5 : white
            previous = white
            let envelope = Float(exp(-Double(offset) / sampleRate * (highPass ? 90 : 30)))
            buffer[index] += gain * sample * envelope
        }
    }

    static func addTone(
        into buffer: inout [Float],
        frequency: Double,
        start: Double,
        seconds: Double,
        sampleRate: Double,
        gain: Float,
        vibrato: Double = 0,
        harmonics: Int = 1
    ) {
        let first = Int(start * sampleRate)
        let length = Int(seconds * sampleRate)
        var phase = 0.0
        for offset in 0..<length {
            let index = first + offset
            if index < 0 || index >= buffer.count { continue }
            let t = Double(offset) / sampleRate
            let instantaneous = frequency * (1 + vibrato * sin(2 * .pi * 5.5 * t))
            phase += 2 * .pi * instantaneous / sampleRate
            var value = 0.0
            for harmonic in 1...max(1, harmonics) {
                value += sin(phase * Double(harmonic)) / Double(harmonic)
            }
            // Short fades so tone edges do not click.
            let fade = min(1, min(t / 0.01, (seconds - t) / 0.01))
            buffer[index] += gain * Float(value * fade)
        }
    }

    /// A drum track at `bpm` for `seconds`, starting on beat 1 at `leadIn`.
    static func drumTrack(bpm: Double, seconds: Double, sampleRate: Double, leadIn: Double = 0.5) -> [Float] {
        var buffer = [Float](repeating: 0, count: Int(seconds * sampleRate))
        addDrums(DrumPattern(bpm: bpm, bassGain: 0.2), into: &buffer, sampleRate: sampleRate, start: leadIn, end: seconds - 0.3)
        return buffer
    }

    /// Envelope-rich material for alignment: bursts of noise with random lengths and gaps, so
    /// every stretch of its RMS envelope is distinctive.
    static func alignmentProgram(seconds: Double, sampleRate: Double, seed: UInt64) -> [Float] {
        var random = Random(seed: seed)
        var buffer = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var time = 0.0
        while time < seconds {
            let length = 0.05 + random.unit() * 0.4
            let gain = Float(0.1 + random.unit() * 0.6)
            addNoiseBurst(into: &buffer, at: time, sampleRate: sampleRate, seconds: length, gain: gain, random: &random, highPass: false)
            time += length + random.unit() * 0.3
        }
        return buffer
    }

    // MARK: - Files

    /// Writes planar channels to a PCM file (`.caf` or `.wav`) or an AAC `.m4a`, by extension.
    static func write(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
        let channelCount = AVAudioChannelCount(channels.count)
        guard let processing = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let settings: [String: Any]
        if url.pathExtension.lowercased() == "m4a" {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels.count,
                // A quality, not a bit rate: the encoder refuses a fixed 128 kbps for mono at
                // 22.05 kHz, which is what most of these tests write.
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        } else {
            settings = processing.settings
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = channels[0].count
        let chunk = 8192
        var written = 0
        while written < frames {
            let count = min(chunk, frames - written)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: AVAudioFrameCount(count)) else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channels.count {
                channels[channel].withUnsafeBufferPointer { source in
                    buffer.floatChannelData![channel].update(from: source.baseAddress! + written, count: count)
                }
            }
            try file.write(from: buffer)
            written += count
        }
    }

    static func write(mono: [Float], sampleRate: Double, to url: URL) throws {
        try write([mono], sampleRate: sampleRate, to: url)
    }

    /// A fresh temporary directory for one test, removed by the test case's teardown block.
    static func temporaryDirectory(for testCase: XCTestCase) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomixTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Zero crossings per second / 2: the dominant frequency of a clean tone.
    static func estimatedFrequency(_ samples: ArraySlice<Float>, sampleRate: Double) -> Double {
        var crossings = 0
        var previous = samples.first ?? 0
        for value in samples.dropFirst() {
            if (previous < 0) != (value < 0) { crossings += 1 }
            previous = value
        }
        return Double(crossings) / 2 / (Double(samples.count) / sampleRate)
    }
}
