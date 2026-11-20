import XCTest
@testable import Automix

/// The C++ analyzer through its C bridge, on synthetic audio whose answers are known.
final class NativeAnalyzerTests: XCTestCase {

    private let rate = TrackFeatures.sampleRate

    func testAnalyzerRunsAtItsOwnLowRate() {
        XCTAssertEqual(TrackFeatures.sampleRate, 11_025)
        XCTAssertEqual(AutomixAudioDecoder.analysisSampleRate, 11_025)
    }

    // MARK: - Tempo and grid

    func testDrumTracksAtKnownTemposAreMeasuredWithinATenthOfAPercent() throws {
        for bpm in [84.0, 96, 110, 120, 128, 140, 150] {
            let samples = SyntheticAudio.drumTrack(bpm: bpm, seconds: 45, sampleRate: rate)
            let features = try XCTUnwrap(TrackFeatures.analyze(samples, durationSeconds: 45))
            XCTAssertEqual(features.bpm, bpm, accuracy: bpm * 0.001, "tempo at \(bpm) BPM")
            XCTAssertEqual(features.beatInterval, 60 / bpm, accuracy: 60 / bpm * 0.001)
            XCTAssertGreaterThan(features.beatConfidence, 0.5, "a clean kit is strong evidence at \(bpm) BPM")
            XCTAssertLessThanOrEqual(features.beatConfidence, 1)
        }
    }

    func testTheGridStaysLockedToTheBeatAcrossTheWholeTrack() throws {
        let bpm = 126.0
        let beat = 60 / bpm
        let samples = SyntheticAudio.drumTrack(bpm: bpm, seconds: 120, sampleRate: rate)
        let features = try XCTUnwrap(TrackFeatures.analyze(samples, durationSeconds: 120))
        XCTAssertFalse(features.downbeats.isEmpty)
        // Every reported downbeat sits on a written beat, including the ones two minutes in: a grid
        // that drifts is exactly what makes a beat-matched blend flam.
        for downbeat in features.downbeats where downbeat > 1 && downbeat < 119 {
            let beatsIn = (downbeat - 0.5) / beat
            XCTAssertEqual(beatsIn, beatsIn.rounded(), accuracy: 0.06, "downbeat at \(downbeat)s is off the grid")
        }
        let gaps = zip(features.downbeats, features.downbeats.dropFirst()).map { $1 - $0 }
        XCTAssertEqual(gaps.sorted()[gaps.count / 2], 4 * beat, accuracy: 0.01, "a bar is four beats")
    }

    func testBeatOneIsWhereTheKickIs() throws {
        // A kick on beat one only, snares and hats everywhere else: the bass band marks the bar.
        let bpm = 120.0
        let beat = 60 / bpm
        var samples = [Float](repeating: 0, count: Int(40 * rate))
        var random = SyntheticAudio.Random(seed: 3)
        var time = 0.5
        var index = 0
        while time < 39.5 {
            if index % 4 == 0 {
                SyntheticAudio.addKick(into: &samples, at: time, sampleRate: rate, gain: 0.9)
            } else {
                SyntheticAudio.addNoiseBurst(into: &samples, at: time, sampleRate: rate, seconds: 0.08, gain: 0.45, random: &random, highPass: true)
            }
            index += 1
            time = 0.5 + Double(index) * beat
        }
        let features = try XCTUnwrap(TrackFeatures.analyze(samples, durationSeconds: 40))
        let first = try XCTUnwrap(features.downbeats.first { $0 > 0.3 })
        let barsIn = (first - 0.5) / (4 * beat)
        XCTAssertEqual(barsIn, barsIn.rounded(), accuracy: 0.03, "downbeats land on the kick, not a backbeat")
    }

    func testSilenceIsNeverTrustedAsAGrid() throws {
        // The tempo search's prior still names a number for silence; what matters is that the
        // confidence it comes with is far below anything the policy will act on.
        let features = try XCTUnwrap(TrackFeatures.analyze([Float](repeating: 0, count: Int(30 * rate)), durationSeconds: 30))
        XCTAssertLessThan(features.beatConfidence, TransitionPolicy.minDJConfidence)
        XCTAssertTrue(features.mixInCandidates.allSatisfy { $0.time.isFinite })
        XCTAssertNil(TrackFeatures.analyze([], durationSeconds: 10))
    }

    // MARK: - Structure and cue picks

    /// Three seconds of silence; an eight-bar intro of hats over a pad; then kick on one, snare on
    /// two and four, bass and pad until three seconds before the end of the file; then silence.
    /// (Enough silence at both ends that the analyzer's noise-floor percentile lands in it, as it
    /// does for a real file with a lead-in and a tail.)
    private func structuredTrack(bpm: Double, seconds: Double) -> [Float] {
        let beat = 60 / bpm
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        let start = 3.0
        let drop = start + 32 * beat
        let end = seconds - 3
        var random = SyntheticAudio.Random(seed: 9)
        SyntheticAudio.addTone(into: &samples, frequency: 330, start: start, seconds: end - start, sampleRate: rate, gain: 0.1, harmonics: 3)
        var index = 0
        var time = start
        while time < end - 1e-9 {
            let main = time >= drop - 1e-9
            SyntheticAudio.addNoiseBurst(into: &samples, at: time, sampleRate: rate, seconds: 0.03, gain: 0.2, random: &random, highPass: true)
            SyntheticAudio.addNoiseBurst(into: &samples, at: time + beat / 2, sampleRate: rate, seconds: 0.03, gain: 0.15, random: &random, highPass: true)
            if main {
                if index % 4 == 0 {
                    SyntheticAudio.addKick(into: &samples, at: time, sampleRate: rate, gain: 0.9)
                    SyntheticAudio.addTone(into: &samples, frequency: 55, start: time, seconds: min(beat * 3.8, end - time), sampleRate: rate, gain: 0.25)
                } else if index % 2 == 1 {
                    SyntheticAudio.addNoiseBurst(into: &samples, at: time, sampleRate: rate, seconds: 0.09, gain: 0.45, random: &random, highPass: false)
                }
            }
            index += 1
            time = start + Double(index) * beat
        }
        return samples
    }

    func testAudibleStartContentEndAndCuesComeFromTheArrangement() throws {
        let bpm = 120.0
        let beat = 60 / bpm
        let seconds = 90.0
        let features = try XCTUnwrap(TrackFeatures.analyze(structuredTrack(bpm: bpm, seconds: seconds), durationSeconds: seconds))

        // The analyzer looks for a sustained run (four of six 250 ms windows active), so its
        // pickup can sit up to two windows plus its 0.1 s lead before the first sound.
        XCTAssertEqual(features.audibleStartTime, 3.0, accuracy: 0.65, "the leading silence is not the song")
        XCTAssertLessThanOrEqual(features.audibleStartTime, 3.0)
        XCTAssertEqual(features.pickupTime, features.audibleStartTime)
        XCTAssertEqual(features.contentEndTime, seconds - 3, accuracy: 0.5, "the trailing silence is not the song")
        XCTAssertEqual(features.duration, seconds)

        // The first mix-in cue is the pickup; the intro drop is on the downbeat eight bars in.
        XCTAssertEqual(features.mixInCandidates.first?.type, "pickup")
        XCTAssertEqual(features.mixInCandidates.first?.time ?? -1, features.audibleStartTime, accuracy: 1e-9)
        let introDrop = try XCTUnwrap(features.mixInCandidates.first { $0.type == "intro_drop" })
        let firstDownbeat = try XCTUnwrap(features.downbeats.first)
        XCTAssertEqual(introDrop.time, firstDownbeat + 32 * beat, accuracy: beat / 2, "eight bars after the first downbeat")
        XCTAssertEqual(introDrop.time, 3.0 + 32 * beat, accuracy: 0.1, "which is where the kit comes in")
        XCTAssertTrue(features.downbeats.contains { abs($0 - introDrop.time) < 1e-6 }, "cue snapped to a downbeat")

        // The track ends where its content does, and the outro precedes it.
        let contentEnd = try XCTUnwrap(features.mixOutCandidates.first { $0.type == "content_end" })
        XCTAssertEqual(contentEnd.time, features.contentEndTime, accuracy: 1e-6)
        let outro = try XCTUnwrap(features.mixOutCandidates.first { $0.type == "outro_start" })
        XCTAssertLessThan(outro.time, features.contentEndTime)
        XCTAssertGreaterThanOrEqual(outro.time, features.introEndTime)

        // Phrases every eight bars from the first downbeat, ending at the content end.
        XCTAssertEqual(features.phraseBoundaries.last ?? -1, features.contentEndTime, accuracy: 0.05)
        XCTAssertTrue(features.phraseBoundaries.contains { abs($0 - introDrop.time) < beat })
    }

    func testALateSilenceBeforeAHiddenTrackIsAnEnergyCliff() throws {
        // Full kit to 70 s, two seconds of silence, then eight more seconds of music to the end.
        let bpm = 124.0
        var samples = [Float](repeating: 0, count: Int(80 * rate))
        SyntheticAudio.addDrums(SyntheticAudio.DrumPattern(bpm: bpm, bassGain: 0.25), into: &samples, sampleRate: rate, start: 0.5, end: 70, seed: 1)
        SyntheticAudio.addDrums(SyntheticAudio.DrumPattern(bpm: bpm, bassGain: 0.25), into: &samples, sampleRate: rate, start: 72, end: 79.8, seed: 2)
        let features = try XCTUnwrap(TrackFeatures.analyze(samples, durationSeconds: 80))

        let cliff = try XCTUnwrap(features.mixOutCandidates.first { $0.type == "energy_cliff" })
        XCTAssertEqual(cliff.time, 70, accuracy: 4.05, "backtracked from the gap by at most four seconds")
        XCTAssertLessThanOrEqual(cliff.time, 70.3)
        XCTAssertEqual(features.mixOutTime, cliff.time)
    }

    func testCurvesAreCompactAndTheVocalMaskIsParallelToTheEnergyCurve() throws {
        let samples = SyntheticAudio.drumTrack(bpm: 120, seconds: 240, sampleRate: rate)
        let features = try XCTUnwrap(TrackFeatures.analyze(samples, durationSeconds: 240))
        XCTAssertLessThanOrEqual(features.energyCurve.count, 240)
        XCTAssertGreaterThan(features.energyCurve.count, 100)
        XCTAssertEqual(features.vocalActivityMask.count, features.energyCurve.count)
        XCTAssertEqual(features.lowEnergyCurve.count, features.energyCurve.count)
        XCTAssertEqual(features.lowEnergyCurve.map(\.time), features.energyCurve.map(\.time))
        XCTAssertTrue(features.vocalActivityMask.allSatisfy { (0...1).contains($0) })
        XCTAssertTrue(features.energyCurve.allSatisfy { (0...1.5).contains($0.energy) })
        XCTAssertTrue((0...1).contains(features.vocalProbability))
    }

    // MARK: - Key

    func testKeyNamesKeepTheirAccidentalsAcrossTheBridge() throws {
        // I–IV–V–I in F♯ major, as sustained triads with the tonic doubled low.
        let triads: [[Double]] = [
            [92.50, 185.00, 233.08, 277.18], // F♯ A♯ C♯
            [123.47, 246.94, 311.13, 369.99], // B D♯ F♯
            [138.59, 277.18, 349.23, 415.30], // C♯ E♯ G♯
            [92.50, 185.00, 233.08, 277.18],
        ]
        let seconds = 32.0
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        for repetition in 0..<2 {
            for (index, chord) in triads.enumerated() {
                let start = Double(repetition * 4 + index) * 4
                for frequency in chord {
                    SyntheticAudio.addTone(into: &samples, frequency: frequency, start: start, seconds: 4, sampleRate: rate, gain: 0.12, harmonics: 3)
                }
            }
        }
        let features = try XCTUnwrap(TrackFeatures.analyze(samples, durationSeconds: seconds))
        XCTAssertTrue(features.key.contains("♯") || features.key.contains("♭"), "got \(features.key)")
        XCTAssertTrue(features.key.hasSuffix(" major") || features.key.hasSuffix(" minor"))
        XCTAssertGreaterThan(features.keyConfidence, 0)
        // And the planner's key table reads it: a key it cannot place would be no key at all.
        XCTAssertNotNil(TransitionPlanner.keyDistance(features.key, "C major"))
    }

    // MARK: - Output parsing

    func testParsingIsForgivingLikeOptDouble() throws {
        let json = #"""
        {"duration": 200, "bpm": null, "beatInterval": "x", "key": "E♭ minor",
         "downbeats": [1, null, 2.5, "3"],
         "energyCurve": [{"t": 0, "e": 0.5}, {"t": null, "e": 1}, {"t": 1}, 7],
         "mixInCandidates": [{"t": 4, "s": 0.9, "y": "intro_drop"}, {"s": 1}, {"t": 5}]}
        """#
        let features = try XCTUnwrap(TrackFeatures.parse(Data(json.utf8)))
        XCTAssertEqual(features.duration, 200)
        XCTAssertEqual(features.bpm, 0)
        XCTAssertEqual(features.beatInterval, 0)
        XCTAssertEqual(features.key, "E♭ minor")
        XCTAssertEqual(features.downbeats, [1, 2.5])
        XCTAssertEqual(features.energyCurve, [EnergySample(time: 0, energy: 0.5)])
        XCTAssertEqual(features.mixInCandidates, [
            MixCandidate(time: 4, score: 0.9, type: "intro_drop"),
            MixCandidate(time: 5, score: 0, type: ""),
        ])
        XCTAssertTrue(features.mixOutCandidates.isEmpty)
        XCTAssertNil(TrackFeatures.parse(Data("[1,2]".utf8)))
    }

    // MARK: - Front ends

    func testResamplerConvertsLengthAndRemovesWhatWouldAlias() throws {
        let inputRate = 44_100.0
        var tone = [Float](repeating: 0, count: Int(inputRate))
        SyntheticAudio.addTone(into: &tone, frequency: 1_000, start: 0, seconds: 1, sampleRate: inputRate, gain: 0.5)
        let converted = try XCTUnwrap(AutomixResampler.resample(tone, from: inputRate, to: rate))
        XCTAssertEqual(converted.count, 11_025)
        XCTAssertEqual(SyntheticAudio.estimatedFrequency(converted[1000..<10000], sampleRate: rate), 1_000, accuracy: 5)

        // 8 kHz is above the 5.5 kHz output Nyquist: decimation would fold it to 3 kHz; the filter removes it.
        var high = [Float](repeating: 0, count: Int(inputRate))
        SyntheticAudio.addTone(into: &high, frequency: 8_000, start: 0, seconds: 1, sampleRate: inputRate, gain: 0.5)
        let filtered = try XCTUnwrap(AutomixResampler.resample(high, from: inputRate, to: rate))
        let rms = (filtered[1000..<10000].reduce(0.0) { $0 + Double($1 * $1) } / 9000).squareRoot()
        XCTAssertLessThan(rms, 0.005)

        XCTAssertEqual(AutomixResampler.resample(tone, from: rate, to: rate), tone)
        XCTAssertNil(AutomixResampler.resample([], from: inputRate, to: rate))
        XCTAssertNil(AutomixResampler.resample(tone, from: 0, to: rate))
    }

    func testBeatSpectrogramHasTheModelsShapeAndRefusesOtherRates() throws {
        XCTAssertEqual(MelSpectrogram.mels, 128)
        XCTAssertEqual(MelSpectrogram.sampleRate, 22_050)
        XCTAssertEqual(MelSpectrogram.frameRate, 50)
        let samples = SyntheticAudio.drumTrack(bpm: 120, seconds: 10, sampleRate: 22_050)
        let spectrogram = try XCTUnwrap(MelSpectrogram.compute(samples))
        XCTAssertEqual(spectrogram.frames, 501, "centred frames: one per hop plus one")
        XCTAssertEqual(spectrogram.values.count, 501 * 128)
        XCTAssertEqual(spectrogram.durationSeconds, 10.02, accuracy: 1e-9)
        XCTAssertTrue(spectrogram.values.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertNil(MelSpectrogram.compute(samples, sampleRate: 44_100))
        XCTAssertNil(MelSpectrogram.compute([0.1, 0.2]))
    }

    func testVocalSpectrogramIsBinMajorStereo() throws {
        XCTAssertEqual(VocalSpectrogram.bins, 2049)
        XCTAssertEqual(VocalSpectrogram.hop, 1024)
        var left = [Float](repeating: 0, count: 44_100)
        let right = [Float](repeating: 0, count: 44_100)
        SyntheticAudio.addTone(into: &left, frequency: 1_000, start: 0, seconds: 1, sampleRate: 44_100, gain: 0.5)
        let spectrogram = try XCTUnwrap(VocalSpectrogram.compute(left: left, right: right))
        XCTAssertEqual(spectrogram.values.count, 2 * 2049 * spectrogram.frames)
        // 1 kHz lands in bin 1000 · 4096 / 44100 ≈ 93 of the left channel; the right is silent.
        let frame = spectrogram.frames / 2
        let bin93 = spectrogram.values[93 * spectrogram.frames + frame]
        let bin300 = spectrogram.values[300 * spectrogram.frames + frame]
        let rightBin93 = spectrogram.values[(2049 + 93) * spectrogram.frames + frame]
        XCTAssertGreaterThan(bin93, 100 * max(bin300, 1e-6))
        XCTAssertEqual(rightBin93, 0, accuracy: 1e-6)
        XCTAssertNil(VocalSpectrogram.compute(left: left, right: Array(right.dropLast())))
        XCTAssertNil(VocalSpectrogram.compute(left: left, right: right, sampleRate: 48_000))
    }
}
