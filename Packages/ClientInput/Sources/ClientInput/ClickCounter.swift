import InputModel

/// Counts quick clicks of a trackpad or mouse into double and triple clicks, as the Mac would
/// (plan section 9, replay rules: the second down and up carry click state 2).
public struct ClickCounter: Sendable {
    public var interval: Duration
    /// Points the pointer may move between clicks.
    public var distance: Double
    private var last: (at: Point2, time: Duration, count: Int, button: Int)?

    public init(interval: Duration = .milliseconds(350), distance: Double = 6) {
        self.interval = interval
        self.distance = distance
    }

    /// A button went down. Returns its click count, 1 to 3.
    public mutating func down(_ button: Int, at point: Point2, time: Duration) -> Int {
        var count = 1
        if let last, last.button == button, time - last.time <= interval,
           abs(last.at.x - point.x) <= distance, abs(last.at.y - point.y) <= distance {
            count = min(last.count + 1, 3)
        }
        last = (point, time, count, button)
        return count
    }
}
