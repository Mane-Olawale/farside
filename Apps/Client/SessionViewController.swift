import ClientInput
import ClientVideo
import InputModel
import QuartzCore
import SessionTransport
import SwiftUI
import UIKit
import WireProtocol

/// The session screen's input and drawing (plan section 7, session view controller): raw touches
/// go through the direct touch recognizer, the viewport turns view points into display positions,
/// and the result goes to the Mac as input. The same viewport places the video and the cursor.
///
/// A display link on the main thread drives the recognizer's timers (long press, momentum),
/// coalesces pointer moves to one per refresh (plan section 9, at most 120 a second), and sends
/// heartbeats while a key or button is held.
///
/// Hardware keys arrive as presses on the touch view, which is also the software keyboard's text
/// input. A trackpad or mouse moves the pointer by hover, clicks as indirect pointer touches with
/// their own path (a click-drag is a drag at once, not a long press), and scrolls through pan
/// recognizers that accept only scroll events. The iPadOS pointer is hidden over the video.
final class SessionViewController: UIViewController, UIPointerInteractionDelegate {
    private let connection: ConnectionModel
    private var viewport = Viewport(viewSize: Size2(0, 0), streamSize: Size2(0, 0))
    private var recognizer = TouchGestureRecognizer()
    private var displayLink: CADisplayLink?
    /// The newest pointer position not yet sent, 0 to 1 on the display.
    private var pendingMove: Point2?
    private var heldButtons: ButtonSet = []
    private var lastHeartbeat: CFTimeInterval = 0
    private var appliedKey: String?
    private let haptics = UIImpactFeedbackGenerator(style: .medium)
    private var clicks = ClickCounter()
    /// The trackpad or mouse button held, by the indirect touch that pressed it.
    private var pointerButton: (touch: ObjectIdentifier, button: GestureAction.Button)?
    private var trackpadMomentum = ScrollMomentum()
    private var lastTrackpadTranslation = CGPoint.zero
    private var lastWheelTranslation = CGPoint.zero

    init(connection: ConnectionModel) {
        self.connection = connection
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let view = TouchView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .black
        view.owner = self
        self.view = view

        // A trackpad or mouse: hover moves the pointer, pans with no touches are scrolls.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered))
        view.addGestureRecognizer(hover)
        let trackpad = UIPanGestureRecognizer(target: self, action: #selector(trackpadScrolled))
        trackpad.allowedScrollTypesMask = .continuous
        trackpad.allowedTouchTypes = []
        view.addGestureRecognizer(trackpad)
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheelScrolled))
        wheel.allowedScrollTypesMask = .discrete
        wheel.allowedTouchTypes = []
        view.addGestureRecognizer(wheel)
        view.addInteraction(UIPointerInteraction(delegate: self))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let surface = connection.surface
        surface.isUserInteractionEnabled = false
        surface.frame = view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(surface)
        connection.cursor?.onChange = { [weak self] in
            DispatchQueue.main.async { self?.updateScene() }
        }
        connection.onAppliedChange = { [weak self] in self?.syncViewport() }
        connection.keyboard.onSoftwareKeyboardChange = { [weak self] shown in
            (self?.view as? TouchView)?.setSoftwareKeyboard(shown)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        // First responder for hardware keys; the software keyboard stays hidden until asked for.
        view.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
        releaseAll()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncViewport()
    }

    // MARK: Viewport

    /// Keeps the viewport in step with the view and the stream the Mac applied.
    private func syncViewport() {
        let size = Size2(view.bounds.width, view.bounds.height)
        let scale = view.window?.screen.nativeScale ?? view.traitCollection.displayScale
        guard let applied = connection.applied else { return }
        let key = "\(applied.width)x\(applied.height)@\(applied.displayID)"
        if key != appliedKey || viewport.viewSize != size {
            let content = applied.hasContentRect && applied.contentRect.width > 0
                ? Rect2(Double(applied.contentRect.x), Double(applied.contentRect.y),
                        Double(applied.contentRect.width), Double(applied.contentRect.height))
                : nil
            let keepZoom = key == appliedKey ? viewport.zoom : 1
            viewport = Viewport(viewSize: size, viewScale: scale,
                                streamSize: Size2(Double(applied.width), Double(applied.height)),
                                contentRect: content, mode: viewport.mode)
            viewport.setZoom(keepZoom)
            appliedKey = key
        }
        updateScene()
    }

    /// Video rect and cursor in drawable pixels, from the viewport and the predicted cursor.
    private func updateScene() {
        guard let applied = connection.applied, !viewport.viewSize.isEmpty else { return }
        let scale = view.window?.screen.nativeScale ?? view.traitCollection.displayScale
        let frame = viewport.frameInView
        var scene = RenderScene(videoRect: CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                                  width: frame.size.width * scale, height: frame.size.height * scale))
        if let cursor = connection.cursor?.drawn {
            // View points per Mac point: stream pixels per Mac point, times view points per stream pixel.
            let factor = Double(applied.scale > 0 ? applied.scale : 1) * viewport.scale
            let hot = viewport.view(fromNormalized: cursor.position)
            let rect = CGRect(x: (hot.x - cursor.hot.x * factor) * scale, y: (hot.y - cursor.hot.y * factor) * scale,
                              width: cursor.size.width * factor * scale, height: cursor.size.height * factor * scale)
            scene.cursor = CursorPlacement(id: cursor.id, rect: rect)
        }
        connection.setScene(scene)
    }

    // MARK: Touches

    fileprivate func touches(_ phase: TouchPhase, _ touches: Set<UITouch>, event: UIEvent?) {
        guard connection.state == .streaming else { return }
        // Trackpad and mouse clicks have their own path.
        let pointer = touches.filter { $0.type == .indirectPointer }
        for touch in pointer { pointerTouch(phase, touch, event: event) }
        let touches = touches.subtracting(pointer)
        guard !touches.isEmpty else { return }
        let samples = touches.map { touch in
            let p = touch.location(in: view)
            return TouchSample(id: ObjectIdentifier(touch).hashValue, location: Point2(p.x, p.y), isPencil: touch.type == .pencil)
        }
        let time = touches.map(\.timestamp).max() ?? CACurrentMediaTime()
        if phase == .began, recognizer.mode != connection.inputMode, (event?.allTouches?.count ?? 1) == touches.count {
            // A new gesture with no other fingers down: safe to switch mode.
            recognizer.mode = connection.inputMode
        }
        perform(recognizer.touches(phase, samples, at: .seconds(time)))
    }

    // MARK: Trackpad and mouse

    /// A trackpad or mouse click. Down presses at once, so click-drag is a drag (plan section 9,
    /// hardware pointer).
    private func pointerTouch(_ phase: TouchPhase, _ touch: UITouch, event: UIEvent?) {
        let p = touch.location(in: view)
        let point = Point2(p.x, p.y)
        let id = ObjectIdentifier(touch)
        switch phase {
        case .began:
            guard pointerButton == nil else { return }
            let button: GestureAction.Button = event?.buttonMask.contains(.secondary) == true ? .right : .left
            pointerButton = (id, button)
            let count = clicks.down(button == .left ? 1 : 2, at: point, time: .seconds(touch.timestamp))
            perform([.move(point), .button(button, down: true, at: point, clickCount: count)])
        case .moved:
            guard pointerButton?.touch == id else { return }
            perform([.move(point)])
        case .ended, .cancelled:
            guard let held = pointerButton, held.touch == id else { return }
            pointerButton = nil
            perform([.button(held.button, down: false, at: point, clickCount: 1)])
        }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard connection.state == .streaming, pointerButton == nil else { return }
        switch recognizer.state {
        case .began, .changed:
            let p = recognizer.location(in: view)
            perform([.move(Point2(p.x, p.y))])
        default:
            break
        }
    }

    /// Two fingers on a trackpad: gesture phases pass through, and momentum is synthesized from
    /// the release velocity, as for touch scrolling.
    @objc private func trackpadScrolled(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        let delta = Point2(translation.x - lastTrackpadTranslation.x, translation.y - lastTrackpadTranslation.y)
        lastTrackpadTranslation = translation
        let now = Duration.seconds(CACurrentMediaTime())
        switch pan.state {
        case .began:
            perform(trackpadMomentum.stop().map { [$0] } ?? [])
            lastTrackpadTranslation = translation
            perform([.scroll(dx: translation.x, dy: translation.y, phase: .began, momentum: .none)])
        case .changed:
            perform([.scroll(dx: delta.x, dy: delta.y, phase: .changed, momentum: .none)])
        case .ended:
            perform([.scroll(dx: delta.x, dy: delta.y, phase: .ended, momentum: .none)])
            let velocity = pan.velocity(in: view)
            trackpadMomentum.start(velocity: Point2(velocity.x, velocity.y), at: now)
            lastTrackpadTranslation = .zero
        case .cancelled, .failed:
            perform([.scroll(dx: 0, dy: 0, phase: .cancelled, momentum: .none)])
            lastTrackpadTranslation = .zero
        default:
            break
        }
    }

    /// A mouse wheel: line-based scroll, no phases (plan section 9).
    @objc private func wheelScrolled(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        let dx = translation.x - lastWheelTranslation.x, dy = translation.y - lastWheelTranslation.y
        lastWheelTranslation = pan.state == .ended || pan.state == .cancelled ? .zero : translation
        guard connection.applied != nil, dx != 0 || dy != 0 else { return }
        // UIKit reports about 10 points per notch.
        func lines(_ v: Double) -> Float { v == 0 ? 0 : Float((v / 10).rounded(.awayFromZero)) }
        connection.sendInput(.scroll(.with {
            $0.dx = lines(dx)
            $0.dy = lines(dy)
            $0.continuous = false
        }))
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // The Mac's cursor is drawn in the video; the iPadOS pointer would hide it.
        .hidden()
    }

    // MARK: Keys

    fileprivate func press(_ presses: Set<UIPress>, down: Bool) -> Bool {
        guard connection.state == .streaming else { return false }
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = true
            connection.keyboard.hardware(UInt32(key.keyCode.rawValue), down: down,
                                         capsLock: key.modifierFlags.contains(.alphaShift))
        }
        return handled
    }

    @objc private func tick(_ link: CADisplayLink) {
        perform(recognizer.advance(to: .seconds(CACurrentMediaTime())))
        if let step = trackpadMomentum.advance(to: .seconds(CACurrentMediaTime())) { perform([step]) }
        flushMove()
        if !heldButtons.isEmpty || connection.keyboard.anyHeld, link.timestamp - lastHeartbeat >= 0.1 {
            lastHeartbeat = link.timestamp
            connection.sendInput(.inputHeartbeat(.init()))
        }
    }

    private func perform(_ actions: [GestureAction]) {
        guard !actions.isEmpty, let applied = connection.applied else { return }
        var sceneChanged = false
        for action in actions {
            switch action {
            case .move(let point):
                pendingMove = viewport.normalized(fromView: point)

            case let .button(button, down, point, clickCount):
                // The click carries its own position; the pending move goes first so the cursor
                // is already there.
                let position = viewport.normalized(fromView: point)
                pendingMove = position
                flushMove()
                let wire: Farside_V1_MouseButton = button == .left ? .left : .right
                let bit = ButtonSet(wireButton: wire.rawValue)
                if down { heldButtons.insert(bit) } else { heldButtons.remove(bit) }
                connection.sendInput(.button(.with {
                    $0.button = wire
                    $0.down = down
                    $0.clickCount = UInt32(clickCount)
                    $0.displayID = applied.displayID
                    $0.x = Float(position.x)
                    $0.y = Float(position.y)
                }))

            case let .scroll(dx, dy, phase, momentum):
                // View points to Mac points.
                let perPoint = Double(applied.scale > 0 ? applied.scale : 1) * viewport.scale
                connection.sendInput(.scroll(.with {
                    $0.dx = Float(dx / perPoint)
                    $0.dy = Float(dy / perPoint)
                    $0.phase = Self.wire(phase)
                    $0.momentumPhase = Self.wire(momentum)
                    $0.continuous = true
                }))

            case .moveBy(let delta):
                // Trackpad mode: from where the cursor is now, as far as the finger went.
                let base = pendingMove ?? connection.cursor?.drawn?.position ?? Point2(0.5, 0.5)
                let step = viewport.normalizedDelta(fromView: delta)
                pendingMove = Point2(min(max(base.x + step.x, 0), 1), min(max(base.y + step.y, 0), 1))

            case let .cursorButton(button, down, clickCount):
                let position = pendingMove ?? connection.cursor?.drawn?.position ?? Point2(0.5, 0.5)
                let point = viewport.view(fromNormalized: position)
                perform([.button(button, down: down, at: point, clickCount: clickCount)])

            case .shortcut(let shortcut):
                let arrow: UInt32 = switch shortcut {
                case .missionControl: KeyMap.Usage.upArrow
                case .spaceLeft: KeyMap.Usage.leftArrow
                case .spaceRight: KeyMap.Usage.rightArrow
                }
                sendChord(modifier: KeyMap.Usage.leftControl, bit: .leftControl, key: arrow)

            case .toggleToolbar:
                connection.showsToolbar.toggle()

            case let .zoom(factor, anchor):
                viewport.zoom(by: factor, around: anchor)
                sceneChanged = true

            case .pan(let delta):
                viewport.pan(by: delta)
                sceneChanged = true

            case .longPress:
                haptics.impactOccurred()
            }
        }
        if sceneChanged { updateScene() }
    }

    /// Sends the newest pointer position, at most once per refresh.
    private func flushMove() {
        guard let move = pendingMove, let applied = connection.applied else { return }
        pendingMove = nil
        guard let seq = connection.sendInput(.pointerMove(.with {
            $0.displayID = applied.displayID
            $0.x = Float(move.x)
            $0.y = Float(move.y)
            $0.buttons = heldButtons.rawValue
        })) else { return }
        connection.cursor?.localMove(to: move, seq: seq)
        if viewport.zoom > 1 {
            viewport.reveal(normalized: move)
        }
        updateScene()
    }

    /// A shortcut as real key presses: modifier down, key down and up, modifier up.
    private func sendChord(modifier: UInt32, bit: ModifierSet, key: UInt32) {
        connection.keyboard.chord(bit, key)
    }

    fileprivate func softwareText(_ text: String) {
        guard connection.state == .streaming else { return }
        connection.keyboard.text(text)
    }

    fileprivate func softwareDelete() {
        guard connection.state == .streaming else { return }
        connection.keyboard.tap(KeyMap.Usage.deleteBackward)
    }

    /// Nothing may stay held on the Mac while the iPad is not in front (plan section 7, app
    /// lifecycle: inactive releases all held keys and buttons).
    @objc private func resignActive() {
        releaseAll()
    }

    private func releaseAll() {
        heldButtons = []
        pendingMove = nil
        pointerButton = nil
        recognizer = TouchGestureRecognizer()
        _ = trackpadMomentum.stop()
        connection.keyboard.reset()
        connection.sendInput(.releaseAll(.init()))
    }

    private static func wire(_ phase: GestureAction.Phase) -> Farside_V1_ScrollPhase {
        switch phase {
        case .none: .none
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        }
    }
}

/// Hands raw touches and key presses to the controller, and is the software keyboard's text input
/// (plan section 9: autocorrect, smart punctuation and capitalization off).
private final class TouchView: UIView, UIKeyInput {
    weak var owner: SessionViewController?
    /// An empty input view keeps the software keyboard away while hardware keys still arrive.
    private var keyboardHidden = UIView()
    private var showsKeyboard = false

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { showsKeyboard ? nil : keyboardHidden }

    func setSoftwareKeyboard(_ shown: Bool) {
        showsKeyboard = shown
        if !isFirstResponder { becomeFirstResponder() }
        reloadInputViews()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { owner?.touches(.began, touches, event: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { owner?.touches(.moved, touches, event: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { owner?.touches(.ended, touches, event: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { owner?.touches(.cancelled, touches, event: event) }

    // Hardware keys. Handled presses do not go on to `insertText`.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if owner?.press(presses, down: true) != true { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if owner?.press(presses, down: false) != true { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if owner?.press(presses, down: false) != true { super.pressesCancelled(presses, with: event) }
    }

    // MARK: UIKeyInput, the software keyboard

    var hasText: Bool { true }
    func insertText(_ text: String) { owner?.softwareText(text) }
    func deleteBackward() { owner?.softwareDelete() }

    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
}

/// The controller in SwiftUI.
struct SessionInputSurface: UIViewControllerRepresentable {
    let connection: ConnectionModel
    func makeUIViewController(context: Context) -> SessionViewController { SessionViewController(connection: connection) }
    func updateUIViewController(_ controller: SessionViewController, context: Context) {}
}
