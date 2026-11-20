import XCTest
@testable import AudioDSP

/// The preset table, preset naming, and the settings value the equaliser screen stores.
final class EqualizerPresetTests: XCTestCase {

    func testThereAreSixteenPresetsPlusCustom() {
        XCTAssertEqual(EqualizerPreset.selectable.count, 16)
        XCTAssertEqual(EqualizerPreset.allCases.last, .custom)
        XCTAssertFalse(EqualizerPreset.selectable.contains(.custom))
    }

    func testEveryPresetCoversEveryBand() {
        for preset in EqualizerPreset.selectable {
            XCTAssertEqual(preset.bandsDb.count, EqualizerLayout.manualCount, "\(preset) should have one value per band")
        }
        XCTAssertTrue(EqualizerPreset.custom.bandsDb.isEmpty)
    }

    func testAPresetsOwnBandsNameItAndAnythingElseIsCustom() {
        XCTAssertEqual(EqualizerPreset.matching(EqualizerPreset.rock.bandsDb), .rock)
        XCTAssertEqual(EqualizerPreset.matching([Float](repeating: 7, count: EqualizerLayout.manualCount)), .custom)
    }

    func testEveryPresetNamesItselfBack() {
        for preset in EqualizerPreset.selectable {
            XCTAssertEqual(EqualizerPreset.matching(preset.bandsDb), preset)
        }
    }

    func testMatchingToleratesRoundingButNotAMovedSlider() {
        var nearlyRock = EqualizerPreset.rock.bandsDb
        nearlyRock[3] += 0.04
        XCTAssertEqual(EqualizerPreset.matching(nearlyRock), .rock)
        nearlyRock[3] += 0.5
        XCTAssertEqual(EqualizerPreset.matching(nearlyRock), .custom)
        XCTAssertEqual(EqualizerPreset.matching(Array(EqualizerPreset.rock.bandsDb.prefix(6))), .custom,
                       "a different band count is nobody's preset")
    }

    /// Attenuation only — a curve is never allowed to make itself louder.
    func testTheMakeUpAttenuationNeverBecomesABoost() {
        for preset in EqualizerPreset.selectable {
            let preamp = EqualizerCurve.manual(bandsDb: preset.bandsDb).preampDb
            XCTAssertLessThanOrEqual(preamp, 0.001, "\(preset) asked for \(preamp) dB of make-up")
        }
        for x in -5...5 {
            for y in -5...5 {
                for focused in [false, true] {
                    XCTAssertLessThanOrEqual(EqualizerCurve.tone(x: x, y: y, focused: focused).preampDb, 0.001)
                }
            }
        }
    }

    /// The make-up is the peak of the summed response, not the largest band:
    /// overlapping neighbours add up to more than either alone.
    func testTheMakeUpCoversTheSummedPeakNotJustTheLargestBand() {
        let neighbours = EqualizerCurve.manual(bandsDb: [0, 0, 6, 6, 0, 0, 0])
        XCTAssertLessThan(neighbours.preampDb, -6.5)
        var peak: Float = 0
        for point in 0..<EqualizerCurve.responsePoints {
            peak = max(peak, neighbours.responseDb(atHz: EqualizerCurve.responseFrequency(point)))
        }
        XCTAssertEqual(neighbours.preampDb, -peak, accuracy: 0.0001)
    }

    func testRawValuesAreTheAndroidNamesSoStoredSettingsCarryAcross() {
        XCTAssertEqual(EqualizerPreset.bassBoost.rawValue, "BASS_BOOST")
        XCTAssertEqual(EqualizerPreset(rawValue: "SMALL_SPEAKERS"), .smallSpeakers)
        XCTAssertEqual(EqualizerPreset(rawValue: "HIP_HOP"), .hipHop)
        XCTAssertEqual(EqualizerSettings.Mode(rawValue: "DYNAMIC"), .dynamic)
        XCTAssertEqual(EqualizerSettings.Mode.manual.rawValue, "MANUAL")
    }

    // ---- Curves -------------------------------------------------------------

    func testTheManualCurveOwnsSlotsZeroToSixAndLeavesTheToneSlotsFlat() {
        let curve = EqualizerCurve.manual(bandsDb: EqualizerPreset.loudness.bandsDb)
        XCTAssertEqual(Array(curve.gainsDb.prefix(7)), EqualizerPreset.loudness.bandsDb)
        XCTAssertEqual(Array(curve.gainsDb.suffix(3)), [0, 0, 0])
        XCTAssertEqual(Array(curve.qs.prefix(7)), [Float](repeating: EqualizerLayout.manualQ, count: 7))
        XCTAssertEqual(Array(curve.qs.suffix(3)), [0.707, 0.707, 0.707])
    }

    func testTheManualCurveClampsAndPadsItsBands() {
        let curve = EqualizerCurve.manual(bandsDb: [30, -30])
        XCTAssertEqual(Array(curve.gainsDb.prefix(7)), [12, -12, 0, 0, 0, 0, 0])
    }

    func testTheToneCurveTiltsInOppositeDirectionsAndClampsToFiveSteps() {
        let warm = EqualizerCurve.tone(x: -9, y: 2, focused: false)
        XCTAssertEqual(warm.gainsDb[EqualizerLayout.toneLow], 6, accuracy: 0.0001)
        XCTAssertEqual(warm.gainsDb[EqualizerLayout.toneHigh], -6, accuracy: 0.0001)
        XCTAssertEqual(warm.gainsDb[EqualizerLayout.toneMid], 2.4, accuracy: 0.0001)
        XCTAssertEqual(Array(warm.gainsDb.prefix(7)), [0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(warm.qs[EqualizerLayout.toneLow], 0.5)
        XCTAssertEqual(warm.qs[EqualizerLayout.toneMid], 0.7)

        let focused = EqualizerCurve.tone(x: 0, y: 0, focused: true)
        XCTAssertEqual(focused.qs[EqualizerLayout.toneHigh], 0.9)
        XCTAssertEqual(focused.qs[EqualizerLayout.toneMid], 2.2)
    }

    func testTheLayoutPutsShelvesAtTheEndsOfEachTab() {
        let kinds = EqualizerLayout.slots.map(\.kind)
        XCTAssertEqual(kinds, [.lowShelf, .bell, .bell, .bell, .bell, .bell, .highShelf, .lowShelf, .bell, .highShelf])
        XCTAssertEqual(EqualizerLayout.slots.map(\.frequencyHz),
                       [60, 150, 400, 1_000, 2_500, 6_000, 14_000, 250, 1_000, 4_000])
    }

    // ---- Settings ------------------------------------------------------------

    func testSettingsRenderTheTabThatIsDrivingThem() {
        var settings = EqualizerSettings(isEnabled: true, mode: .dynamic, toneX: 3, toneY: -2, isFocused: true,
                                         balance: 0.25, bandsDb: EqualizerPreset.rock.bandsDb)
        XCTAssertEqual(settings.curve, .tone(x: 3, y: -2, focused: true))
        settings.mode = .manual
        XCTAssertEqual(settings.curve, .manual(bandsDb: EqualizerPreset.rock.bandsDb))
        XCTAssertEqual(settings.preset, .rock)
    }

    func testSettingsDefaultsAreAndroids() {
        let settings = EqualizerSettings()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.mode, .dynamic)
        XCTAssertEqual(settings.toneX, 0)
        XCTAssertEqual(settings.toneY, 0)
        XCTAssertFalse(settings.isFocused)
        XCTAssertEqual(settings.balance, 0)
        XCTAssertEqual(settings.bandsDb, EqualizerPreset.flat.bandsDb)
        XCTAssertEqual(settings.preset, .flat)
    }

    /// Padded rather than rejected: a backup from a build with a different
    /// number of bands restores the ones it has.
    /// A corrupt stored value must not turn the whole curve (and every sample) into NaN.
    func testNaNSettingsReadAsFlatAndCentred() {
        let curve = EqualizerCurve.manual(bandsDb: [.nan, 3, 0, 0, 0, 0, 0])
        XCTAssertEqual(curve.gainsDb[0], 0)
        XCTAssertEqual(curve.gainsDb[1], 3)
        XCTAssertFalse(curve.preampDb.isNaN)
        XCTAssertEqual(EqualizerSettings.normalizedBands([.nan]), [0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(EqualizerSettings.clampedBalance(.nan), 0)

        let eq = EqualizerProcessor()
        eq.setTuning(enabled: true, curve: curve, balance: .nan)
        let output = DSPTestSignals.run(eq, DSPTestSignals.stereoSine(hz: 1_000, amplitude: 0.25, frames: 2_048,
                                                                     sampleRate: 48_000),
                                        sampleRate: 48_000)
        XCTAssertFalse(output.contains { !$0.isFinite })
    }

    func testStoredBandsArePaddedAndClampedLikeAndroidsSettings() {
        XCTAssertEqual(EqualizerSettings.normalizedBands([1, 2, 3]), [1, 2, 3, 0, 0, 0, 0])
        XCTAssertEqual(EqualizerSettings.normalizedBands([20, -20, 0, 0, 0, 0, 0, 5, 5]), [12, -12, 0, 0, 0, 0, 0])
        XCTAssertEqual(EqualizerSettings.clampedToneStep(9), 5)
        XCTAssertEqual(EqualizerSettings.clampedToneStep(-9), -5)
        XCTAssertEqual(EqualizerSettings.clampedBalance(-3), -1)
    }
}
