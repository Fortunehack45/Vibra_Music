import AudioToolbox
import XCTest
@testable import Sources

/// The Dolby Atmos decoder question: asked of AudioToolbox once, cached, overridable.
final class DeviceCodecsTests: XCTestCase {

    /// A host smoke test: the real probe agrees with a direct AudioToolbox query for E-AC-3 decoders,
    /// written out here rather than read back from the probe. It can't tell E-AC-3 from AC-3 on a
    /// host that has both or neither; the decision logic itself would need an injectable query.
    func testTheProbeAsksAudioToolboxForAnEnhancedAC3Decoder() {
        var formatID = kAudioFormatEnhancedAC3
        var size: UInt32 = 0
        let status = AudioFormatGetPropertyInfo(
            kAudioFormatProperty_Decoders, UInt32(MemoryLayout<AudioFormatID>.size), &formatID, &size
        )
        // Same costs as the probe: an unreadable list counts as yes, an unknown format as no.
        let expected = status == noErr ? size > 0 : status != kAudioFormatUnsupportedDataFormatError
        print("E-AC-3 decoder on this host: \(expected)")
        XCTAssertEqual(DeviceCodecs.hasEnhancedAC3Decoder(), expected)
        XCTAssertEqual(DeviceCodecs().playsDolbyAtmos, expected)
    }

    func testTheAnswerIsCachedAndCanBeForced() {
        let probes = LockedBox(0)
        let codecs = DeviceCodecs(probe: {
            probes.value += 1
            return false
        })
        XCTAssertFalse(codecs.playsDolbyAtmos)
        XCTAssertFalse(codecs.playsDolbyAtmos)
        XCTAssertEqual(probes.value, 1)
        codecs.force(true)
        XCTAssertTrue(codecs.playsDolbyAtmos)
        codecs.force(nil)
        XCTAssertFalse(codecs.playsDolbyAtmos)
        XCTAssertTrue(DeviceCodecs.fixed(true).playsDolbyAtmos)
    }

    /// Both gates must be open for an immersive mix to be asked for or accepted.
    func testAtmosIsWantedOnlyWhenTheDeviceAndTheListenerBothWantIt() async {
        let yes = await SourceEnvironment(deviceCodecs: .fixed(true), dolbyAtmosEnabled: { true }).atmosWanted()
        let settingOff = await SourceEnvironment(deviceCodecs: .fixed(true), dolbyAtmosEnabled: { false }).atmosWanted()
        let noDecoder = await SourceEnvironment(deviceCodecs: .fixed(false), dolbyAtmosEnabled: { true }).atmosWanted()
        XCTAssertTrue(yes)
        XCTAssertFalse(settingOff)
        XCTAssertFalse(noDecoder)
    }
}
