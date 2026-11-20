import XCTest
@testable import PlaybackPolicy

/// Output route descriptors (ports AudioRouting's classification, dedupe and naming).
final class AudioRoutingTests: XCTestCase {
    func testPortTypesMapToTheKindsWorthTellingApart() {
        XCTAssertEqual(AudioRouting.kind(of: .builtInSpeaker), .phone)
        XCTAssertEqual(AudioRouting.kind(of: .builtInReceiver), .phone)
        XCTAssertEqual(AudioRouting.kind(of: .headphones), .wired)
        XCTAssertEqual(AudioRouting.kind(of: .lineOut), .wired)
        XCTAssertEqual(AudioRouting.kind(of: .usbAudio), .usb)
        XCTAssertEqual(AudioRouting.kind(of: .bluetoothA2DP), .bluetooth)
        XCTAssertEqual(AudioRouting.kind(of: .bluetoothLE), .bluetooth)
        XCTAssertEqual(AudioRouting.kind(of: .bluetoothHFP), .bluetooth)
        XCTAssertEqual(AudioRouting.kind(of: .hdmi), .hdmi)
        XCTAssertEqual(AudioRouting.kind(of: .displayPort), .hdmi)
        XCTAssertEqual(AudioRouting.kind(of: .airPlay), .airPlay)
        XCTAssertEqual(AudioRouting.kind(of: .carAudio), .car)
        XCTAssertEqual(AudioRouting.kind(of: .other("Thunderbolt")), .other)
    }

    /// Kind alone can't say which Bluetooth profile: LE Audio earbuds are not A2DP.
    func testBluetoothProfilesAreNamed() {
        XCTAssertEqual(AudioRouting.bluetoothProfile(of: .bluetoothA2DP), "A2DP")
        XCTAssertEqual(AudioRouting.bluetoothProfile(of: .bluetoothLE), "LE Audio")
        XCTAssertEqual(AudioRouting.bluetoothProfile(of: .bluetoothHFP), "Hands-free")
        XCTAssertNil(AudioRouting.bluetoothProfile(of: .headphones))
    }

    /// One row per physical device, and A2DP — the media profile — wins any tie: pointing at the
    /// telephony profile sent Android's music to the phone speaker at the headset's volume.
    func testOneRowPerDeviceWithTheMediaProfilePreferred() {
        let ports = [
            AudioRouting.Port(type: .bluetoothHFP, name: "AirPods Pro", uid: "hfp"),
            AudioRouting.Port(type: .bluetoothLE, name: "AirPods Pro", uid: "le"),
            AudioRouting.Port(type: .bluetoothA2DP, name: "AirPods Pro", uid: "a2dp"),
        ]
        let devices = AudioRouting.devices(from: ports)
        XCTAssertEqual(devices.map(\.id), ["a2dp"])
        XCTAssertEqual(devices.first?.bluetoothProfile, "A2DP")
    }

    func testDevicesAreListedInKindOrder() {
        let ports = [
            AudioRouting.Port(type: .airPlay, name: "Living Room", uid: "air"),
            AudioRouting.Port(type: .usbAudio, name: " Qudelix-5K ", uid: "usb"),
            AudioRouting.Port(type: .builtInSpeaker, name: "Speaker", uid: "spk"),
            AudioRouting.Port(type: .hdmi, name: "LG TV", uid: "hdmi"),
        ]
        let devices = AudioRouting.devices(from: ports)
        XCTAssertEqual(devices.map(\.kind), [.phone, .usb, .hdmi, .airPlay])
        XCTAssertTrue(devices.allSatisfy(\.isActive), "every output in the current route is where the music is going")
        XCTAssertEqual(devices[1].name, "Qudelix-5K")
    }

    /// The phone's speaker and wired headphones carry no name of their own worth showing.
    func testOutputsWithoutTheirOwnNameGetALabel() {
        let devices = AudioRouting.devices(from: [
            AudioRouting.Port(type: .builtInSpeaker, name: "Speaker", uid: "spk"),
            AudioRouting.Port(type: .headphones, name: "Headphones", uid: "wired"),
        ])
        XCTAssertEqual(devices.map(\.name), ["", ""])
        XCTAssertEqual(AudioRouting.label(for: devices[0], accountName: "Kushagra Singh"), "Kushagra’s Phone")
        XCTAssertEqual(AudioRouting.label(for: devices[0], accountName: nil), "This phone")
        XCTAssertEqual(AudioRouting.label(for: devices[0], accountName: "   "), "This phone")
        XCTAssertEqual(AudioRouting.label(for: devices[1], accountName: "Kushagra"), "Wired headphones")

        let unnamedUSB = AudioRouting.Device(id: "u", portType: .usbAudio, name: "", kind: .usb)
        XCTAssertEqual(AudioRouting.label(for: unnamedUSB, accountName: nil), "USB audio")
        let unnamedHDMI = AudioRouting.Device(id: "h", portType: .hdmi, name: "", kind: .hdmi)
        XCTAssertEqual(AudioRouting.label(for: unnamedHDMI, accountName: nil), "HDMI")
    }

    /// The caption under the transport reads off the same list the output sheet shows.
    func testTheOutputNameIsTheActiveDevicesLabel() {
        let airPods = AudioRouting.devices(from: [AudioRouting.Port(type: .bluetoothA2DP, name: "AirPods Max", uid: "bt")])
        XCTAssertEqual(AudioRouting.outputName(of: airPods, accountName: "Alex"), "AirPods Max")
        XCTAssertEqual(AudioRouting.outputName(of: [], accountName: "Alex Doe"), "Alex’s Phone")
    }

    func testRouteNamesMatchTheAndroidDialog() {
        XCTAssertEqual(AudioRouting.Kind.allCases.map(\.routeName), ["PHONE", "WIRED", "USB", "BLUETOOTH", "HDMI", "AIRPLAY", "CAR", "OTHER"])
    }

    /// Spatial Audio and channel counts ride along from the port.
    func testPortDetailsCarryOver() {
        let devices = AudioRouting.devices(from: [
            AudioRouting.Port(type: .bluetoothA2DP, name: "AirPods Pro", uid: "bt", channelCount: 2, isSpatialAudioEnabled: true),
        ])
        XCTAssertEqual(devices.first?.channelCount, 2)
        XCTAssertEqual(devices.first?.isSpatialAudioEnabled, true)
        let status = AudioOutputStatus()
        status.publishRoute(
            ports: [AudioRouting.Port(type: .bluetoothA2DP, name: "AirPods Pro", uid: "bt", isSpatialAudioEnabled: true)],
            hardwareSampleRateHz: 48_000,
            outputChannels: 2,
            maximumOutputChannels: 2,
            ioBufferDuration: 0.005,
            outputLatency: 0.16
        )
        XCTAssertTrue(status.current.systemSpatialAudioEnabled)
        XCTAssertFalse(status.current.routeCarriesHiRes)
        XCTAssertEqual(status.current.ioBufferDuration, 0.005)
    }

    func testWiredAndUSBRoutesCarryHiRes() {
        let status = AudioOutputStatus()
        status.publishRoute(ports: [AudioRouting.Port(type: .headphones, name: "Headphones", uid: "w")], hardwareSampleRateHz: 48_000, outputChannels: 2)
        XCTAssertTrue(status.current.routeCarriesHiRes)
        XCTAssertEqual(status.current.deviceName, "Wired headphones", "an unnamed wired route is labelled by kind")
        status.publishRoute(ports: [AudioRouting.Port(type: .builtInSpeaker, name: "Speaker", uid: "s")], hardwareSampleRateHz: 48_000, outputChannels: 2)
        XCTAssertFalse(status.current.routeCarriesHiRes)
    }
}
