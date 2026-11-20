import XCTest
@testable import AudioDSP

/// The audio pipeline readout's verdict. PORTING.md's done-test is "with EQ
/// on, the dialog shows the signal as altered".
final class SignalAlterationTests: XCTestCase {

    func testWithEverythingOffTheSignalIsUnaltered() {
        let chain = DSPChain()
        chain.apply(AudioDSPSettings(loudnessNormalization: false))
        XCTAssertFalse(chain.signalAlteration.isAltered)
        XCTAssertNil(chain.signalAlteration.primaryStage)
    }

    func testWithTheEqualizerOnTheSignalIsAltered() {
        let chain = DSPChain()
        chain.apply(AudioDSPSettings(equalizer: EqualizerSettings(isEnabled: true), loudnessNormalization: false))
        XCTAssertTrue(chain.signalAlteration.isAltered)
        XCTAssertEqual(chain.signalAlteration.primaryStage, .equalizer)
    }

    /// Switched on, even to a flat curve: the readout reports the setting, as Android's does.
    func testAnEnabledFlatEqualizerStillCountsAsAltering() {
        let chain = DSPChain()
        chain.equalizer.setTuning(enabled: true, curve: .flat, balance: 0)
        chain.loudness.setEnabled(false)
        XCTAssertEqual(chain.signalAlteration.alteringStages, [.equalizer])
    }

    /// Loudness normalization is on by default but alters nothing until a
    /// track's figure is known; then it is named first.
    func testLoudnessCountsOnceAGainIsKnownAndIsNamedFirst() {
        let chain = DSPChain()
        chain.apply(AudioDSPSettings(equalizer: EqualizerSettings(isEnabled: true), spatialAudio: true))
        XCTAssertEqual(chain.signalAlteration.alteringStages, [.equalizer, .spatialAudio])
        chain.loudness.setTrackLoudness(3.2)
        XCTAssertEqual(chain.signalAlteration.alteringStages, [.loudnessNormalization, .equalizer, .spatialAudio])
        XCTAssertEqual(chain.signalAlteration.primaryStage, .loudnessNormalization)
    }

    func testAnAutomixFilterMidBlendCountsLast() {
        let chain = DSPChain()
        chain.apply(AudioDSPSettings(spatialAudio: true, loudnessNormalization: false))
        chain.transition.setCutoffs(lowPassHz: 800, highPassHz: TransitionFilterProcessor.offHz)
        XCTAssertEqual(chain.signalAlteration.alteringStages, [.spatialAudio, .transitionFilter])
    }

    /// For a screen that holds the settings but not the chain.
    func testTheVerdictCanBeWorkedOutFromSettingsAlone() {
        let settings = AudioDSPSettings(equalizer: EqualizerSettings(isEnabled: true), loudnessNormalization: true)
        XCTAssertEqual(SignalAlteration(settings: settings, loudness: .inactive).alteringStages, [.equalizer])
        XCTAssertEqual(SignalAlteration(settings: settings, loudness: LoudnessReadout(gainDb: -2, loudnessDb: 2)).primaryStage,
                       .loudnessNormalization)
        XCTAssertFalse(SignalAlteration(settings: AudioDSPSettings(loudnessNormalization: false),
                                        loudness: LoudnessReadout(gainDb: -2, loudnessDb: 2)).isAltered)
    }

    /// The verdict is honest: when it says unaltered, the chain really hands
    /// every sample back bit for bit, and when the EQ is on it really doesn't.
    func testTheVerdictMatchesWhatHappensToTheSamples() {
        let input = DSPTestSignals.stereoSine(hz: 997, amplitude: 0.7, frames: 8_192, sampleRate: 44_100)
        let chain = DSPChain()
        chain.apply(AudioDSPSettings(loudnessNormalization: false, skipSilence: true))
        XCTAssertFalse(chain.signalAlteration.isAltered)
        XCTAssertEqual(DSPTestSignals.run(chain, input, sampleRate: 44_100), input)

        chain.apply(AudioDSPSettings(equalizer: EqualizerSettings(isEnabled: true, mode: .dynamic, toneX: 3),
                                     loudnessNormalization: false))
        XCTAssertTrue(chain.signalAlteration.isAltered)
        XCTAssertNotEqual(DSPTestSignals.run(chain, input, sampleRate: 44_100), input)
    }
}
