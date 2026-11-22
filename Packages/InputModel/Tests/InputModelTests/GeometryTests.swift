import Testing
@testable import InputModel

/// Plan section 9: "round-trip property tests across zoom levels and display layouts".
@Suite struct ViewportTests {
    /// A seeded generator, so a failure repeats.
    struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
    }

    static func randomViewport(_ rng: inout Rng) -> Viewport {
        let view = Size2(rng.range(300, 1400), rng.range(300, 1100))
        let stream = Size2(rng.range(800, 3500).rounded(), rng.range(600, 2300).rounded())
        let mode = Viewport.Mode.allCases[Int(rng.next() * 3) % 3]
        var viewport = Viewport(viewSize: view, viewScale: 2, streamSize: stream, mode: mode)
        viewport.zoom(by: rng.range(1, 5), around: Point2(rng.range(0, view.width), rng.range(0, view.height)))
        viewport.pan(by: Point2(rng.range(-500, 500), rng.range(-500, 500)))
        return viewport
    }

    /// Any display position the view shows comes back unchanged.
    @Test func normalizedRoundTrips() {
        var rng = Rng(state: 42)
        for _ in 0..<2_000 {
            let viewport = Self.randomViewport(&rng)
            let n = Point2(rng.next(), rng.next())
            let back = viewport.normalized(fromView: viewport.view(fromNormalized: n))
            #expect(abs(back.x - n.x) < 1e-9 && abs(back.y - n.y) < 1e-9, "\(n) -> \(back)")
        }
    }

    /// The letterbox clamps to the display's edge instead of leaving it.
    @Test func pointsOutsideTheDisplayClamp() {
        let viewport = Viewport(viewSize: Size2(1000, 1000), streamSize: Size2(2000, 1000))  // fit: 1000 x 500, letterboxed
        #expect(viewport.displayInView == Rect2(0, 250, 1000, 500))
        #expect(viewport.normalized(fromView: Point2(500, 10)) == Point2(0.5, 0))
        #expect(viewport.normalized(fromView: Point2(500, 990)) == Point2(0.5, 1))
        #expect(!viewport.isOnDisplay(Point2(500, 10)))
        #expect(viewport.isOnDisplay(Point2(500, 500)))
    }

    @Test func fillCropsAndActualSizeIsOneToOne() {
        let fill = Viewport(viewSize: Size2(1000, 1000), streamSize: Size2(2000, 1000), mode: .fill)
        #expect(fill.displayInView == Rect2(-500, 0, 2000, 1000))
        let actual = Viewport(viewSize: Size2(1000, 1000), viewScale: 2, streamSize: Size2(2000, 1000), mode: .actualSize)
        #expect(actual.displayInView.size == Size2(1000, 500))
    }

    /// Zooming keeps the content under the fingers where it was.
    @Test func zoomKeepsTheAnchor() {
        var rng = Rng(state: 7)
        for _ in 0..<500 {
            var viewport = Viewport(viewSize: Size2(1200, 900), streamSize: Size2(2752, 1152))
            let anchor = Point2(rng.range(200, 1000), rng.range(400, 500))  // on the display
            let before = viewport.normalized(fromView: anchor)
            viewport.zoom(by: rng.range(1.1, 3), around: anchor)
            let after = viewport.normalized(fromView: anchor)
            // Exact unless the pan had to be clamped at an edge.
            let display = viewport.displayInView
            if display.minX <= 0, display.maxX >= 1200 {
                #expect(abs(after.x - before.x) < 1e-9, "\(before) -> \(after)")
            }
        }
    }

    @Test func zoomIsBounded() {
        var viewport = Viewport(viewSize: Size2(1000, 800), streamSize: Size2(2000, 1600))
        viewport.zoom(by: 100, around: Point2(500, 400))
        #expect(viewport.zoom == Viewport.maxZoom)
        viewport.zoom(by: 0.001, around: Point2(500, 400))
        #expect(viewport.zoom == 1)
        #expect(viewport.pan == Point2(0, 0))
    }

    /// Panning never shows past the content's edge.
    @Test func panStaysInside() {
        var viewport = Viewport(viewSize: Size2(1000, 800), streamSize: Size2(2000, 1600))
        viewport.setZoom(2)
        viewport.pan(by: Point2(10_000, -10_000))
        let frame = viewport.frameInView
        #expect(frame.minX == 0)
        #expect(frame.maxY == 800)
    }

    @Test func revealBringsTheCursorIntoView() {
        var viewport = Viewport(viewSize: Size2(1000, 800), streamSize: Size2(2000, 1600))
        viewport.setZoom(3)
        viewport.reveal(normalized: Point2(0.95, 0.5))
        let p = viewport.view(fromNormalized: Point2(0.95, 0.5))
        #expect(p.x <= 1000 - 40 + 1e-9)
    }

    @Test func contentRectInsideTheStream() {
        // The display sits in the middle 1000 x 1000 of a 2000 x 1000 frame.
        let viewport = Viewport(viewSize: Size2(2000, 1000), viewScale: 1, streamSize: Size2(2000, 1000),
                                contentRect: Rect2(500, 0, 1000, 1000))
        #expect(viewport.normalized(fromView: Point2(1000, 500)) == Point2(0.5, 0.5))
        #expect(viewport.normalized(fromView: Point2(500, 0)) == Point2(0, 0))
    }
}

@Suite struct DisplayMappingTests {
    /// Displays left of and above the main one have negative origins.
    @Test(arguments: [
        Rect2(0, 0, 1728, 1117),
        Rect2(1728, -200, 3440, 1440),
        Rect2(-1920, 0, 1920, 1080),
        Rect2(0, -1440, 2560, 1440),
    ])
    func roundTripsAcrossLayouts(bounds: Rect2) {
        let mapping = DisplayMapping(bounds: bounds)
        var rng = ViewportTests.Rng(state: UInt64(abs(bounds.minX) + abs(bounds.minY) + 1))
        for _ in 0..<1_000 {
            // Inside the display, away from the far edge that is clamped.
            let n = Point2(rng.next() * 0.999, rng.next() * 0.999)
            let global = mapping.global(fromNormalized: n)
            #expect(mapping.contains(global))
            let back = mapping.normalized(fromGlobal: global)
            #expect(abs(back.x - n.x) < 1e-9 && abs(back.y - n.y) < 1e-9)
        }
    }

    /// x = 1 is the first point of the next display; it stays on this one.
    @Test func farEdgeStaysOnTheDisplay() {
        let mapping = DisplayMapping(bounds: Rect2(0, 0, 1728, 1117))
        let corner = mapping.global(fromNormalized: Point2(1, 1))
        #expect(mapping.contains(corner))
        #expect(corner == Point2(1727, 1116))
    }

    @Test func outOfRangeClamps() {
        let mapping = DisplayMapping(bounds: Rect2(100, 100, 1000, 500))
        #expect(mapping.global(fromNormalized: Point2(-3, 7)) == Point2(100, 599))
    }
}

@Suite struct ButtonSetTests {
    @Test func wireNumbering() {
        #expect(ButtonSet(wireButton: 1) == .left)
        #expect(ButtonSet(wireButton: 2) == .right)
        #expect(ButtonSet(wireButton: 3) == .middle)
        #expect(ButtonSet(wireButton: 0) == [])
    }
}
