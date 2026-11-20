import VibraMusicCore
import Lyrics
import SwiftUI

/// What one provider row says and whether it can be tapped (LyricsProviderRow's rules).
struct LyricsProviderRowState: Equatable {
    enum Mark: Equatable {
        case spinner
        case check
        case cross
        case search
    }

    let source: LyricsSource
    let state: LyricsProviderState
    let current: Bool

    /// A running automatic request can still be picked — it's applied when that call completes —
    /// but the current provider and a known miss can't.
    var enabled: Bool { !current && state != .notFound }

    var status: String {
        if current { return L10n.lyricsProviderCurrent }
        switch state {
        case .found: return L10n.lyricsProviderFound
        case .notFound: return L10n.lyricsProviderNotFound
        case .fetching: return L10n.lyricsProviderFetching
        case .notFetched: return L10n.lyricsProviderNotFetched
        }
    }

    var mark: Mark {
        if state == .fetching { return .spinner }
        if current || state == .found { return .check }
        if state == .notFound { return .cross }
        return .search
    }

    /// Every provider, in the listener's saved priority order, then any the order doesn't name.
    static func orderedSources(_ savedOrder: [LyricsSource]) -> [LyricsSource] {
        savedOrder + LyricsSource.allCases.filter { !savedOrder.contains($0) }
    }
}

/// The picker behind "Change" on the lyrics status line (ports ui/player/LyricsProviderSheet.kt):
/// every provider with where it stands for this track. A provider the automatic lookup already
/// found switches at once and closes the sheet; one not yet asked is asked now, and the sheet
/// closes when its lyrics arrive; a miss can't be asked twice.
///
/// A player drawer on Android, so dark over the player whatever the app theme; the system sheet
/// supplies the handle and the drag to dismiss.
struct LyricsProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(LyricsSession.self) private var injectedSession: LyricsSession?
    /// Only reached when nothing injected the player's session: every row then reads "not
    /// fetched" and taps are inert, since there is no track to look up.
    @State private var detachedSession = LyricsSession()
    @State private var requested: LyricsSource?
    /// 19 sp on Android, so it grows with the reader's text size like the rows under it.
    @ScaledMetric(relativeTo: .title3) private var titleSize: CGFloat = 19

    private var session: LyricsSession { injectedSession ?? detachedSession }

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.chooseLyricsProvider)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 14)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(LyricsProviderRowState.orderedSources(settings.lyricsSourceOrder), id: \.self) { source in
                        let row = LyricsProviderRowState(
                            source: source,
                            state: session.providerStates[source] ?? .notFetched,
                            current: source == session.source
                        )
                        LyricsProviderRow(row: row) { select(row) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: 640)
        .environment(\.colorScheme, .dark)
        .presentationDragIndicator(.visible)
        .presentationBackground { PlayerDrawerBackground() }
        .onChange(of: session.source) { _, source in
            if let requested, source == requested { dismiss() }
        }
        // A container: without this the identifier lands on every child and hides theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lyrics.providerSheet")
    }

    private func select(_ row: LyricsProviderRowState) {
        let wasFound = row.state == .found
        requested = row.source
        session.selectProvider(row.source)
        if wasFound { dismiss() }
    }
}

private struct LyricsProviderRow: View {
    let row: LyricsProviderRowState
    let action: () -> Void

    var body: some View {
        Button {
            // Not `.disabled`: that would wash the row out on top of the row's own alphas.
            guard row.enabled else { return }
            Haptics.shared.play(.select)
            action()
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(.white.opacity(row.current ? 0.16 : 0.08))
                    switch row.mark {
                    case .spinner:
                        ProgressView().controlSize(.small).tint(.white.opacity(0.8))
                    case .check:
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(row.current ? 1 : 0.75))
                    case .cross:
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    case .search:
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.source.label)
                        .font(.body.weight(row.current ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(row.current ? 1 : 0.85))
                        .lineLimit(1)
                    Text(row.status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(row.current ? 0.7 : 0.5))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(row.current ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityRemoveTraits(row.enabled ? [] : .isButton)
        .accessibilityAddTraits(row.current ? .isSelected : [])
        .accessibilityIdentifier("lyricsProvider.\(row.source.rawValue)")
    }
}
