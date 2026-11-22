import AppKit
import Carbon
import HostInput
import Telemetry

struct CaseResult: Codable {
    var name: String
    var question: String
    /// nil when the case only records behavior.
    var pass: Bool?
    var observed: [String: String]
}

/// The probe window: an event surface, a text view and a tall scroll view.
@MainActor
final class ProbeWindow {
    let window: NSWindow
    let surface: Surface
    let textView: NSTextView
    let scrollView: NSScrollView

    final class Surface: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {}
        override func keyUp(with event: NSEvent) {}
        override func flagsChanged(with event: NSEvent) {}
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.18, alpha: 1).setFill()
            dirtyRect.fill()
        }
    }

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Farside Input Probe: hands off the keyboard and mouse"
        window.acceptsMouseMovedEvents = true
        let content = NSView(frame: frame)

        surface = Surface(frame: NSRect(x: 0, y: 0, width: 480, height: 700))
        content.addSubview(surface)

        let textScroll = NSTextView.scrollableTextView()
        textScroll.frame = NSRect(x: 500, y: 360, width: 490, height: 330)
        textView = textScroll.documentView as! NSTextView
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        content.addSubview(textScroll)

        scrollView = NSScrollView(frame: NSRect(x: 500, y: 10, width: 490, height: 330))
        scrollView.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 6000))
        document.wantsLayer = true
        document.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.3).cgColor
        scrollView.documentView = document
        content.addSubview(scrollView)

        window.contentView = content
        window.center()
    }

    /// A point in `view`, as fractions of its bounds, in global display points.
    func point(in view: NSView, _ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        let local = NSPoint(x: view.bounds.width * fx, y: view.bounds.height * fy)
        let screen = window.convertPoint(toScreen: view.convert(local, to: nil))
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: screen.x, y: height - screen.y)
    }

    var scrollOffset: CGFloat { scrollView.contentView.bounds.origin.y }
}

/// Runs every case in order and collects results.
@MainActor
final class Probe {
    let ui: ProbeWindow
    let injector: EventInjector
    let recorder: Recorder
    private let rawSource = CGEventSource(stateID: .hidSystemState)
    var latency = SampleSet()
    var keyboardAborted = false

    init(ui: ProbeWindow, injector: EventInjector, recorder: Recorder) {
        self.ui = ui
        self.injector = injector
        self.recorder = recorder
    }

    func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    var focusLosses: [String] = []

    /// Keyboard cases run only while this window is key, so no keystroke lands in another app.
    /// One retry covers a system panel that took focus for a moment.
    func focused(_ responder: NSResponder) async -> Bool {
        guard !keyboardAborted else { return false }
        for attempt in 0..<2 {
            ui.window.makeFirstResponder(responder)
            if NSApp.isActive && ui.window.isKeyWindow { return true }
            focusLosses.append("attempt \(attempt): active=\(NSApp.isActive) key=\(ui.window.isKeyWindow) keyWindow=\(NSApp.keyWindow?.title ?? "none") frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")
            NSApp.activate()
            ui.window.makeKeyAndOrderFront(nil)
            await settle(400)
        }
        keyboardAborted = true
        return false
    }

    func run() async -> [CaseResult] {
        var results: [CaseResult] = []
        let original = CGEvent(source: nil)?.location
        defer {
            injector.releaseAll()
            if let original { CGWarpMouseCursorPosition(original) }
        }
        let cases: [(String, String, () async -> CaseResult)] = [
            ("move", "Does an absolute move land exactly, with no acceleration?", move),
            ("click", "Does down then up arrive as one click?", click),
            ("doubleClick", "Does click state 2 make AppKit report a double click?", { await self.multiClick(2) }),
            ("tripleClick", "Does click state 3 make a triple click?", { await self.multiClick(3) }),
            ("rightClick", "Do right button events arrive as right mouse events?", rightClick),
            ("middleClick", "Does the middle button arrive with button number 2?", middleClick),
            ("drag", "Do dragged events posted with the button held arrive as a drag?", drag),
            ("moveWhileHeld", "If moved (not dragged) events are posted with the button held, do apps see a drag?", moveWhileHeld),
            ("pointerDelta", "Do delta fields on a moved event reach the app?", pointerDelta),
            ("scrollLine", "How does a line-unit wheel scroll arrive?", scrollLine),
            ("scrollPrecise", "Do pixel scrolls keep their phases, momentum and precision?", scrollPrecise),
            ("scrollViewWithMomentum", "Does NSScrollView follow a posted gesture plus posted momentum?", { await self.scrollView(momentum: true) }),
            ("scrollViewNoMomentum", "Does NSScrollView add its own momentum after a posted gesture ends?", { await self.scrollView(momentum: false) }),
            ("modifiersExplicit", "Do modifier keys produce flags-changed, and do explicit flags reach the key event?", modifiersExplicit),
            ("modifiersImplicit", "Does a key posted with no flags inherit a held synthetic Shift?", modifiersImplicit),
            ("everyModifier", "Does each modifier key, left and right, set and clear its flag?", everyModifier),
            ("capsLock", "Does a synthetic Caps Lock toggle the lock state?", capsLock),
            ("keyRepeat", "Does a held synthetic key auto-repeat?", keyRepeat),
            ("textBasic", "Does ASCII text sent as Unicode strings arrive intact in a text view?", { await self.text("Hello, world 123") }),
            ("textUnicode", "Do accents, combining marks, CJK, emoji and flags arrive intact?", { await self.text("café naïve – 日本語 👩‍👩‍👧 🇳🇬 e\u{301} Ω") }),
            ("textLong", "Does 500 characters of chunked text arrive intact?", textLong),
            ("unicodeLimit", "How many UTF-16 units does one keyboard event carry?", unicodeLimit),
            ("keyCodeTyping", "Does typing by virtual key code produce the expected text (the lock screen path)?", keyCodeTyping),
            ("editingKeys", "Do Delete and Return as key codes edit text?", editingKeys),
            ("latency", "How long from posting a key on the main thread to the app receiving it?", { await self.keyLatency(background: false) }),
            ("latencyBackground", "Same, posting from a background queue while the main thread is idle", { await self.keyLatency(background: true) }),
            ("releaseAll", "Does release-all clear held keys and buttons at the system level?", releaseAll),
            ("fnAlone", "Does a synthetic fn (Globe) press on its own trigger the system Globe action?", fnAlone),
        ]
        let only = CommandLine.arguments.firstIndex(of: "--only").flatMap { i in
            i + 1 < CommandLine.arguments.count ? Set(CommandLine.arguments[i + 1].split(separator: ",").map(String.init)) : nil
        }
        for (name, question, body) in cases where only?.contains(name) ?? true {
            var result = await body()
            result.name = name
            result.question = question
            results.append(result)
            await settle(400)
        }
        return results
    }

    private func result(_ pass: Bool?, _ observed: [String: String]) -> CaseResult {
        CaseResult(name: "", question: "", pass: pass, observed: observed)
    }

    private func count(_ events: [RecordedEvent], _ type: String) -> Int { events.filter { $0.type == type }.count }

    // MARK: Pointer

    private func move() async -> CaseResult {
        let targets = [(0.2, 0.2), (0.8, 0.3), (0.5, 0.5), (0.3, 0.8), (0.71, 0.66)].map { ui.point(in: ui.surface, $0.0, $0.1) }
        let mark = recorder.mark
        for t in targets {
            injector.move(to: t)
            await settle(40)
        }
        await settle(100)
        let moved = recorder.since(mark).filter { $0.type == "mouseMoved" }
        let errors = targets.map { t in moved.compactMap(\.location).map { hypot($0.x - t.x, $0.y - t.y) }.min() ?? .infinity }
        let worst = errors.max() ?? .infinity
        return result(worst <= 1, ["movedEvents": "\(moved.count)", "worstErrorPoints": String(format: "%.2f", worst)])
    }

    private func click() async -> CaseResult {
        let p = ui.point(in: ui.surface, 0.5, 0.5)
        injector.move(to: p)
        await settle(50)
        let mark = recorder.mark
        injector.button(.left, down: true, at: p)
        injector.button(.left, down: false, at: p)
        await settle(150)
        let e = recorder.since(mark)
        let downs = e.filter { $0.type == "leftMouseDown" }
        return result(downs.count == 1 && count(e, "leftMouseUp") == 1 && downs.first?.clickCount == 1,
                      ["downs": "\(downs.count)", "ups": "\(count(e, "leftMouseUp"))", "clickCount": "\(downs.first?.clickCount ?? -1)"])
    }

    private func multiClick(_ n: Int) async -> CaseResult {
        await settle(Int(NSEvent.doubleClickInterval * 1000) + 100)
        let p = ui.point(in: ui.surface, 0.4, 0.6)
        let mark = recorder.mark
        for k in 1...n {
            injector.button(.left, down: true, at: p, clickCount: k)
            injector.button(.left, down: false, at: p, clickCount: k)
            await settle(60)
        }
        await settle(150)
        let counts = recorder.since(mark).filter { $0.type == "leftMouseDown" }.compactMap(\.clickCount)
        return result(counts == Array(1...n), ["clickCounts": counts.map(String.init).joined(separator: ","),
                                               "doubleClickInterval": String(format: "%.2f s", NSEvent.doubleClickInterval)])
    }

    private func rightClick() async -> CaseResult {
        let p = ui.point(in: ui.surface, 0.6, 0.4)
        let mark = recorder.mark
        injector.button(.right, down: true, at: p)
        injector.button(.right, down: false, at: p)
        await settle(150)
        let e = recorder.since(mark)
        return result(count(e, "rightMouseDown") == 1 && count(e, "rightMouseUp") == 1,
                      ["rightDowns": "\(count(e, "rightMouseDown"))", "rightUps": "\(count(e, "rightMouseUp"))"])
    }

    private func middleClick() async -> CaseResult {
        let p = ui.point(in: ui.surface, 0.6, 0.45)
        let mark = recorder.mark
        injector.button(.middle, down: true, at: p)
        injector.button(.middle, down: false, at: p)
        await settle(150)
        let downs = recorder.since(mark).filter { $0.type == "otherMouseDown" }
        return result(downs.count == 1 && downs.first?.buttonNumber == 2,
                      ["otherDowns": "\(downs.count)", "buttonNumber": "\(downs.first?.buttonNumber ?? -1)"])
    }

    private func drag() async -> CaseResult {
        let start = ui.point(in: ui.surface, 0.2, 0.5)
        injector.move(to: start)
        await settle(50)
        let mark = recorder.mark
        injector.button(.left, down: true, at: start)
        var end = start
        for i in 1...12 {
            end = CGPoint(x: start.x + CGFloat(i) * 15, y: start.y + CGFloat(i) * 4)
            injector.move(to: end)
            await settle(20)
        }
        injector.button(.left, down: false, at: end)
        await settle(150)
        let e = recorder.since(mark)
        let dragged = e.filter { $0.type == "leftMouseDragged" }
        let last = dragged.last?.location ?? .zero
        let error = hypot(last.x - end.x, last.y - end.y)
        return result(!dragged.isEmpty && error <= 1 && count(e, "leftMouseUp") == 1 && count(e, "mouseMoved") == 0,
                      ["draggedEvents": "\(dragged.count) of 12 posted", "movedEvents": "\(count(e, "mouseMoved"))",
                       "endErrorPoints": String(format: "%.2f", error)])
    }

    private func moveWhileHeld() async -> CaseResult {
        let start = ui.point(in: ui.surface, 0.2, 0.3)
        injector.move(to: start)
        await settle(50)
        let mark = recorder.mark
        injector.button(.left, down: true, at: start)
        for i in 1...6 {
            let p = CGPoint(x: start.x + CGFloat(i) * 15, y: start.y)
            let event = CGEvent(mouseEventSource: rawSource, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
            event?.setIntegerValueField(.eventSourceUserData, value: injector.tag)
            event?.post(tap: .cghidEventTap)
            await settle(20)
        }
        injector.button(.left, down: false, at: CGPoint(x: start.x + 90, y: start.y))
        await settle(150)
        let e = recorder.since(mark)
        let dragged = count(e, "leftMouseDragged")
        let moved = count(e, "mouseMoved")
        // Pass means the plan's rule holds: moved events do not become drags.
        return result(dragged == 0, ["draggedEvents": "\(dragged)", "movedEvents": "\(moved)"])
    }

    private func pointerDelta() async -> CaseResult {
        let p = ui.point(in: ui.surface, 0.5, 0.3)
        injector.move(to: p)
        await settle(60)
        let mark = recorder.mark
        injector.moveBy(dx: 7, dy: -4)
        await settle(120)
        let moved = recorder.since(mark).filter { $0.type == "mouseMoved" }
        let d = moved.last
        let stayed = d?.location.map { hypot($0.x - p.x, $0.y - p.y) <= 1 } ?? false
        return result(d?.deltaX == 7 && d?.deltaY == -4 && stayed,
                      ["deltaX": "\(d?.deltaX ?? .nan)", "deltaY": "\(d?.deltaY ?? .nan)", "locationUnchanged": "\(stayed)"])
    }

    /// A trackpad-like gesture: began, nine changes, ended, then momentum. Sums to -124 px.
    private func gesture(momentum: Bool) -> [ScrollInput] {
        var posted: [ScrollInput] = [ScrollInput(dy: -10, phase: 1)]
        posted += Array(repeating: ScrollInput(dy: -10, phase: 2), count: 9)
        posted.append(ScrollInput(dy: 0, phase: 4))
        guard momentum else { return posted }
        posted.append(ScrollInput(dy: -8, momentumPhase: 1))
        posted += [-6, -4, -3, -2, -1].map { ScrollInput(dy: $0, momentumPhase: 2) }
        posted.append(ScrollInput(dy: 0, momentumPhase: 3))
        return posted
    }

    private func post(_ inputs: [ScrollInput]) async {
        for s in inputs {
            injector.scroll(s)
            await settle(16)
        }
    }

    /// Over the plain surface, which does not run a scroll tracking loop, so every event reaches
    /// the recorder.
    private func scrollPrecise() async -> CaseResult {
        injector.move(to: ui.point(in: ui.surface, 0.5, 0.5))
        await settle(100)
        let mark = recorder.mark
        let posted = gesture(momentum: true)
        await post(posted)
        await settle(250)
        let scrolls = recorder.since(mark).filter { $0.type == "scrollWheel" }
        let phases = scrolls.compactMap(\.phase)
        let momentum = scrolls.compactMap(\.momentumPhase)
        let sum = scrolls.compactMap(\.scrollDY).reduce(0, +)
        let expectedPhases: [UInt] = [1] + Array(repeating: 4, count: 9) + [8] + Array(repeating: 0, count: 7)
        let expectedMomentum: [UInt] = Array(repeating: 0, count: 11) + [1, 4, 4, 4, 4, 4, 8]
        return result(scrolls.count == posted.count && phases == expectedPhases && momentum == expectedMomentum
                      && scrolls.allSatisfy { $0.precise == true } && abs(sum + 124) <= 1,
                      ["events": "\(scrolls.count) of \(posted.count)",
                       "phases": phases.map(String.init).joined(separator: ","),
                       "momentumPhases": momentum.map(String.init).joined(separator: ","),
                       "precise": "\(scrolls.allSatisfy { $0.precise == true })",
                       "sumScrollingDeltaY": String(format: "%.1f (posted -124 px)", sum),
                       "directionInverted": "\(scrolls.first?.directionInverted ?? false)"])
    }

    /// NSScrollView tracks a phased gesture itself, so only its offset is measured.
    private func scrollView(momentum: Bool) async -> CaseResult {
        ui.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 2500))
        ui.scrollView.reflectScrolledClipView(ui.scrollView.contentView)
        injector.move(to: ui.point(in: ui.scrollView, 0.5, 0.5))
        await settle(150)
        let before = ui.scrollOffset
        let posted = gesture(momentum: momentum)
        let postedSum = posted.reduce(0) { $0 + Int($1.dy) }
        await post(posted)
        var samples: [CGFloat] = []
        for _ in 0..<15 {
            await settle(100)
            samples.append(ui.scrollOffset - before)
        }
        let final = samples.last ?? 0
        let settledAt = (samples.firstIndex { abs($0 - final) < 0.5 } ?? 0) * 100
        return result(nil, ["postedPx": "\(postedSum)", "scrollViewMoved": String(format: "%.1f pt", final),
                            "settledWithin": "\(settledAt) ms after the last event"])
    }

    private func scrollLine() async -> CaseResult {
        ui.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 2500))
        ui.scrollView.reflectScrolledClipView(ui.scrollView.contentView)
        injector.move(to: ui.surface.window == nil ? .zero : ui.point(in: ui.surface, 0.5, 0.5))
        await settle(80)
        let mark = recorder.mark
        injector.scroll(ScrollInput(dy: -3, units: .line))
        await settle(150)
        injector.move(to: ui.point(in: ui.scrollView, 0.5, 0.5))
        await settle(150)
        let before = ui.scrollOffset
        injector.scroll(ScrollInput(dy: -3, units: .line))
        await settle(300)
        let s = recorder.since(mark).filter { $0.type == "scrollWheel" }
        return result(nil, ["eventsRecorded": "\(s.count) (one over the surface, one over the scroll view)", "precise": "\(s.first?.precise.map(String.init) ?? "–")",
                            "scrollingDeltaY": "\(s.first?.scrollDY ?? .nan)",
                            "scrollViewMoved": String(format: "%.1f pt", ui.scrollOffset - before)])
    }

    // MARK: Keyboard

    private func aborted() -> CaseResult {
        result(false, ["aborted": "window lost focus; keyboard cases stopped",
                       "frontmostApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "none",
                       "keyWindow": NSApp.keyWindow?.title ?? "none"])
    }

    private func modifiersExplicit() async -> CaseResult {
        guard await focused(ui.surface) else { return aborted() }
        let mark = recorder.mark
        injector.key(0x37, down: true, flags: .maskCommand)
        await settle(30)
        injector.key(0x28, down: true, flags: .maskCommand)
        injector.key(0x28, down: false, flags: .maskCommand)
        await settle(30)
        injector.key(0x37, down: false, flags: [])
        await settle(150)
        let e = recorder.since(mark)
        let flagEvents = e.filter { $0.type == "flagsChanged" }
        let keyDown = e.first { $0.type == "keyDown" && $0.keyCode == 0x28 }
        let setThenClear = flagEvents.count == 2 && flagEvents[0].modifierFlags.contains(.command) && !flagEvents[1].modifierFlags.contains(.command)
        return result(setThenClear && keyDown?.modifierFlags.contains(.command) == true,
                      ["flagsChanged": "\(flagEvents.count)", "commandSetThenCleared": "\(setThenClear)",
                       "keyDownHasCommand": "\(keyDown?.modifierFlags.contains(.command) ?? false)",
                       "charactersIgnoringModifiers": keyDown?.charactersIgnoringModifiers ?? "–"])
    }

    private func modifiersImplicit() async -> CaseResult {
        guard await focused(ui.surface) else { return aborted() }
        let mark = recorder.mark
        injector.key(0x38, down: true)
        await settle(30)
        injector.key(0x28, down: true)
        injector.key(0x28, down: false)
        await settle(30)
        injector.key(0x38, down: false)
        await settle(150)
        let e = recorder.since(mark)
        let keyDown = e.first { $0.type == "keyDown" && $0.keyCode == 0x28 }
        return result(keyDown?.modifierFlags.contains(.shift) == true && keyDown?.characters == "K",
                      ["keyDownHasShift": "\(keyDown?.modifierFlags.contains(.shift) ?? false)",
                       "characters": keyDown?.characters ?? "–",
                       "flagsChanged": "\(count(e, "flagsChanged"))"])
    }

    private func everyModifier() async -> CaseResult {
        guard await focused(ui.surface) else { return aborted() }
        let keys: [(UInt16, String, NSEvent.ModifierFlags)] = [
            (0x38, "shift", .shift), (0x3C, "rightShift", .shift), (0x3B, "control", .control), (0x3E, "rightControl", .control),
            (0x3A, "option", .option), (0x3D, "rightOption", .option), (0x37, "command", .command), (0x36, "rightCommand", .command),
        ]
        var observed: [String: String] = [:]
        var allGood = true
        for (code, name, flag) in keys {
            let mark = recorder.mark
            injector.key(code, down: true)
            await settle(40)
            injector.key(code, down: false)
            // Space presses out, so no pair matches a double-press system shortcut.
            await settle(700)
            let f = recorder.since(mark).filter { $0.type == "flagsChanged" }
            let good = f.count == 2 && f[0].modifierFlags.contains(flag) && !f[1].modifierFlags.contains(flag)
            allGood = allGood && good
            observed[name] = good ? "ok" : "flagsChanged \(f.count), flags " + f.map { String($0.flags, radix: 16) }.joined(separator: "/")
        }
        return result(allGood, observed)
    }

    private func capsLock() async -> CaseResult {
        guard await focused(ui.surface) else { return aborted() }
        func locked() -> Bool { CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) }
        let start = locked()
        let mark = recorder.mark
        injector.key(0x39, down: true)
        injector.key(0x39, down: false)
        await settle(200)
        let afterFirst = locked()
        injector.key(0x39, down: true)
        injector.key(0x39, down: false)
        await settle(200)
        let afterSecond = locked()
        let f = recorder.since(mark).filter { $0.type == "flagsChanged" }
        return result(afterFirst != start && afterSecond == start,
                      ["startLocked": "\(start)", "afterFirstPress": "\(afterFirst)", "afterSecondPress": "\(afterSecond)",
                       "flagsChangedEvents": "\(f.count)",
                       "appSawCapsLock": "\(f.contains { $0.modifierFlags.contains(.capsLock) })"])
    }

    private func keyRepeat() async -> CaseResult {
        guard await focused(ui.surface) else { return aborted() }
        let delay = NSEvent.keyRepeatDelay
        let interval = NSEvent.keyRepeatInterval
        let hold = delay + interval * 10 + 0.2
        let mark = recorder.mark
        injector.key(0x28, down: true)
        await settle(Int(hold * 1000))
        injector.key(0x28, down: false)
        await settle(150)
        let downs = recorder.since(mark).filter { $0.type == "keyDown" && $0.keyCode == 0x28 }
        let repeats = downs.filter { $0.isARepeat == true }.count
        // Pass means the plan's assumption holds: no auto-repeat, so the host must generate it.
        return result(downs.count == 1 && repeats == 0,
                      ["keyDowns": "\(downs.count)", "repeats": "\(repeats)",
                       "heldFor": String(format: "%.2f s", hold),
                       "systemRepeatDelay": String(format: "%.3f s", delay),
                       "systemRepeatInterval": String(format: "%.3f s", interval),
                       "hardwareWouldRepeat": "about \(Int(((hold - delay) / interval).rounded(.down))) times"])
    }

    private func clearText() async -> Bool {
        guard await focused(ui.textView) else { return false }
        ui.textView.string = ""
        await settle(50)
        return true
    }

    private func text(_ text: String) async -> CaseResult {
        guard await clearText() else { return aborted() }
        let mark = recorder.mark
        injector.text(text)
        await settle(400)
        let got = ui.textView.string
        let downs = recorder.since(mark).filter { $0.type == "keyDown" }
        return result(got == text && Array(got.unicodeScalars) == Array(text.unicodeScalars),
                      ["sent": text, "received": got, "scalarsIdentical": "\(Array(got.unicodeScalars) == Array(text.unicodeScalars))",
                       "keyDownEvents": "\(downs.count)"])
    }

    private func textLong() async -> CaseResult {
        guard await clearText() else { return aborted() }
        let unit = "The quick brown fox jumps over the lazy dog. "
        let text = String(String(repeating: unit, count: 12).prefix(500))
        let start = ProcessInfo.processInfo.systemUptime
        injector.text(text)
        let posted = ProcessInfo.processInfo.systemUptime - start
        var waited = 0
        while ui.textView.string.count < text.count && waited < 3000 {
            await settle(20)
            waited += 20
        }
        let got = ui.textView.string
        return result(got == text, ["sentCharacters": "\(text.count)", "receivedCharacters": "\(got.count)",
                                    "postTime": String(format: "%.1f ms", posted * 1000),
                                    "arrivedWithin": "\(waited) ms"])
    }

    private func unicodeLimit() async -> CaseResult {
        var observed: [String: String] = [:]
        for size in [20, 21, 40, 100] {
            guard await clearText() else { return aborted() }
            let sent = String((0..<size).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) })
            injector.unicodeEvent(sent)
            await settle(300)
            observed["\(size) units"] = "\(ui.textView.string.utf16.count) arrived"
        }
        return result(nil, observed)
    }

    private func keyCodeTyping() async -> CaseResult {
        guard await clearText() else { return aborted() }
        let ansi: [Character: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
            "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22,
            "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E, " ": 0x31,
        ]
        let text = "hello world"
        for ch in text {
            guard let code = ansi[ch] else { continue }
            injector.key(code, down: true, flags: [])
            injector.key(code, down: false, flags: [])
            await settle(10)
        }
        await settle(300)
        let layout = Self.keyboardLayoutName()
        return result(ui.textView.string == text, ["sent": text, "received": ui.textView.string, "keyboardLayout": layout])
    }

    private func editingKeys() async -> CaseResult {
        guard await clearText() else { return aborted() }
        ui.textView.string = "abc"
        ui.textView.setSelectedRange(NSRange(location: 3, length: 0))
        injector.key(0x33, down: true, flags: [])
        injector.key(0x33, down: false, flags: [])
        await settle(100)
        injector.key(0x24, down: true, flags: [])
        injector.key(0x24, down: false, flags: [])
        await settle(200)
        let got = ui.textView.string
        return result(got == "ab\n", ["received": got.replacingOccurrences(of: "\n", with: "\\n")])
    }

    /// Posts 100 key presses 10 ms apart. Splits the delay at the event's own timestamp, which
    /// the system sets when the event enters the window server.
    private func keyLatency(background: Bool) async -> CaseResult {
        guard await focused(ui.surface) else { return aborted() }
        let mark = recorder.mark
        let postTimes: [TimeInterval]
        if background {
            guard let worker = EventInjector() else { return result(false, ["error": "no event source"]) }
            postTimes = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInteractive).async {
                    var times: [TimeInterval] = []
                    for _ in 0..<100 {
                        times.append(ProcessInfo.processInfo.systemUptime)
                        worker.key(0x28, down: true, flags: [])
                        worker.key(0x28, down: false, flags: [])
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    continuation.resume(returning: times)
                }
            }
        } else {
            var times: [TimeInterval] = []
            for _ in 0..<100 {
                times.append(ProcessInfo.processInfo.systemUptime)
                injector.key(0x28, down: true, flags: [])
                injector.key(0x28, down: false, flags: [])
                await settle(10)
            }
            postTimes = times
        }
        await settle(200)
        let downs = recorder.since(mark).filter { $0.type == "keyDown" && $0.keyCode == 0x28 }
        var total = SampleSet(), toStamp = SampleSet(), stampToApp = SampleSet()
        for (posted, event) in zip(postTimes, downs) {
            total.add((event.arrival - posted) * 1000)
            toStamp.add((event.timestamp - posted) * 1000)
            stampToApp.add((event.arrival - event.timestamp) * 1000)
        }
        if !background { latency = total }
        func fmt(_ s: SampleSet) -> String {
            s.summary.map { String(format: "p50 %.2f, p95 %.2f, max %.2f", $0.median, $0.p95, $0.max) } ?? "–"
        }
        return result(nil, ["delivered": "\(downs.count) of 100", "postToAppMs": fmt(total),
                            "postToEventTimestampMs": fmt(toStamp), "eventTimestampToAppMs": fmt(stampToApp)])
    }

    private func releaseAll() async -> CaseResult {
        guard await focused(ui.surface) else { return aborted() }
        let p = ui.point(in: ui.surface, 0.5, 0.7)
        injector.move(to: p)
        await settle(50)
        let mark = recorder.mark
        injector.key(0x38, down: true)
        injector.key(0x28, down: true)
        injector.button(.left, down: true, at: p)
        await settle(150)
        let heldBefore = CGEventSource.keyState(.hidSystemState, key: 0x28) && CGEventSource.buttonState(.hidSystemState, button: .left)
        injector.releaseAll()
        await settle(200)
        let e = recorder.since(mark)
        let kUp = e.contains { $0.type == "keyUp" && $0.keyCode == 0x28 }
        let shiftCleared = e.last { $0.type == "flagsChanged" }.map { !$0.modifierFlags.contains(.shift) } ?? false
        let mouseUp = e.contains { $0.type == "leftMouseUp" }
        let systemClear = !CGEventSource.keyState(.hidSystemState, key: 0x28)
            && !CGEventSource.keyState(.hidSystemState, key: 0x38)
            && !CGEventSource.buttonState(.hidSystemState, button: .left)
        return result(heldBefore && kUp && shiftCleared && mouseUp && systemClear && injector.held.isEmpty,
                      ["systemSawHeldBefore": "\(heldBefore)", "keyUp": "\(kUp)", "shiftCleared": "\(shiftCleared)",
                       "mouseUp": "\(mouseUp)", "systemStateClearAfter": "\(systemClear)"])
    }

    /// Last, because fn alone is the Globe key and may open a system panel.
    private func fnAlone() async -> CaseResult {
        guard await focused(ui.surface) else { return aborted() }
        let mark = recorder.mark
        injector.key(0x3F, down: true)
        await settle(40)
        injector.key(0x3F, down: false)
        await settle(800)
        let f = recorder.since(mark).filter { $0.type == "flagsChanged" }
        let stillKey = NSApp.isActive && ui.window.isKeyWindow
        let observed = [
            "flagsChangedWithFn": "\(f.contains { $0.modifierFlags.contains(.function) })",
            "probeStillKey": "\(stillKey)",
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "none",
            "systemGlobeSetting": UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType").map { "\($0)" } ?? "unset",
        ]
        if !stillKey {
            // Dismiss whatever opened, then take focus back.
            injector.key(0x35, down: true, flags: [])
            injector.key(0x35, down: false, flags: [])
            await settle(200)
            NSApp.activate()
            ui.window.makeKeyAndOrderFront(nil)
        }
        return result(nil, observed)
    }

    static func keyboardLayoutName() -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
        else { return "unknown" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
