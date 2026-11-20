import VibraMusicCore
import Observation
import Photos
import Replay
import SwiftUI

// Ports ui/replay/ReplayShareSheet.kt: the picture, and two buttons. The image is the sheet —
// nobody shares a Replay they have not looked at — small enough that both buttons are on screen
// with it. Save puts it in Photos (add-only access, PORTING.md §4's replacement for MediaStore);
// Share hands it to the system share sheet (ShareLink, the replacement for the chooser). Both are
// disabled rather than hidden while the poster draws, so they never move under a finger.

/// Saves an image to the photo library. The live one asks for add-only access.
typealias ReplayPhotoSaver = @Sendable (UIImage) async -> Bool

enum ReplayPhotos {
    /// Add-only: the app can put the poster in Photos without being able to read the library.
    static let live: ReplayPhotoSaver = { image in
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            DebugLog.w("Replay", "poster not saved: \(error.localizedDescription)")
            return false
        }
    }
}

@MainActor
@Observable
final class ReplayShareModel {
    private(set) var poster: UIImage?
    private(set) var failed = false
    private(set) var saved = false
    private(set) var saving = false

    @ObservationIgnored private let draw: () async -> UIImage?
    @ObservationIgnored private let saver: ReplayPhotoSaver

    init(draw: @escaping () async -> UIImage?, saver: @escaping ReplayPhotoSaver = ReplayPhotos.live) {
        self.draw = draw
        self.saver = saver
    }

    var ready: Bool { poster != nil }
    var canSave: Bool { ready && !saved && !saving }

    func render() async {
        guard poster == nil else { return }
        if let image = await draw() {
            poster = image
        } else {
            failed = true
        }
    }

    func save() async {
        guard let poster, canSave else { return }
        saving = true
        saved = await saver(poster)
        saving = false
    }
}

struct ReplayShareSheet: View {
    let page: ReplayStoryPage?
    @State private var model: ReplayShareModel

    init(summary: ReplaySummary, periodLabel: String, holder: String, memberSince: String?, page: ReplayStoryPage?,
         saver: @escaping ReplayPhotoSaver = ReplayPhotos.live) {
        self.page = page
        _model = State(initialValue: ReplayShareModel(draw: {
            await ReplayPoster.render(summary: summary, periodLabel: periodLabel, holder: holder,
                                      memberSince: memberSince, page: page)
        }, saver: saver))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.shareMyReplay)
                .font(.title.weight(.heavy))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 4)
            Text(page == nil ? L10n.replayShareSummaryDescription : L10n.replayShareCardDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            preview
                .padding(.top, 16)

            HStack(spacing: 12) {
                ShareActionButton(title: model.saved ? L10n.saved : L10n.save,
                                  symbol: model.saved ? "checkmark" : "square.and.arrow.down",
                                  accent: false, enabled: model.canSave) {
                    Task { await model.save() }
                }
                .accessibilityIdentifier("replayShare.save")
                if let poster = model.poster {
                    ShareLink(item: Image(uiImage: poster),
                              preview: SharePreview(L10n.shareYourReplay, image: Image(uiImage: poster))) {
                        ShareActionLabel(title: L10n.share, symbol: "square.and.arrow.up", accent: true, enabled: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("replayShare.share")
                } else {
                    ShareActionButton(title: L10n.share, symbol: "square.and.arrow.up", accent: true, enabled: false) {}
                }
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .task { await model.render() }
        // Android's sheet (skipPartiallyExpanded) wraps its column; a large detent left half the
        // screen empty under the buttons.
        .fittedSheet()
    }

    /// Small enough that the two buttons are on screen with it.
    private var preview: some View {
        Color.clear
            .aspectRatio(9 / 16, contentMode: .fit)
            .containerRelativeFrame(.horizontal) { length, _ in length * 0.42 }
            .overlay { previewContent }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity)
    }

    private var previewContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemFill))
            if let poster = model.poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(L10n.yourReplay)
                    .accessibilityIdentifier("replayShare.poster")
            } else if model.failed {
                Text(L10n.couldntDrawPicture)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                ProgressView()
            }
        }
    }
}

struct ShareActionButton: View {
    let title: String
    let symbol: String
    let accent: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ShareActionLabel(title: title, symbol: symbol, accent: accent, enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The one that sends it is the one reached for, so it carries the accent.
struct ShareActionLabel: View {
    let title: String
    let symbol: String
    let accent: Bool
    let enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            Text(title).font(.headline).lineLimit(1)
        }
        .foregroundStyle(accent ? Color.white : Color.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background((accent ? Color.accentColor : Color(.secondarySystemFill)).opacity(enabled ? 1 : 0.4),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
