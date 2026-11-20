import VibraMusicCore
import Foundation

/// A stream one client offered, and the identity its media fetch has to wear.
/// Port of `InnerTubeXResolver.Extracted`.
struct ExtractedStream: Sendable, Equatable {
    var videoId: String
    var url: URL
    var itag: Int
    var kbps: Int
    var mimeType: String
    var loudnessDb: Double?
    var contentLength: Int64?
    var approxDurationMs: Int64?
    var clientName: String
    var profileId: String
    var headers: [String: String]
    var expiresAt: Date?

    var resolved: ResolvedYouTubeStream {
        ResolvedYouTubeStream(
            videoId: videoId, url: url, itag: itag, kbps: kbps, mimeType: mimeType, loudnessDb: loudnessDb,
            contentLength: contentLength, approxDurationMs: approxDurationMs, clientName: clientName,
            profileId: profileId, mediaHeaders: headers, expiresAt: expiresAt
        )
    }
}

/// How a walk over the catalog ended.
enum ExtractionOutcome: Sendable, Equatable {
    case found(ExtractedStream)
    /// No client produced a usable stream.
    /// - permanent: a verdict about the track, when the answers support one.
    /// - offered: whether any client listed a format of the wanted container at all.
    case exhausted(permanent: PermanentReason?, offered: Bool, detail: String)
}

/// Walks the client catalog for one videoId and returns the first usable stream. Port of
/// `InnerTubeXResolver` — the part of InnerTubeX this app used — with NewPipe's failsafe folded
/// in as the catalog's cipher tier.
///
/// Also the memory of what it minted: each URL's exact headers (so the media fetch is dressed
/// as the client that asked) and which client to bench when googlevideo refuses one mid-play.
actor InnerTubeStreamExtractor {
    private let session: URLSession
    private let catalog: [StreamClientProfile]
    private let visitorData: StreamVisitorDataStore
    private let cipher: StreamCipherSolver?
    private let poTokens: StreamPoTokenProvider?
    private let auth: StreamAuthProvider?
    private let language: @Sendable () -> String
    private let now: @Sendable () -> Date

    /// What each minted URL was, so its fetch can be dressed and its refusal attributed.
    private var minted: [URL: ExtractedStream] = [:]
    /// Clients refused a track mid-playback, by videoId, and until when.
    private var excluded: [String: [String: Date]] = [:]
    /// Clients whose URLs keep failing the probe across tracks, and until when. See `noteProbe`.
    private var benchedUntil: [String: Date] = [:]
    private var consecutiveProbeFailures: [String: Int] = [:]

    static let excludeDuration: TimeInterval = 10 * 60
    static let benchDuration: TimeInterval = 10 * 60
    /// Refusals in a row, across different tracks, before a client sits the walk out.
    static let benchAfterFailures = 3
    static let maxRemembered = 64
    static let requestTimeout: TimeInterval = 10

    init(
        session: URLSession, catalog: [StreamClientProfile], visitorData: StreamVisitorDataStore,
        cipher: StreamCipherSolver?, poTokens: StreamPoTokenProvider?, auth: StreamAuthProvider?,
        language: @escaping @Sendable () -> String, now: @escaping @Sendable () -> Date
    ) {
        self.session = session
        self.catalog = catalog
        self.visitorData = visitorData
        self.cipher = cipher
        self.poTokens = poTokens
        self.auth = auth
        self.language = language
        self.now = now
    }

    /// The first client in the catalog, not excluded or skipped, whose answer holds a usable
    /// format for `selection`.
    func extract(videoId: String, selection: StreamSelection, skip: Set<String>) async -> ExtractionOutcome {
        let authSession = await auth?.streamAuthSession()
        let ruledOut = excludedClients(for: videoId).union(skip)
        var permanent: [PermanentReason] = []
        var answers = 0
        var offered = false
        var refreshedVisitorData = false
        var timeouts = 0
        var details: [String] = []

        var queue = catalog.filter { !ruledOut.contains($0.id) && !isBenched($0.id) }
        if queue.isEmpty {
            // Everything benched: better to ask a benched client than nobody.
            queue = catalog.filter { !ruledOut.contains($0.id) }
        }
        var index = 0
        while index < queue.count {
            let profile = queue[index]
            if profile.usesPlayerScript && cipher == nil {
                index += 1
                continue
            }
            let response: PlayerResponse
            do {
                response = try await requestPlayer(profile, videoId: videoId, auth: authSession)
            } catch {
                details.append("\(profile.id): \(error.localizedDescription)")
                streamLog.warning("\(profile.id, privacy: .public) player request failed for \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // No network, or one that stopped answering: every other client would fail the
                // same way, each after a request timeout of its own. One timeout alone may
                // be one slow host, so it takes a second in a row, from the next client, to end
                // the walk: a client that answers in between shows the network is up.
                if Self.isOffline(error) { break }
                if (error as? URLError)?.code == .timedOut {
                    timeouts += 1
                    if timeouts >= 2 { break }
                }
                index += 1
                continue
            }
            answers += 1
            timeouts = 0
            switch PlayabilityVerdict.classify(response.playabilityStatus) {
            case .botCheck:
                details.append("\(profile.id): bot check")
                if !refreshedVisitorData {
                    // Once per walk: an id can be burned while the session around it is fine.
                    refreshedVisitorData = true
                    _ = await visitorData.visitorData(refresh: true)
                    continue
                }
            case .refused(let why):
                details.append("\(profile.id): \(why)")
            case .permanent(let reason):
                details.append("\(profile.id): \(reason)")
                permanent.append(reason)
            case .playable:
                let formats = response.audioFormats
                if selection.offersContainer(formats) { offered = true }
                guard let format = selection.pick(from: formats) else {
                    details.append("\(profile.id): no usable format")
                    break
                }
                do {
                    let stream = try await makeStream(format, response: response, profile: profile, videoId: videoId)
                    remember(stream)
                    return .found(stream)
                } catch {
                    details.append("\(profile.id): \(error.localizedDescription)")
                    streamLog.warning("\(profile.id, privacy: .public) format for \(videoId, privacy: .public) unusable: \(error.localizedDescription, privacy: .public)")
                }
            }
            index += 1
        }
        return .exhausted(
            permanent: Self.verdict(permanent, answers: answers), offered: offered,
            detail: details.isEmpty ? "no client to ask" : details.joined(separator: "; ")
        )
    }

    /// The device has no network at all. Fast, possibly host-specific failures (a refused
    /// connection, an unknown host) and a dropped connection (a Wi-Fi to cellular switch, after
    /// which the next request may well go through) still let the walk try the next client.
    static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
    }

    /// A permanent verdict needs support. An age gate or region block from any client that
    /// answered stands (the ones that did not say so said something vaguer, like WEB_REMIX's
    /// "Video unavailable" for anything that is not music). "Removed" needs every answer to agree.
    static func verdict(_ reasons: [PermanentReason], answers: Int) -> PermanentReason? {
        let specific = reasons.filter { $0 != .removed }
        if let strongest = specific.min() { return strongest }
        if !reasons.isEmpty, reasons.count == answers { return .removed }
        return nil
    }

    // MARK: - Minted URLs

    /// Headers the media fetch for `url` must carry, when this extractor minted it.
    func headers(for url: URL) -> [String: String]? { minted[url]?.headers }

    /// Records that googlevideo refused `url` mid-playback.
    /// - Returns: the videoId it was minted for, or nil when this extractor did not mint it.
    func onRefused(_ url: URL) async -> String? {
        guard let refused = minted.removeValue(forKey: url) else { return nil }
        exclude(videoId: refused.videoId, profileId: refused.profileId)
        // A refused deciphered URL is the signal the cipher config may be stale; it has its own cooldown.
        if let profile = catalog.first(where: { $0.id == refused.profileId }), profile.usesPlayerScript {
            await cipher?.refreshAfterStreamRejection()
        }
        return refused.videoId
    }

    func exclude(videoId: String, profileId: String) {
        streamLog.warning("\(profileId, privacy: .public) refused \(videoId, privacy: .public); skipping it for this track")
        if excluded.count >= Self.maxRemembered, excluded[videoId] == nil {
            let current = now()
            excluded = excluded.filter { entry in entry.value.values.contains { $0 > current } }
            // Still full of live entries: the one that lapses soonest goes, the rest keep their word.
            if excluded.count >= Self.maxRemembered,
               let oldest = excluded.min(by: { ($0.value.values.max() ?? .distantPast) < ($1.value.values.max() ?? .distantPast) })?.key {
                excluded[oldest] = nil
            }
        }
        excluded[videoId, default: [:]][profileId] = now().addingTimeInterval(Self.excludeDuration)
    }

    /// A new cookie or visitor means a new hearing for every client.
    func onSessionChanged() {
        excluded.removeAll()
        minted.removeAll()
        benchedUntil.removeAll()
        consecutiveProbeFailures.removeAll()
    }

    /// Feeds the probe's verdict back. A client whose URLs are refused on three different tracks
    /// in a row sits the walk out for ten minutes, so a whole-catalog regression (ANDROID_VR's
    /// one-minute URLs, today) costs three tracks a wasted request each rather than every track.
    /// One success clears the count.
    func noteProbe(profileId: String, ok: Bool) {
        if ok {
            consecutiveProbeFailures[profileId] = nil
            benchedUntil[profileId] = nil
            return
        }
        let failures = (consecutiveProbeFailures[profileId] ?? 0) + 1
        if consecutiveProbeFailures.count >= Self.maxRemembered { consecutiveProbeFailures.removeAll() }
        consecutiveProbeFailures[profileId] = failures
        if failures >= Self.benchAfterFailures {
            streamLog.warning("\(profileId, privacy: .public) benched after \(failures) refused URLs in a row")
            if benchedUntil.count >= Self.maxRemembered {
                let current = now()
                benchedUntil = benchedUntil.filter { $0.value > current }
                if benchedUntil.count >= Self.maxRemembered { benchedUntil.removeAll() }
            }
            benchedUntil[profileId] = now().addingTimeInterval(Self.benchDuration)
            consecutiveProbeFailures[profileId] = 0
        }
    }

    func isBenched(_ profileId: String) -> Bool {
        guard let until = benchedUntil[profileId] else { return false }
        if now() < until { return true }
        benchedUntil[profileId] = nil
        return false
    }

    private func excludedClients(for videoId: String) -> Set<String> {
        guard var entries = excluded[videoId] else { return [] }
        let current = now()
        entries = entries.filter { $0.value > current }
        excluded[videoId] = entries.isEmpty ? nil : entries
        return Set(entries.keys)
    }

    private func remember(_ stream: ExtractedStream) {
        if minted.count >= Self.maxRemembered { minted.removeAll() }
        minted[stream.url] = stream
    }

    // MARK: - Requests

    private func requestPlayer(
        _ profile: StreamClientProfile, videoId: String, auth: StreamAuthSession?
    ) async throws -> PlayerResponse {
        let sessionAuth = profile.sendsAuth ? auth : nil
        var embed: EmbedConfig?
        if profile.embedsPage {
            embed = try await embedConfig(videoId: videoId, profile: profile)
        }
        var visitor = embed?.visitorData ?? sessionAuth?.visitorData
        if visitor == nil { visitor = await visitorData.visitorData() }
        if profile.requiresVisitorData && visitor == nil {
            throw StreamResolutionError.noPlayableStream(detail: "no visitor id for \(profile.clientName)")
        }
        var signatureTimestamp: Int?
        if profile.usesPlayerScript {
            signatureTimestamp = await cipher?.signatureTimestamp()
            guard signatureTimestamp != nil else {
                throw StreamResolutionError.noPlayableStream(detail: "no signature timestamp for \(profile.clientName)")
            }
        }
        var clientVersion = embed?.clientVersion ?? profile.clientVersion
        if profile.clientName == "WEB_REMIX" {
            if let live = sessionAuth?.webRemixClientVersion {
                clientVersion = live
            } else if let live = await visitorData.shellClientVersion {
                clientVersion = live
            }
        }
        let poToken = await poTokenIfUseful(for: profile, videoId: videoId, visitorData: visitor)
        let request = try Self.playerRequest(
            profile: profile, clientVersion: clientVersion, videoId: videoId, visitorData: visitor,
            signatureTimestamp: signatureTimestamp, auth: sessionAuth, poToken: poToken,
            language: language(), cpn: Self.newCpn(), now: now(), embed: embed
        )
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw StreamResolutionError.noPlayableStream(detail: "\(profile.clientName) player HTTP \(status)")
        }
        var decoded = try PlayerResponse.decode(data)
        if let poToken { decoded.attachedPoToken = poToken }
        return decoded
    }

    /// What the embedded player's `player` request borrows from its embed page's ytcfg (yt-dlp's
    /// `web_embedded`: `_download_ytcfg` + `_fix_embedded_ytcfg` + `encryptedHostFlags`).
    struct EmbedConfig {
        /// Any non-YouTube page: what the request claims to be embedded on.
        static let embedUrl = "https://www.reddit.com/"
        var client: [String: Any]
        var thirdParty: [String: Any]
        var clientVersion: String?
        var visitorData: String?
        var encryptedHostFlags: String?
    }

    private func embedConfig(videoId: String, profile: StreamClientProfile) async throws -> EmbedConfig {
        var components = URLComponents(string: "https://www.youtube.com/embed/\(videoId)")!
        components.queryItems = [URLQueryItem(name: "html5", value: "1")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(EmbedConfig.embedUrl, forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-us,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let html = String(data: data, encoding: .utf8) else {
            throw StreamResolutionError.noPlayableStream(detail: "embed page HTTP \(status)")
        }
        guard let config = Self.parseEmbedConfig(html) else {
            throw StreamResolutionError.noPlayableStream(detail: "no ytcfg on the embed page")
        }
        return config
    }

    /// Reads every `ytcfg.set({...})` on the page, merged, into an ``EmbedConfig``.
    static func parseEmbedConfig(_ html: String) -> EmbedConfig? {
        var merged: [String: Any] = [:]
        var searchStart = html.startIndex
        while let marker = html.range(of: "ytcfg.set({", range: searchStart..<html.endIndex) {
            let open = html.index(before: marker.upperBound)
            guard let close = matchingBrace(in: html, from: open) else { break }
            let json = String(html[open...close])
            if let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                merged.merge(object) { _, new in new }
            }
            searchStart = html.index(after: close)
        }
        guard let context = merged["INNERTUBE_CONTEXT"] as? [String: Any],
              let client = context["client"] as? [String: Any] else { return nil }
        let flags = ((merged["WEB_PLAYER_CONTEXT_CONFIGS"] as? [String: Any])?["WEB_PLAYER_CONTEXT_CONFIG_ID_EMBEDDED_PLAYER"]
            as? [String: Any])?["encryptedHostFlags"] as? String
        return EmbedConfig(
            client: client,
            thirdParty: context["thirdParty"] as? [String: Any] ?? [:],
            clientVersion: client["clientVersion"] as? String ?? merged["INNERTUBE_CLIENT_VERSION"] as? String,
            visitorData: client["visitorData"] as? String ?? merged["VISITOR_DATA"] as? String,
            encryptedHostFlags: flags
        )
    }

    /// The `}` closing the `{` at `open`, skipping braces inside JSON strings.
    private static func matchingBrace(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func poTokenIfUseful(
        for profile: StreamClientProfile, videoId: String, visitorData: String?
    ) async -> StreamPoToken? {
        guard profile.usesPoToken, let poTokens, let visitorData else { return nil }
        do {
            return try await poTokens.poToken(videoId: videoId, visitorData: visitorData)
        } catch {
            // Walking on without a token beats blocking the whole play path on one.
            streamLog.warning("no PoToken for \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            TrackLog.w(StreamResolver.logCategory, "YouTube: no PoToken for \(profile.id): \(error.localizedDescription)", about: videoId)
            return nil
        }
    }

    /// The `player` request exactly as this client would send it.
    static func playerRequest(
        profile: StreamClientProfile, clientVersion: String, videoId: String, visitorData: String?,
        signatureTimestamp: Int?, auth: StreamAuthSession?, poToken: StreamPoToken?, language: String,
        cpn: String, now: Date, embed: EmbedConfig? = nil
    ) throws -> URLRequest {
        var client: [String: Any] = [
            "clientName": profile.clientName,
            "clientVersion": clientVersion,
            "hl": language,
            "gl": "US",
            "utcOffsetMinutes": 0,
        ]
        if let value = profile.clientScreen { client["clientScreen"] = value }
        if let value = profile.platform { client["platform"] = value }
        if let value = profile.deviceMake { client["deviceMake"] = value }
        if let value = profile.deviceModel { client["deviceModel"] = value }
        if let value = profile.osName { client["osName"] = value }
        if let value = profile.osVersion { client["osVersion"] = value }
        if let value = profile.androidSdkVersion { client["androidSdkVersion"] = value }
        if profile.origin == nil { client["userAgent"] = profile.userAgent }
        if let visitorData { client["visitorData"] = visitorData }

        var user: [String: Any] = ["lockedSafetyMode": false]
        if let dataSyncId = auth?.dataSyncId, !dataSyncId.isEmpty { user["onBehalfOfUser"] = dataSyncId }

        var context: [String: Any] = [
            "client": client,
            "request": ["internalExperimentFlags": [Any](), "useSsl": true] as [String: Any],
            "user": user,
        ]
        if let embed {
            // The embed page's own client block (visitor id, version, form factor) with this
            // request's language, and a third-party embed URL: the embedded player refuses a
            // request that claims to be embedded on YouTube itself.
            var embedClient = embed.client
            embedClient["hl"] = language
            embedClient["clientName"] = profile.clientName
            embedClient["clientVersion"] = clientVersion
            if let visitorData { embedClient["visitorData"] = visitorData }
            context["client"] = embedClient
            var thirdParty = embed.thirdParty
            thirdParty["embedUrl"] = EmbedConfig.embedUrl
            context["thirdParty"] = thirdParty
        }
        var body: [String: Any] = [
            "context": context,
            "videoId": videoId,
            "cpn": cpn,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        if let signatureTimestamp {
            var playback: [String: Any] = [
                "html5Preference": "HTML5_PREF_WANTS",
                "signatureTimestamp": signatureTimestamp,
            ]
            if let origin = profile.origin { playback["referer"] = "\(origin)/watch?v=\(videoId)" }
            if let flags = embed?.encryptedHostFlags { playback["encryptedHostFlags"] = flags }
            body["playbackContext"] = ["contentPlaybackContext": playback]
        }
        if let poToken { body["serviceIntegrityDimensions"] = ["poToken": poToken.playerRequestToken] }

        var components = URLComponents()
        components.scheme = "https"
        components.host = profile.endpointHost
        components.path = "/youtubei/v1/player"
        var query = [URLQueryItem(name: "prettyPrint", value: "false")]
        if profile.endpointHost.hasSuffix("googleapis.com") {
            // NewPipe's shape for this host: a random `t` and the id again.
            query.append(URLQueryItem(name: "t", value: randomToken(length: 12)))
            query.append(URLQueryItem(name: "id", value: videoId))
        }
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(profile.clientNameId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let origin = profile.origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue("\(origin)/", forHTTPHeaderField: "Referer")
        }
        for (name, value) in profile.extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let auth {
            let origin = profile.origin ?? StreamPlayerClient.youtubeOrigin
            request.setValue(origin, forHTTPHeaderField: "X-Origin")
            for (name, value) in auth.headers(origin: origin, now: now) { request.setValue(value, forHTTPHeaderField: name) }
        }
        return request
    }

    // MARK: - Formats

    private func makeStream(
        _ format: PlayerResponse.Format, response: PlayerResponse, profile: StreamClientProfile, videoId: String
    ) async throws -> ExtractedStream {
        var url: URL
        if let direct = format.url.flatMap(URL.init(string:)) {
            url = direct
            if url.streamQueryValue("n") != nil, let cipher {
                url = try await cipher.transformN(in: url)
            }
        } else if let signatureCipher = format.signatureCipher ?? format.cipher {
            guard let cipher else { throw StreamCipherSolver.CipherError.malformedCipher }
            url = try await cipher.decipher(signatureCipher: signatureCipher)
        } else {
            throw StreamCipherSolver.CipherError.malformedCipher
        }
        // The streaming token binds the URL to the session that asked (`pot`).
        if let token = response.attachedPoToken {
            url = url.settingStreamQuery("pot", token.streamingDataToken)
        }
        let mime = format.mimeType ?? ""
        let expires = url.streamQueryValue("expire").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            ?? response.streamingData?.expiresInSeconds.flatMap(TimeInterval.init).map { now().addingTimeInterval($0) }
        return ExtractedStream(
            videoId: videoId,
            url: url,
            itag: format.itag,
            kbps: format.kbps,
            mimeType: mime,
            loudnessDb: response.loudnessDb(for: format),
            contentLength: url.streamQueryValue("clen").flatMap { Int64($0) } ?? format.contentLengthValue,
            approxDurationMs: format.approxDurationMsValue,
            clientName: profile.clientName,
            profileId: profile.id,
            headers: profile.mediaHeaders,
            expiresAt: expires
        )
    }

    // MARK: - Nonces

    static let nonceAlphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// A fresh client-playback-nonce, identifying one play of one track.
    static func newCpn() -> String { randomToken(length: 16) }

    static func randomToken(length: Int) -> String {
        String((0..<length).map { _ in nonceAlphabet.randomElement()! })
    }
}
