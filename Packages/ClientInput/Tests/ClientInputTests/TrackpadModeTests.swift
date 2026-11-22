import InputModel
import Testing
@testable import ClientInput

/// Plan section 9, touch gestures in trackpad mode.
@Suite struct TrackpadModeTests {
    func ms(_ v: Int) -> Duration { .milliseconds(v) }
    func t(_ id: Int, _ x: Double, _ y: Double) -> TouchSample { TouchSample(id: id, location: Point2(x, y)) }

    struct Script {
        var r: TouchGestureRecognizer = {
            var r = TouchGestureRecognizer()
            r.mode = .trackpad
            return r
        }()
        var actions: [GestureAction] = []
        mutating func callAsFunction(_ phase: TouchPhase, _ samples: [TouchSample], at time: Duration) {
            actions += r.advance(to: time)
            actions += r.touches(phase, samples, at: time)
        }
        mutating func tick(to time: Duration) { actions += r.advance(to: time) }
        var buttons: [String] {
            actions.compactMap {
                if case let .cursorButton(b, down, count) = $0 { "\(b == .left ? "L" : "R")\(down ? "down" : "up")\(count)" } else { nil }
            }
        }
        var moved: Point2 {
            actions.reduce(Point2(0, 0)) { sum, a in
                if case let .moveBy(d) = a { Point2(sum.x + d.x, sum.y + d.y) } else { sum }
            }
        }
    }

    /// A slow drag moves the cursor exactly as far as the finger: no absolute jump, no click.
    @Test func slowDragMovesRelatively() {
        var s = Script()
        s(.began, [t(1, 500, 500)], at: .zero)
        for step in 1...10 { s(.moved, [t(1, 500 + Double(step) * 2, 500)], at: ms(step * 40)) }  // 50 pt/s
        s(.ended, [t(1, 520, 500)], at: ms(420))
        #expect(abs(s.moved.x - 20) < 1e-9)
        #expect(s.buttons.isEmpty)
        #expect(!s.actions.contains { if case .move = $0 { true } else { false } }, "no absolute moves")
    }

    /// A fast flick goes further than the finger: up to three times.
    @Test func fastDragIsAccelerated() {
        var s = Script()
        s(.began, [t(1, 100, 500)], at: .zero)
        for step in 1...10 { s(.moved, [t(1, 100 + Double(step) * 20, 500)], at: ms(step * 16)) }  // 1250 pt/s
        s(.ended, [t(1, 300, 500)], at: ms(170))
        #expect(s.moved.x > 200 * 2.5)
        #expect(s.moved.x <= 200 * 3 + 1e-9)
    }

    @Test func accelerationIsMonotonic() {
        var last = 0.0
        for speed in stride(from: 0.0, through: 1000, by: 25) {
            let out = TouchGestureRecognizer.accelerated(Point2(speed / 100, 0), seconds: 0.01).x
            #expect(out >= last)
            last = out
        }
        #expect(TouchGestureRecognizer.accelerated(Point2(1, 0), seconds: 0.1) == Point2(1, 0))
    }

    @Test func tapClicksAtTheCursor() {
        var s = Script()
        s(.began, [t(1, 800, 100)], at: .zero)
        s(.ended, [t(1, 800, 100)], at: ms(80))
        #expect(s.buttons == ["Ldown1", "Lup1"])
        #expect(s.moved == Point2(0, 0), "a tap does not move the cursor")
    }

    @Test func doubleTapIsADoubleClick() {
        var s = Script()
        s(.began, [t(1, 800, 100)], at: .zero)
        s(.ended, [t(1, 800, 100)], at: ms(60))
        s(.began, [t(2, 802, 101)], at: ms(180))
        s(.ended, [t(2, 802, 101)], at: ms(240))
        #expect(s.buttons == ["Ldown1", "Lup1", "Ldown2", "Lup2"])
    }

    /// Double tap and hold, then drag: a left drag that moves relatively.
    @Test func doubleTapHoldDragIsALeftDrag() {
        var s = Script()
        s(.began, [t(1, 500, 500)], at: .zero)
        s(.ended, [t(1, 500, 500)], at: ms(60))
        s(.began, [t(2, 500, 500)], at: ms(180))
        s(.moved, [t(2, 520, 500)], at: ms(260))
        s(.moved, [t(2, 540, 500)], at: ms(340))
        s(.ended, [t(2, 540, 500)], at: ms(400))
        #expect(s.buttons == ["Ldown1", "Lup1", "Ldown1", "Lup1"])
        #expect(s.moved.x > 0)
    }

    /// No long press in trackpad mode: holding still is just holding still.
    @Test func noLongPress() {
        var s = Script()
        s(.began, [t(1, 500, 500)], at: .zero)
        s.tick(to: ms(900))
        #expect(!s.actions.contains(.longPress))
        s(.ended, [t(1, 500, 500)], at: ms(950))
        #expect(s.buttons == ["Ldown1", "Lup1"])
    }

    @Test func twoFingerTapRightClicksAtTheCursor() {
        var s = Script()
        s(.began, [t(1, 100, 100), t(2, 140, 100)], at: .zero)
        s(.ended, [t(1, 100, 100), t(2, 140, 100)], at: ms(90))
        #expect(s.buttons == ["Rdown1", "Rup1"])
        #expect(!s.actions.contains { if case .move = $0 { true } else { false } })
    }

    @Test func twoFingersStillScroll() {
        var s = Script()
        s(.began, [t(1, 100, 100), t(2, 140, 100)], at: .zero)
        for step in 1...5 { s(.moved, [t(1, 100, 100 + Double(step) * 10), t(2, 140, 100 + Double(step) * 10)], at: ms(step * 16)) }
        s(.ended, [t(1, 100, 150), t(2, 140, 150)], at: ms(100))
        #expect(s.actions.contains { if case .scroll(_, _, .began, _) = $0 { true } else { false } })
    }
}
