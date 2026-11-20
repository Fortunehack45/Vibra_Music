import AudioDSP
import VibraMusicCore
import SwiftUI
import XCTest
@testable import Vibra Music

/// PORTING §2.7 "Equalizer": the tone pad, seven bands with sixteen presets, balance, and the
/// screen in both modes.
@MainActor
final class EqualizerScreenTests: XCTestCase {
    func testTheTonePadMapsCornersCentreAndOutsideToSteps() {
        let size = CGSize(width: 338, height: 230)
        let inset: CGFloat = 19
        XCTAssertTrue(EqualizerMath.toneStep(at: CGPoint(x: size.width / 2, y: size.height / 2), in: size, inset: inset) == (0, 0))
        XCTAssertTrue(EqualizerMath.toneStep(at: CGPoint(x: inset, y: inset), in: size, inset: inset) == (-5, 5))
        XCTAssertTrue(EqualizerMath.toneStep(at: CGPoint(x: size.width - inset, y: size.height - inset), in: size, inset: inset) == (5, -5))
        // Past the edge the puck stays on the grid.
        XCTAssertTrue(EqualizerMath.toneStep(at: CGPoint(x: -100, y: 999), in: size, inset: inset) == (-5, -5))
    }

    func testAFaderSnapsToHalfDecibelsWithADetentAtZero() {
        XCTAssertEqual(EqualizerMath.gain(atFraction: 0), 12)
        XCTAssertEqual(EqualizerMath.gain(atFraction: 1), -12)
        XCTAssertEqual(EqualizerMath.gain(atFraction: 0.5), 0)
        XCTAssertEqual(EqualizerMath.snapGain(0.55), 0)
        XCTAssertEqual(EqualizerMath.snapGain(0.7), 0.5)
        XCTAssertEqual(EqualizerMath.snapGain(3.26), 3.5)
        XCTAssertEqual(EqualizerMath.snapGain(40), 12)
        XCTAssertEqual(EqualizerMath.balance(atFraction: 0.51), 0)
        XCTAssertEqual(EqualizerMath.balance(atFraction: 0), -1)
    }

    func testReadoutsPrintLikeAHardwareEqualizer() {
        XCTAssertEqual(EqualizerMath.formatGain(0.01), "0")
        XCTAssertEqual(EqualizerMath.formatGain(6), "+6")
        XCTAssertEqual(EqualizerMath.formatGain(-3.5), "-3.5")
        XCTAssertEqual(EqualizerMath.bandsHz.map(EqualizerMath.formatFrequency), ["60", "150", "400", "1k", "2.5k", "6k", "14k"])
        XCTAssertEqual(EqualizerMath.signed(2), "+2")
        XCTAssertEqual(EqualizerMath.signed(0), "0")
    }

    /// Sixteen presets to pick from; choosing Bass Boost writes its curve, which names itself, and
    /// moving a band afterwards reads as Custom.
    func testSixteenPresetsAndBassBoostWritesItsCurve() {
        XCTAssertEqual(EqualizerPreset.selectable.count, 16)
        XCTAssertEqual(Set(EqualizerPreset.allCases.map(\.settingsLabel)).count, 17)
        let settings = makeSettingsTestSettings()
        settings.equalizerBands = EqualizerPreset.bassBoost.bandsDb
        XCTAssertEqual(EqualizerMath.preset(of: settings.equalizerBands), .bassBoost)
        XCTAssertGreaterThan(EqualizerCurve.manual(bandsDb: settings.equalizerBands).responseDb(atHz: 60), 3)
        settings.equalizerBands[3] = 2
        XCTAssertEqual(EqualizerMath.preset(of: settings.equalizerBands), .custom)
        settings.equalizerBands = EqualizerPreset.flat.bandsDb
        XCTAssertEqual(EqualizerMath.preset(of: settings.equalizerBands), .flat)
    }

    /// Boost is taken back by the automatic preamp, so a preset never clips.
    func testTheAutomaticPreampTakesBackBoost() {
        XCTAssertLessThan(EqualizerCurve.manual(bandsDb: EqualizerPreset.bassBoost.bandsDb).preampDb, 0)
    }

    func testTheScreenRendersInBothModesOnAndOff() {
        for mode in EqualizerMode.allCases {
            for enabled in [true, false] {
                let settings = makeSettingsTestSettings()
                settings.equalizerMode = mode
                settings.equalizerEnabled = enabled
                let app = makeSettingsTestApp(settings: settings)
                settingsHostAndLayOut(NavigationStack { EqualizerScreen() }.settingsTestEnvironment(app))
            }
        }
    }
}
