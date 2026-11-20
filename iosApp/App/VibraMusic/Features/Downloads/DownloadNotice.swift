import Downloads
import Foundation

/// What a tap on "Download" finally tells the user above the mini player (MainActivity's
/// `startDownload` toasts): the Wi-Fi hold it refuses to let look like a hang, what a "Download
/// all" actually queued, and nothing for a single track — whose sheet row turns into the progress
/// the queue reports there.
enum DownloadNotice {
    struct Line: Hashable {
        let message: String
        /// An SF Symbol beside the line, or nil for a plain refusal.
        let symbol: String?
    }

    /// A notice for the tap, or nil when the row turning into its progress is feedback enough.
    ///
    /// The Wi-Fi hold speaks first whatever the count: a queued-forever row explains itself once, at
    /// the top, where the tap was. Then a batch says what it started (Android's "Downloading N
    /// songs" / "Already downloaded"); a single fresh track stays silent.
    ///
    /// - Parameter queueHoldingForWiFi: whether the queue this tap lands in is already held (a
    ///   repeat tap during a hold queues nothing new by itself, but its hold is still what it
    ///   means — Android checks the gate again at every tap).
    static func make(for outcome: DownloadRequestOutcome, requested: Int, queueHoldingForWiFi: Bool = false) -> Line? {
        if outcome.waitingForWiFi { return Line(message: L10n.wifiOnlyDownloadRefusal, symbol: "wifi.slash") }
        let asked = outcome.queued + outcome.alreadyQueued
        if queueHoldingForWiFi, asked > 0 { return Line(message: L10n.wifiOnlyDownloadRefusal, symbol: "wifi.slash") }
        guard requested > 1 else { return nil }
        return asked == 0
            ? Line(message: L10n.alreadyDownloaded, symbol: nil)
            : Line(message: L10n.downloadingSongCount(asked), symbol: "arrow.down.circle")
    }

    /// A queued row's label (the song menu's Download row and the manager sheet's row alike): a
    /// queue holding for Wi-Fi says so; anything else just says queued.
    static func queuedRowLabel(waitingForWiFi: Bool) -> String {
        waitingForWiFi ? wifiOnlyWaitingMessage : L10n.queued
    }
}
