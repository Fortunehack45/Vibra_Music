import Foundation
import VibraMusicCore

// Ports playback/StreamChoice.kt.

/// Which copy of a track is being served, remembered for as long as the track is being served from
/// it.
///
/// A player opens a source many times over one play: the initial read, a seek past the buffer, a
/// resume, and — the one that matters — the continuation fetch when playback reaches the end of
/// what the cache holds. Every one of those goes back through the resolver, and each was free to
/// come back with a *different* answer. Measured on Android: a track started on YouTube with 57
/// seconds pre-buffered, and its continuation fetch resolved to a module's 320 kbps AAC instead.
/// The player was handed the middle of an MP4 where it expected the rest of a WebM and failed with
/// `EOFException`.
///
/// Two sources cannot share one cache entry, and the cache's key cannot tell them apart: it is
/// computed before the resolve, off the `vibramusic://watch?v=…` URI, when which server will answer is
/// not yet known. So the entry does not learn who is filling it; the resolver is held to whoever
/// filled it first. ``QualityUpgrade`` works the same way for the streams it swaps in.
///
/// ### Why a time limit
///
/// A module's stream URL is signed and expires (around five hours on the catalogues in use). Holding
/// one indefinitely would eventually hand the player a dead URL rather than a wrong one, which is no
/// better. ``ttl`` is far inside every expiry seen, so a choice is either reused while it is certainly
/// still good or made again from scratch.
///
/// Thread-safe: the resolver, the read-ahead and the recovery path all call in from their own
/// threads.
public final class StreamChoice: @unchecked Sendable {
    /// The instance the app shares between the resolver, the cache and the player menu.
    public static let shared = StreamChoice()

    /// Long enough to outlast any one play, far short of any signed URL's life.
    public static let ttl: TimeInterval = 15 * 60

    /// How long a track stays off substitution after one broke it.
    ///
    /// Comfortably longer than the recovery it protects — the retry happens within seconds — and
    /// longer than a play of the track, so nothing swaps back mid-song. Short enough that a module
    /// which was briefly returning bad URLs gets another chance in the same listening session.
    public static let refusalPeriod: TimeInterval = 10 * 60

    public static let maxRemembered = 32

    private struct Choice {
        let stream: ResolvedStream
        let at: TimeInterval
        let substituted: Bool
    }

    private let lock = NSLock()
    private var chosen: [String: Choice] = [:]
    private var refusedSubstitutes: [String: TimeInterval] = [:]
    private let now: @Sendable () -> TimeInterval

    public convenience init() {
        self.init(now: { monotonicSeconds() })
    }

    /// `now` is seconds on a monotonic clock; tests drive it by hand.
    init(now: @escaping @Sendable () -> TimeInterval) {
        self.now = now
    }

    /// The stream already serving `videoId`, or nil if this is the first read for it — or the last
    /// one was long enough ago that its URL is no longer worth trusting.
    public func stream(for videoId: String) -> ResolvedStream? {
        lock.withLock {
            guard let choice = chosen[videoId] else { return nil }
            if now() - choice.at > Self.ttl {
                chosen[videoId] = nil
                return nil
            }
            return choice.stream
        }
    }

    /// Records `stream` as the one copy of `videoId` this play is reading.
    ///
    /// - Parameter substituted: whether this came from a source standing in for YouTube rather than
    ///   from YouTube itself. Only the resolver knows, and only ``refuseSubstitutes(for:)`` needs it:
    ///   a substitution that turns out to be unplayable has somewhere else to fall back to, and a
    ///   YouTube stream that fails has not.
    public func remember(_ stream: ResolvedStream, for videoId: String, substituted: Bool) {
        lock.withLock {
            let at = now()
            if chosen.count >= Self.maxRemembered {
                // Drop what can no longer be honoured, and only then the oldest of what can. This
                // used to empty the map, which is the one eviction capable of causing the corruption
                // this type exists to prevent: every live entry is a promise that a half-filled
                // cache entry will be finished by the stream that started filling it. Read-ahead
                // pins the next track before it is reached, so a promise can outlive several other
                // tracks' worth of entries and the blunt version became reachable.
                chosen = chosen.filter { at - $0.value.at <= Self.ttl }
                if chosen.count >= Self.maxRemembered,
                   let oldest = chosen.min(by: { $0.value.at < $1.value.at })?.key {
                    chosen[oldest] = nil
                }
            }
            chosen[videoId] = Choice(stream: stream, at: at, substituted: substituted)
        }
    }

    /// Whether the copy currently serving `videoId` came from a source standing in for YouTube.
    ///
    /// Read on the recovery path, before ``forget(_:)``, to tell a track that died on a
    /// substitution from one that died on YouTube's own stream. The two have opposite right
    /// answers: the first should stop substituting, the second has nothing better to try.
    public func isSubstitute(_ videoId: String) -> Bool {
        lock.withLock { chosen[videoId]?.substituted == true }
    }

    /// Releases `videoId` to be resolved afresh: the queue moved past the track, its cache entry
    /// was discarded after a read error, or ``QualityUpgrade`` replaced the whole stream.
    public func forget(_ videoId: String) {
        _ = lock.withLock { chosen.removeValue(forKey: videoId) }
    }

    /// Stops `videoId` being substituted for ``refusalPeriod`` and sends it to YouTube instead.
    /// Called from the recovery path.
    ///
    /// ``forget(_:)`` alone does not recover from a substitution that refused to serve its bytes.
    /// The search behind it is deterministic and, by the second attempt, cached and fast — so a
    /// retry free to substitute again wins the race against YouTube by the same margin and resolves
    /// straight back to the URL that just failed, three times over, while a working YouTube URL
    /// sits unused.
    ///
    /// It expires rather than lasting the session: the ordinary causes of a well-formed URL that
    /// won't serve (a signature that expired between minting and use, a backend having a bad
    /// minute) clear up by themselves, and holding one forever would cost the lossless copy of
    /// every track it touched.
    public func refuseSubstitutes(for videoId: String) {
        lock.withLock {
            let at = now()
            if refusedSubstitutes.count >= Self.maxRemembered {
                // Same eviction as remember(): emptying the map would lift refusals still in force.
                refusedSubstitutes = refusedSubstitutes.filter { at - $0.value <= Self.refusalPeriod }
                if refusedSubstitutes.count >= Self.maxRemembered,
                   let oldest = refusedSubstitutes.min(by: { $0.value < $1.value })?.key {
                    refusedSubstitutes[oldest] = nil
                }
            }
            refusedSubstitutes[videoId] = at
        }
    }

    /// Whether a substitution has broken `videoId` recently enough to still count.
    public func substitutesRefused(for videoId: String) -> Bool {
        lock.withLock {
            guard let at = refusedSubstitutes[videoId] else { return false }
            if now() - at <= Self.refusalPeriod { return true }
            refusedSubstitutes[videoId] = nil
            return false
        }
    }
}
