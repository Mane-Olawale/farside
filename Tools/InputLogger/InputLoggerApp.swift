import GameController
import UIKit

/// Spike S7: which keys and pointer events reach an iPad app. A guided checklist asks the person
/// to press each combination; the app records what UIKit and GameController saw, and whether the
/// system took the press (the scene left the foreground). The report is written to Documents.
@main
final class InputLoggerApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = LoggerController()
        window.makeKeyAndVisible()
        self.window = window
        application.isIdleTimerDisabled = true
        return true
    }
}

struct KeyStep: Codable {
    var name: String
    /// HID usage of the main key; nil for a modifier or the Globe key alone.
    var usage: Int?
    var modifiers: [String]
    var uikitDown = false
    var uikitUp = false
    var gameControllerDown = false
    var uikitModifiersSeen: [String] = []
    var leftForeground = false
    var seconds = 0.0
    /// Every key event during the step, in order.
    var events: [String] = []
    /// The main key arrived with exactly the expected modifiers.
    var deliveredExactly = false
    /// Every expected modifier arrived but the main key did not: the system took it.
    var modifiersOnly = false
}

struct PointerStep: Codable {
    var events: [String] = []
    var name: String
    var instruction: String
    var observed: [String: String] = [:]
}

struct Report: Codable {
    var date: Date
    var device: String
    var os: String
    var keyboard: String?
    var mouse: String?
    var keys: [KeyStep]
    var pointer: [PointerStep]
}

final class LoggerController: UIViewController, UIGestureRecognizerDelegate {
    private let prompt = UILabel()
    private let detail = UILabel()
    private let logView = UITextView()
    private var steps: [KeyStep] = LoggerController.keySteps()
    private var pointerSteps: [PointerStep] = []
    private var stepIndex = -1
    private var stepStarted = Date()
    private var phase = "start"
    private var lines: [String] = []

    // Pointer counters for the current pointer step.
    private var hoverCount = 0
    private var hoverLast: CGPoint?
    private var primaryClicks = 0
    private var secondaryClicks = 0
    private var pointerTouchTypes: Set<String> = []
    private var scrollContinuous: [String] = []
    private var scrollDiscrete: [String] = []
    private var scrollContinuousTotal = CGPoint.zero
    private var scrollEndedAt: Date?
    private var gcScrollEvents = 0
    private var gcScrollAfterEnd = 0
    private var gcMouseDeltas = 0
    private var gcMouseTotal = CGPoint.zero
    private var wantsLock = false

    static func keySteps() -> [KeyStep] {
        let c = ["command"], s = ["shift"], o = ["option"], k = ["control"], g = ["globe"]
        return [
            KeyStep(name: "A", usage: 0x04, modifiers: []),
            KeyStep(name: "Left arrow", usage: 0x50, modifiers: []),
            KeyStep(name: "Escape", usage: 0x29, modifiers: []),
            KeyStep(name: "Caps Lock", usage: 0x39, modifiers: []),
            KeyStep(name: "Command alone", usage: nil, modifiers: c),
            KeyStep(name: "Option alone", usage: nil, modifiers: o),
            KeyStep(name: "Control alone", usage: nil, modifiers: k),
            KeyStep(name: "Globe alone", usage: nil, modifiers: g),
            KeyStep(name: "Command-C", usage: 0x06, modifiers: c),
            KeyStep(name: "Command-V", usage: 0x19, modifiers: c),
            KeyStep(name: "Command-Z", usage: 0x1D, modifiers: c),
            KeyStep(name: "Command-W", usage: 0x1A, modifiers: c),
            KeyStep(name: "Command-Q", usage: 0x14, modifiers: c),
            KeyStep(name: "Command-. (period)", usage: 0x37, modifiers: c),
            KeyStep(name: "Command-` (backtick)", usage: 0x35, modifiers: c),
            KeyStep(name: "Command-Space", usage: 0x2C, modifiers: c),
            KeyStep(name: "Option-Space", usage: 0x2C, modifiers: o),
            KeyStep(name: "Control-Space", usage: 0x2C, modifiers: k),
            KeyStep(name: "Option-Tab", usage: 0x2B, modifiers: o),
            KeyStep(name: "Control-Up arrow", usage: 0x52, modifiers: k),
            KeyStep(name: "Control-Left arrow", usage: 0x50, modifiers: k),
            KeyStep(name: "Command-Option-Escape", usage: 0x29, modifiers: c + o),
            KeyStep(name: "Command-Option-D", usage: 0x07, modifiers: c + o),
            KeyStep(name: "Command-Shift-3 (takes a screenshot)", usage: 0x20, modifiers: c + s),
            KeyStep(name: "Command-Shift-4", usage: 0x21, modifiers: c + s),
            KeyStep(name: "Globe-C", usage: 0x06, modifiers: g),
            KeyStep(name: "Globe-A", usage: 0x04, modifiers: g),
            KeyStep(name: "Command-Tab (come back to this app after)", usage: 0x2B, modifiers: c),
            KeyStep(name: "Command-Shift-H (come back after)", usage: 0x0B, modifiers: c + s),
            KeyStep(name: "Command-H (come back after)", usage: 0x0B, modifiers: c),
            KeyStep(name: "Globe-H (come back after)", usage: 0x0B, modifiers: g),
        ]
    }

    override var canBecomeFirstResponder: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersPointerLocked: Bool { wantsLock }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.1, alpha: 1)
        prompt.font = .systemFont(ofSize: 40, weight: .bold)
        prompt.textColor = .white
        prompt.numberOfLines = 0
        prompt.textAlignment = .center
        detail.font = .systemFont(ofSize: 20)
        detail.textColor = .lightGray
        detail.numberOfLines = 0
        detail.textAlignment = .center
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.backgroundColor = .clear
        logView.textColor = .systemGreen
        logView.isEditable = false
        logView.isSelectable = false
        logView.isUserInteractionEnabled = false
        [prompt, detail, logView].forEach { view.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            prompt.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            prompt.topAnchor.constraint(equalTo: view.topAnchor, constant: 120),
            prompt.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.85),
            detail.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            detail.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 20),
            detail.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.85),
            logView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            logView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            logView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            logView.heightAnchor.constraint(equalToConstant: 260),
        ])
        prompt.text = "Farside S7 input logger"
        detail.text = "Turn Caps Lock off. Tap the screen with your finger to start. For each step, press the combination once, then tap the screen with your finger to go to the next step."

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        view.addGestureRecognizer(hover)
        let continuous = UIPanGestureRecognizer(target: self, action: #selector(scrolledContinuous(_:)))
        continuous.allowedScrollTypesMask = .continuous
        continuous.allowedTouchTypes = []
        continuous.delegate = self
        view.addGestureRecognizer(continuous)
        let discrete = UIPanGestureRecognizer(target: self, action: #selector(scrolledDiscrete(_:)))
        discrete.allowedScrollTypesMask = .discrete
        discrete.allowedTouchTypes = []
        discrete.delegate = self
        view.addGestureRecognizer(discrete)
        view.addInteraction(UIPointerInteraction(delegate: nil))

        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(lockChanged), name: UIPointerLockState.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gcConnected), name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gcConnected), name: .GCMouseDidConnect, object: nil)
        gcConnected()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func log(_ line: String) {
        lines.append(String(format: "%6.2f ", Date().timeIntervalSince(stepStarted)) + line)
        if lines.count > 18 { lines.removeFirst(lines.count - 18) }
        logView.text = lines.joined(separator: "\n")
    }

    // MARK: GameController

    @objc private func gcConnected() {
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            keyboard.keyChangedHandler = { [weak self] _, _, code, pressed in
                DispatchQueue.main.async { self?.gcKey(Int(code.rawValue), pressed) }
            }
        }
        if let mouse = GCMouse.current?.mouseInput {
            mouse.mouseMovedHandler = { [weak self] _, dx, dy in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.gcMouseDeltas += 1
                    self.gcMouseTotal.x += CGFloat(dx)
                    self.gcMouseTotal.y += CGFloat(dy)
                }
            }
            mouse.scroll.valueChangedHandler = { [weak self] _, _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.gcScrollEvents += 1
                    if self.scrollEndedAt != nil { self.gcScrollAfterEnd += 1 }
                }
            }
        }
    }

    private func gcKey(_ usage: Int, _ pressed: Bool) {
        let line = "GC 0x\(String(usage, radix: 16)) \(pressed ? "down" : "up")"
        log(line)
        guard phase == "keys", stepIndex >= 0, stepIndex < steps.count else { return }
        steps[stepIndex].events.append(line)
        if pressed, usage == steps[stepIndex].usage { steps[stepIndex].gameControllerDown = true }
    }

    // MARK: Keys

    private static func names(_ flags: UIKeyModifierFlags) -> [String] {
        var n: [String] = []
        if flags.contains(.command) { n.append("command") }
        if flags.contains(.shift) { n.append("shift") }
        if flags.contains(.alternate) { n.append("option") }
        if flags.contains(.control) { n.append("control") }
        if flags.contains(.alphaShift) { n.append("capsLock") }
        if flags.contains(.numericPad) { n.append("numericPad") }
        return n
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { handle(press, down: true) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { handle(press, down: false) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { log("UIKit press cancelled \(press.key?.keyCode.rawValue ?? -1)") }
    }

    private func handle(_ press: UIPress, down: Bool) {
        guard let key = press.key else { return }
        let usage = key.keyCode.rawValue
        let mods = Self.names(key.modifierFlags).filter { $0 != "capsLock" }
        let line = "UIKit 0x\(String(usage, radix: 16)) \(down ? "down" : "up") [\(mods.joined(separator: ","))]"
        log(line)
        guard phase == "keys", stepIndex >= 0, stepIndex < steps.count else { return }
        var step = steps[stepIndex]
        step.events.append(line)
        let target = step.usage
        let expected = Set(step.modifiers.filter { $0 != "globe" })
        let matchesModifierOnly = target == nil && Self.modifierUsages(step.modifiers).contains(usage)
        if usage == target || matchesModifierOnly {
            if down {
                step.uikitDown = true
                step.uikitModifiersSeen = mods
                if target != nil, Set(mods) == expected { step.deliveredExactly = true }
                if target == nil { step.deliveredExactly = true }
            } else {
                step.uikitUp = true
            }
        }
        steps[stepIndex] = step
    }

    private static func modifierUsages(_ names: [String]) -> Set<Int> {
        var u: Set<Int> = []
        if names.contains("command") { u.formUnion([0xE3, 0xE7]) }
        if names.contains("option") { u.formUnion([0xE2, 0xE6]) }
        if names.contains("control") { u.formUnion([0xE0, 0xE4]) }
        if names.contains("shift") { u.formUnion([0xE1, 0xE5]) }
        if names.contains("globe") { u.formUnion([0x29A, 0xFF, 0x03]) }
        return u
    }

    @objc private func resigned() {
        log("scene resigned active")
        if phase == "keys", stepIndex >= 0, stepIndex < steps.count {
            steps[stepIndex].leftForeground = true
            steps[stepIndex].events.append("scene resigned active")
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let type: String = switch touch.type {
            case .direct: "direct"
            case .indirectPointer: "indirectPointer"
            case .pencil: "pencil"
            default: "other"
            }
            pointerTouchTypes.insert(type)
            if touch.type == .indirectPointer, let mask = event?.buttonMask {
                if mask.contains(.secondary) { secondaryClicks += 1 } else if mask.contains(.primary) { primaryClicks += 1 }
            }
            log("touch \(type) buttons \(event?.buttonMask.rawValue ?? 0)")
            guard touch.type == .direct else { continue }
            switch phase {
            case "start": startKeys()
            case "keys": nextKeyStep()
            case "pointer": nextPointerStep()
            default: break
            }
        }
    }

    private func startKeys() {
        phase = "keys"
        stepIndex = -1
        nextKeyStep()
    }

    private func nextKeyStep() {
        if stepIndex >= 0, stepIndex < steps.count {
            var step = steps[stepIndex]
            step.seconds = Date().timeIntervalSince(stepStarted)
            if step.usage != nil, !step.uikitDown {
                let wanted = Self.modifierUsages(step.modifiers.filter { $0 != "globe" })
                let groups = step.modifiers.filter { $0 != "globe" }.map { Self.modifierUsages([$0]) }
                let seen = Set(step.events.compactMap { e -> Int? in
                    guard e.hasPrefix("UIKit 0x"), e.contains(" down") else { return nil }
                    return Int(e.dropFirst("UIKit 0x".count).prefix { $0 != " " }, radix: 16)
                })
                step.modifiersOnly = !wanted.isEmpty && groups.allSatisfy { !$0.isDisjoint(with: seen) }
            }
            steps[stepIndex] = step
        }
        save()
        stepIndex += 1
        guard stepIndex < steps.count else { return startPointer() }
        stepStarted = Date()
        prompt.text = "Press: \(steps[stepIndex].name)"
        detail.text = "Key step \(stepIndex + 1) of \(steps.count). Press it once, then tap the screen with your finger."
    }

    // MARK: Pointer

    private let pointerPlan: [(String, String, Double)] = [
        ("hover", "Move the pointer around the screen with the trackpad or mouse, without clicking.", 0),
        ("primaryClick", "Click with the trackpad or mouse three times.", 0),
        ("secondaryClick", "Right click (two-finger click on a trackpad) three times.", 0),
        ("trackpadScroll", "Two-finger scroll on the trackpad: flick quickly and lift, twice. No trackpad: just tap.", 0),
        ("mouseWheel", "Scroll a mouse wheel if you have one. No mouse: just tap.", 0),
        ("pointerLock", "The app asks to lock the pointer. Move the pointer in circles, then tap.", 0),
    ]
    private var pointerIndex = -1

    private func startPointer() {
        phase = "pointer"
        pointerIndex = -1
        nextPointerStep()
    }

    private func resetPointerCounters() {
        hoverCount = 0; hoverLast = nil; primaryClicks = 0; secondaryClicks = 0; pointerTouchTypes = []
        scrollContinuous = []; scrollDiscrete = []; scrollContinuousTotal = .zero; scrollEndedAt = nil
        gcScrollEvents = 0; gcScrollAfterEnd = 0; gcMouseDeltas = 0; gcMouseTotal = .zero
    }

    private func nextPointerStep() {
        if pointerIndex >= 0 { recordPointerStep() }
        pointerIndex += 1
        guard pointerIndex < pointerPlan.count else { return finish() }
        let (name, instruction, seconds) = pointerPlan[pointerIndex]
        resetPointerCounters()
        stepStarted = Date()
        prompt.text = instruction
        detail.text = "Pointer step \(pointerIndex + 1) of \(pointerPlan.count) (\(name)), \(Int(seconds)) seconds."
        _ = seconds
        detail.text = "Pointer step \(pointerIndex + 1) of \(pointerPlan.count) (\(name)). Tap the screen with your finger when finished."
        if name == "pointerLock" {
            wantsLock = true
            setNeedsUpdateOfPrefersPointerLocked()
        }
    }

    private func recordPointerStep() {
        let (name, instruction, _) = pointerPlan[pointerIndex]
        var step = PointerStep(name: name, instruction: instruction)
        let lockState = view.window?.windowScene?.pointerLockState
        step.observed = [
            "hoverEvents": "\(hoverCount)",
            "primaryClicks": "\(primaryClicks)",
            "secondaryClicks": "\(secondaryClicks)",
            "touchTypes": pointerTouchTypes.sorted().joined(separator: ","),
            "continuousScrollStates": scrollContinuous.joined(separator: ","),
            "continuousScrollTotal": String(format: "%.0f,%.0f", scrollContinuousTotal.x, scrollContinuousTotal.y),
            "discreteScrollStates": scrollDiscrete.joined(separator: ","),
            "gameControllerScrollEvents": "\(gcScrollEvents)",
            "gameControllerScrollEventsAfterPanEnded": "\(gcScrollAfterEnd)",
            "gameControllerMouseDeltas": "\(gcMouseDeltas)",
            "gameControllerMouseTotal": String(format: "%.0f,%.0f", gcMouseTotal.x, gcMouseTotal.y),
            "pointerLocked": lockState.map { "\($0.isLocked)" } ?? "no lock state",
        ]
        if name == "pointerLock" {
            wantsLock = false
            setNeedsUpdateOfPrefersPointerLocked()
        }
        pointerSteps.append(step)
        save()
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        hoverCount += 1
        hoverLast = g.location(in: view)
    }

    private static func stateName(_ s: UIGestureRecognizer.State) -> String {
        switch s {
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        default: "other"
        }
    }

    @objc private func scrolledContinuous(_ g: UIPanGestureRecognizer) {
        let name = Self.stateName(g.state)
        if scrollContinuous.last != name { scrollContinuous.append(name) }
        if g.state == .began { scrollEndedAt = nil }
        if g.state == .ended {
            scrollEndedAt = Date()
            let t = g.translation(in: view)
            scrollContinuousTotal.x += t.x
            scrollContinuousTotal.y += t.y
            let v = g.velocity(in: view)
            log(String(format: "continuous scroll ended, velocity %.0f,%.0f", v.x, v.y))
        }
    }

    @objc private func scrolledDiscrete(_ g: UIPanGestureRecognizer) {
        let name = Self.stateName(g.state)
        if scrollDiscrete.last != name { scrollDiscrete.append(name) }
    }

    @objc private func lockChanged() {
        log("pointer lock changed: \(view.window?.windowScene?.pointerLockState?.isLocked ?? false)")
    }

    // MARK: Report

    private func finish() {
        phase = "done"
        save()
        prompt.text = "Done"
        detail.text = "Report saved. You can close the app."
    }

    private func save() {
        let report = Report(date: Date(), device: Self.model(), os: UIDevice.current.systemVersion,
                            keyboard: GCKeyboard.coalesced?.vendorName, mouse: GCMouse.current?.vendorName,
                            keys: steps, pointer: pointerSteps)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "s7-report.json")
        try? encoder.encode(report).write(to: url)
    }

    static func model() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
