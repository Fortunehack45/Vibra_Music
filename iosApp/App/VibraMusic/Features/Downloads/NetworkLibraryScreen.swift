import VibraMusicCore
import SwiftUI

/// An SMB share or a WebDAV server as a library: ports LocalMusicScreen.kt as MainActivity.kt placed
/// it for `local:smb` and `local:webdav` — the same Songs / Artists / Albums page as the device
/// folders, over the server's listing (MainViewModel's `remoteLibrary` / `RemoteListing.state`).
///
/// Tapping a row plays it (streamed through the audio cache from the server); holding it opens the
/// song menu, as for any page that isn't the Downloads folder. The listing is taken again when the
/// server settings change, and after an upload put something on the WebDAV server.
struct NetworkLibraryScreen: View {
    let kind: NetworkLibraryKind

    @Environment(AppModel.self) private var model
    @State private var listing: LoadState<[Song]> = .loading

    var body: some View {
        let context = DownloadsContext.shared(for: model)
        let service = context.service
        LocalMusicView(
            title: kind.title,
            browseId: kind.browseId,
            songs: listing.value ?? [],
            isDownloads: false,
            emptyMessage: errorMessage,
            isLoading: listing.isLoading,
            isDownloaded: { service.isDownloaded($0) }
        )
        .environment(\.remoteArtworkResolver) { song in await service.remoteArtwork(for: song) }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadKey(service: service, context: context)) {
            // A failure is the old settings' answer; a list stays up while it is refreshed.
            if case .error = listing { listing = .loading }
            let answer = await service.listNetworkLibrary(kind)
            // Superseded by newer settings: this answer is theirs to replace, not to overwrite.
            guard !Task.isCancelled else { return }
            listing = answer
        }
        // A container: without this the screen identifier lands on every child and hides theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.networkLibrary.\(kind.rawValue)")
    }

    private func reloadKey(service: DownloadsService, context: DownloadsContext) -> String {
        let uploads = kind == .webDAV ? context.webDAVRevision : 0
        return "\(service.networkSettingsKey(kind))#\(uploads)"
    }

    private var errorMessage: String? {
        if case .error(let message) = listing { return message }
        return nil
    }
}
