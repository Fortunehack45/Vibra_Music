import Foundation

/// One value derived from a view's input, worked out again only when that input changes.
///
/// Held in `@State` by a page whose body re-runs for reasons that leave its list alone: a filter
/// box's focus, a selection, another page filling in on the same store, the queue moving on. A plain
/// class rather than an observable one, so filling it in while the body runs invalidates nothing.
/// Arrays compare by buffer before element by element, so the same list handed back by a store
/// costs next to nothing to check.
@MainActor
final class ViewMemo<Input: Equatable, Output> {
    private var last: (input: Input, output: Output)?

    /// `compute(input)`, or what it gave last time if `input` is the same as it was then.
    func value(for input: Input, _ compute: (Input) -> Output) -> Output {
        if let last, last.input == input { return last.output }
        let output = compute(input)
        last = (input, output)
        return output
    }
}
