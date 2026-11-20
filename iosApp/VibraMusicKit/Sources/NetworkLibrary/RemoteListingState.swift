import VibraMusicCore
import Foundation

// Ports data/remote/RemoteListing.kt: what a remote library page shows for a
// listing. Android's UiState is VibraMusicCore's LoadState here.

/// The load state for one remote library listing.
///
/// A failed listing names its cause: a share that answers with an error is
/// not an empty share, and "no audio files" would send the user hunting
/// through folder paths for a login or network problem.
public enum RemoteListing {
    /// Maps a listing result onto a page state: an empty success reads as the
    /// empty-library message, a failure as its cause.
    public static func state<T>(for listing: Result<[T], Error>, emptyMessage: String) -> LoadState<[T]> {
        switch listing {
        case .success(let items):
            return items.isEmpty ? .error(emptyMessage) : .success(items)
        case .failure(let error):
            return .error(message(for: error))
        }
    }

    /// The user-presentable cause of `error`: its message, or its type name
    /// when it carries nothing worth showing.
    public static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return description
        }
        if let description = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return description
        }
        return String(describing: type(of: error))
    }
}
