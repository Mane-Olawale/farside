import AppKit
import HostCapture
import InputModel
import os
import SessionTransport
import WireProtocol

/// Sends the Mac's cursor to the iPad (plan section 10, cursor).
///
/// - Shape: polled about 30 times a second. Each distinct shape goes once as `CursorShape`, then
///   `CursorState` names the shape in use.
/// - Position: polled 60 times a second, and sent only while the real cursor is not where this
///   session last put it, for example because someone moved the Mac's own mouse or an app warped
///   the pointer. A single differing poll is ignored (the iPad's own move may still be landing),
///   and reports stop once the position has stayed put long enough for the iPad to snap to it.
@MainActor
final class HostCursor {
    private let log = Logger(subsystem: "app.farside.host", category: "cursor")
    private let shapes = CursorShapes()
    private let session: HostSession
    private let media: HostMedia
    private var shapeTimer: Timer?
    private var positionTimer: Timer?
    private var sentState: (id: UInt32, visible: Bool)?
    private var foreignPolls = 0
    private var lastReported: Point2?
    private var sameReports = 0

    /// Reports of one unchanged position before going quiet: 12 at 60 Hz is 200 ms, twice the
    /// iPad's 100 ms wait, so one lost report does not matter.
    private static let reportsPerPosition = 12

    /// Whether the system cursor's shape can be read on this Mac. If not, capture draws the
    /// cursor into the video and the iPad draws none.
    static func shapesWork() -> Bool { CursorShapes().current() != nil }

    init(session: HostSession, media: HostMedia) {
        self.session = session
        self.media = media
    }

    func start() {
        guard shapeTimer == nil else { return }
        if media.cursorInVideo {
            session.sendCursor(.cursorState(.with { $0.visible = false }))
            log.info("cursor drawn into the video: its shape cannot be read")
        } else {
            shapeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollShape() }
            }
            pollShape()
        }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPosition() }
        }
        // The iPad needs to know where the cursor starts.
        foreignPolls = 1
    }

    func stop() {
        shapeTimer?.invalidate()
        positionTimer?.invalidate()
        shapeTimer = nil
        positionTimer = nil
        shapes.reset()
        sentState = nil
    }

    private func pollShape() {
        guard let (shape, isNew) = shapes.current() else { return }
        if isNew {
            session.sendCursor(.cursorShape(.with {
                $0.id = shape.id
                $0.png = shape.png
                $0.width = Float(shape.width)
                $0.height = Float(shape.height)
                $0.hotX = Float(shape.hotX)
                $0.hotY = Float(shape.hotY)
                $0.scale = Float(shape.scale)
            }))
        }
        // A new id, or a shape the iPad may not have had when the state was sent.
        if sentState?.id != shape.id || isNew {
            sentState = (shape.id, true)
            session.sendCursor(.cursorState(.with {
                $0.shapeID = shape.id
                $0.visible = true
            }))
        }
    }

    private func pollPosition() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let actual = Point2(location.x, location.y)
        let posted = media.input.lastPostedLocation
        let foreign = posted.map { abs($0.x - actual.x) > 1 || abs($0.y - actual.y) > 1 } ?? true
        guard foreign else {
            foreignPolls = 0
            lastReported = nil
            return
        }
        foreignPolls += 1
        // One differing poll may be the iPad's own move still landing.
        guard foreignPolls >= 2 else { return }
        if actual == lastReported {
            sameReports += 1
            if sameReports > Self.reportsPerPosition { return }
        } else {
            lastReported = actual
            sameReports = 1
        }
        let seq = media.input.lastPointerSequence
        if let streamed = media.streamedDisplayID, let bounds = media.input.displayBounds(streamed),
           DisplayMapping(bounds: bounds).contains(actual) {
            let n = DisplayMapping(bounds: bounds).normalized(fromGlobal: actual)
            session.sendCursor(.cursorPosition(.with {
                $0.displayID = streamed
                $0.x = Float(n.x)
                $0.y = Float(n.y)
                $0.lastInputSeq = seq
            }))
        } else if let other = media.input.display(containing: actual) {
            // On a display the iPad is not showing: it hides its cursor.
            let n = DisplayMapping(bounds: other.bounds).normalized(fromGlobal: actual)
            session.sendCursor(.cursorPosition(.with {
                $0.displayID = other.id
                $0.x = Float(n.x)
                $0.y = Float(n.y)
                $0.lastInputSeq = seq
            }))
        }
    }
}
