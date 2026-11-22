import InputModel
import Testing
@testable import HostInput

/// Plan section 9, replay rules on the Mac, as unit tests on the events the replayer asks for.
@Suite struct InputReplayerTests {
    static let main = Rect2(0, 0, 1728, 1117)
    static let external = Rect2(1728, -200, 3440, 1440)

    func replayer(_ settings: InputReplayer.Settings = .init()) -> InputReplayer {
        InputReplayer(settings: settings) { id in
            switch id {
            case 1: InputReplayerTests.main
            case 3: InputReplayerTests.external
            default: nil
            }
        }
    }

    /// Drops the user-activity declarations, which most tests do not care about.
    func posted(_ events: [PostedEvent]) -> [PostedEvent] { events.filter { $0 != .userActivity } }

    let cmd: UInt16 = 0x37, shift: UInt16 = 0x38, k: UInt16 = 0x28

    // MARK: Pointer

    @Test func movesMapToTheDisplay() {
        var r = replayer()
        let out = posted(r.handle(.pointerMove(display: 3, x: 0.5, y: 0.25, seq: 1), at: .zero))
        #expect(out == [.move(Point2(1728 + 1720, -200 + 360), drag: nil)])
        #expect(r.lastPointerSeq == 1)
    }

    /// Section 9: moves with a button down are posted as dragged events, or apps will not see a drag.
    @Test func movesWithAButtonHeldAreDrags() {
        var r = replayer()
        _ = r.handle(.button(1, down: true, clickCount: 1, display: 1, x: 0.1, y: 0.1), at: .zero)
        let drag = posted(r.handle(.pointerMove(display: 1, x: 0.2, y: 0.2, seq: 1), at: .zero))
        #expect(drag.count == 1)
        if case let .move(_, button) = drag[0] { #expect(button == .left) } else { Issue.record("not a move") }
        _ = r.handle(.button(1, down: false, clickCount: 1, display: 1, x: 0.2, y: 0.2), at: .zero)
        let plain = posted(r.handle(.pointerMove(display: 1, x: 0.3, y: 0.3, seq: 2), at: .zero))
        if case let .move(_, button) = plain[0] { #expect(button == nil) } else { Issue.record("not a move") }
    }

    /// The pointer channel is unordered: an older move than the newest posted is dropped,
    /// including across the sequence wrapping.
    @Test func staleMovesAreDropped() {
        var r = replayer()
        _ = r.handle(.pointerMove(display: 1, x: 0.5, y: 0.5, seq: UInt32.max - 1), at: .zero)
        #expect(posted(r.handle(.pointerMove(display: 1, x: 0.4, y: 0.4, seq: UInt32.max - 2), at: .zero)).isEmpty)
        #expect(posted(r.handle(.pointerMove(display: 1, x: 0.6, y: 0.6, seq: 3), at: .zero)).count == 1)  // wrapped, newer
        #expect(posted(r.handle(.pointerMove(display: 1, x: 0.6, y: 0.6, seq: 3), at: .zero)).isEmpty)       // duplicate
    }

    @Test func movesToAMissingDisplayAreDropped() {
        var r = replayer()
        #expect(posted(r.handle(.pointerMove(display: 9, x: 0.5, y: 0.5, seq: 1), at: .zero)).isEmpty)
    }

    // MARK: Buttons

    @Test func doubleClickCarriesClickState() {
        var r = replayer()
        var out: [PostedEvent] = []
        for count in [1, 2] {
            out += posted(r.handle(.button(1, down: true, clickCount: count, display: 1, x: 0.5, y: 0.5), at: .zero))
            out += posted(r.handle(.button(1, down: false, clickCount: count, display: 1, x: 0.5, y: 0.5), at: .zero))
        }
        let counts = out.compactMap { if case let .button(_, _, _, c) = $0 { c } else { nil } }
        #expect(counts == [1, 1, 2, 2])
    }

    /// An up with nothing held, or a second down, would confuse apps.
    @Test func unmatchedButtonEventsAreDropped() {
        var r = replayer()
        #expect(posted(r.handle(.button(2, down: false, clickCount: 1, display: 1, x: 0.5, y: 0.5), at: .zero)).isEmpty)
        _ = r.handle(.button(2, down: true, clickCount: 1, display: 1, x: 0.5, y: 0.5), at: .zero)
        #expect(posted(r.handle(.button(2, down: true, clickCount: 1, display: 1, x: 0.5, y: 0.5), at: .zero)).isEmpty)
    }

    @Test func wireButtonsMapToCoreGraphicsNumbers() {
        var r = replayer()
        let out = posted(r.handle(.button(3, down: true, clickCount: 1, display: 1, x: 0, y: 0), at: .zero))
        #expect(out == [.button(.middle, down: true, at: Point2(0, 0), clickCount: 1)])
    }

    // MARK: Scroll

    /// Deltas sum correctly: slow trackpad fractions are carried, not rounded away.
    @Test func scrollDeltasSumCorrectly() {
        var r = replayer()
        var sum: Int32 = 0
        for i in 0..<10 {
            let phase: ScrollPhase = i == 0 ? .began : .changed
            for case let .scroll(_, dy, _, _, _) in posted(r.handle(.scroll(dx: 0, dy: 0.4, phase: phase, momentum: .none, continuous: true), at: .zero)) {
                sum += dy
            }
        }
        #expect(sum == 4)
    }

    /// Phases arrive in order, as Core Graphics values.
    @Test func scrollPhasesMap() {
        var r = replayer()
        let sequence: [(ScrollPhase, ScrollPhase)] = [(.began, .none), (.changed, .none), (.ended, .none),
                                                      (.none, .began), (.none, .changed), (.none, .ended)]
        let phases = sequence.flatMap { phase, momentum in
            posted(r.handle(.scroll(dx: 0, dy: -5, phase: phase, momentum: momentum, continuous: true), at: .zero))
        }.compactMap { if case let .scroll(_, _, _, p, m) = $0 { [p, m] } else { nil } }
        #expect(phases == [[1, 0], [2, 0], [4, 0], [0, 1], [0, 2], [0, 3]])
    }

    @Test func wheelScrollsInLines() {
        var r = replayer()
        #expect(posted(r.handle(.scroll(dx: 0, dy: -3, phase: .none, momentum: .none, continuous: false), at: .zero))
            == [.scroll(dx: 0, dy: -3, pixels: false, phase: 0, momentum: 0)])
    }

    // MARK: Keys

    /// Modifier keys are posted as keys, then the key with the flags set.
    @Test func commandK() {
        var r = replayer()
        var out = posted(r.handle(.key(hidUsage: KeyMap.Usage.leftCommand, down: true, modifiers: .leftCommand), at: .zero))
        out += posted(r.handle(.key(hidUsage: 0x0E, down: true, modifiers: .leftCommand), at: .zero))
        out += posted(r.handle(.key(hidUsage: 0x0E, down: false, modifiers: .leftCommand), at: .zero))
        out += posted(r.handle(.key(hidUsage: KeyMap.Usage.leftCommand, down: false, modifiers: []), at: .zero))
        let keys = out.compactMap { if case let .key(code, down, _, _) = $0 { "\(code):\(down)" } else { nil } }
        #expect(keys == ["\(cmd):true", "\(k):true", "\(k):false", "\(cmd):false"])
        if case let .key(_, _, flags, _) = out[1] { #expect(flags & MacEventFlags.command != 0) }
        #expect(r.postedModifiers == [])
        #expect(r.held.isEmpty)
    }

    /// Spike S7: the iPad's Command-down can be missed by the event's own flags; if the key event
    /// says Command is held, the Mac posts Command first.
    @Test func modifierDriftIsCorrected() {
        var r = replayer()
        let out = posted(r.handle(.key(hidUsage: 0x0E, down: true, modifiers: .leftShift), at: .zero))
        let keys = out.compactMap { if case let .key(code, down, _, _) = $0 { "\(code):\(down)" } else { nil } }
        #expect(keys == ["\(shift):true", "\(k):true"])
    }

    /// Spike S2: Caps Lock is never posted. Letters get Shift in their flags instead.
    @Test func capsLockIsNeverPosted() {
        var r = replayer()
        #expect(posted(r.handle(.key(hidUsage: KeyMap.Usage.capsLock, down: true, modifiers: .capsLock), at: .zero)).isEmpty)
        let out = posted(r.handle(.key(hidUsage: 0x0E, down: true, modifiers: .capsLock), at: .zero))
        #expect(out.count == 1)
        if case let .key(code, _, flags, _) = out[0] {
            #expect(code == k)
            #expect(flags & MacEventFlags.shift != 0)
        }
    }

    @Test func unknownKeysAreDropped() {
        var r = replayer()
        #expect(posted(r.handle(.key(hidUsage: 0x7F, down: true, modifiers: []), at: .zero)).isEmpty)  // mute
    }

    // MARK: Repeat (spike S2: synthetic keys never auto-repeat, so the host does)

    func ms(_ value: Int) -> Duration { .milliseconds(value) }

    @Test func heldKeyRepeatsOnTheMacsSchedule() {
        var r = replayer(.init(repeatDelay: ms(500), repeatInterval: ms(100)))
        _ = r.handle(.key(hidUsage: 0x0E, down: true, modifiers: []), at: .zero)
        var repeats = 0
        for t in stride(from: 100, through: 1000, by: 100) {
            _ = r.handle(.heartbeat, at: ms(t))
            repeats += r.advance(to: ms(t)).count
        }
        #expect(repeats == 6)  // at 500, 600, 700, 800, 900, 1000
        _ = r.handle(.key(hidUsage: 0x0E, down: false, modifiers: []), at: ms(1010))
        #expect(r.advance(to: ms(2000)).isEmpty)
    }

    @Test func repeatsAreMarked() {
        var r = replayer(.init(repeatDelay: ms(100), repeatInterval: ms(50)))
        _ = r.handle(.key(hidUsage: 0x0E, down: true, modifiers: []), at: .zero)
        _ = r.handle(.heartbeat, at: ms(100))
        #expect(r.advance(to: ms(100)) == [.key(k, down: true, flags: MacEventFlags.nonCoalesced, isRepeat: true)])
    }

    /// Section 9: repeats stop when no heartbeat has arrived for 300 ms, so a stalled network
    /// cannot leave a key running away.
    @Test func repeatStopsWhenTheIPadGoesQuiet() {
        var r = replayer(.init(repeatDelay: ms(100), repeatInterval: ms(50)))
        _ = r.handle(.key(hidUsage: 0x0E, down: true, modifiers: []), at: .zero)
        _ = r.handle(.heartbeat, at: ms(200))
        #expect(r.advance(to: ms(200)).count == 3)  // 100, 150, 200
        #expect(r.advance(to: ms(600)).isEmpty)    // silent since 200
    }

    @Test func modifiersDoNotRepeat() {
        var r = replayer(.init(repeatDelay: ms(100), repeatInterval: ms(50)))
        _ = r.handle(.key(hidUsage: KeyMap.Usage.leftShift, down: true, modifiers: .leftShift), at: .zero)
        _ = r.handle(.heartbeat, at: ms(200))
        #expect(r.advance(to: ms(200)).isEmpty)
    }

    // MARK: Stuck keys (exit criterion 4)

    @Test func silenceReleasesEverythingHeld() {
        var r = replayer(.init(releaseSilence: .seconds(1)))
        _ = r.handle(.key(hidUsage: KeyMap.Usage.leftShift, down: true, modifiers: .leftShift), at: .zero)
        _ = r.handle(.key(hidUsage: 0x0E, down: true, modifiers: .leftShift), at: .zero)
        _ = r.handle(.button(1, down: true, clickCount: 1, display: 1, x: 0.5, y: 0.5), at: .zero)
        #expect(r.nextDeadline != nil)
        #expect(r.advance(to: ms(999)).filter { if case .key(_, false, _, _) = $0 { true } else { false } }.isEmpty)
        let released = r.advance(to: .seconds(1))
        let order = released.map { event -> String in
            switch event {
            case let .key(code, false, _, _): code == shift ? "shift" : "key"
            case .button(_, false, _, _): "button"
            default: "other"
            }
        }
        #expect(order == ["key", "shift", "button"])
        #expect(r.held.isEmpty)
        #expect(r.postedModifiers == [])
    }

    @Test func releaseAllFromTheIPad() {
        var r = replayer()
        _ = r.handle(.key(hidUsage: KeyMap.Usage.leftCommand, down: true, modifiers: .leftCommand), at: .zero)
        let out = posted(r.handle(.releaseAll, at: .zero))
        #expect(out == [.key(cmd, down: false, flags: MacEventFlags.nonCoalesced, isRepeat: false)])
        #expect(r.held.isEmpty)
    }

    @Test func nothingHeldMeansNoDeadline() {
        var r = replayer()
        _ = r.handle(.pointerMove(display: 1, x: 0.5, y: 0.5, seq: 1), at: .zero)
        #expect(r.nextDeadline == nil)
    }

    // MARK: Text and activity

    @Test func textIsChunked() {
        var r = replayer(.init(textChunk: 4))
        let out = posted(r.handle(.text("héllo 👋🏽!"), at: .zero))
        #expect(out == [.text("héll"), .text("o "), .text("👋🏽"), .text("!")])
    }

    /// The first input wakes the display; later input re-declares only after a while.
    @Test func userActivityIsDeclaredAtFirstAndThenSparingly() {
        var r = replayer(.init(activityInterval: .seconds(30)))
        #expect(r.handle(.pointerMove(display: 1, x: 0.1, y: 0.1, seq: 1), at: .zero).first == .userActivity)
        #expect(!r.handle(.pointerMove(display: 1, x: 0.2, y: 0.2, seq: 2), at: .seconds(10)).contains(.userActivity))
        #expect(r.handle(.pointerMove(display: 1, x: 0.3, y: 0.3, seq: 3), at: .seconds(31)).first == .userActivity)
        #expect(!r.handle(.heartbeat, at: .seconds(100)).contains(.userActivity))
    }
}
