import InputModel

/// Where the iPad draws the Mac's cursor (plan section 9, local cursor prediction).
///
/// The iPad moves its drawn cursor the moment the finger or pointer moves, without waiting for the
/// Mac. The Mac reports the cursor's position only when something else moved it: a person at the
/// Mac, or an app warping the pointer. A report wins only when it is not older than the iPad's
/// newest move and reports have disagreed for `settle` with no local move in between. Every local
/// move restarts that wait, so while the iPad is moving its own position always wins, and a report
/// that trails the iPad's moves by a few milliseconds never pulls the cursor back.
public struct CursorPredictor: Sendable, Equatable {
    /// Position on the streamed display, 0 to 1. Nil until known, or while the cursor is on
    /// another display.
    public private(set) var position: Point2?
    public var settle: Duration
    /// Differences smaller than this, as a fraction of the display, are the same position.
    public var tolerance: Double

    private var lastSentSeq: UInt32?
    private var disagreeingSince: Duration?

    public init(settle: Duration = .milliseconds(100), tolerance: Double = 0.002) {
        self.settle = settle
        self.tolerance = tolerance
    }

    /// The iPad moved the pointer and sent this move with `seq`.
    public mutating func localMove(to point: Point2, seq: UInt32, at now: Duration) {
        position = point
        lastSentSeq = seq
        disagreeingSince = nil
    }

    /// A report from the Mac. `onDisplay` is false when the cursor is on a display the iPad is not
    /// showing, which hides the drawn cursor. Returns true if the drawn position changed.
    @discardableResult
    public mutating func report(_ point: Point2, lastInputSeq: UInt32, onDisplay: Bool, at now: Duration) -> Bool {
        if let sent = lastSentSeq, Self.isOlder(lastInputSeq, than: sent) { return false }
        guard onDisplay else {
            let changed = position != nil
            position = nil
            disagreeingSince = nil
            return changed
        }
        guard let current = position else {
            // Nothing drawn yet: take the Mac's word at once.
            position = point
            return true
        }
        if abs(current.x - point.x) <= tolerance, abs(current.y - point.y) <= tolerance {
            disagreeingSince = nil
            return false
        }
        let since = disagreeingSince ?? now
        disagreeingSince = since
        guard now - since >= settle else { return false }
        position = point
        disagreeingSince = nil
        return true
    }

    /// Sequence comparison with wrap-around.
    static func isOlder(_ a: UInt32, than b: UInt32) -> Bool {
        a != b && (b &- a) < 0x8000_0000
    }
}
