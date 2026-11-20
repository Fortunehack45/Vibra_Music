import Foundation
import VibraMusicCore
@testable import PlaybackPolicy

/// A source layer driven by hand: answers with the first candidate the policy accepts.
final class FakeUpgradeSearch: QualityUpgradeSearching, @unchecked Sendable {
    struct Call: Hashable {
        var target: QualityUpgrade.Target
        var servedBy: String?
        var playing: StreamFormat? = nil
    }

    private let lock = NSLock()
    private var _canSubstitute: Bool
    private var _candidates: [ResolvedStream]
    private var _error: Error?
    private var _delay: Duration?
    private var _calls: [Call] = []
    private var _refused: [ResolvedStream] = []

    init(canSubstitute: Bool = true, candidates: [ResolvedStream] = []) {
        _canSubstitute = canSubstitute
        _candidates = candidates
    }

    var canSubstituteForYouTube: Bool {
        get { lock.withLock { _canSubstitute } }
        set { lock.withLock { _canSubstitute = newValue } }
    }

    var candidates: [ResolvedStream] {
        get { lock.withLock { _candidates } }
        set { lock.withLock { _candidates = newValue } }
    }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    /// How long a search takes; cancellation during it throws `CancellationError`.
    var delay: Duration? {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    private var _clears = 0
    /// How many times the completed answers were dropped.
    var clears: Int { lock.withLock { _clears } }

    func clearCompletedAnswers() async {
        lock.withLock { _clears += 1 }
    }

    var calls: [Call] { lock.withLock { _calls } }
    /// Candidates the policy turned down, in the order offered.
    var refused: [ResolvedStream] { lock.withLock { _refused } }

    func findUpgrade(
        for target: QualityUpgrade.Target,
        playing: StreamFormat?,
        excluding servedBy: String?,
        isWorthSwapping: @escaping @Sendable (ResolvedStream) -> Bool
    ) async throws -> ResolvedStream? {
        let (delay, error, candidates) = lock.withLock { () -> (Duration?, Error?, [ResolvedStream]) in
            _calls.append(Call(target: target, servedBy: servedBy, playing: playing))
            return (_delay, _error, _candidates)
        }
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        for candidate in candidates where candidate.sourceConfigId != servedBy {
            if isWorthSwapping(candidate) { return candidate }
            lock.withLock { _refused.append(candidate) }
        }
        return nil
    }
}

/// A clock tests move by hand, in seconds.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval

    init(_ start: TimeInterval = 1_000) { seconds = start }

    var now: TimeInterval { lock.withLock { seconds } }

    func advance(by delta: TimeInterval) {
        lock.withLock { seconds += delta }
    }

    var reader: @Sendable () -> TimeInterval { { [self] in now } }
}

enum Streams {
    static func make(
        _ host: String,
        codec: String?,
        kbps: Int? = nil,
        durationSeconds: Int? = nil,
        sourceConfigId: String? = nil,
        origin: StreamOrigin = .addon
    ) -> ResolvedStream {
        ResolvedStream(
            url: URL(string: "https://\(host)/track")!,
            origin: origin,
            format: StreamFormat(codec: codec, kbps: kbps),
            durationSeconds: durationSeconds,
            sourceConfigId: sourceConfigId
        )
    }

    static let youTubeOpus = make("rr1---sn.googlevideo.com", codec: "opus", kbps: 160, origin: .youtube)
    static let youTubeAAC = make("rr1---sn.googlevideo.com", codec: "aac", kbps: 128, origin: .youtube)
}

extension QualityUpgrade {
    /// An instance with its own NerdStats and StreamChoice, asking for `tier`.
    static func testInstance(
        search: FakeUpgradeSearch = FakeUpgradeSearch(),
        tier: StreamRequest.Tier = .lossless,
        nerdStats: NerdStats = NerdStats(),
        streamChoice: StreamChoice = StreamChoice()
    ) -> QualityUpgrade {
        QualityUpgrade(
            search: search,
            requestForNow: { StreamRequest(tier: tier) },
            streamChoice: streamChoice,
            nerdStats: nerdStats
        )
    }
}
