import MediaPlayer
import UIKit
import XCTest
@testable import VibraMusic

/// The volume bar in Now Playing (`PlayerVolumeRow`) and in the output sheet
/// (`SystemVolumeRow`) rode above the centre of the speaker glyph beside it, and at full volume
/// a dark gap showed between the fill and the knob. Both rows host `CentredVolumeView`, whose
/// slider rect is moved to the row's centre line, with no knob.
///
/// The drawn bar can't be checked on CI: the simulator's MPVolumeView builds no slider at all,
/// so these tests hold the centring itself, against the rect the system lays out (top-aligned,
/// at the slider's own height). The drawn result needs a look on a device.
@MainActor
final class VolumeBarAlignmentTests: XCTestCase {
    /// The system's top-aligned rect lands centred, at both rows' heights, with its x and size kept.
    func testTheSliderRectIsMovedToTheRowsCentreLine() {
        let topAligned = CGRect(x: 0, y: 0, width: 273, height: 23)
        for height in [32.0, 40.0] {
            let bounds = CGRect(x: 0, y: 0, width: 273, height: height)
            let centred = CentredVolumeView.centred(topAligned, in: bounds)
            XCTAssertEqual(centred.midY, bounds.midY, "row height \(height)")
            XCTAssertEqual(centred.size, topAligned.size, "row height \(height)")
            XCTAssertEqual(centred.minX, topAligned.minX, "row height \(height)")
        }
        let already = CGRect(x: 0, y: 4.5, width: 273, height: 23)
        XCTAssertEqual(CentredVolumeView.centred(already, in: CGRect(x: 0, y: 0, width: 273, height: 32)), already,
                       "a rect already centred stays put")
    }

    /// The view's own override applies it: the slider's place is the plain system view's rect
    /// for the same bounds, moved onto the centre line with its x and size kept.
    func testTheVolumeViewCentresTheSystemsOwnSliderRect() {
        let frame = CGRect(x: 0, y: 0, width: 273, height: 32)
        let view = CentredVolumeView(frame: frame)
        let system = MPVolumeView(frame: frame)
        for height in [32.0, 40.0] {
            let bounds = CGRect(x: 0, y: 0, width: 273, height: height)
            let expected = CentredVolumeView.centred(system.volumeSliderRect(forBounds: bounds), in: bounds)
            XCTAssertEqual(view.volumeSliderRect(forBounds: bounds), expected, "row height \(height)")
        }
    }

    /// No knob: the thumb paints nothing, so the fill meets the bar's end at full volume.
    func testTheThumbIsAClearPoint() throws {
        let image = PlayerSystemVolumeSlider.thumb()
        XCTAssertEqual(image.size, CGSize(width: 1, height: 1))
        let data = try XCTUnwrap(image.cgImage?.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertTrue((0..<CFDataGetLength(data)).allSatisfy { bytes[$0] == 0 }, "every byte is clear")
    }
}
