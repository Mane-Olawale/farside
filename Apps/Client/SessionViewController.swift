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
/// heartbeats while a button is held.
final class SessionViewController: UIViewController {
    private let connection: ConnectionModel
    private var viewport = Viewport(viewSize: Size2(0, 0), streamSize: Size2(0, 0))
    private var recognizer = DirectTouchRecognizer()
    private var displayLink: CADisplayLink?
    /// The newest pointer position not yet sent, 0 to 1 on the display.
    private var pendingMove: Point2?
    private var heldButtons: ButtonSet = []
    private var lastHeartbeat: CFTimeInterval = 0
    private var appliedKey: String?
    private let haptics = UIImpactFeedbackGenerator(style: .medium)

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
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
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
        let samples = touches.map { touch in
            let p = touch.location(in: view)
            return TouchSample(id: ObjectIdentifier(touch).hashValue, location: Point2(p.x, p.y), isPencil: touch.type == .pencil)
        }
        let time = touches.map(\.timestamp).max() ?? CACurrentMediaTime()
        perform(recognizer.touches(phase, samples, at: .seconds(time)))
    }

    @objc private func tick(_ link: CADisplayLink) {
        perform(recognizer.advance(to: .seconds(CACurrentMediaTime())))
        flushMove()
        if !heldButtons.isEmpty, link.timestamp - lastHeartbeat >= 0.1 {
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
        for (usage, down, modifiers) in [(modifier, true, bit), (key, true, bit), (key, false, bit), (modifier, false, ModifierSet())] {
            connection.sendInput(.key(.with {
                $0.hidUsage = usage
                $0.down = down
                $0.modifiers = modifiers.rawValue
            }))
        }
    }

    /// Nothing may stay held on the Mac while the iPad is not in front (plan section 7, app
    /// lifecycle: inactive releases all held keys and buttons).
    @objc private func resignActive() {
        releaseAll()
    }

    private func releaseAll() {
        heldButtons = []
        pendingMove = nil
        recognizer = DirectTouchRecognizer()
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

/// Hands raw touches to the controller.
private final class TouchView: UIView {
    weak var owner: SessionViewController?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { owner?.touches(.began, touches, event: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { owner?.touches(.moved, touches, event: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { owner?.touches(.ended, touches, event: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { owner?.touches(.cancelled, touches, event: event) }
}

/// The controller in SwiftUI.
struct SessionInputSurface: UIViewControllerRepresentable {
    let connection: ConnectionModel
    func makeUIViewController(context: Context) -> SessionViewController { SessionViewController(connection: connection) }
    func updateUIViewController(_ controller: SessionViewController, context: Context) {}
}
