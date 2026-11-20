import Darwin
import os

// Hand-off between whoever changes a setting (the main actor, a settings
// observer) and the audio thread that reads it.
//
// The audio thread must never wait, so nothing it touches here takes a lock:
// it reads a 64-bit word with an atomic barrier load, or swaps a buffer index.
// Writers may take a lock among themselves (several settings observers can
// race each other), because the audio thread never contends for it.
//
// `Synchronization.Atomic` would be the obvious tool, but it needs iOS 18 /
// macOS 15 and this package deploys to iOS 17 / macOS 14. libkern's OSAtomic
// barrier functions are available on both, compile to the same hardware
// atomics, and never block.

/// A 64-bit word shared between a control thread and the audio thread.
final class AtomicWord: @unchecked Sendable {
    private let cell: UnsafeMutablePointer<Int64>

    init(_ value: Int64 = 0) {
        cell = .allocate(capacity: 1)
        cell.initialize(to: value)
    }

    deinit {
        cell.deallocate()
    }

    /// Full-barrier load. Adding zero is the cheapest barrier read OSAtomic offers.
    @inline(__always)
    func load() -> Int64 {
        OSAtomicAdd64Barrier(0, cell)
    }

    @inline(__always)
    func store(_ value: Int64) {
        exchange(value)
    }

    /// Stores [value] and returns what it replaced.
    @inline(__always)
    @discardableResult
    func exchange(_ value: Int64) -> Int64 {
        while true {
            let current = load()
            if OSAtomicCompareAndSwap64Barrier(current, value, cell) { return current }
        }
    }
}

/// Two `Float`s published together, so a reader can never see one half of an update.
enum FloatPair {
    @inline(__always)
    static func pack(_ first: Float, _ second: Float) -> Int64 {
        Int64(bitPattern: UInt64(first.bitPattern) << 32 | UInt64(second.bitPattern))
    }

    @inline(__always)
    static func unpack(_ word: Int64) -> (Float, Float) {
        let bits = UInt64(bitPattern: word)
        return (Float(bitPattern: UInt32(truncatingIfNeeded: bits >> 32)),
                Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
    }
}

/// A block of `Float`s handed from writers to one reader without the reader ever waiting.
///
/// A classic triple buffer: the reader owns one slot, the writers own another,
/// and the third sits between them. Publishing fills the writers' slot and
/// swaps it into the middle; acquiring swaps the middle out to the reader when
/// something new has arrived. Every slot is touched by one side at a time, so
/// there is no torn read and no data race, and the reader's cost is one atomic
/// load per block (plus one swap when a change is waiting).
final class FloatTripleBuffer: @unchecked Sendable {
    let count: Int

    private let slots: UnsafeMutablePointer<Float>

    /// Index of the middle slot in the low two bits; bit 2 set when it holds an unread update.
    private let middle: AtomicWord

    /// The reader's slot. Only ever touched by the reader.
    private let readerSlot: UnsafeMutablePointer<Int>

    /// The writers' slot, and the lock that serialises writers against each other.
    private let writerSlot = OSAllocatedUnfairLock(initialState: 2)

    private static let fresh: Int64 = 4

    init(initial values: [Float]) {
        let count = values.count
        let slots = UnsafeMutablePointer<Float>.allocate(capacity: count * 3)
        for slot in 0..<3 {
            (slots + slot * count).initialize(from: values, count: count)
        }
        self.count = count
        self.slots = slots
        middle = AtomicWord(1)
        readerSlot = .allocate(capacity: 1)
        readerSlot.initialize(to: 0)
    }

    deinit {
        slots.deallocate()
        readerSlot.deallocate()
    }

    /// Control side: [fill] writes the new values into the slot it is handed.
    func publish(_ fill: (UnsafeMutablePointer<Float>) -> Void) {
        writerSlot.withLock { back in
            fill(slots + back * count)
            let previous = middle.exchange(Int64(back) | Self.fresh)
            back = Int(previous & 3)
        }
    }

    /// Audio side: the newest values, and whether they changed since the last call.
    ///
    /// The pointer stays valid, and unchanged, until the reader acquires again.
    @inline(__always)
    func acquire() -> (values: UnsafePointer<Float>, isNew: Bool) {
        guard middle.load() & Self.fresh != 0 else {
            return (UnsafePointer(slots + readerSlot.pointee * count), false)
        }
        let previous = middle.exchange(Int64(readerSlot.pointee))
        readerSlot.pointee = Int(previous & 3)
        return (UnsafePointer(slots + readerSlot.pointee * count), true)
    }
}
