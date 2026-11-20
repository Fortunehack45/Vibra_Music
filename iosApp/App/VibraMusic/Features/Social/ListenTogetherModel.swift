import VibraMusicCore
import Foundation
import InnerTube
import ListenTogether
import Observation

// Ports the state ListenTogetherScreen.kt keeps in `remember { … }` — the code being typed, the
// open sheet, the last failure, the nickname, the size a new party is made at, the invite waiting
// for a server-switch consent — together with the flows it collects from `ListenTogether`. The
// screen's lambdas (`openPartyPreview`, `showInviteAfterCreate`, the confirm sheet's join) are the
// methods here, so the order of their steps can be tested without a window.

/// What the Listen Together screen needs from the party layer.
///
/// The live one wraps ``ListenTogetherSession`` and the party client (``LiveListenTogetherService``);
/// tests hand in a fake so the screen's decisions can be checked offline.
@MainActor
protocol ListenTogetherService: AnyObject {
    /// The party as the client last reported it. Read through an `@Observable`, so a view reading
    /// it redraws when it changes.
    var state: PartySessionState { get }
    /// The party's recent events, newest first.
    var activity: [PartyActivity] { get }
    /// Whether a YouTube Music account is signed in (a party needs one).
    var signedIn: Bool { get }
    /// This device's own picture for the party, if the account has one.
    var myAvatarUrl: String? { get }
    /// The built-in server's address. Never shown; only compared against.
    var defaultServer: String { get }
    /// The typed server address, or `""` when the built-in one is used.
    var customServer: String { get }
    var nickname: String { get }
    func setNickname(_ value: String)

    /// Whether there is any server to talk to at all.
    func hasServer() async -> Bool
    func serverConnection() async -> PartyServerConnectionState
    func activePartyServer() async -> String?
    func effectiveIdleServer() async -> String
    func refreshServerHealth() async
    /// Opens the socket for a membership that outlived the process.
    func ensureConnected() async
    func partyPositionMs() async -> Int64?

    func preview(code: String, server: String?) async -> Result<PartyPreview, PartyClientError>
    func createParty(nickname: String, maxMembers: Int) async -> Result<String, PartyClientError>
    func joinParty(code: String, nickname: String) async -> Result<String, PartyClientError>
    func switchParty(server: String, code: String, nickname: String) async -> PartySwitchResult
    func leaveParty() async

    func kick(memberId: String)
    func setHostOnlyControl(_ enabled: Bool)
    func setMaxMembers(_ value: Int)

    func setCustomServer(_ normalizedUrl: String) async -> PartyServerConnectionState
    func probe(_ normalizedUrl: String) async -> PartyProbeResult
}

/// Which of the party sheets is up, if any (ListenTogetherSheets.kt's `PartySheet`).
///
/// One value rather than a flag each: they are alternatives, and a set of flags that must not both
/// be true is a bug waiting for the one path that sets the second without clearing the first.
enum PartySheet: Identifiable, Hashable {
    /// Name and size, then create.
    case create
    /// Six cells, to look a party up.
    case joinCode
    /// Who is in the party this device is about to commit a slot to. `server` rides along because
    /// an invite may point at somebody's own server, and the join has to go where the preview came
    /// from.
    case confirm(PartyPreview, server: String?)
    /// A link and a square, for getting somebody else in.
    case invite

    var id: String {
        switch self {
        case .create: return "create"
        case .joinCode: return "join"
        case .confirm(let preview, let server): return "confirm:\(preview.code):\(server ?? "")"
        case .invite: return "invite"
        }
    }
}

/// An invite that names a different server than this device is using, waiting for consent.
struct PendingServerSwitch: Hashable, Identifiable {
    var code: String
    /// `""` means back to the built-in server.
    var server: String

    var id: String { "\(code)@\(server)" }
    var isSwitchToOfficial: Bool { server.isEmpty }
}

@MainActor
@Observable
final class ListenTogetherModel {
    @ObservationIgnored let service: ListenTogetherService

    /// Six characters at most, letters and digits, upper-cased as typed.
    var codeInput = ""
    var busy = false
    /// The last attempt's message. Shown inside the sheet that produced it, or under the page when
    /// no sheet is up.
    var failure: String?
    var nickname: String
    /// The size a new party is made at, 2…10.
    var maxMembers = PartyLimits.defaultMaxMembers
    var pendingServerSwitch: PendingServerSwitch?
    var sheet: PartySheet?
    /// The server health line the row and the top bar read.
    private(set) var connection: PartyServerConnectionState = .checking
    private(set) var customServer: String
    private(set) var hasServer = true
    /// The server the running party lives on, for the invite link.
    private(set) var activeServer: String?
    @ObservationIgnored private var handlingInvite = false
    /// An invite that arrived while a lookup or join of the user's own was running: taken when
    /// that finishes, instead of waiting for the page to be reopened.
    @ObservationIgnored private var heldInvite: (code: String, server: String?)?

    /// How long the newly made party sits on screen before the invite rises over it: long enough
    /// to be a page that was arrived at, short enough that nobody has started reading it yet.
    @ObservationIgnored var inviteDelay: Duration = .seconds(1)
    /// How long a sheet takes to go down, so the invite is a fresh sheet sliding up rather than a
    /// swap of contents under a drawer that never moved.
    @ObservationIgnored var sheetDismissDelay: Duration = .milliseconds(350)

    init(service: ListenTogetherService) {
        self.service = service
        nickname = service.nickname
        customServer = service.customServer
    }

    // MARK: What the page reads

    var state: PartySessionState { service.state }
    var activity: [PartyActivity] { service.activity }
    var signedIn: Bool { service.signedIn }
    var inParty: Bool { state.inParty }
    var isHost: Bool { state.you?.isHost == true }
    var myAvatarUrl: String? { service.myAvatarUrl }

    /// Create and Join are offered only to a signed-in device that has a server.
    var canStart: Bool { signedIn && hasServer }

    /// The line under the page: the last failure, else the party's own error — only while no
    /// sheet is up, since a sheet already shows its failure and a line under it cannot be read.
    var pageError: String? {
        guard sheet == nil else { return nil }
        return failure ?? state.error
    }

    /// The host's "−": never below two, nor below the people already in.
    var canShrinkParty: Bool { state.maxMembers > max(2, state.members.count) }
    var canGrowParty: Bool { state.maxMembers < PartyLimits.maxMembers }

    /// The invite URL for `code`, pointing at whichever server holds the party.
    func inviteLink(for code: String) -> String {
        guard let host = activeServer, host != service.defaultServer else {
            return JamInviteLink.url(code: code)
        }
        return JamInviteLink.url(code: code, customServer: host)
    }

    /// What the system share sheet sends: the link and the spoken-aloud code together.
    var shareMessage: String? {
        guard let code = state.code else { return nil }
        return inviteLink(for: code) + "\n\n" + L10n.listenTogetherShareText(code)
    }

    // MARK: Lifecycle

    /// The screen appeared: a membership outlives the process, the socket does not, so it is
    /// opened now rather than on every cold start. The server's health is looked at too.
    func appeared() async {
        await service.ensureConnected()
        await refreshServer()
    }

    func refreshServer() async {
        await service.refreshServerHealth()
        connection = await service.serverConnection()
        hasServer = await service.hasServer()
        activeServer = await service.activePartyServer()
        customServer = service.customServer
    }

    /// Re-reads what the store and client hold after something changed them elsewhere.
    func syncFromService() async {
        activeServer = await service.activePartyServer()
        customServer = service.customServer
        connection = await service.serverConnection()
    }

    // MARK: Nickname and code

    func setNickname(_ value: String) {
        nickname = String(value.prefix(80))
        service.setNickname(nickname)
    }

    /// Typing is the retry: the old verdict goes as soon as the code is being corrected.
    func setCode(_ typed: String) {
        codeInput = String(typed.filter { $0.isLetter || $0.isNumber }.uppercased().prefix(PartyLimits.codeLength))
        failure = nil
    }

    func setNewPartySize(_ value: Int) {
        maxMembers = min(max(value, 2), PartyLimits.maxMembers)
    }

    // MARK: Sheets

    func openCreate() {
        failure = nil
        sheet = .create
    }

    func openJoin() {
        failure = nil
        sheet = .joinCode
    }

    func openInvite() {
        sheet = .invite
    }

    /// A sheet closed with its message unread is still read.
    func sheetDismissed() {
        sheet = nil
        failure = nil
    }

    // MARK: Create, preview, join

    func createParty() async {
        busy = true
        failure = nil
        let result = await service.createParty(nickname: nickname, maxMembers: maxMembers)
        busy = false
        if case .failure(let error) = result {
            failure = error.displayMessage
            await takeHeldInvite()
            return
        }
        activeServer = await service.activePartyServer()
        await showInviteAfterCreate()
        await takeHeldInvite()
    }

    /// Hands the create sheet over to the invite sheet with the party page visible in between: the
    /// create sheet goes down, a beat with nothing over the page (which has just become a
    /// different page), and only then the invite — unless something else was opened meanwhile,
    /// since a drawer nobody asked for is worse than not being offered the link.
    func showInviteAfterCreate() async {
        sheet = nil
        try? await Task.sleep(for: sheetDismissDelay + inviteDelay)
        if sheet == nil, inParty { sheet = .invite }
    }

    /// Taken once the flow that held it up has put its own result on screen, so the two don't
    /// race for the sheet: the invite, being the later request, is the one left showing.
    private func takeHeldInvite() async {
        guard let held = heldInvite else { return }
        heldInvite = nil
        await handleInvite(code: held.code, server: held.server)
    }

    /// Looks a party up and puts its faces on screen rather than joining it. Both doors in — a
    /// tapped link and six characters typed — come through here.
    func openPartyPreview(code: String, server: String?) async {
        busy = true
        failure = nil
        let result = await service.preview(code: code, server: server)
        busy = false
        switch result {
        case .success(let preview): sheet = .confirm(preview, server: server)
        case .failure(let error): failure = error.displayMessage
        }
        await takeHeldInvite()
    }

    func submitCode() async {
        guard codeInput.count == PartyLimits.codeLength else { return }
        await openPartyPreview(code: codeInput, server: nil)
    }

    /// The confirm sheet's Join. A server named on the invite always wins; otherwise, already being
    /// in a party means a switch, which keeps this device where it is if the new party turns it
    /// away.
    func confirmJoin(_ preview: PartyPreview, server: String?) async {
        busy = true
        failure = nil
        let problem: String?
        if server != nil || inParty {
            let target = PartyServerConfig.resolveSwitchTarget(
                inviteServer: server, customServer: service.customServer,
                idleServer: await service.effectiveIdleServer()
            )
            switch await service.switchParty(server: target, code: preview.code, nickname: nickname) {
            case .success: problem = nil
            case .targetFailedRecovered(_, let error): problem = error
            case .targetFailedNoParty(let error): problem = error
            }
        } else {
            switch await service.joinParty(code: preview.code, nickname: nickname) {
            case .success: problem = nil
            case .failure(let error): problem = error.displayMessage
            }
        }
        failure = problem
        busy = false
        if problem == nil {
            codeInput = ""
            sheet = nil
            await syncFromService()
        }
        await takeHeldInvite()
    }

    func leave() async {
        await service.leaveParty()
        await syncFromService()
    }

    // MARK: Host controls

    func setPartySize(_ value: Int) { service.setMaxMembers(value) }
    func setHostOnlyControl(_ enabled: Bool) { service.setHostOnlyControl(enabled) }
    func kick(_ member: PartyMember) { service.kick(memberId: member.memberId) }

    // MARK: Invites

    /// An invite link was opened. A link tap is already an explicit request to join, so it goes
    /// straight to the confirm sheet — unless it names a different server than this device is
    /// using, which needs consent first. Returns whether the invite was consumed (one that lands
    /// mid-lookup is held and taken as soon as the lookup ends); a signed-out device keeps it
    /// waiting (and the code filled in) while the sign-in page is open.
    @discardableResult
    func handleInvite(code: String, server: String?) async -> Bool {
        codeInput = code
        // One at a time: the page hands the invite over from more than one place (appearing, a
        // sign-in finishing, the router's value changing), and `busy` is only raised once the
        // server lookups below have been awaited — two callers would both get past it and look
        // the same party up twice. The second is told "not taken"; the first one takes it.
        guard signedIn, !handlingInvite else { return false }
        if busy {
            heldInvite = (code, server)
            return true
        }
        handlingInvite = true
        defer { handlingInvite = false }
        var activeRaw = await service.activePartyServer()
        if activeRaw == nil { activeRaw = await service.effectiveIdleServer() }
        let active = PartyServerConfig.normalizeServerBase(activeRaw ?? "")
        let target = server.map(PartyServerConfig.normalizeServerBase)

        if let target, !target.isEmpty {
            if target.caseInsensitiveCompare(active) != .orderedSame {
                pendingServerSwitch = PendingServerSwitch(code: code, server: target)
                return true
            }
        } else if !service.customServer.isEmpty {
            pendingServerSwitch = PendingServerSwitch(code: code, server: "")
            return true
        }

        if state.code?.caseInsensitiveCompare(code) == .orderedSame { return true }
        await openPartyPreview(code: code, server: target)
        return true
    }

    /// The server-switch dialog's "Switch and join": consent to talk to another server at all. The
    /// next step is the same confirm sheet as any other invite, not a join.
    func acceptServerSwitch() async {
        guard let pending = pendingServerSwitch else { return }
        pendingServerSwitch = nil
        await openPartyPreview(code: pending.code, server: pending.server.isEmpty ? nil : pending.server)
    }

    func declineServerSwitch() {
        pendingServerSwitch = nil
    }
}

// MARK: - Presentation helpers

extension PartyServerURLError {
    /// ListenTogetherScreen.kt's `ServerUrlError.toMessageRes`.
    var message: String {
        switch self {
        case .whitespace: return L10n.listenTogetherErrWhitespace
        case .invalidScheme, .invalidHost, .malformed: return L10n.listenTogetherInvalidServerUrl
        case .invalidPort: return L10n.listenTogetherErrInvalidPort
        case .invalidPath: return L10n.listenTogetherErrInvalidPath
        case .hasQuery: return L10n.listenTogetherErrNoQuery
        case .hasFragment: return L10n.listenTogetherErrNoFragment
        }
    }
}

enum PartyText {
    /// `m:ss`, as the party's position is read out (ListenTogetherScreen.kt's `elapsed`).
    static func elapsed(_ ms: Int64) -> String {
        let total = max(ms / 1000, 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Whether this device is actually keeping up, and how well (`connectionLine`).
    static func connectionLine(_ state: PartySessionState) -> String {
        if state.connection != .live { return L10n.listenTogetherReconnecting }
        // Live, but the clock not yet measured: the position is the server's last word on it.
        if !state.clockSynced { return L10n.listenTogetherSyncingClock }
        return L10n.listenTogetherInSync(Int(state.roundTripMs))
    }

    /// The subtitle of the Now playing row: artist · position / duration, then the sync line.
    static func nowPlayingSubtitle(_ state: PartySessionState, positionMs: Int64) -> String {
        let connection = connectionLine(state)
        guard let track = state.playback.track else { return connection }
        var line = ""
        if !track.artist.isEmpty { line += track.artist + " · " }
        line += elapsed(positionMs)
        if let duration = track.durationMs { line += " / " + elapsed(duration) }
        return line + "\n" + connection
    }

    /// One line of the activity log: `[HH:mm:ss] who: what`.
    static func activityLine(_ entry: PartyActivity, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        let stamp = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(entry.atMs) / 1000))
        return "[\(stamp)] \(entry.by): \(entry.detail.isEmpty ? entry.action : entry.detail)"
    }

    /// The first letter of a name, for a face with no picture.
    static func initial(_ name: String) -> String {
        name.first.map { String($0).uppercased() } ?? ""
    }
}

// MARK: - Live service

/// The party layer as the app has it: ``ListenTogetherSession`` for membership and state, the
/// client for health and the playhead, the store for the server address and nickname.
@MainActor
final class LiveListenTogetherService: ListenTogetherService {
    private let session: ListenTogetherSession
    private let store: PartyServerStore
    private let accounts: YouTubeAccountManager
    private let urlSession: URLSession
    private var client: PartyClient { session.client }

    init(session: ListenTogetherSession, store: PartyServerStore, accounts: YouTubeAccountManager, urlSession: URLSession = VibraMusicHTTP.session) {
        self.session = session
        self.store = store
        self.accounts = accounts
        self.urlSession = urlSession
    }

    convenience init(app: AppModel) {
        self.init(session: app.listenTogether, store: app.partyStore, accounts: app.accounts, urlSession: VibraMusicHTTP.session)
    }

    var state: PartySessionState { session.state }
    var activity: [PartyActivity] { session.activity }
    var signedIn: Bool { accounts.isSignedIn }
    var myAvatarUrl: String? { accounts.account?.thumbnailUrl }
    var defaultServer: String { store.defaultServer }
    var customServer: String { store.customServer }
    var nickname: String { store.nickname }
    func setNickname(_ value: String) { store.setNickname(value) }

    func hasServer() async -> Bool { await client.hasServer }
    func serverConnection() async -> PartyServerConnectionState { await client.serverConnection }
    func activePartyServer() async -> String? { await client.activePartyServer }
    func effectiveIdleServer() async -> String { await client.effectiveIdleServer }
    func refreshServerHealth() async { await client.setScreenActive(true) }
    func ensureConnected() async {
        session.start()
        await client.ensureConnected()
    }
    func partyPositionMs() async -> Int64? { await client.partyPositionMs() }

    func preview(code: String, server: String?) async -> Result<PartyPreview, PartyClientError> {
        await session.preview(code: code, server: server)
    }

    func createParty(nickname: String, maxMembers: Int) async -> Result<String, PartyClientError> {
        await session.createParty(nickname: nickname, maxMembers: maxMembers)
    }

    func joinParty(code: String, nickname: String) async -> Result<String, PartyClientError> {
        await session.joinParty(code: code, nickname: nickname)
    }

    func switchParty(server: String, code: String, nickname: String) async -> PartySwitchResult {
        await session.switchParty(server: server, code: code, nickname: nickname)
    }

    func leaveParty() async { await session.leaveParty() }
    func kick(memberId: String) {
        guard let member = session.members.first(where: { $0.memberId == memberId }) else { return }
        session.kick(member)
    }
    func setHostOnlyControl(_ enabled: Bool) { session.setHostOnlyControl(enabled) }
    func setMaxMembers(_ value: Int) { session.setMaxMembers(value) }

    func setCustomServer(_ normalizedUrl: String) async -> PartyServerConnectionState {
        if normalizedUrl.isEmpty {
            // Back to the built-in server: the client's setter takes canonical URLs only.
            store.setCustomServer("")
            await client.refreshServerHealth()
            return await client.serverConnection
        }
        return await client.setCustomServerUrl(normalizedUrl)
    }

    /// PartyServerEditor.kt's Test: `GET /healthz`, 8 s, and the body has to say `"ok":true`.
    /// Longer than the background check, because this one was asked for and is being watched.
    func probe(_ normalizedUrl: String) async -> PartyProbeResult {
        await PartyHealthProbe.probe(normalizedUrl, defaultServer: store.defaultServer, session: urlSession)
    }
}

/// The Test button's health check (`probeHealthWithLatency` with the editor's 8 s timeout). The
/// client's own probe is internal to the module, so the editor makes the same request here.
enum PartyHealthProbe {
    static let timeout: TimeInterval = 8

    static func probe(_ server: String, defaultServer: String, session: URLSession) async -> PartyProbeResult {
        let base = PartyServerConfig.resolveHttpBase(server, defaultServer: defaultServer)
        guard !base.isEmpty, let url = URL(string: "\(base)/healthz") else { return PartyProbeResult(isOnline: false) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let start = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  String(decoding: data, as: UTF8.self).contains("\"ok\":true")
            else { return PartyProbeResult(isOnline: false) }
            let elapsed = ContinuousClock.now - start
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            return PartyProbeResult(isOnline: true, latencyMs: max(0, ms))
        } catch {
            return PartyProbeResult(isOnline: false)
        }
    }
}
