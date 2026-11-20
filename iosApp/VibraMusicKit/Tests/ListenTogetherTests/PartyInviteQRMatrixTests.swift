import CoreImage
import XCTest
@testable import ListenTogether

/// The QR matrix the UI draws: deterministic, square, with intact finder patterns in three
/// corners and no quiet zone baked in (the caller pads).
final class PartyInviteQRMatrixTests: XCTestCase {
    func testEncodesInviteToSquareMatrix() {
        let matrix = PartyInviteQRMatrix.make(
            content: "https://vibramusic.kushagrasingh.in/invite/ABC123")
        XCTAssertNotNil(matrix)
        XCTAssertGreaterThanOrEqual(matrix!.dimension, 21)
        XCTAssertEqual(matrix!.dimension, matrix!.rows.count)
        XCTAssertTrue(matrix!.rows.allSatisfy { $0.count == matrix!.dimension })
        let dark = matrix!.darkModuleCount
        XCTAssertGreaterThan(dark, 0)
        XCTAssertLessThan(dark, matrix!.dimension * matrix!.dimension)
    }

    func testFinderPatternsSurviveInThreeCorners() {
        // The 7×7 finder pattern (dark border, light separator ring, dark 3×3 core).
        let matrix = try! XCTUnwrap(PartyInviteQRMatrix.make(content: "vibramusic://party/ABC123"))
        func finder(at ox: Int, _ oy: Int) -> Bool {
            for dy in 0 ..< 7 {
                for dx in 0 ..< 7 {
                    let onBorder = dx == 0 || dx == 6 || dy == 0 || dy == 6
                    let inCore = (2 ... 4).contains(dx) && (2 ... 4).contains(dy)
                    if matrix.isSet(x: ox + dx, y: oy + dy) != (onBorder || inCore) {
                        return false
                    }
                }
            }
            return true
        }
        let n = matrix.dimension
        XCTAssertTrue(finder(at: 0, 0))
        XCTAssertTrue(finder(at: n - 7, 0))
        XCTAssertTrue(finder(at: 0, n - 7))
    }

    /// Shape checks pass for a well-formed symbol that says the wrong thing; a scanner is the
    /// only judge of that. The matrix is drawn the way the UI draws it (padded by a quiet zone)
    /// and read back.
    func testTheMatrixScansBackToTheInvite() throws {
        let content = "https://vibramusic.kushagrasingh.in/invite/ABC123"
        let matrix = try XCTUnwrap(PartyInviteQRMatrix.make(content: content))
        let scale = 8
        let quiet = 4
        let side = (matrix.dimension + quiet * 2) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for y in 0 ..< matrix.dimension {
            for x in 0 ..< matrix.dimension where matrix.isSet(x: x, y: y) {
                for dy in 0 ..< scale {
                    for dx in 0 ..< scale {
                        pixels[((y + quiet) * scale + dy) * side + (x + quiet) * scale + dx] = 0
                    }
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual([content], found)
    }

    func testDeterministic() {
        let content = "https://vibramusic.kushagrasingh.in/invite/XYZ789"
        XCTAssertEqual(
            PartyInviteQRMatrix.make(content: content),
            PartyInviteQRMatrix.make(content: content))
    }

    func testBlankContentIsNil() {
        XCTAssertNil(PartyInviteQRMatrix.make(content: ""))
        XCTAssertNil(PartyInviteQRMatrix.make(content: "   "))
    }

    func testOutOfBoundsReadsAreClear() {
        let matrix = try! XCTUnwrap(PartyInviteQRMatrix.make(content: "vibramusic://party/ABC123"))
        XCTAssertFalse(matrix.isSet(x: -1, y: 0))
        XCTAssertFalse(matrix.isSet(x: 0, y: matrix.dimension))
    }
}
