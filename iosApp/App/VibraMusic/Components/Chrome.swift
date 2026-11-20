import VibraMusicCore
import SwiftUI

// Ports the app's chrome: ui/components/{FrostedTopBar, TopFadeBlur, BottomFadeScrim,
// SearchField, QueueActionNotice, ArtworkBackdrop}.kt. Android faked Apple's materials with a
// haze library; SwiftUI's materials are the real thing.

/// A frosted bar background (FrostedTopBar.kt), or a solid one with "Reduce dynamic blur" on.
struct FrostedBackground: View {
    var reduceBlur = false

    var body: some View {
        if reduceBlur {
            Rectangle().fill(Color(.systemBackground))
        } else {
            Rectangle().fill(.bar)
        }
    }
}

/// Fades the page out under the floating bars at the foot of the screen (BottomFadeScrim.kt).
struct BottomFadeScrim: View {
    var height: CGFloat = 120

    var body: some View {
        LinearGradient(
            colors: [Color(.systemBackground).opacity(0), Color(.systemBackground).opacity(0.85)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Fades content out under the status bar (TopFadeBlur.kt).
struct TopFadeScrim: View {
    var height: CGFloat = 60

    var body: some View {
        LinearGradient(
            colors: [Color(.systemBackground).opacity(0.9), Color(.systemBackground).opacity(0)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The search field (SearchField.kt): magnifier, text, clear button; submit runs the search.
struct SearchField: View {
    @Binding var text: String
    var prompt: String = L10n.searchHint
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: AppSymbol.search).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .focused(focus)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("search.field")
            if !text.isEmpty {
                Button {
                    text = ""
                    // Clearing is to type something else: focus and the keyboard stay (Android's
                    // focusRequester.requestFocus() + keyboardController.show()).
                    focus.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.clearSearch)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The toast a queue action leaves above the mini player (QueueActionNotice.kt): "Song added to
/// queue", "Only the host can do that". It clears itself after a moment.
struct QueueNoticeView: View {
    let notice: QueueNotice

    var body: some View {
        HStack(spacing: 8) {
            if let symbol = notice.symbol {
                Image(systemName: symbol)
            }
            Text(notice.message)
                .lineLimit(2)
        }
        .font(AppTheme.Typeface.bodySmall.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityIdentifier("queueNotice")
    }
}

/// Blurred, dimmed artwork filling a page's background (ArtworkBackdrop.kt), for Now Playing and
/// page headers.
struct ArtworkBackdrop: View {
    let artwork: String?
    var blurRadius: CGFloat = 60
    var dim: Double = 0.35

    var body: some View {
        GeometryReader { proxy in
            ArtworkImage(artwork, pixels: ArtworkSize.header, cornerRadius: 0)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .blur(radius: blurRadius, opaque: true)
                .overlay(Color.black.opacity(dim))
                .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
