import Foundation
import VibraMusicCore

/// YouTube Music search, as the ``YouTubeSource`` needs it. Implemented by the InnerTube module's
/// repository (a songs-filtered search); the app wires it in.
public protocol YouTubeSongSearching: Sendable {
    /// Song rows for `query` (Android: `YtMusicRepository.search(query, SearchFilter.SONGS)`).
    func searchSongs(_ query: String) async throws -> [Song]
}

/// What every source needs from the app, injected once into ``SourceRegistry``.
public struct SourceEnvironment: Sendable {
    /// For addons, JioSaavn and module fetches.
    public var session: URLSession
    public var deviceCodecs: DeviceCodecs
    /// The listener's Dolby Atmos switch (``AppSettings/dolbyAtmos``), read per request.
    public var dolbyAtmosEnabled: @Sendable () async -> Bool
    /// Where converted DASH playlists are written.
    public var manifestFiles: SourceManifestFiles
    /// YouTube's own catalogue and stream resolver. Without them the YouTube source answers nothing
    /// and the resolver's YouTube fallback is left to the caller.
    public var youTubeSearch: YouTubeSongSearching?
    public var youTubeStreams: StreamResolving?

    public init(
        session: URLSession = VibraMusicHTTP.session,
        deviceCodecs: DeviceCodecs = .shared,
        dolbyAtmosEnabled: @escaping @Sendable () async -> Bool,
        manifestFiles: SourceManifestFiles = .standard,
        youTubeSearch: YouTubeSongSearching? = nil,
        youTubeStreams: StreamResolving? = nil
    ) {
        self.session = session
        self.deviceCodecs = deviceCodecs
        self.dolbyAtmosEnabled = dolbyAtmosEnabled
        self.manifestFiles = manifestFiles
        self.youTubeSearch = youTubeSearch
        self.youTubeStreams = youTubeStreams
    }

    /// The app's wiring: the shared session, this device's decoders, and `settings.dolbyAtmos`.
    public static func live(
        settings: AppSettings,
        youTubeSearch: YouTubeSongSearching?,
        youTubeStreams: StreamResolving?
    ) -> SourceEnvironment {
        SourceEnvironment(
            dolbyAtmosEnabled: { await settings.dolbyAtmos },
            youTubeSearch: youTubeSearch,
            youTubeStreams: youTubeStreams
        )
    }

    /// Whether an immersive mix is worth asking for and accepting right now: the device can decode
    /// it and the listener wants it. The one gate the addon `?atmos=` hint, the module
    /// `dolbyAtmos` setting, ``ModuleSource/unplayable(_:atmosAllowed:)`` and
    /// ``SourceResolver/preferred(_:target:wantsLossless:atmosWanted:)`` all ask.
    public func atmosWanted() async -> Bool {
        guard deviceCodecs.playsDolbyAtmos else { return false }
        return await dolbyAtmosEnabled()
    }
}
