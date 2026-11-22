import Foundation

/// Plain geometry, so the transforms test on any platform without CoreGraphics types.
public struct Point2: Equatable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
    public var description: String { String(format: "(%.3f, %.3f)", x, y) }
}

public struct Size2: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(_ width: Double, _ height: Double) {
        self.width = width
        self.height = height
    }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

public struct Rect2: Equatable, Sendable {
    public var origin: Point2
    public var size: Size2
    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        origin = Point2(x, y)
        size = Size2(width, height)
    }
    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
}

/// How the Mac display sits in the iPad's view (plan section 7, viewport). All of it is local to
/// the iPad and costs no bandwidth.
public struct Viewport: Equatable, Sendable {
    public enum Mode: String, Sendable, CaseIterable, Codable {
        /// The whole display, letterboxed. The default.
        case fit
        /// Fills the view, cropping the display's longer side.
        case fill
        /// One stream pixel to one screen pixel.
        case actualSize
    }

    public static let maxZoom = 4.0

    /// The view's size in points.
    public var viewSize: Size2
    /// The view's pixels per point, for actual size.
    public var viewScale: Double
    /// The stream frame in pixels.
    public var streamSize: Size2
    /// Where the Mac display sits inside the stream frame, in stream pixels (from
    /// `StreamConfigApplied.content_rect`). Usually the whole frame.
    public var contentRect: Rect2
    public var mode: Mode
    /// 1 to `maxZoom`, on top of the mode's own scale.
    public private(set) var zoom: Double = 1
    /// Offset of the zoomed content from its centered position, in view points.
    public private(set) var pan = Point2(0, 0)

    public init(viewSize: Size2, viewScale: Double = 2, streamSize: Size2, contentRect: Rect2? = nil, mode: Mode = .fit) {
        self.viewSize = viewSize
        self.viewScale = viewScale
        self.streamSize = streamSize
        self.contentRect = contentRect ?? Rect2(0, 0, streamSize.width, streamSize.height)
        self.mode = mode
    }

    /// View points per stream pixel at zoom 1.
    public var baseScale: Double {
        guard !viewSize.isEmpty, !streamSize.isEmpty else { return 1 }
        let sx = viewSize.width / streamSize.width
        let sy = viewSize.height / streamSize.height
        switch mode {
        case .fit: return min(sx, sy)
        case .fill: return max(sx, sy)
        case .actualSize: return 1 / viewScale
        }
    }

    /// View points per stream pixel, zoom included.
    public var scale: Double { baseScale * zoom }

    /// Where the whole stream frame lands in the view, in points. Centered, then panned.
    public var frameInView: Rect2 {
        let width = streamSize.width * scale
        let height = streamSize.height * scale
        return Rect2((viewSize.width - width) / 2 + pan.x, (viewSize.height - height) / 2 + pan.y, width, height)
    }

    /// Where the Mac display lands in the view.
    public var displayInView: Rect2 {
        let frame = frameInView
        return Rect2(frame.minX + contentRect.minX * scale, frame.minY + contentRect.minY * scale,
                     contentRect.size.width * scale, contentRect.size.height * scale)
    }

    // MARK: Transforms (plan section 9, coordinate mapping)

    /// A view point to a position on the Mac display, 0 to 1 on each axis, clamped. Undoes zoom,
    /// pan and letterboxing.
    public func normalized(fromView point: Point2) -> Point2 {
        let display = displayInView
        guard display.size.width > 0, display.size.height > 0 else { return Point2(0.5, 0.5) }
        let x = (point.x - display.minX) / display.size.width
        let y = (point.y - display.minY) / display.size.height
        return Point2(min(max(x, 0), 1), min(max(y, 0), 1))
    }

    /// Whether a view point is over the Mac display rather than the letterbox.
    public func isOnDisplay(_ point: Point2) -> Bool {
        let d = displayInView
        return point.x >= d.minX && point.x <= d.maxX && point.y >= d.minY && point.y <= d.maxY
    }

    /// A display position, 0 to 1, to a view point. For drawing the cursor.
    public func view(fromNormalized point: Point2) -> Point2 {
        let display = displayInView
        return Point2(display.minX + point.x * display.size.width, display.minY + point.y * display.size.height)
    }

    /// A movement in view points to the same movement as a fraction of the display, for relative
    /// pointer input.
    public func normalizedDelta(fromView delta: Point2) -> Point2 {
        let display = displayInView
        guard display.size.width > 0, display.size.height > 0 else { return Point2(0, 0) }
        return Point2(delta.x / display.size.width, delta.y / display.size.height)
    }

    // MARK: Zoom and pan

    /// Zooms by `factor` around `anchor`, a view point that stays over the same content.
    public mutating func zoom(by factor: Double, around anchor: Point2) {
        let newZoom = min(max(zoom * factor, 1), Self.maxZoom)
        guard newZoom != zoom else { return }
        let content = contentPoint(fromView: anchor)
        zoom = newZoom
        // Keep the content point under the anchor.
        let moved = viewPoint(fromContent: content)
        pan = Point2(pan.x + anchor.x - moved.x, pan.y + anchor.y - moved.y)
        clampPan()
    }

    public mutating func setZoom(_ value: Double) {
        zoom = min(max(value, 1), Self.maxZoom)
        clampPan()
    }

    public mutating func pan(by delta: Point2) {
        pan = Point2(pan.x + delta.x, pan.y + delta.y)
        clampPan()
    }

    public mutating func resetZoom() {
        zoom = 1
        pan = Point2(0, 0)
        clampPan()
    }

    /// Pans so that a display position is visible, with `margin` points to spare. Fill mode and
    /// zoom follow the cursor near the edges with this.
    public mutating func reveal(normalized point: Point2, margin: Double = 40) {
        let p = view(fromNormalized: point)
        var dx = 0.0, dy = 0.0
        if p.x < margin { dx = margin - p.x } else if p.x > viewSize.width - margin { dx = viewSize.width - margin - p.x }
        if p.y < margin { dy = margin - p.y } else if p.y > viewSize.height - margin { dy = viewSize.height - margin - p.y }
        if dx != 0 || dy != 0 { pan(by: Point2(dx, dy)) }
    }

    /// Keeps the content covering the view where it is larger than the view, and centered where
    /// it is smaller.
    private mutating func clampPan() {
        let width = streamSize.width * scale
        let height = streamSize.height * scale
        let limitX = max(0, (width - viewSize.width) / 2)
        let limitY = max(0, (height - viewSize.height) / 2)
        pan = Point2(min(max(pan.x, -limitX), limitX), min(max(pan.y, -limitY), limitY))
    }

    private func contentPoint(fromView point: Point2) -> Point2 {
        let frame = frameInView
        return Point2((point.x - frame.minX) / scale, (point.y - frame.minY) / scale)
    }

    private func viewPoint(fromContent point: Point2) -> Point2 {
        let frame = frameInView
        return Point2(frame.minX + point.x * scale, frame.minY + point.y * scale)
    }
}

/// Mac side: a display position, 0 to 1, to a point in the global coordinate space, and back
/// (plan section 9, steps 3 and 4). Core Graphics events use points, so Retina scale never
/// enters the math.
public struct DisplayMapping: Equatable, Sendable {
    /// The display's bounds in global points; the main display's top left is the origin and y
    /// grows downwards, as `CGDisplayBounds` reports.
    public var bounds: Rect2

    public init(bounds: Rect2) { self.bounds = bounds }

    public func global(fromNormalized point: Point2) -> Point2 {
        let x = min(max(point.x, 0), 1)
        let y = min(max(point.y, 0), 1)
        // Stay one point inside the far edges: a point exactly on maxX belongs to the next display.
        return Point2(bounds.minX + min(x * bounds.size.width, bounds.size.width - 1),
                      bounds.minY + min(y * bounds.size.height, bounds.size.height - 1))
    }

    public func normalized(fromGlobal point: Point2) -> Point2 {
        guard bounds.size.width > 0, bounds.size.height > 0 else { return Point2(0, 0) }
        return Point2((point.x - bounds.minX) / bounds.size.width, (point.y - bounds.minY) / bounds.size.height)
    }

    public func contains(_ point: Point2) -> Bool {
        point.x >= bounds.minX && point.x < bounds.maxX && point.y >= bounds.minY && point.y < bounds.maxY
    }
}
