import VibraMusicCore
import Downloads
import InnerTube
import SwiftUI

// The trailing items of MainActivity.kt's FrostedTopBar (the `actions` block, ~lines 3090–3200),
// placed by RootTabView on every page of every tab: the History clock (Library's own page only),
// the download-batch ring (only while there is a batch to report on), and the account photo.
//
// Android shows none of them while Settings or Account & integrations is open, nor on the pages
// opened from those (they stay "open" underneath); here, that is any page whose tab has Settings or
// the account page on its stack. The app-update icon is not ported (in-app updates are out of scope,
// PORTING.md). Sort buttons on album/playlist pages and "Show all" grids sit here too, left of the
// photo as on Android: from a page's own toolbar they landed right of it and pushed it along.

/// Where a page sits, which decides the trailing top-bar items.
struct TopBarPlacement: Equatable {
    let tab: AppTab
    /// Nil for the tab's own page.
    let route: AppRoute?
    /// The tab's whole stack.
    let path: [AppRoute]

    /// Android hides every trailing item under Settings and Account & integrations.
    var showsItems: Bool {
        !path.contains { $0 == .settings || $0 == .account }
    }

    /// History sits left of the photo, and only on Library itself: a history is a record of what
    /// was played, which reads as that tab's business rather than every tab's.
    var showsHistory: Bool {
        showsItems && tab == .library && route == nil
    }

    enum SortButton: Equatable {
        case songs(browseId: String)
        case library
    }

    /// The page's sort: an album or playlist's track list (the device's folders carry their own
    /// control), or a Library "Show all" grid.
    var sortButton: SortButton? {
        guard showsItems else { return nil }
        switch route {
        case .album(let browseId, _), .playlist(let browseId, _):
            let hasOwnControl = LocalBrowseID.isLocal(browseId) && !browseId.hasPrefix(LocalBrowseID.playlistPrefix)
            return hasOwnControl ? nil : .songs(browseId: browseId)
        case .libraryShowAll:
            return .library
        default:
            return nil
        }
    }
}

extension View {
    /// Adds the shared trailing top-bar items for a page at `placement`.
    func appTopBar(_ placement: TopBarPlacement) -> some View {
        modifier(AppTopBarItems(placement: placement))
    }
}

private struct AppTopBarItems: ViewModifier {
    let placement: TopBarPlacement
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content.toolbar {
            if placement.showsItems {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if placement.showsHistory {
                        Button {
                            router.open(.history)
                        } label: {
                            Image(systemName: AppSymbol.history)
                        }
                        .accessibilityLabel(L10n.listeningHistory)
                        .accessibilityIdentifier("topBar.history")
                    }
                    switch placement.sortButton {
                    case .songs(let browseId): SongSortButton(browseId: browseId)
                    case .library: LibrarySortButton()
                    case nil: EmptyView()
                    }
                    TopBarDownloadButton()
                    TopBarAccountButton()
                }
            }
        }
    }
}

// MARK: - Account photo

/// The account affordance at the end of the bar (Android `TopBarAccountButton`): the signed-in
/// profile's own photo — or a person glyph on a filled circle while signed out or before the photo
/// is known, so the target never disappears.
///
/// Tapping it signed in opens the account/profile selector; signed out it opens Settings, where the
/// account lives. A vertical swipe on it steps to the next (down) or previous (up) profile; at
/// either end it nudges and springs back. VoiceOver reaches the same through adjustable actions.
struct TopBarAccountButton: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @State private var nudge: CGFloat = 0

    /// Android `AVATAR_SIZE`.
    static let avatarSize: CGFloat = 28

    var body: some View {
        let identity = AccountIdentity(model.accounts)
        AccountAvatar(url: identity.signedIn ? identity.account?.thumbnailUrl : nil, size: Self.avatarSize)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .offset(y: nudge)
            .onTapGesture { tap(signedIn: identity.signedIn) }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        guard let forward = AvatarSwipe.direction(forVerticalDrag: value.translation.height) else { return }
                        step(forward: forward)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(L10n.switchAccount)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap(signedIn: identity.signedIn) }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(forward: true)
                case .decrement: step(forward: false)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("topBar.account")
    }

    private func tap(signedIn: Bool) {
        if signedIn {
            Task { await model.accounts.loadChannels() }
            router.present(.profileSwitcher)
        } else {
            router.open(.settings)
        }
    }

    private func step(forward: Bool) {
        Task {
            let moved = await model.accounts.stepProfile(forward: forward)
            if moved {
                Haptics.shared.play(.select)
            } else {
                // The elastic cue at an end: a short jolt the way it was pushed, sprung back.
                nudge = AvatarSwipe.edgeNudge(forward: forward)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { nudge = 0 }
            }
        }
    }
}

/// The avatar swipe's rules (Android `TopBarAccountButton`'s drag handler).
enum AvatarSwipe {
    /// A drag shorter than this is not a swipe.
    static let threshold: CGFloat = 28

    /// Down steps forward, up steps back; nil for a drag too short to count.
    static func direction(forVerticalDrag height: CGFloat) -> Bool? {
        guard abs(height) >= threshold else { return nil }
        return height > 0
    }

    static func edgeNudge(forward: Bool) -> CGFloat { forward ? 9 : -9 }
}

// MARK: - Download batch

/// The download-batch indicator left of the photo (Android `TopBarDownloadButton`): present only
/// while a batch is running or finished-but-unseen, a ring of the whole batch's progress with an
/// arrow inside while busy, then a tick — or a warning if anything failed. Opens the download
/// manager.
///
/// It waits for the app to have opened the download manager itself (a moment after launch, off the
/// first frame) rather than opening it early to ask.
struct TopBarDownloadButton: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.downloadsReady) private var downloadsReady

    var body: some View {
        if downloadsReady {
            DownloadBatchIndicator(state: model.downloads.session.state) {
                Haptics.shared.play(.select)
                router.present(.downloadManager)
            }
        }
    }
}

/// The indicator for one batch state.
struct DownloadBatchIndicator: View {
    let state: DownloadSession.State
    let action: () -> Void

    var body: some View {
        if state.visible {
            let failed = state.failed > 0
            let tint: Color = failed ? .red : .accentColor
            Button(action: action) {
                ZStack {
                    if state.busy {
                        Circle().stroke(tint.opacity(0.22), lineWidth: 2)
                        // Never quite zero: a ring pinned at nothing reads as stalled.
                        Circle()
                            .trim(from: 0, to: max(state.fraction, 0.02))
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.3), value: state.fraction)
                    }
                    Image(systemName: DownloadBatchIndicator.symbol(for: state))
                        .font(.system(size: state.busy ? 11 : 17, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 26, height: 26)
            }
            .accessibilityLabel(DownloadBatchIndicator.accessibilityLabel(for: state))
            .accessibilityIdentifier("topBar.downloads")
            .transition(.opacity.combined(with: .scale))
        }
    }

    static func symbol(for state: DownloadSession.State) -> String {
        if state.failed > 0 { return "exclamationmark.circle" }
        return state.busy ? "arrow.down" : "checkmark.circle"
    }

    static func accessibilityLabel(for state: DownloadSession.State) -> String {
        if state.busy { return L10n.downloadsProgress(Int(state.fraction * 100)) }
        if state.failed > 0 { return L10n.downloadsFailedCount(state.failed) }
        return L10n.downloadsFinished
    }
}

private struct DownloadsReadyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True once the app has opened its download manager (RootTabView sets it a moment after
    /// launch), so the top bar can read the batch without forcing it open on the first frame.
    var downloadsReady: Bool {
        get { self[DownloadsReadyKey.self] }
        set { self[DownloadsReadyKey.self] = newValue }
    }
}
