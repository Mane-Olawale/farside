import InputModel

/// One touch at one moment, in view points.
public struct TouchSample: Sendable, Equatable {
    public var id: Int
    public var location: Point2
    public var isPencil: Bool

    public init(id: Int, location: Point2, isPencil: Bool = false) {
        self.id = id
        self.location = location
        self.isPencil = isPencil
    }
}

public enum TouchPhase: Sendable { case began, moved, ended, cancelled }

/// What a gesture asks for. Positions and deltas are in view points; the session turns them into
/// display positions and Mac points through the viewport.
public enum GestureAction: Sendable, Equatable {
    /// Move the pointer here, buttons unchanged.
    case move(Point2)
    case button(Button, down: Bool, at: Point2, clickCount: Int)
    /// Positive dx and dy move the content right and down, as the fingers do.
    case scroll(dx: Double, dy: Double, phase: Phase, momentum: Phase)
    case shortcut(Shortcut)
    case toggleToolbar
    /// Local to the iPad: zoom by `factor` around `anchor`, and pan the viewport.
    case zoom(factor: Double, anchor: Point2)
    case pan(Point2)
    /// A long press was recognized; the session can give haptic feedback.
    case longPress

    public enum Button: Sendable, Equatable { case left, right }
    public enum Phase: Sendable, Equatable { case none, began, changed, ended, cancelled }
    /// Multi-finger swipes have no public synthesis API on the Mac, so they become shortcuts
    /// (plan section 9, replay rules).
    public enum Shortcut: Sendable, Equatable { case missionControl, spaceLeft, spaceRight }
}

/// Direct touch mode (plan section 9): the finger acts where it touches.
///
/// | Gesture | Mac action |
/// | --- | --- |
/// | Tap | Move there and left click; taps in quick succession make double and triple clicks |
/// | One-finger drag | Move the pointer without a button |
/// | Long press, then drag | Left button drag |
/// | Long press, then lift | Right click |
/// | Two-finger tap | Right click |
/// | Two-finger drag | Scroll, with momentum after the lift |
/// | Pinch | Zoom and pan the iPad's viewport; nothing is sent |
/// | Three-finger swipe up, left, right | Mission Control, next Space, previous Space |
/// | Three-finger tap | Show or hide the toolbar |
///
/// Apple Pencil presses the left button at once: tap clicks, drag drags.
///
/// A two-finger gesture that changes the fingers' spread is a pinch and stays local; one that only
/// moves them scrolls the Mac. That is how the plan's "two fingers pan while zoomed" and
/// "two-finger drag scrolls" live together: panning happens within the pinch.
///
/// Pure: time is passed in. Call `touches` for UIKit's touch callbacks and `advance` on every
/// display refresh for long presses and momentum.
public struct DirectTouchRecognizer: Sendable {
    public struct Settings: Sendable {
        /// Movement under this, in points, is still a tap or a press.
        public var slop: Double = 10
        public var tapTime: Duration = .milliseconds(250)
        public var longPress: Duration = .milliseconds(500)
        /// Taps closer than this in time and space count up to double and triple clicks.
        public var multiTapTime: Duration = .milliseconds(350)
        public var multiTapDistance: Double = 30
        /// A spread change beyond this fraction makes two fingers a pinch.
        public var pinchThreshold: Double = 0.08
        public var swipeDistance: Double = 60
        /// Momentum: decay per second, and the speed it stops at, in points per second.
        public var momentumDecay: Double = 0.06
        public var momentumMinimum: Double = 20
        public init() {}
    }

    public var settings: Settings

    private enum OneFinger: Sendable {
        /// Down, not yet a drag or a press.
        case pending
        /// Moving the pointer, no button.
        case hovering
        /// Long press recognized; a drag makes it a left drag, a lift a right click.
        case pressed
        /// Left button held.
        case dragging
    }

    private enum TwoFinger: Sendable {
        case pending
        case scrolling
        case pinching
    }

    private enum State: Sendable {
        case idle
        case one(id: Int, start: Point2, startTime: Duration, last: Point2, mode: OneFinger)
        case two(start: Point2, startSpread: Double, startTime: Duration, lastMid: Point2, lastSpread: Double, mode: TwoFinger)
        case three(start: Point2, startTime: Duration, fired: Bool)
        /// The gesture is over; wait for every finger to lift.
        case draining
    }

    private var state = State.idle
    private var touches: [Int: Point2] = [:]
    private var lastTap: (at: Point2, time: Duration, count: Int)?
    private var lastTime: Duration = .zero
    /// Recent scroll deltas, for the release velocity.
    private var scrollHistory: [(time: Duration, delta: Point2)] = []
    private var momentum: (velocity: Point2, last: Duration, began: Bool)?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// When `advance` next has something to do.
    public var nextDeadline: Duration? {
        if momentum != nil { return lastTime }
        if case let .one(_, _, startTime, _, .pending) = state, !isPencilActive { return startTime + settings.longPress }
        return nil
    }

    private var pencil: Set<Int> = []
    private var pencilClicks = 1
    private var isPencilActive: Bool { !pencil.isEmpty }

    // MARK: Touches

    public mutating func touches(_ phase: TouchPhase, _ samples: [TouchSample], at now: Duration) -> [GestureAction] {
        lastTime = now
        var out: [GestureAction] = []
        switch phase {
        case .began:
            out += stopMomentum()
            for sample in samples {
                touches[sample.id] = sample.location
                if sample.isPencil { pencil.insert(sample.id) }
            }
            out += fingersChanged(at: now)
        case .moved:
            for sample in samples where touches[sample.id] != nil { touches[sample.id] = sample.location }
            out += moved(at: now)
        case .ended:
            for sample in samples where touches[sample.id] != nil { touches[sample.id] = sample.location }
            out += lifted(samples.map(\.id), at: now)
        case .cancelled:
            out += cancel()
            for sample in samples {
                touches[sample.id] = nil
                pencil.remove(sample.id)
            }
            if touches.isEmpty { state = .idle }
        }
        return out
    }

    /// Long presses and momentum that are due.
    public mutating func advance(to now: Duration) -> [GestureAction] {
        var out: [GestureAction] = []
        if case let .one(id, start, startTime, last, .pending) = state, !isPencilActive, now - startTime >= settings.longPress {
            state = .one(id: id, start: start, startTime: startTime, last: last, mode: .pressed)
            out.append(.move(start))
            out.append(.longPress)
        }
        if let current = momentum {
            let dt = seconds(now - current.last)
            guard dt > 0 else { lastTime = now; return out }
            let factor = pow(settings.momentumDecay, dt)
            let velocity = Point2(current.velocity.x * factor, current.velocity.y * factor)
            let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
            if speed < settings.momentumMinimum {
                out.append(.scroll(dx: 0, dy: 0, phase: .none, momentum: .ended))
                momentum = nil
            } else {
                out.append(.scroll(dx: velocity.x * dt, dy: velocity.y * dt, phase: .none,
                                   momentum: current.began ? .changed : .began))
                momentum = (velocity, now, true)
            }
        }
        lastTime = now
        return out
    }

    // MARK: State changes

    private mutating func fingersChanged(at now: Duration) -> [GestureAction] {
        let points = Array(touches.values)
        switch (state, points.count) {
        case (.idle, 1):
            let (id, point) = touches.first!
            if isPencilActive {
                // Pencil presses at once (plan section 9, hardware pointer and Pencil).
                state = .one(id: id, start: point, startTime: now, last: point, mode: .dragging)
                pencilClicks = clickCount(at: point, now: now)
                return [.move(point), .button(.left, down: true, at: point, clickCount: pencilClicks)]
            }
            state = .one(id: id, start: point, startTime: now, last: point, mode: .pending)
            return []
        case (.one(_, _, _, _, .pending), 2), (.idle, 2):
            let mid = centroid(points)
            let spread = distance(points[0], points[1])
            state = .two(start: mid, startSpread: spread, startTime: startTime(of: state) ?? now, lastMid: mid, lastSpread: spread, mode: .pending)
            return []
        case (.two(_, _, _, _, _, .pending), 3), (.idle, 3):
            state = .three(start: centroid(points), startTime: startTime(of: state) ?? now, fired: false)
            return []
        case (.one(_, _, _, let last, .dragging), _) where points.count > 1:
            // A second finger during a drag: finish the drag cleanly, then ignore the rest.
            state = .draining
            return [.button(.left, down: false, at: last, clickCount: 1)]
        case (.two(_, _, _, _, _, .scrolling), _) where points.count > 2:
            state = .draining
            return endScroll(cancelled: true)
        default:
            if points.count > 3 { state = .draining }
            if case .one(_, _, _, _, .pending) = state { state = .draining }
            if case .one(_, _, _, _, .hovering) = state { state = .draining }
            if case .one(_, _, _, _, .pressed) = state { state = .draining }
            return []
        }
    }

    private mutating func moved(at now: Duration) -> [GestureAction] {
        switch state {
        case let .one(id, start, startTime, _, mode):
            guard let point = touches[id] else { return [] }
            let far = distance(point, start) > settings.slop
            switch mode {
            case .pending where far:
                state = .one(id: id, start: start, startTime: startTime, last: point, mode: .hovering)
                return [.move(point)]
            case .pending:
                state = .one(id: id, start: start, startTime: startTime, last: point, mode: .pending)
                return []
            case .hovering:
                state = .one(id: id, start: start, startTime: startTime, last: point, mode: .hovering)
                return [.move(point)]
            case .pressed where far:
                state = .one(id: id, start: start, startTime: startTime, last: point, mode: .dragging)
                return [.button(.left, down: true, at: start, clickCount: 1), .move(point)]
            case .pressed:
                return []
            case .dragging:
                state = .one(id: id, start: start, startTime: startTime, last: point, mode: .dragging)
                return [.move(point)]
            }

        case let .two(start, startSpread, startTime, lastMid, lastSpread, mode):
            guard touches.count == 2 else { return [] }
            let points = Array(touches.values)
            let mid = centroid(points)
            let spread = distance(points[0], points[1])
            var next = mode
            var out: [GestureAction] = []
            switch mode {
            case .pending:
                if startSpread > 0, abs(spread / startSpread - 1) > settings.pinchThreshold {
                    next = .pinching
                    out.append(.zoom(factor: spread / startSpread, anchor: mid))
                    out.append(.pan(Point2(mid.x - start.x, mid.y - start.y)))
                } else if distance(mid, start) > settings.slop {
                    next = .scrolling
                    scrollHistory = []
                    out.append(scroll(Point2(mid.x - start.x, mid.y - start.y), phase: .began, at: now))
                }
            case .scrolling:
                out.append(scroll(Point2(mid.x - lastMid.x, mid.y - lastMid.y), phase: .changed, at: now))
            case .pinching:
                if lastSpread > 0 { out.append(.zoom(factor: spread / lastSpread, anchor: mid)) }
                out.append(.pan(Point2(mid.x - lastMid.x, mid.y - lastMid.y)))
            }
            let keepMid = next == .pending ? lastMid : mid
            let keepSpread = next == .pending ? lastSpread : spread
            state = .two(start: start, startSpread: startSpread, startTime: startTime, lastMid: keepMid, lastSpread: keepSpread, mode: next)
            return out

        case let .three(start, startTime, fired):
            guard !fired, touches.count == 3 else { return [] }
            let mid = centroid(Array(touches.values))
            let dx = mid.x - start.x, dy = mid.y - start.y
            guard max(abs(dx), abs(dy)) > settings.swipeDistance else { return [] }
            state = .three(start: start, startTime: startTime, fired: true)
            if abs(dy) > abs(dx) {
                return dy < 0 ? [.shortcut(.missionControl)] : []
            }
            // Fingers moving left bring in the Space on the right, as on a Mac trackpad.
            return [.shortcut(dx < 0 ? .spaceRight : .spaceLeft)]

        case .idle, .draining:
            return []
        }
    }

    private mutating func lifted(_ ids: [Int], at now: Duration) -> [GestureAction] {
        var out: [GestureAction] = []
        switch state {
        case let .one(id, start, _, last, mode) where ids.contains(id):
            switch mode {
            case .pending:
                // Still within the slop: a tap, however long, unless a long press was recognized.
                let count = clickCount(at: start, now: now)
                lastTap = (start, now, count)
                out += [.move(start), .button(.left, down: true, at: start, clickCount: count),
                        .button(.left, down: false, at: start, clickCount: count)]
            case .pressed:
                out += [.move(start), .button(.right, down: true, at: start, clickCount: 1),
                        .button(.right, down: false, at: start, clickCount: 1)]
            case .dragging:
                if isPencilActive {
                    out.append(.button(.left, down: false, at: last, clickCount: pencilClicks))
                    // A Pencil tap counts towards double clicks like a finger tap.
                    if distance(last, start) <= settings.slop { lastTap = (start, now, pencilClicks) }
                } else {
                    out.append(.button(.left, down: false, at: last, clickCount: 1))
                }
            case .hovering:
                break
            }
            state = .draining

        case let .two(start, _, startTime, _, _, mode):
            switch mode {
            case .pending where now - startTime <= settings.tapTime:
                // Two-finger tap: right click where the fingers were.
                out += [.move(start), .button(.right, down: true, at: start, clickCount: 1),
                        .button(.right, down: false, at: start, clickCount: 1)]
            case .scrolling:
                out += endScroll(cancelled: false)
            case .pending, .pinching:
                break
            }
            state = .draining

        case let .three(start, startTime, fired):
            if !fired, now - startTime <= settings.tapTime + .milliseconds(100),
               distance(centroid(Array(touches.values)), start) <= settings.slop * 2 {
                out.append(.toggleToolbar)
            }
            state = .draining

        case .one, .idle, .draining:
            break
        }
        for id in ids {
            touches[id] = nil
            pencil.remove(id)
        }
        if touches.isEmpty { state = .idle }
        return out
    }

    private mutating func cancel() -> [GestureAction] {
        var out: [GestureAction] = []
        switch state {
        case let .one(_, _, _, last, .dragging):
            out.append(.button(.left, down: false, at: last, clickCount: 1))
        case .two(_, _, _, _, _, .scrolling):
            out += endScroll(cancelled: true)
        default:
            break
        }
        out += stopMomentum()
        state = .draining
        return out
    }

    // MARK: Scroll

    private mutating func scroll(_ delta: Point2, phase: GestureAction.Phase, at now: Duration) -> GestureAction {
        scrollHistory.append((now, delta))
        scrollHistory.removeAll { now - $0.time > .milliseconds(100) }
        return .scroll(dx: delta.x, dy: delta.y, phase: phase, momentum: .none)
    }

    private mutating func endScroll(cancelled: Bool) -> [GestureAction] {
        let out: [GestureAction] = [.scroll(dx: 0, dy: 0, phase: cancelled ? .cancelled : .ended, momentum: .none)]
        defer { scrollHistory = [] }
        guard !cancelled, let first = scrollHistory.first, let last = scrollHistory.last else { return out }
        let span = seconds(last.time - first.time)
        guard span > 0.005 else { return out }
        // Velocity over the last 100 ms, leaving out the first sample's own delta.
        let total = scrollHistory.dropFirst().reduce(Point2(0, 0)) { Point2($0.x + $1.delta.x, $0.y + $1.delta.y) }
        let velocity = Point2(total.x / span, total.y / span)
        if (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot() >= settings.momentumMinimum * 2 {
            momentum = (velocity, last.time, false)
        }
        return out
    }

    private mutating func stopMomentum() -> [GestureAction] {
        guard let current = momentum else { return [] }
        momentum = nil
        return current.began ? [.scroll(dx: 0, dy: 0, phase: .none, momentum: .ended)] : []
    }

    // MARK: Helpers

    private func clickCount(at point: Point2, now: Duration) -> Int {
        guard let lastTap, now - lastTap.time <= settings.multiTapTime,
              distance(lastTap.at, point) <= settings.multiTapDistance else { return 1 }
        return min(lastTap.count + 1, 3)
    }

    private func startTime(of state: State) -> Duration? {
        switch state {
        case let .one(_, _, time, _, _): time
        case let .two(_, _, time, _, _, _): time
        case let .three(_, time, _): time
        case .idle, .draining: nil
        }
    }

    private func centroid(_ points: [Point2]) -> Point2 {
        guard !points.isEmpty else { return Point2(0, 0) }
        let sum = points.reduce(Point2(0, 0)) { Point2($0.x + $1.x, $0.y + $1.y) }
        return Point2(sum.x / Double(points.count), sum.y / Double(points.count))
    }

    private func distance(_ a: Point2, _ b: Point2) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

import Foundation
