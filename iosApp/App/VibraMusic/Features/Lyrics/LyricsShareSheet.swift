import VibraMusicCore
import Observation
import SwiftUI
import UIKit

// Ports app/src/main/java/com/music/vibramusic/ui/player/AndroidLyricsShareSheet.kt: the picked lines,
// drawn, with the two things you can do to the picture. Built on the Replay's sheet — the same
// preview, the same two buttons — because it is the same job: a card, saved to Photos or handed to
// the system share sheet.
//
// The iOS sheet adds one thing Android does not have: a story toggle. A card is only as tall as its
// passage, which is right for a chat but leaves a 9:16 story frame with bands to spare, so the
// toggle redraws it to fill the frame and back again.

/// The sheet's state: the picture, whether it is drawn as a story, and the two actions
/// (Android's `image` / `failed` / `saved` and the drawing effect).
@MainActor
@Observable
final class LyricsShareModel {
    private(set) var card: UIImage?
    private(set) var story = false
    private(set) var failed = false
    private(set) var saved = false
    private(set) var saving = false

    @ObservationIgnored private let draw: (Bool) async -> UIImage?
    @ObservationIgnored private let saver: ReplayPhotoSaver

    init(story: Bool = false, draw: @escaping (Bool) async -> UIImage?, saver: @escaping ReplayPhotoSaver = ReplayPhotos.live) {
        self.story = story
        self.draw = draw
        self.saver = saver
    }

    var ready: Bool { card != nil }
    var canSave: Bool { ready && !saved && !saving }
    var canShare: Bool { ready }
    /// The other shape is only worth offering once there is a picture, and not while a save of the
    /// current one is still in flight: that save's answer belongs to the card it was given, and a
    /// redraw underneath would take it for the new one.
    var canToggleStory: Bool { ready && !saving }
    /// Once the picture is in the gallery the button says so itself, rather than sitting there
    /// offering to do it again.
    var saveLabel: String { saved ? L10n.savedBang : L10n.save }
    /// What the story button offers: the other shape.
    var storyLabel: String { story ? L10n.lyricsShareStoryRevert : L10n.lyricsShareStory }

    func render() async {
        card = nil
        failed = false
        saved = false
        if let image = await draw(story) {
            card = image
        } else {
            failed = true
        }
    }

    /// Redraws the passage in the other shape — the full 9:16 story, or back to the strip its lines
    /// make.
    func toggleStory() async {
        guard canToggleStory else { return }
        story.toggle()
        await render()
    }

    func save() async {
        guard let card, canSave else { return }
        saving = true
        saved = await saver(card)
        saving = false
    }
}

struct LyricsShareSheet: View {
    let request: LyricsShareRequest
    @State private var model: LyricsShareModel

    init(request: LyricsShareRequest, saver: @escaping ReplayPhotoSaver = ReplayPhotos.live) {
        self.request = request
        _model = State(initialValue: LyricsShareModel(draw: { story in
            await LyricsShareCard.render(request: request, story: story)
        }, saver: saver))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.lyricsShareTitle)
                .font(.title.weight(.heavy))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 4)
            Text(L10n.lyricsShareDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            preview
                .padding(.top, 16)

            // Android's story toggle is the same `ShareAction` as Save and Share, full width: the
            // three things you can do to the picture read as one set, and it is only live once
            // there is a picture to reshape.
            ShareActionButton(title: model.storyLabel,
                              symbol: model.story ? "rectangle" : "rectangle.portrait",
                              accent: false, enabled: model.canToggleStory) {
                Haptics.shared.play(.tap)
                Task { await model.toggleStory() }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .accessibilityIdentifier("lyricsShare.story")

            if model.failed {
                Text(L10n.couldntDrawPicture)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            } else {
                Color.clear.frame(height: 12)
            }

            HStack(spacing: 12) {
                ShareActionButton(title: model.saveLabel,
                                  symbol: model.saved ? "checkmark" : "square.and.arrow.down",
                                  accent: false, enabled: model.canSave) {
                    Haptics.shared.play(.tap)
                    Task { await model.save() }
                }
                .accessibilityIdentifier("lyricsShare.save")
                if let card = model.card {
                    ShareLink(item: Image(uiImage: card),
                              preview: SharePreview(L10n.shareYourLyrics, image: Image(uiImage: card))) {
                        ShareActionLabel(title: L10n.share, symbol: "square.and.arrow.up", accent: true, enabled: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lyricsShare.share")
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
        // Android's sheet wraps its column; a large detent left half the screen empty under the
        // buttons.
        .fittedSheet()
    }

    /// The card is only as tall as its lines, so the frame follows it: a strip comes out wide, a
    /// full verse narrow, both about the same height on screen rather than a fixed box with bands to
    /// spare.
    private var preview: some View {
        let ratio = previewRatio
        let share = min(max(0.72 * ratio, 0.36), 0.92)
        return Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .containerRelativeFrame(.horizontal) { length, _ in length * share }
            .overlay { previewContent }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity)
    }

    private var previewRatio: CGFloat {
        guard let card = model.card, card.size.height > 0 else { return 9 / 16 }
        return card.size.width / card.size.height
    }

    private var previewContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemFill))
            if let card = model.card {
                Image(uiImage: card)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(L10n.yourLyricsCard)
                    .accessibilityIdentifier("lyricsShare.card")
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
