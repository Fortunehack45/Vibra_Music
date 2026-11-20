import ListenTogether
import SwiftUI

// Ports ui/components/QrCode.kt: a party invite as a square somebody else can point a camera at.
// The matrix comes from ListenTogether's `PartyInviteQRMatrix` (Core Image, error correction M,
// no margin); this paints it with rounded modules — slightly smaller than their cells so
// neighbours read as separate dots, which is what lets a rounded code still scan — on a white
// square with our own quiet zone.

struct PartyQRCode: View {
    let content: String
    var size: CGFloat = 180
    var foreground: Color = .black
    var background: Color = .white
    var quietZone: CGFloat = 12

    @State private var matrix: PartyInviteQRMatrix?

    var body: some View {
        // The square is painted before the code is ready, so the sheet does not reflow around it.
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                if let matrix {
                    PartyQRModules(matrix: matrix, color: foreground)
                        .padding(quietZone)
                        .transition(.opacity)
                }
            }
            .task(id: content) {
                // Encoding walks the matrix several times; kept off the main thread.
                let content = content
                let made = await Task.detached(priority: .userInitiated) { PartyInviteQRMatrix.make(content: content) }.value
                withAnimation(.easeIn(duration: 0.2)) { matrix = made }
            }
            .accessibilityElement()
            .accessibilityLabel(L10n.listenTogetherScanQr)
            .accessibilityIdentifier("partyQRCode")
    }
}

/// The modules, drawn once into a Canvas (a version-7 code is two thousand rounded squares).
struct PartyQRModules: View {
    let matrix: PartyInviteQRMatrix
    let color: Color

    var body: some View {
        Canvas { context, size in
            for rect in Self.moduleRects(matrix, side: min(size.width, size.height)) {
                let radius = rect.width * 0.3
                context.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(color))
            }
        }
        .drawingGroup()
    }

    /// Where each dark module is drawn: 86% of its cell, centred in it.
    static func moduleRects(_ matrix: PartyInviteQRMatrix, side: CGFloat) -> [CGRect] {
        let modules = matrix.dimension
        guard modules > 0, side > 0 else { return [] }
        let cell = side / CGFloat(modules)
        let dot = cell * 0.86
        let inset = (cell - dot) / 2
        var rects: [CGRect] = []
        rects.reserveCapacity(matrix.darkModuleCount)
        for y in 0..<modules {
            for x in 0..<modules where matrix.isSet(x: x, y: y) {
                rects.append(CGRect(x: CGFloat(x) * cell + inset, y: CGFloat(y) * cell + inset, width: dot, height: dot))
            }
        }
        return rects
    }
}
