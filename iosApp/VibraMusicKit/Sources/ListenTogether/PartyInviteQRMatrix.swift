import CoreImage
import Foundation

/// A party invite as a boolean matrix somebody else can point a camera at.
///
/// The encoder is Core Image's `CIQRCodeGenerator` (PORTING.md §5 replaces ZXing with it);
/// this type exposes the raw modules so the UI draws them — rounded, in theme colours —
/// instead of blitting a baked black-on-white bitmap. Error correction level M, like the
/// Android original: the code gets photographed off a phone screen at an angle, often a
/// cracked one, and M tolerates about 15% of it being unreadable for a matrix only
/// slightly denser. (Ports the matrix half of `ui/components/QrCode.kt`.)
public struct PartyInviteQRMatrix: Hashable, Sendable {
    /// Rows of modules, `true` = dark. No quiet zone: the caller draws that as padding,
    /// so the generator must not also reserve a margin inside the matrix and shrink the
    /// modules.
    public var rows: [[Bool]]

    public init(rows: [[Bool]]) {
        self.rows = rows
    }

    public var dimension: Int { rows.count }
    public var isEmpty: Bool { rows.isEmpty }

    public func isSet(x: Int, y: Int) -> Bool {
        guard rows.indices.contains(y), rows[y].indices.contains(x) else { return false }
        return rows[y][x]
    }

    public var darkModuleCount: Int {
        rows.reduce(0) { $0 + $1.reduce(0) { $0 + ($1 ? 1 : 0) } }
    }

    /// Encodes `content` into modules. Returns nil for blank content or an encoder failure.
    public static func make(content: String) -> PartyInviteQRMatrix? {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = content.data(using: .utf8)
        else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // Render at 1pt-per-module so each pixel maps to exactly one module.
        let extent = output.extent.integral
        guard extent.width >= 21, extent.width == extent.height else { return nil }
        let dimension = Int(extent.width)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(output, from: extent) else { return nil }
        guard let provider = cgImage.dataProvider,
              let cgData = provider.data,
              let ptr = CFDataGetBytePtr(cgData)
        else { return nil }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil }
        let bytesPerRow = cgImage.bytesPerRow

        var rows: [[Bool]] = []
        rows.reserveCapacity(dimension)
        for y in 0 ..< dimension {
            var row: [Bool] = []
            row.reserveCapacity(dimension)
            for x in 0 ..< dimension {
                // Core Image renders dark modules as low luminance; sample red (grayscale-equivalent here).
                let offset = y * bytesPerRow + x * bytesPerPixel
                row.append(ptr[offset] < 128)
            }
            rows.append(row)
        }
        return PartyInviteQRMatrix(rows: Self.trimQuietZone(rows))
    }

    /// Cuts the generator's quiet-zone border: leading/trailing rows and columns that are
    /// entirely clear. The UI draws its own padding (the caller's quiet zone), so the
    /// matrix must start at the symbol's own edge — and trimming stops at the first row
    /// or column holding any dark module, which a real symbol edge always does.
    static func trimQuietZone(_ rows: [[Bool]]) -> [[Bool]] {
        var trimmed = rows
        while trimmed.count > 21, trimmed.first?.allSatisfy(!) == true {
            trimmed.removeFirst()
        }
        while trimmed.count > 21, trimmed.last?.allSatisfy(!) == true {
            trimmed.removeLast()
        }
        while (trimmed.first?.count ?? 0) > 21,
              trimmed.allSatisfy({ $0.first == false })
        {
            trimmed = trimmed.map { Array($0.dropFirst()) }
        }
        while (trimmed.first?.count ?? 0) > 21,
              trimmed.allSatisfy({ $0.last == false })
        {
            trimmed = trimmed.map { Array($0.dropLast()) }
        }
        return trimmed
    }
}
