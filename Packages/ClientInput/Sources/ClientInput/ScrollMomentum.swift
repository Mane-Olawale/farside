import Foundation
import InputModel

/// Momentum after a scroll gesture lifts (plan section 9). UIKit's scroll gestures end at the lift
/// with no momentum phase (spike S7), so the iPad synthesizes it from the release velocity and
/// sends it with momentum phases, as a Mac trackpad would. Used by two-finger touch scrolling and
/// by trackpad and mouse scrolling, so both feel the same.
public struct ScrollMomentum: Sendable {
    /// Fraction of the speed left after one second.
    public var decay: Double
    /// Below this speed, in points per second, momentum ends.
    public var minimum: Double

    private var history: [(time: Duration, delta: Point2)] = []
    private var running: (velocity: Point2, last: Duration, began: Bool)?

    public init(decay: Double = 0.06, minimum: Double = 20) {
        self.decay = decay
        self.minimum = minimum
    }

    public var isRunning: Bool { running != nil }

    /// Records a delta of the live gesture, for the release velocity.
    public mutating func record(_ delta: Point2, at now: Duration) {
        history.append((now, delta))
        history.removeAll { now - $0.time > .milliseconds(100) }
    }

    /// The gesture lifted: starts momentum from the last 100 ms of deltas if they were fast enough.
    public mutating func release() {
        defer { history = [] }
        guard let first = history.first, let last = history.last else { return }
        let span = Self.seconds(last.time - first.time)
        guard span > 0.005 else { return }
        // The first sample's delta happened before the span began.
        let total = history.dropFirst().reduce(Point2(0, 0)) { Point2($0.x + $1.delta.x, $0.y + $1.delta.y) }
        start(velocity: Point2(total.x / span, total.y / span), at: last.time)
    }

    /// Starts momentum from a known velocity, in points per second.
    public mutating func start(velocity: Point2, at now: Duration) {
        history = []
        guard Self.speed(velocity) >= minimum * 2 else { return }
        running = (velocity, now, false)
    }

    /// The next momentum step, or the end, or nil when not running.
    public mutating func advance(to now: Duration) -> GestureAction? {
        guard let current = running else { return nil }
        let dt = Self.seconds(now - current.last)
        guard dt > 0 else { return nil }
        let factor = pow(decay, dt)
        let velocity = Point2(current.velocity.x * factor, current.velocity.y * factor)
        if Self.speed(velocity) < minimum {
            running = nil
            return current.began ? .scroll(dx: 0, dy: 0, phase: .none, momentum: .ended) : nil
        }
        running = (velocity, now, true)
        return .scroll(dx: velocity.x * dt, dy: velocity.y * dt, phase: .none, momentum: current.began ? .changed : .began)
    }

    /// Stops at once, for a new touch. Returns the end if momentum had begun.
    public mutating func stop() -> GestureAction? {
        guard let current = running else { return nil }
        running = nil
        history = []
        return current.began ? .scroll(dx: 0, dy: 0, phase: .none, momentum: .ended) : nil
    }

    static func speed(_ v: Point2) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
