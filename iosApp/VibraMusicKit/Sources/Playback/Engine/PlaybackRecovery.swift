import AudioCache
import AVFoundation
import Foundation

/// An error that means "never", not "not just now": the resolver has established that no client,
/// session or source can serve the track (age gate, region block, removed upload).
///
/// The app's stream resolver throws errors conforming to this (retroactively if they come from
/// another module). The engine looks for one anywhere in an error's `NSUnderlyingErrorKey` chain,
/// because by the time a failure reaches it AVFoundation has usually wrapped what the resolver
/// threw — the same reason the Android service unwrapped `PermanentlyUnplayableException` by hand.
public protocol PermanentPlaybackError: Error {
    /// Why the track cannot be played, for the log and the error shown.
    var verdict: String { get }
}

/// A failure the engine reports, and what it did about it.
public struct PlaybackError: Error, Hashable, Sendable, CustomStringConvertible {
    public var itemID: String
    /// Human-readable, e.g. "Playback failed: The file tone.caf is missing".
    public var message: String
    /// Set when the error carried a ``PermanentPlaybackError`` verdict.
    public var isPermanent: Bool
    /// How many times this item has failed since it became current.
    public var attempt: Int

    public init(itemID: String, message: String, isPermanent: Bool = false, attempt: Int = 1) {
        self.itemID = itemID
        self.message = message
        self.isPermanent = isPermanent
        self.attempt = attempt
    }

    public var description: String { message }
}

/// Why the engine is asking for a fresh source.
public enum RecoveryReason: Hashable, Sendable {
    /// The stream died; this is retry number `attempt` (1-based) at the same position. The app
    /// should drop cached bytes and its choice of source before resolving again: an entry filled
    /// from two different files reads fine until playback reaches the seam, and the source that was
    /// picked may be the one handing over something unreadable.
    ///
    /// `networkFault` says the failure was the connection's rather than the bytes' (a dropped
    /// connection, a timeout, a server refusing an expired URL; see ``RecoveryLedger/isNetworkFault(_:)``):
    /// copies already on disk in full say nothing wrong then, and should be kept.
    case retry(attempt: Int, networkFault: Bool = false)
    /// A downloaded file has gone missing from under the app. Return a streaming source for the
    /// same track, or nil when there is no stream behind it (a file imported from Files).
    case missingLocalFile(URL)
    /// The system failed the item, not its bytes or its server (see ``RecoveryLedger/isSystemFault(_:)``),
    /// as a media-services reset does. Nothing is wrong with the copy: keep every cached byte, keep
    /// every refusal as it was, and hand back that same copy to open afresh, or nil when the item's
    /// own source finds it again without resolving.
    case systemFault
}

/// Supplies a fresh source for an item that failed. Returning nil means "no alternative": for a
/// retry the item's own source is opened again (its factory re-resolves), for a missing file the
/// failure stands.
public typealias PlaybackSourceRecovery = @MainActor (PlayableItem, RecoveryReason) async throws -> PlayableItem.Source?

/// What to do about one failure — see ``RecoveryLedger``.
enum RecoveryDecision: Equatable {
    /// Seek-and-reopen at the same position, after ``RecoveryLedger/recoveryDelay``.
    case retry(attempt: Int)
    /// Stop retrying. With a skip reason the queue moves past the track; without one it stays
    /// parked on it with the error showing.
    case giveUp(skipReason: String?, attempt: Int)
}

/// The Android service's recovery bookkeeping (`recoverFrom` / `skipReason`), without the player.
///
/// - Each item gets ``maxRecoveries`` retries, counted from when it became current. The count is
///   *not* reset by the engine's own retry re-opening the item — that is what let one unplayable
///   track loop through twenty-seven resolve walks on Android.
/// - A permanent verdict gives up at once and always skips: a playlist with a run of age-gated
///   tracks should walk straight through them.
/// - Otherwise a track that has used its retries is skipped only if it never made a sound. One
///   that dies mid-song stays put: jumping to the next track would take the song away.
/// - At most ``maxConsecutiveSkips`` tracks in a row are skipped for plain errors. Offline, every
///   track fails identically, and without the limit a dropped connection would quietly walk to the
///   end of the queue. Anything actually playing restores the allowance.
struct RecoveryLedger {
    static let maxRecoveries = 2
    static let maxConsecutiveSkips = 4
    /// The pause before a retry: long enough for the failed source to let go of its cache entry,
    /// short enough to read as a stutter.
    static let recoveryDelay: TimeInterval = 0.35
    /// How many reopens a media-services reset gets with no sound between them, each waiting twice
    /// as long as the last from ``recoveryDelay``: about eleven seconds in all, longer than the
    /// 4.6 s the session's notification was seen to lag the items' failures.
    static let maxResetReopens = 5

    private(set) var attempts: [String: Int] = [:]
    /// The last item that actually made a sound — how "never started" is told from "died mid-song".
    private(set) var audibleItemID: String?
    private(set) var consecutiveErrorSkips = 0
    /// Resets reopened since anything last sounded. Kept apart from ``attempts``: a reset says
    /// nothing about the item, so it neither spends nor refills the item's retries.
    private(set) var resetsSinceSound = 0
    /// The item a retry is about to reopen, so its re-appearance isn't read as a fresh start.
    var retryingItemID: String?

    /// A different item, or the same one for any reason but our own retry, is a clean slate.
    mutating func itemBecameCurrent(_ id: String?) {
        if id == nil || id != retryingItemID { attempts.removeAll() }
        retryingItemID = nil
    }

    /// Sound is out of the speaker: from here a failure is mid-song, and the queue is evidently not
    /// unplayable end to end.
    mutating func itemBecameAudible(_ id: String) {
        audibleItemID = id
        consecutiveErrorSkips = 0
        resetsSinceSound = 0
    }

    /// Books a reset an item reported: how long to wait before reopening, or nil when media services
    /// have stayed down through every reopen and the track should wait for the system or the listener.
    mutating func recordReset() -> TimeInterval? {
        guard resetsSinceSound < Self.maxResetReopens else { return nil }
        defer { resetsSinceSound += 1 }
        return Self.recoveryDelay * pow(2, Double(resetsSinceSound))
    }

    /// The session says media services are back, which is what the reopens were waiting for.
    mutating func mediaServicesCameBack() { resetsSinceSound = 0 }

    func attemptCount(for id: String) -> Int { attempts[id] ?? 0 }

    /// Books a failure a local-file restream or similar source switch should not charge for.
    mutating func forgetAttempts(for id: String) { attempts[id] = nil }

    mutating func recordFailure(itemID id: String, verdict: String?) -> RecoveryDecision {
        let attempt = (attempts[id] ?? 0) + 1
        attempts[id] = attempt
        let givingUp = verdict != nil || attempt > Self.maxRecoveries
        guard givingUp else { return .retry(attempt: attempt) }
        return .giveUp(skipReason: skipReason(verdict: verdict, neverStarted: audibleItemID != id, attempt: attempt), attempt: attempt)
    }

    private mutating func skipReason(verdict: String?, neverStarted: Bool, attempt: Int) -> String? {
        if let verdict { return verdict }
        guard neverStarted else { return nil }
        guard consecutiveErrorSkips < Self.maxConsecutiveSkips else { return nil }
        consecutiveErrorSkips += 1
        return "failed to start after \(attempt) attempts"
    }

    /// The verdict carried anywhere in `error`'s underlying-error chain, or nil.
    static func permanentVerdict(in error: Error?) -> String? {
        for case let permanent as PermanentPlaybackError in chain(of: error) { return permanent.verdict }
        return nil
    }

    /// Whether anything in `error`'s underlying-error chain was the network's fault rather than the
    /// file's (Android's `isNetworkFault`): a connection that dropped or timed out, or a server
    /// refusing the request.
    static func isNetworkFault(_ error: Error?) -> Bool {
        chain(of: error).contains(where: AudioCacheError.isNetworkFault)
    }

    /// Whether media services restarted under `error` (`AVErrorMediaServicesWereReset`): every player
    /// object is dead, whichever item happened to report it.
    static func isMediaServicesReset(_ error: Error?) -> Bool {
        chain(of: error).contains { isAVFoundationError($0, in: [mediaServicesWereReset]) }
    }

    /// Whether `error` is the system's rather than the bytes' or the server's: memory, disk, a decoder
    /// taken away for now, the system interrupting or cancelling the operation, AirPlay's own state.
    /// Reopening the same copy is the cure, and throwing it away buys nothing.
    ///
    /// Everything else AVFoundation can say stays with the bytes: the decode and format errors
    /// (`-11821`, `-11828`, `-11829`, `-11855`), `-11850` from a server, and the catch-all `-11800`,
    /// where a real fault in the file looks the same. A network error under any of them is
    /// ``isNetworkFault(_:)``'s.
    static func isSystemFault(_ error: Error?) -> Bool {
        chain(of: error).contains { isAVFoundationError($0, in: systemFaults) }
    }

    /// `AVErrorMediaServicesWereReset`, by number: the name exists only on iOS and this builds for macOS too.
    private static let mediaServicesWereReset = -11819
    /// From `AVError.h`: out of memory, disk full, session interrupted, the reset, decoder temporarily
    /// unavailable, operation interrupted, AirPlay controller and receiver requiring the internet,
    /// operation cancelled, AirPlay receiver temporarily unavailable.
    private static let systemFaults: Set<Int> = [
        -11801, -11807, -11818, mediaServicesWereReset, -11839, -11847, -11856, -11857, -11878, -11882,
    ]

    private static func isAVFoundationError(_ error: Error, in codes: Set<Int>) -> Bool {
        let error = error as NSError
        return error.domain == AVFoundationErrorDomain && codes.contains(error.code)
    }

    /// `error` and the errors under it (`NSUnderlyingErrorKey`), outermost first, at most eight deep.
    private static func chain(of error: Error?) -> [Error] {
        var found: [Error] = []
        var current: Error? = error
        while let candidate = current, found.count < 8 {
            found.append(candidate)
            let underlying = (candidate as NSError).userInfo[NSUnderlyingErrorKey] as? Error
            if let underlying, (underlying as NSError) === (candidate as NSError) { break }
            current = underlying
        }
        return found
    }
}
