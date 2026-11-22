import InputModel
import Testing
@testable import ClientInput

/// Plan section 9, touch gestures in direct touch mode.
@Suite struct DirectTouchTests {
    typealias A = GestureAction
    func ms(_ v: Int) -> Duration { .milliseconds(v) }
    func t(_ id: Int, _ x: Double, _ y: Double, pencil: Bool = false) -> TouchSample {
        TouchSample(id: id, location: Point2(x, y), isPencil: pencil)
    }

    /// Runs a script of touch events and refresh ticks, collecting every action.
    struct Script {
        var r = TouchGestureRecognizer()
        var actions: [A] = []
        mutating func callAsFunction(_ phase: TouchPhase, _ samples: [TouchSample], at time: Duration) {
            actions += r.advance(to: time)
            actions += r.touches(phase, samples, at: time)
        }
        mutating func tick(to time: Duration) { actions += r.advance(to: time) }
        var buttons: [String] {
            actions.compactMap {
                if case let .button(b, down, _, count) = $0 { "\(b == .left ? "L" : "R")\(down ? "down" : "up")\(count)" } else { nil }
            }
        }
    }

    @Test func tapClicksWhereTheFingerIs() {
        var s = Script()
        s(.began, [t(1, 100, 200)], at: .zero)
        s(.ended, [t(1, 102, 201)], at: ms(80))
        #expect(s.actions.first == .move(Point2(100, 200)))
        #expect(s.buttons == ["Ldown1", "Lup1"])
    }

    @Test func quickTapsCountUp() {
        var s = Script()
        for (i, start) in [0, 200, 400].enumerated() {
            s(.began, [t(i, 100, 200)], at: ms(start))
            s(.ended, [t(i, 100, 200)], at: ms(start + 60))
        }
        #expect(s.buttons == ["Ldown1", "Lup1", "Ldown2", "Lup2", "Ldown3", "Lup3"])
    }

    @Test func slowTapsStaySingle() {
        var s = Script()
        s(.began, [t(1, 100, 200)], at: .zero)
        s(.ended, [t(1, 100, 200)], at: ms(60))
        s(.began, [t(2, 100, 200)], at: ms(600))
        s(.ended, [t(2, 100, 200)], at: ms(660))
        #expect(s.buttons == ["Ldown1", "Lup1", "Ldown1", "Lup1"])
    }

    @Test func dragMovesThePointerWithoutAButton() {
        var s = Script()
        s(.began, [t(1, 100, 100)], at: .zero)
        s(.moved, [t(1, 105, 100)], at: ms(20))   // within slop
        s(.moved, [t(1, 150, 100)], at: ms(40))
        s(.moved, [t(1, 200, 120)], at: ms(60))
        s(.ended, [t(1, 200, 120)], at: ms(80))
        #expect(s.actions == [.move(Point2(150, 100)), .move(Point2(200, 120))])
    }

    @Test func longPressThenDragIsALeftDrag() {
        var s = Script()
        s(.began, [t(1, 100, 100)], at: .zero)
        s.tick(to: ms(520))
        s(.moved, [t(1, 160, 100)], at: ms(560))
        s(.moved, [t(1, 220, 100)], at: ms(580))
        s(.ended, [t(1, 220, 100)], at: ms(600))
        #expect(s.actions.contains(.longPress))
        #expect(s.buttons == ["Ldown1", "Lup1"])
        // The press starts where the finger went down, then drags.
        #expect(s.actions.contains(.button(.left, down: true, at: Point2(100, 100), clickCount: 1)))
        #expect(s.actions.contains(.button(.left, down: false, at: Point2(220, 100), clickCount: 1)))
    }

    @Test func longPressThenLiftIsARightClick() {
        var s = Script()
        s(.began, [t(1, 100, 100)], at: .zero)
        s.tick(to: ms(520))
        s(.ended, [t(1, 101, 100)], at: ms(700))
        #expect(s.buttons == ["Rdown1", "Rup1"])
    }

    @Test func twoFingerTapIsARightClick() {
        var s = Script()
        s(.began, [t(1, 100, 100), t(2, 140, 100)], at: .zero)
        s(.ended, [t(1, 100, 100), t(2, 140, 100)], at: ms(90))
        #expect(s.buttons == ["Rdown1", "Rup1"])
        #expect(s.actions.first == .move(Point2(120, 100)))
    }

    /// The second finger may land a little after the first.
    @Test func staggeredTwoFingerTap() {
        var s = Script()
        s(.began, [t(1, 100, 100)], at: .zero)
        s(.began, [t(2, 140, 100)], at: ms(30))
        s(.ended, [t(1, 100, 100)], at: ms(100))
        s(.ended, [t(2, 140, 100)], at: ms(110))
        #expect(s.buttons == ["Rdown1", "Rup1"])
    }

    /// Phases arrive in order, deltas sum to the finger travel, and momentum follows a flick.
    @Test func twoFingerScrollWithMomentum() {
        var s = Script()
        s(.began, [t(1, 100, 100), t(2, 140, 100)], at: .zero)
        var y = 100.0
        for step in 1...10 {
            y += 15
            s(.moved, [t(1, 100, y), t(2, 140, y)], at: ms(step * 8))
        }
        s(.ended, [t(1, 100, y), t(2, 140, y)], at: ms(88))
        for step in 1...400 { s.tick(to: ms(88 + step * 8)) }  // about 2 s of momentum
        let scrolls = s.actions.compactMap { if case let .scroll(_, dy, p, m) = $0 { (dy, p, m) } else { nil } }
        let fingerPhases = scrolls.filter { $0.2 == .none }.map(\.1)
        #expect(fingerPhases.first == .began)
        #expect(fingerPhases.last == .ended)
        #expect(fingerPhases.dropFirst().dropLast().allSatisfy { $0 == .changed })
        let fingerTotal = scrolls.filter { $0.2 == .none }.map(\.0).reduce(0, +)
        #expect(abs(fingerTotal - 150) < 1e-9)
        let momentum = scrolls.filter { $0.2 != .none }.map(\.2)
        #expect(momentum.first == .began)
        #expect(momentum.last == .ended)
        #expect(scrolls.filter { $0.2 != .none }.map(\.0).allSatisfy { $0 >= 0 }, "momentum keeps the direction")
    }

    @Test func aNewTouchStopsMomentum() {
        var s = Script()
        s(.began, [t(1, 100, 100), t(2, 140, 100)], at: .zero)
        for step in 1...5 { s(.moved, [t(1, 100, 100 + Double(step) * 20), t(2, 140, 100 + Double(step) * 20)], at: ms(step * 8)) }
        s(.ended, [t(1, 100, 200), t(2, 140, 200)], at: ms(48))
        s.tick(to: ms(56))
        s.tick(to: ms(64))
        s(.began, [t(3, 300, 300)], at: ms(70))
        let last = s.actions.last { if case .scroll = $0 { true } else { false } }
        #expect(last == .scroll(dx: 0, dy: 0, phase: .none, momentum: .ended))
        let count = s.actions.count
        s.tick(to: ms(200))
        #expect(s.actions.count == count, "no more momentum after the new touch")
    }

    /// A pinch zooms locally and sends nothing to the Mac.
    @Test func pinchZoomsTheViewportOnly() {
        var s = Script()
        s(.began, [t(1, 100, 100), t(2, 200, 100)], at: .zero)
        s(.moved, [t(1, 80, 100), t(2, 220, 100)], at: ms(16))
        s(.moved, [t(1, 50, 100), t(2, 250, 100)], at: ms(32))
        s(.ended, [t(1, 50, 100), t(2, 250, 100)], at: ms(48))
        #expect(s.actions.contains { if case .zoom = $0 { true } else { false } })
        #expect(!s.actions.contains { if case .scroll = $0 { true } else { false } })
        #expect(s.buttons.isEmpty)
        let product = s.actions.compactMap { if case let .zoom(f, _) = $0 { f } else { nil } }.reduce(1, *)
        #expect(abs(product - 2) < 1e-9, "zoom factors multiply to the spread ratio")
    }

    @Test(arguments: [(0.0, -100.0, A.Shortcut.missionControl), (-100, 0, .spaceRight), (100, 0, .spaceLeft)])
    func threeFingerSwipes(dx: Double, dy: Double, expected: A.Shortcut) {
        var s = Script()
        s(.began, [t(1, 300, 300), t(2, 340, 300), t(3, 380, 300)], at: .zero)
        s(.moved, [t(1, 300 + dx, 300 + dy), t(2, 340 + dx, 300 + dy), t(3, 380 + dx, 300 + dy)], at: ms(80))
        s(.moved, [t(1, 300 + dx * 2, 300 + dy * 2), t(2, 340 + dx * 2, 300 + dy * 2), t(3, 380 + dx * 2, 300 + dy * 2)], at: ms(120))
        s(.ended, [t(1, 0, 0), t(2, 0, 0), t(3, 0, 0)], at: ms(150))
        #expect(s.actions == [.shortcut(expected)], "fires once")
    }

    @Test func threeFingerTapTogglesTheToolbar() {
        var s = Script()
        s(.began, [t(1, 300, 300), t(2, 340, 300), t(3, 380, 300)], at: .zero)
        s(.ended, [t(1, 300, 300), t(2, 340, 300), t(3, 380, 300)], at: ms(120))
        #expect(s.actions == [.toggleToolbar])
    }

    /// Plan section 9: the Pencil's drag presses the left button at once, no long press.
    @Test func pencilDragsImmediately() {
        var s = Script()
        s(.began, [t(1, 100, 100, pencil: true)], at: .zero)
        s(.moved, [t(1, 150, 100, pencil: true)], at: ms(16))
        s(.ended, [t(1, 150, 100, pencil: true)], at: ms(32))
        #expect(s.buttons == ["Ldown1", "Lup1"])
        #expect(s.actions.contains(.move(Point2(150, 100))))
    }

    @Test func pencilDoubleTap() {
        var s = Script()
        s(.began, [t(1, 100, 100, pencil: true)], at: .zero)
        s(.ended, [t(1, 100, 100, pencil: true)], at: ms(40))
        s(.began, [t(2, 102, 101, pencil: true)], at: ms(150))
        s(.ended, [t(2, 102, 101, pencil: true)], at: ms(190))
        #expect(s.buttons == ["Ldown1", "Lup1", "Ldown2", "Lup2"])
    }

    /// A cancelled touch (a system gesture took over) must not leave the button down on the Mac.
    @Test func cancelReleasesADrag() {
        var s = Script()
        s(.began, [t(1, 100, 100)], at: .zero)
        s.tick(to: ms(520))
        s(.moved, [t(1, 200, 100)], at: ms(540))
        s(.cancelled, [t(1, 200, 100)], at: ms(560))
        #expect(s.buttons == ["Ldown1", "Lup1"])
    }

    @Test func secondFingerDuringADragEndsIt() {
        var s = Script()
        s(.began, [t(1, 100, 100)], at: .zero)
        s.tick(to: ms(520))
        s(.moved, [t(1, 200, 100)], at: ms(540))
        s(.began, [t(2, 300, 300)], at: ms(560))
        s(.moved, [t(1, 250, 100), t(2, 350, 300)], at: ms(580))
        s(.ended, [t(1, 250, 100), t(2, 350, 300)], at: ms(600))
        #expect(s.buttons == ["Ldown1", "Lup1"])
    }
}
