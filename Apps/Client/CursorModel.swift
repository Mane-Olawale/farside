import ClientInput
import ClientVideo
import Foundation
import ImageIO
import InputModel
import os
import WireProtocol

/// The Mac's cursor on the iPad (plan sections 9 and 10): shapes from the Mac, uploaded once to
/// the renderer; the shape in use; and where to draw it, predicted from the iPad's own moves and
/// corrected by the Mac's reports.
///
/// Messages arrive on the session queue and local moves on the main thread, so state sits behind a
/// lock. `onChange` runs whenever the drawn cursor should move or change.
final class CursorModel: @unchecked Sendable {
    struct Drawn: Equatable {
        let id: UInt32
        /// Display position, 0 to 1, of the hot spot.
        let position: Point2
        /// Mac points.
        let size: Size2
        let hot: Point2
    }

    private struct ShapeInfo {
        let size: Size2
        let hot: Point2
    }

    private let lock = NSLock()
    private var shapes: [UInt32: ShapeInfo] = [:]
    private var current: UInt32?
    private var visible = true
    private var predictor = CursorPredictor()
    private var display: UInt32?
    private let origin = ContinuousClock.now
    private let log = Logger(subsystem: "app.farside.client", category: "cursor")
    private weak var presenter: VideoPresenter?
    var onChange: (@Sendable () -> Void)?

    init(presenter: VideoPresenter?) {
        self.presenter = presenter
    }

    /// The display the iPad is showing; reports for other displays hide the cursor.
    func setDisplay(_ id: UInt32) {
        lock.withLock { display = id }
    }

    /// What to draw now, or nil when there is nothing to draw.
    var drawn: Drawn? {
        lock.withLock {
            guard visible, let id = current, let shape = shapes[id], let position = predictor.position else { return nil }
            return Drawn(id: id, position: position, size: shape.size, hot: shape.hot)
        }
    }

    /// The iPad moved the pointer: draw it there at once.
    func localMove(to point: Point2, seq: UInt32) {
        let now = ContinuousClock.now - origin
        lock.withLock { predictor.localMove(to: point, seq: seq, at: now) }
        onChange?()
    }

    func handle(_ body: Envelope.OneOf_Body) {
        let changed: Bool
        switch body {
        case .cursorShape(let shape):
            guard let image = Self.image(png: shape.png) else {
                log.error("cursor shape \(shape.id) did not decode")
                return
            }
            presenter?.setCursorImage(id: shape.id, image: image)
            lock.withLock {
                shapes[shape.id] = ShapeInfo(size: Size2(Double(shape.width), Double(shape.height)),
                                             hot: Point2(Double(shape.hotX), Double(shape.hotY)))
            }
            changed = true
        case .cursorState(let state):
            lock.withLock {
                current = state.shapeID == 0 ? nil : state.shapeID
                visible = state.visible
            }
            changed = true
        case .cursorPosition(let position):
            let now = ContinuousClock.now - origin
            changed = lock.withLock {
                predictor.report(Point2(Double(position.x), Double(position.y)), lastInputSeq: position.lastInputSeq,
                                 onDisplay: display.map { $0 == position.displayID } ?? true, at: now)
            }
        default:
            return
        }
        if changed { onChange?() }
    }

    private static func image(png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
