import Synchronization

/// One stage's admission rule: at most one item in work and one waiting, newest wins
/// (plan section 3, design rule 6, and section 8, frame gating).
///
/// `offer` returns the item if the stage is idle and should start it now. Otherwise the item
/// replaces whatever was waiting. `finish` is called when the stage completes and returns the
/// waiting item to start next, or marks the stage idle.
public final class LatestSlot<Element: Sendable>: Sendable {
    private struct State: ~Copyable {
        var busy = false
        var waiting: Element?
        var replaced = 0
    }

    private let state = Mutex(State())

    public init() {}

    public func offer(_ item: Element) -> Element? {
        state.withLock { s in
            if !s.busy {
                s.busy = true
                return item
            }
            if s.waiting != nil { s.replaced += 1 }
            s.waiting = item
            return nil
        }
    }

    public func finish() -> Element? {
        state.withLock { s in
            if let next = s.waiting {
                s.waiting = nil
                return next
            }
            s.busy = false
            return nil
        }
    }

    /// Items replaced before they started, since the last call.
    public func takeReplacedCount() -> Int {
        state.withLock { s in
            defer { s.replaced = 0 }
            return s.replaced
        }
    }
}
