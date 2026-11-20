import Foundation
import VibraMusicCore

// Ports the public API, writes and stats pings of data/innertube/Innertube.kt.

extension InnerTubeClient {

    // MARK: - Reads

    public func browse(_ browseId: String, params: String? = nil) async throws -> InnerTubeJSON {
        var body = InnerTubeJSONObject(["browseId": .string(browseId)])
        if let params { body["params"] = .string(params) }
        return try await postMusic("browse", body: body)
    }

    /// The next page of a paged browse response — playlists and library feeds come back roughly 100
    /// rows at a time. The web client passes the token in the body and the older query-string form
    /// is still honoured; both are sent so either is enough.
    public func browseContinuation(_ token: String) async throws -> InnerTubeJSON {
        try await postMusic("browse", query: continuationQuery(token), body: InnerTubeJSONObject(["continuation": .string(token)]))
    }

    /// Signed-in profile: display name, email/handle and avatar.
    public func accountMenu() async throws -> InnerTubeJSON {
        try await postMusic("account/account_menu")
    }

    /// Every channel this session can act as, as Innertube's account switcher lists them: the
    /// account's own channel first, then its brand channels. Each entry carries the `pageIdToken`
    /// and `datasyncIdToken` a request needs to be made *as* that channel.
    public func accountsList() async throws -> InnerTubeJSON {
        try await postMusic("account/accounts_list")
    }

    /// The same list from youtube.com's own switcher, as a second route.
    ///
    /// `accounts_list` is the tidier call but it is not uniformly answered for every client
    /// identity, and a listener whose music is on a brand channel is stuck with the wrong library
    /// until *something* enumerates their channels. This endpoint is what the youtube.com avatar menu
    /// calls, and it answers a plain signed GET. The body is JSON behind Google's XSSI guard — a
    /// `)]}'` line that exists to make the response invalid JavaScript — trimmed before parsing.
    public func accountSwitcher() async throws -> InnerTubeJSON {
        try requireSession()
        await ensureSessionScope()
        let session = scope
        let text = try await withRetry { () async throws -> String in
            var request = URLRequest(url: URL(string: "\(Self.youtubeOrigin)/getAccountSwitcherEndpoint")!)
            request.setValue(VibraMusicHTTP.UserAgent.chromeDesktop, forHTTPHeaderField: "User-Agent")
            request.setValue(InnerTubeLocale.acceptLanguage(for: currentLanguage), forHTTPHeaderField: "Accept-Language")
            request.setValue(Self.youtubeOrigin, forHTTPHeaderField: "X-Origin")
            request.setValue("\(Self.youtubeOrigin)/", forHTTPHeaderField: "Referer")
            for (name, value) in signedHeaders(origin: Self.youtubeOrigin, session: session, includePageId: false, includeAuthUser: true) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            return String(decoding: try await send(request, label: "getAccountSwitcherEndpoint").0, as: UTF8.self)
        }
        return try Self.jsonObject(from: Data(Self.strippingXSSIGuard(text).utf8), label: "getAccountSwitcherEndpoint")
    }

    static func strippingXSSIGuard(_ text: String) -> String {
        text.substring(after: ")]}'", missing: text).trimmedText
    }

    /// The watch queue YouTube Music would play after `videoId` — the "RDAMVM" radio mix. Keeps
    /// AutoPlay going past the last track, and carries the track's own menu (rating, library tokens)
    /// and its Lyrics tab.
    public func next(videoId: String) async throws -> InnerTubeJSON {
        try await postMusic("next", body: InnerTubeJSONObject([
            "videoId": .string(videoId),
            "playlistId": .string("RDAMVM\(videoId)"),
            "isAudioOnly": true,
        ]))
    }

    /// Timed caption transcript, a last-resort lyrics source. `get_transcript` expects a tiny
    /// protobuf: field 1, length, video id.
    public func transcript(videoId: String) async throws -> InnerTubeJSON {
        try await postMusic("get_transcript", body: InnerTubeJSONObject(["params": .string(Self.transcriptParams(videoId: videoId))]))
    }

    static func transcriptParams(videoId: String) -> String {
        let id = Array(videoId.utf8)
        return Data([10, UInt8(truncatingIfNeeded: id.count)] + id).base64EncodedString()
    }

    public func search(_ query: String, params: String? = nil) async throws -> InnerTubeJSON {
        var body = InnerTubeJSONObject(["query": .string(query)])
        if let params { body["params"] = .string(params) }
        return try await postMusic("search", body: body)
    }

    /// The next page of a filtered search result.
    public func searchContinuation(_ token: String) async throws -> InnerTubeJSON {
        try await postMusic("search", query: continuationQuery(token), body: InnerTubeJSONObject(["continuation": .string(token)]))
    }

    /// The typeahead list YouTube Music's own search box shows for a half-typed query — query
    /// strings, not results. A different endpoint from ``search(_:params:)`` and far cheaper: a few
    /// hundred bytes of text, which is what makes it affordable per keystroke.
    public func searchSuggestions(_ input: String) async throws -> InnerTubeJSON {
        try await postMusic("music/get_search_suggestions", body: InnerTubeJSONObject(["input": .string(input)]))
    }

    /// Live media results for the typeahead phase — same shape as ``search(_:params:)`` but
    /// deliberately unauthenticated, so YouTube Music does not log each debounced keystroke ("P",
    /// "Pe", "Perf…") to the account's server-side search history. Confirmed searches still go
    /// through the authenticated path.
    public func searchTypeahead(_ query: String) async throws -> InnerTubeJSON {
        try await postMusicAnonymous("search", body: InnerTubeJSONObject(["query": .string(query)]))
    }

    private func continuationQuery(_ token: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "ctoken", value: token),
            URLQueryItem(name: "continuation", value: token),
            URLQueryItem(name: "type", value: "next"),
        ]
    }

    // MARK: - Play history

    /// A player response fetched *with* the session cookie, purely to read back `playbackTracking`.
    /// Nil for guests: there's no account history to update.
    ///
    /// `signatureTimestamp` is not optional in practice. WEB_REMIX is a browser identity, and a
    /// browser proves it is running YouTube's current player by quoting that player's timestamp.
    /// Without one — or with a stale one — Google answers HTTP 200, `playabilityStatus` `UNPLAYABLE`,
    /// "The page needs to be reloaded", and simply omits `playbackTracking`. Nothing fails loudly;
    /// no history is written. It is the *only* gate (verified against the live endpoint on Android).
    public func playbackTracking(videoId: String, signatureTimestamp: Int?) async throws -> InnerTubePlaybackTracking? {
        guard cookie != nil else { return nil }
        await ensureSessionScope()
        var contentContext = InnerTubeJSONObject([
            "html5Preference": "HTML5_PREF_WANTS",
            "referer": .string("\(Self.musicOrigin)/watch?v=\(videoId)"),
        ])
        if let signatureTimestamp { contentContext["signatureTimestamp"] = .number(String(signatureTimestamp)) }
        let response = try await postMusic("player", body: InnerTubeJSONObject([
            "videoId": .string(videoId),
            "contentCheckOk": true,
            "racyCheckOk": true,
            // Real clients always describe where playback is happening; the response's tracking
            // block is scoped to it.
            "playbackContext": ["contentPlaybackContext": .object(contentContext)],
        ]))
        return Self.playbackTracking(from: response, videoId: videoId, signatureTimestamp: signatureTimestamp)
    }

    static func playbackTracking(from response: InnerTubeJSON, videoId: String, signatureTimestamp: Int?) -> InnerTubePlaybackTracking? {
        guard let tracking = response.o("playbackTracking") else {
            let playability = response.o("playabilityStatus")
            DebugLog.w(
                log,
                "player response has no playbackTracking for \(videoId) (status=\(playability.s("status") ?? "nil"), "
                    + "reason=\(playability.s("reason") ?? "nil"), sts=\(signatureTimestamp.map(String.init) ?? "none"))"
            )
            return nil
        }
        guard let playbackUrl = tracking.o("videostatsPlaybackUrl").s("baseUrl") else { return nil }
        return InnerTubePlaybackTracking(
            playbackUrl: playbackUrl,
            watchtimeUrl: tracking.o("videostatsWatchtimeUrl").s("baseUrl"),
            atrUrl: tracking.o("atrUrl").s("baseUrl"),
            atrAfterSeconds: tracking.o("atrUrl").s("elapsedMediaTimeSeconds").flatMap { Int64($0) } ?? defaultATRSeconds
        )
    }

    /// What YouTube Music itself schedules `atr` for, when it doesn't say.
    static let defaultATRSeconds: Int64 = 5

    /// The "playback started" ping real YouTube Music clients send once a track becomes audible.
    /// This creates the history entry the home feed feeds off. `cpn` identifies this one play and
    /// must be the same for every watchtime ping that follows.
    ///
    /// No `el` here: the base URL already carries `el=detailpage`, and a repeated query parameter is
    /// an ambiguous request rather than a stronger statement.
    @discardableResult
    public func pingPlayback(baseUrl: String, cpn: String) async throws -> Int {
        try await pingStats(baseUrl: baseUrl, cpn: cpn, extras: [])
    }

    /// The follow-up ping reporting how much of the track was heard. A history entry with no
    /// watchtime behind it reads as a skip. `st`/`et` bound the watched segment; `cmt` is the
    /// playhead position — the web client sends both and they are not redundant.
    ///
    /// - Parameter final: whether this is the last report for the play, which lets Google close the
    ///   play out rather than leave it looking abandoned.
    @discardableResult
    public func pingWatchtime(baseUrl: String, cpn: String, seconds: Int64, final: Bool = false) async throws -> Int {
        var extras = [
            URLQueryItem(name: "st", value: "0"),
            URLQueryItem(name: "et", value: String(seconds)),
            URLQueryItem(name: "cmt", value: String(seconds)),
            URLQueryItem(name: "state", value: final ? "paused" : "playing"),
        ]
        if final { extras.append(URLQueryItem(name: "final", value: "1")) }
        return try await pingStats(baseUrl: baseUrl, cpn: cpn, extras: extras)
    }

    /// The `atr` ping, fired a few seconds into a play — the leg that distinguishes a play that
    /// started from a play that happened. Its base URL already carries `ver`, `c` and `cver`, so
    /// unlike the others it is sent as-is.
    @discardableResult
    public func pingAtr(baseUrl: String, cpn: String) async throws -> Int {
        // Playback can outlive the screen that restored the session; make sure the selected
        // profile's headers exist before this first history ping.
        if cookie != nil { await ensureSessionScope() }
        let session = scope
        guard let url = Self.appendingQuery(to: baseUrl, [URLQueryItem(name: "cpn", value: cpn)]) else {
            throw InnerTubeError.invalidResponse("atr url \(baseUrl)")
        }
        return try await send(statsRequest(url, session: session), label: "atr").1.statusCode
    }

    private func pingStats(baseUrl: String, cpn: String, extras: [URLQueryItem]) async throws -> Int {
        if cookie != nil { await ensureSessionScope() }
        let session = scope
        // What the web client says about itself. Cheap, and pings are weighted by how much they
        // look like a real session.
        let query = [
            URLQueryItem(name: "ver", value: "2"),
            URLQueryItem(name: "c", value: "WEB_REMIX"),
            URLQueryItem(name: "cver", value: webRemixVersion),
            URLQueryItem(name: "cpn", value: cpn),
            URLQueryItem(name: "cplayer", value: "UNIPLAYER"),
            URLQueryItem(name: "cbr", value: "Chrome"),
            URLQueryItem(name: "cbrver", value: "141.0.0.0"),
            URLQueryItem(name: "cos", value: "Windows"),
            URLQueryItem(name: "cosver", value: "10.0"),
            URLQueryItem(name: "hl", value: "en_US"),
            URLQueryItem(name: "cr", value: "US"),
        ] + extras
        guard let url = Self.appendingQuery(to: baseUrl, query) else {
            throw InnerTubeError.invalidResponse("stats url \(baseUrl)")
        }
        return try await send(statsRequest(url, session: session), label: "stats").1.statusCode
    }

    /// The headers the tracking block asks for by name — `USER_AUTH`, `VISITOR_ID` and
    /// `PLUS_PAGE_ID`. Sending fewer is what makes a ping land somewhere other than the listener's
    /// own history.
    private func statsRequest(_ url: URL, session: InnerTubeSessionScope?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.musicOrigin, forHTTPHeaderField: "X-Origin")
        request.setValue(Self.musicOrigin, forHTTPHeaderField: "Origin")
        request.setValue("\(Self.musicOrigin)/", forHTTPHeaderField: "Referer")
        request.setValue(VibraMusicHTTP.UserAgent.chromeDesktop, forHTTPHeaderField: "User-Agent")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        for (name, value) in signedHeaders(origin: Self.musicOrigin, session: session, includePageId: true, includeAuthUser: true) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// `base` with `items` appended to whatever query it already has (Ktor's `parameter`).
    static func appendingQuery(to base: String, _ items: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        let existing = components.percentEncodedQuery.map { $0.isEmpty ? [] : [$0] } ?? []
        let added = items.map { item in
            "\(encodeQueryComponent(item.name))=\(encodeQueryComponent(item.value ?? ""))"
        }
        components.percentEncodedQuery = (existing + added).joined(separator: "&")
        return components.url
    }

    private static func encodeQueryComponent(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// A fresh client-playback-nonce, identifying one play of one track.
    public nonisolated static func newCpn() -> String {
        String((0..<16).map { _ in cpnAlphabet.randomElement()! })
    }

    private static let cpnAlphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    // MARK: - Writes
    //
    // Everything below changes something on the account, so all of it needs the session cookie
    // postMusic already signs with. None of it needs a new credential or a different client — the
    // same WEB_REMIX identity that reads the library is the one allowed to edit it.

    /// Thumbs up / down / neither, for `videoId`.
    ///
    /// The response is inspected rather than discarded: Innertube answers a refused write with HTTP
    /// 200 and an `error` object in the body, so the status line alone will happily report a rating
    /// that never happened.
    public func rate(videoId: String, status: LikeStatus) async throws {
        try requireSession()
        let endpoint: String
        switch status {
        case .like: endpoint = "like/like"
        case .dislike: endpoint = "like/dislike"
        case .indifferent: endpoint = "like/removelike"
        }
        let response = try await postMusic(endpoint, body: InnerTubeJSONObject(["target": ["videoId": .string(videoId)]]))
        try Self.throwIfRefused(response, what: "the rating")
        // YouTube states what it did in the toast it would have shown — the difference between "the
        // call was made" and "the call did something".
        DebugLog.d(Self.log, "\(endpoint) \(videoId) -> \(response.findString("text") ?? "no confirmation")")
    }

    /// Saves an album or playlist to the library, or takes it back out.
    ///
    /// The same endpoints ``rate(videoId:status:)`` uses, aimed at a playlist: a saved album *is* a
    /// liked one. `playlistId` is the id the page itself named (``LibraryState/playlistId``), not its
    /// browse id. No dislike half: nothing in YouTube Music reads a disliked release.
    public func ratePlaylist(playlistId: String, saved: Bool) async throws {
        try requireSession()
        let endpoint = saved ? "like/like" : "like/removelike"
        let response = try await postMusic(endpoint, body: InnerTubeJSONObject(["target": ["playlistId": .string(playlistId)]]))
        try Self.throwIfRefused(response, what: "the change")
        DebugLog.d(Self.log, "\(endpoint) \(playlistId) -> \(response.findString("text") ?? "no confirmation")")
    }

    /// Subscribes to an artist's channel, or unsubscribes. A subscription is a YouTube-wide
    /// relationship addressed by the `UC…` channel id the page's subscribe button named.
    public func setSubscribed(channelId: String, subscribed: Bool) async throws {
        try requireSession()
        let endpoint = subscribed ? "subscription/subscribe" : "subscription/unsubscribe"
        let response = try await postMusic(endpoint, body: InnerTubeJSONObject(["channelIds": [.string(channelId)]]))
        try Self.throwIfRefused(response, what: "the change")
        DebugLog.d(Self.log, "\(endpoint) \(channelId) -> \(response.findString("text") ?? "no confirmation")")
    }

    /// Adds or removes a track from the library, using a token minted by YouTube for exactly that
    /// transition (see ``SongMenu``). There is no video-id form of this call; the token *is* the
    /// request.
    public func sendFeedback(token: String) async throws {
        try requireSession()
        let response = try await postMusic("feedback", body: InnerTubeJSONObject(["feedbackTokens": [.string(token)]]))
        try Self.throwIfRefused(response, what: "the change")
        // The token was minted when the song menu opened, so by the time it is tapped it can have
        // expired or been used already. YouTube still answers 200, and says so per token.
        if response.a("feedbackResponses")?.contains(where: { $0.s("isProcessed") == "false" }) == true {
            throw InnerTubeError.refused("YouTube Music refused the change: the library token was not accepted")
        }
    }

    /// Creates a playlist and returns its id. `videoIds` seeds it in the same request — "add to a
    /// new playlist" in one round trip rather than a create followed by an edit that could
    /// half-succeed.
    public func createPlaylist(
        title: String,
        privacy: PlaylistPrivacy,
        description: String? = nil,
        videoIds: [String] = []
    ) async throws -> String {
        try requireSession()
        var body = InnerTubeJSONObject([
            "title": .string(title),
            "description": .string(description ?? ""),
            "privacyStatus": .string(privacy.apiValue),
        ])
        if !videoIds.isEmpty { body["videoIds"] = .array(videoIds.map(InnerTubeJSON.string)) }
        let response = try await postMusic("playlist/create", body: body)
        // Normally a bare top-level id; occasionally only inside the command that would navigate the
        // web client to the new page, so fall back to finding it by name.
        guard let id = response.s("playlistId") ?? response.findString("playlistId") else {
            throw InnerTubeError.missingData("playlist created but no id came back")
        }
        return id
    }

    public func deletePlaylist(playlistId: String) async throws {
        try requireSession()
        _ = try await postMusic("playlist/delete", body: InnerTubeJSONObject(["playlistId": .string(playlistId.removingPrefix("VL"))]))
    }

    /// One or more edits to a playlist, applied together.
    ///
    /// The endpoint answers a status other than `STATUS_SUCCEEDED` rather than an HTTP error when it
    /// refuses — a playlist the account merely saved rather than owns is the usual reason — so the
    /// body is checked as well as the status line.
    private func editPlaylist(_ playlistId: String, actions: [InnerTubeJSON]) async throws -> InnerTubeJSON {
        try requireSession()
        let response = try await postMusic("browse/edit_playlist", body: InnerTubeJSONObject([
            // The edit endpoint takes the raw id; `VL` is the browse prefix.
            "playlistId": .string(playlistId.removingPrefix("VL")),
            "actions": .array(actions),
        ]))
        if let status = response.s("status"), status != "STATUS_SUCCEEDED" {
            throw InnerTubeError.refused("YouTube Music refused the edit (\(status))")
        }
        return response
    }

    /// Adds tracks to a playlist, and reports the per-entry id each one landed under — video id to
    /// set-video-id, for the tracks the response named.
    ///
    /// Worth reading: a set-video-id is minted by this call, and it is what a later removal has to
    /// be expressed in. Absences are normal — the add still happened; only the id for undoing it is
    /// unknown.
    @discardableResult
    public func addToPlaylist(playlistId: String, videoIds: [String]) async throws -> [String: String] {
        let response = try await editPlaylist(playlistId, actions: videoIds.map {
            ["action": "ACTION_ADD_VIDEO", "addedVideoId": .string($0)]
        })
        var added: [String: String] = [:]
        for result in response.a("playlistEditResults") ?? [] {
            guard let data = result.o("playlistEditVideoAddedResultData"),
                  let videoId = data.s("videoId"), let setVideoId = data.s("setVideoId") else { continue }
            added[videoId] = setVideoId
        }
        return added
    }

    /// Removes entries from a playlist. Keyed by set-video-id as well as video id: the same track
    /// added twice is two entries, and only the pair says which of them to drop.
    public func removeFromPlaylist(playlistId: String, entries: [PlaylistEntryRef]) async throws {
        _ = try await editPlaylist(playlistId, actions: entries.map {
            ["action": "ACTION_REMOVE_VIDEO", "setVideoId": .string($0.setVideoId), "removedVideoId": .string($0.videoId)]
        })
    }

    public func renamePlaylist(playlistId: String, title: String) async throws {
        _ = try await editPlaylist(playlistId, actions: [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": .string(title)]])
    }

    private static func throwIfRefused(_ response: InnerTubeJSON, what: String) throws {
        guard let error = response["error"] else { return }
        let message = error.s("message") ?? String(decoding: error.serialized(), as: UTF8.self)
        throw InnerTubeError.refused("YouTube Music refused \(what): \(message)")
    }
}

/// One entry of a playlist, as a removal has to name it — see ``Song/setVideoId``.
public struct PlaylistEntryRef: Hashable, Sendable {
    public var setVideoId: String
    public var videoId: String

    public init(setVideoId: String, videoId: String) {
        self.setVideoId = setVideoId
        self.videoId = videoId
    }
}
