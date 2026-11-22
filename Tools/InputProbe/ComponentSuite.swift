import AppKit
import HostInput
import InputModel

/// Phase 2's component tests for input (plan section 17, what the component tests assert). Unlike
/// the S2 probe, which posts raw events, these drive the product's path: `InputEvent`s through
/// `InputReplayer`, posted by `EventInjector`, into this app's window, and check what AppKit
/// delivers. Run with `make component-input` on a Mac where InputProbe has Accessibility.
///
/// | Area | Assertions |
/// | --- | --- |
/// | Mouse | Click count, button, position within 1 point, drag sequence of down, dragged, up |
/// | Scroll | Deltas sum correctly. Phases arrive in order |
/// | Keyboard | Every mapped key produces the expected virtual key code. Modifier state matches. Release-all leaves nothing held |
/// | Text | Unicode strings arrive intact, including emoji and combined characters |
@MainActor
final class ComponentSuite {
    let ui: ProbeWindow
    let injector: EventInjector
    let recorder: Recorder
    private var replayer: InputReplayer
    private let origin = ContinuousClock.now
    private var seq: UInt32 = 0
    private let mainBounds: Rect2
    var keyboardAborted = false

    /// The main display, as display 1.
    init(ui: ProbeWindow, injector: EventInjector, recorder: Recorder) {
        self.ui = ui
        self.injector = injector
        self.recorder = recorder
        let main = CGDisplayBounds(CGMainDisplayID())
        let bounds = Rect2(main.minX, main.minY, main.width, main.height)
        mainBounds = bounds
        replayer = InputReplayer(settings: .init(repeatDelay: .milliseconds(300), repeatInterval: .milliseconds(50))) { id in
            id == 1 ? bounds : nil
        }
    }

    func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
    private func now() -> Duration { ContinuousClock.now - origin }

    /// Sends one event the way the host does, and posts what the replayer asks for.
    private func send(_ event: InputEvent) {
        injector.post(replayer.handle(event, at: now()))
    }

    private func normalized(_ point: CGPoint) -> (Double, Double) {
        let n = DisplayMapping(bounds: mainBounds).normalized(fromGlobal: Point2(point.x, point.y))
        return (n.x, n.y)
    }

    private func moveTo(_ point: CGPoint) {
        seq &+= 1
        let (x, y) = normalized(point)
        send(.pointerMove(display: 1, x: x, y: y, seq: seq))
    }

    private func button(_ number: Int, down: Bool, at point: CGPoint, count: Int = 1) {
        let (x, y) = normalized(point)
        send(.button(number, down: down, clickCount: count, display: 1, x: x, y: y))
    }

    private func key(_ usage: UInt32, down: Bool, _ modifiers: ModifierSet = []) {
        send(.key(hidUsage: usage, down: down, modifiers: modifiers))
    }

    func run() async -> [CaseResult] {
        let original = CGEvent(source: nil)?.location
        // AppKit merges drags that arrive close together; off, so every posted event is counted.
        let coalescing = NSEvent.isMouseCoalescingEnabled
        NSEvent.isMouseCoalescingEnabled = false
        defer {
            NSEvent.isMouseCoalescingEnabled = coalescing
            injector.post(replayer.releaseAll())
            injector.releaseAll()
            if let original { CGWarpMouseCursorPosition(original) }
        }
        let cases: [(String, String, () async -> CaseResult)] = [
            ("mouseClick", "Mouse: one click, left button, within 1 point", click),
            ("mouseDoubleClick", "Mouse: two quick clicks give click count 2", doubleClick),
            ("mouseRightClick", "Mouse: the right button arrives as right mouse events", rightClick),
            ("mouseDrag", "Mouse: a drag is down, dragged events, up, and ends within 1 point", drag),
            ("scrollGesture", "Scroll: trackpad deltas sum correctly and phases arrive in order, momentum after", scrollGesture),
            ("scrollWheel", "Scroll: a wheel scrolls in lines, not precise", scrollWheel),
            ("keyCodes", "Keyboard: every mapped key produces the expected virtual key code", keyCodes),
            ("modifiers", "Keyboard: modifier state matches, left and right, with flags-changed events", modifiers),
            ("capsLockAsShift", "Keyboard: the iPad's Caps Lock types capitals without touching the Mac's lock", capsLockAsShift),
            ("keyRepeat", "Keyboard: a held key repeats on the host's timer and stops on key up", keyRepeat),
            ("releaseAll", "Keyboard: release-all leaves no key or button held at the system level", releaseAllCase),
            ("textUnicode", "Text: Unicode arrives intact, emoji and combined characters included", text),
        ]
        var results: [CaseResult] = []
        for (name, question, body) in cases {
            var result = await body()
            result.name = name
            result.question = question
            results.append(result)
            await settle(300)
        }
        return results
    }

    private func result(_ pass: Bool, _ observed: [String: String]) -> CaseResult {
        CaseResult(name: "", question: "", pass: pass, observed: observed)
    }

    private func within1(_ a: CGPoint?, _ b: CGPoint) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1
    }

    // MARK: Mouse

    private func click() async -> CaseResult {
        let target = ui.point(in: ui.surface, 0.5, 0.5)
        moveTo(target)
        await settle(100)
        let mark = recorder.mark
        button(1, down: true, at: target)
        button(1, down: false, at: target)
        await settle(200)
        let got = recorder.since(mark).filter { $0.type.hasPrefix("leftMouse") }
        let down = got.first { $0.type == "leftMouseDown" }
        let pass = got.map(\.type) == ["leftMouseDown", "leftMouseUp"] && down?.clickCount == 1
            && down?.buttonNumber == 0 && within1(down?.location, target)
        return result(pass, ["events": got.map(\.type).joined(separator: ","),
                             "clickCount": "\(down?.clickCount ?? -1)",
                             "location": "\(down?.location.map { "\($0)" } ?? "none") target \(target)"])
    }

    private func doubleClick() async -> CaseResult {
        let target = ui.point(in: ui.surface, 0.4, 0.4)
        moveTo(target)
        await settle(100)
        let mark = recorder.mark
        for count in [1, 2] {
            button(1, down: true, at: target, count: count)
            button(1, down: false, at: target, count: count)
        }
        await settle(200)
        let counts = recorder.since(mark).filter { $0.type == "leftMouseDown" }.compactMap(\.clickCount)
        return result(counts == [1, 2], ["clickCounts": "\(counts)"])
    }

    private func rightClick() async -> CaseResult {
        let target = ui.point(in: ui.surface, 0.6, 0.6)
        moveTo(target)
        await settle(100)
        let mark = recorder.mark
        button(2, down: true, at: target)
        button(2, down: false, at: target)
        await settle(200)
        let got = recorder.since(mark).filter { $0.type.contains("Mouse") && !$0.type.contains("Moved") }
        let pass = got.map(\.type) == ["rightMouseDown", "rightMouseUp"] && within1(got.first?.location, target)
        return result(pass, ["events": got.map(\.type).joined(separator: ",")])
    }

    private func drag() async -> CaseResult {
        let start = ui.point(in: ui.surface, 0.2, 0.5)
        let end = ui.point(in: ui.surface, 0.8, 0.5)
        moveTo(start)
        await settle(100)
        let mark = recorder.mark
        button(1, down: true, at: start)
        for i in 1...10 {
            let f = CGFloat(i) / 10
            moveTo(CGPoint(x: start.x + (end.x - start.x) * f, y: start.y))
            await settle(10)
        }
        button(1, down: false, at: end)
        await settle(200)
        let got = recorder.since(mark).filter { $0.type.hasPrefix("leftMouse") || $0.type == "mouseMoved" }
        let types = got.map(\.type)
        let dragged = types.filter { $0 == "leftMouseDragged" }.count
        let pass = types.first == "leftMouseDown" && types.last == "leftMouseUp" && dragged == 10
            && !types.contains("mouseMoved") && within1(got.last?.location, end)
        return result(pass, ["down": types.first ?? "none", "dragged": "\(dragged)", "up": types.last ?? "none",
                             "movedDuringDrag": "\(types.filter { $0 == "mouseMoved" }.count)",
                             "end": "\(got.last?.location.map { "\($0)" } ?? "none") target \(end)"])
    }

    // MARK: Scroll

    private func scrollGesture() async -> CaseResult {
        moveTo(ui.point(in: ui.surface, 0.5, 0.5))
        await settle(100)
        let mark = recorder.mark
        var posted: Int32 = 0
        func scroll(_ dy: Double, _ phase: ScrollPhase, _ momentum: ScrollPhase) {
            let events = replayer.handle(.scroll(dx: 0, dy: dy, phase: phase, momentum: momentum, continuous: true), at: now())
            for case let .scroll(_, d, _, _, _) in events { posted += d }
            injector.post(events)
        }
        scroll(3.7, .began, .none)
        for _ in 0..<8 { scroll(3.7, .changed, .none); await settle(8) }
        scroll(0, .ended, .none)
        scroll(5, .none, .began)
        for _ in 0..<5 { scroll(2.5, .none, .changed); await settle(8) }
        scroll(0, .none, .ended)
        await settle(250)
        let got = recorder.since(mark).filter { $0.type == "scrollWheel" }
        let received = got.compactMap(\.scrollDY).reduce(0, +)
        // NSEvent.Phase raw values: began 1, changed 4, ended 8.
        let phases = got.compactMap(\.phase).filter { $0 != 0 }
        let momentum = got.compactMap(\.momentumPhase).filter { $0 != 0 }
        let phasesInOrder = phases.first == 1 && phases.last == 8 && phases.dropFirst().dropLast().allSatisfy { $0 == 4 }
        let momentumInOrder = momentum.first == 1 && momentum.last == 8 && momentum.dropFirst().dropLast().allSatisfy { $0 == 4 }
        let truth = 3.7 * 9 + 5 + 2.5 * 5
        let pass = Int32(received.rounded()) == posted && abs(Double(posted) - truth) < 1 && phasesInOrder && momentumInOrder
        return result(pass, ["sent": String(format: "%.1f", truth), "posted": "\(posted)", "received": "\(received)",
                             "phases": "\(phases)", "momentumPhases": "\(momentum)"])
    }

    private func scrollWheel() async -> CaseResult {
        moveTo(ui.point(in: ui.surface, 0.5, 0.5))
        await settle(100)
        let mark = recorder.mark
        send(.scroll(dx: 0, dy: -3, phase: .none, momentum: .none, continuous: false))
        await settle(200)
        let got = recorder.since(mark).filter { $0.type == "scrollWheel" }
        let pass = got.count == 1 && got.first?.precise == false && (got.first?.scrollDY ?? 0) < 0
        return result(pass, ["events": "\(got.count)", "precise": "\(got.first?.precise.map { "\($0)" } ?? "none")",
                             "deltaY": "\(got.first?.scrollDY ?? 0)"])
    }

    // MARK: Keyboard

    /// Keys left out because they act on the system or the input source, not the window: F11
    /// shows the desktop, F14 and F15 change brightness, the JIS Eisu and Kana keys switch input
    /// source, and Caps Lock and the modifiers have their own cases.
    static let skipped: Set<UInt32> = [0x44, 0x69, 0x6A, 0x47, 0x48, 0x90, 0x91, KeyMap.Usage.capsLock]

    private func keyCodes() async -> CaseResult {
        guard await focus(ui.surface) else { return aborted() }
        var wrong: [String] = []
        var checked = 0
        for (usage, expected) in KeyMap.table.sorted(by: { $0.key < $1.key }) {
            guard !KeyMap.Usage.isModifier(usage), !Self.skipped.contains(usage) else { continue }
            let mark = recorder.mark
            key(usage, down: true)
            key(usage, down: false)
            // Delivery takes 8 to 17 ms (spike S2); wait for this key's up, at most 500 ms.
            let deadline = ContinuousClock.now + .milliseconds(500)
            while !recorder.since(mark).contains(where: { $0.type == "keyUp" }), ContinuousClock.now < deadline {
                await settle(2)
            }
            let got = recorder.since(mark).filter { $0.type == "keyDown" || $0.type == "keyUp" }
            checked += 1
            if got.map(\.type) != ["keyDown", "keyUp"] || got.contains(where: { $0.keyCode != expected }) {
                wrong.append(String(format: "0x%02X→%@", usage, got.map { "\($0.type)(\($0.keyCode ?? 0))" }.joined(separator: ",")))
            }
            if !NSApp.isActive { keyboardAborted = true; break }
        }
        return result(wrong.isEmpty && !keyboardAborted, ["checked": "\(checked)", "wrong": wrong.isEmpty ? "none" : wrong.joined(separator: " ")])
    }

    private func modifiers() async -> CaseResult {
        guard await focus(ui.surface) else { return aborted() }
        let mark = recorder.mark
        key(KeyMap.Usage.leftCommand, down: true, .leftCommand)
        key(0x0E, down: true, .leftCommand)  // K
        key(0x0E, down: false, .leftCommand)
        key(KeyMap.Usage.leftCommand, down: false, [])
        key(KeyMap.Usage.rightShift, down: true, .rightShift)
        key(0x04, down: true, .rightShift)   // A
        key(0x04, down: false, .rightShift)
        key(KeyMap.Usage.rightShift, down: false, [])
        await settle(200)
        let got = recorder.since(mark)
        let k = got.first { $0.type == "keyDown" && $0.keyCode == 0x28 }
        let a = got.first { $0.type == "keyDown" && $0.keyCode == 0x00 }
        let flagsChanged = got.filter { $0.type == "flagsChanged" }.count
        let held = CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskShift])
        let pass = k?.modifierFlags.contains(.command) == true && a?.modifierFlags.contains(.shift) == true
            && a?.characters == "A" && flagsChanged == 4 && held.isEmpty
        return result(pass, ["cmdK": "\(k?.modifierFlags.contains(.command) ?? false)", "shiftA": a?.characters ?? "none",
                             "flagsChanged": "\(flagsChanged)", "heldAfter": "\(held.rawValue)"])
    }

    private func capsLockAsShift() async -> CaseResult {
        guard await focus(ui.surface) else { return aborted() }
        let mark = recorder.mark
        key(KeyMap.Usage.capsLock, down: true, .capsLock)
        key(0x04, down: true, .capsLock)
        key(0x04, down: false, .capsLock)
        key(KeyMap.Usage.capsLock, down: false, [])
        await settle(200)
        let a = recorder.since(mark).first { $0.type == "keyDown" && $0.keyCode == 0x00 }
        let macLock = CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
        return result(a?.characters == "A" && !macLock, ["typed": a?.characters ?? "none", "macCapsLock": "\(macLock)"])
    }

    private func keyRepeat() async -> CaseResult {
        guard await focus(ui.surface) else { return aborted() }
        let mark = recorder.mark
        key(0x0E, down: true)
        // Heartbeats every 100 ms, as the iPad sends while a key is held; the host's timer repeats.
        let until = ContinuousClock.now + .milliseconds(700)
        var lastBeat = ContinuousClock.now
        while ContinuousClock.now < until {
            if ContinuousClock.now - lastBeat >= .milliseconds(100) {
                send(.heartbeat)
                lastBeat = .now
            }
            injector.post(replayer.advance(to: now()))
            await settle(5)
        }
        key(0x0E, down: false)
        await settle(300)
        injector.post(replayer.advance(to: now()))
        let got = recorder.since(mark).filter { $0.keyCode == 0x28 }
        let repeats = got.filter { $0.type == "keyDown" && $0.isARepeat == true }.count
        let afterUp = got.drop { $0.type != "keyUp" }.dropFirst().count
        // 700 ms held: first repeat at 300, then every 50: about 8.
        let pass = (6...10).contains(repeats) && afterUp == 0
        return result(pass, ["repeats": "\(repeats)", "eventsAfterKeyUp": "\(afterUp)"])
    }

    private func releaseAllCase() async -> CaseResult {
        guard await focus(ui.surface) else { return aborted() }
        let target = ui.point(in: ui.surface, 0.5, 0.3)
        moveTo(target)
        await settle(50)
        let mark = recorder.mark
        key(KeyMap.Usage.leftShift, down: true, .leftShift)
        key(0x0E, down: true, .leftShift)
        button(1, down: true, at: target)
        await settle(150)
        // As spike S2 checked it: the system's own record of K and the left button.
        let heldBefore = CGEventSource.keyState(.hidSystemState, key: 0x28) && CGEventSource.buttonState(.hidSystemState, button: .left)
        send(.releaseAll)
        await settle(200)
        let e = recorder.since(mark)
        let kUp = e.contains { $0.type == "keyUp" && $0.keyCode == 0x28 }
        let shiftCleared = e.last { $0.type == "flagsChanged" }.map { !$0.modifierFlags.contains(.shift) } ?? false
        let mouseUp = e.contains { $0.type == "leftMouseUp" }
        let systemClear = !CGEventSource.keyState(.hidSystemState, key: 0x28)
            && !CGEventSource.keyState(.hidSystemState, key: 0x38)
            && !CGEventSource.buttonState(.hidSystemState, button: .left)
        let pass = heldBefore && kUp && shiftCleared && mouseUp && systemClear && replayer.held.isEmpty
        return result(pass, ["heldBefore": "\(heldBefore)", "keyUp": "\(kUp)", "shiftCleared": "\(shiftCleared)",
                             "mouseUp": "\(mouseUp)", "systemClearAfter": "\(systemClear)"])
    }

    // MARK: Text

    private func text() async -> CaseResult {
        let expected = "café naïve – 日本語 👩‍👩‍👧 🇳🇬 e\u{301} Ω"
        ui.textView.string = ""
        guard await focus(ui.textView) else { return aborted() }
        send(.text(expected))
        await settle(400)
        let got = ui.textView.string
        return result(got.unicodeScalars.elementsEqual(expected.unicodeScalars), ["got": got])
    }

    // MARK: Focus

    /// Keyboard cases run only while this window is key, so no keystroke lands in another app.
    private func focus(_ responder: NSResponder) async -> Bool {
        guard !keyboardAborted else { return false }
        for _ in 0..<2 {
            ui.window.makeFirstResponder(responder)
            if NSApp.isActive && ui.window.isKeyWindow { return true }
            NSApp.activate()
            ui.window.makeKeyAndOrderFront(nil)
            await settle(400)
        }
        keyboardAborted = true
        return false
    }

    private func aborted() -> CaseResult {
        result(false, ["aborted": "The window was not key; keyboard cases stopped."])
    }
}
