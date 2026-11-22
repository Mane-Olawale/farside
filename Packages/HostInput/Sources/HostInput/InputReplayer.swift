import InputModel

/// One input event from the iPad, in the host's terms (plan section 9, event model). The host app
/// turns wire messages into these; this package does not know the wire.
public enum InputEvent: Sendable, Equatable {
    /// `seq` orders moves on the unreliable channel: an older one than the newest posted is dropped.
    case pointerMove(display: UInt32, x: Double, y: Double, seq: UInt32)
    case pointerDelta(dx: Double, dy: Double)
    /// `button` uses the wire numbering: 1 left, 2 right, 3 middle.
    case button(Int, down: Bool, clickCount: Int, display: UInt32, x: Double, y: Double)
    /// Deltas in points when `continuous`, in lines when not. Positive dy scrolls the content
    /// down, as a scroll wheel turned towards you on a Mac with natural scrolling off.
    case scroll(dx: Double, dy: Double, phase: ScrollPhase, momentum: ScrollPhase, continuous: Bool)
    case key(hidUsage: UInt32, down: Bool, modifiers: ModifierSet)
    case text(String)
    case releaseAll
    case heartbeat
}

public enum ScrollPhase: Sendable, Equatable {
    case none, began, changed, ended, cancelled, mayBegin
}

/// What the replayer asks the Mac to post, in order. Pure values, so every rule in section 9's
/// replay table is a unit test.
public enum PostedEvent: Sendable, Equatable {
    /// To a point in the global display space. `drag` is the held button whose dragged event type
    /// to use; nil posts a plain move.
    case move(Point2, drag: MouseButton?)
    case delta(dx: Int64, dy: Int64)
    case button(MouseButton, down: Bool, at: Point2, clickCount: Int)
    /// Raw `CGScrollPhase` and `CGMomentumScrollPhase` values.
    case scroll(dx: Int32, dy: Int32, pixels: Bool, phase: Int64, momentum: Int64)
    /// A key by virtual key code with raw `CGEventFlags`. `isRepeat` marks host-generated repeats.
    case key(UInt16, down: Bool, flags: UInt64, isRepeat: Bool)
    /// A key event carrying a Unicode string.
    case text(String)
    /// Tell macOS a person is here, which wakes a sleeping display.
    case userActivity
}

/// Replays the iPad's input as the Mac expects it (plan section 9, replay rules):
/// moves become drags while a button is held, modifiers are reconciled against what was posted,
/// Caps Lock becomes Shift on letters, keys repeat on the host's own timer, and everything held is
/// released when the iPad goes quiet or the session ends.
///
/// Not thread-safe: the host calls it from one serial queue, which is also the posting order.
/// Time is passed in, so tests drive it with a fake clock.
public struct InputReplayer: Sendable {
    public struct Settings: Sendable, Equatable {
        /// The Mac's own key repeat delay and interval (System Settings, Keyboard).
        public var repeatDelay: Duration
        public var repeatInterval: Duration
        /// Repeats stop when the iPad has been silent this long with a key held (section 9).
        public var repeatSilence: Duration
        /// Everything held is released when the iPad has been silent this long.
        public var releaseSilence: Duration
        /// A new user-activity declaration after this long without one.
        public var activityInterval: Duration
        /// Largest text chunk per key event, in UTF-16 units (spike S2 found 100 works; 20 is safe).
        public var textChunk: Int

        public init(repeatDelay: Duration = .milliseconds(500), repeatInterval: Duration = .milliseconds(83),
                    repeatSilence: Duration = .milliseconds(300), releaseSilence: Duration = .seconds(1),
                    activityInterval: Duration = .seconds(30), textChunk: Int = 20) {
            self.repeatDelay = repeatDelay
            self.repeatInterval = repeatInterval
            self.repeatSilence = repeatSilence
            self.releaseSilence = releaseSilence
            self.activityInterval = activityInterval
            self.textChunk = textChunk
        }
    }

    public var settings: Settings
    /// Global bounds of a display, in points, by id. Nil for a display that is gone.
    public var displayBounds: @Sendable (UInt32) -> Rect2?

    public private(set) var held = HeldInputs()
    /// Modifier keys posted down, in the wire's bit layout.
    public private(set) var postedModifiers: ModifierSet = []
    /// The newest pointer move posted, echoed in cursor reports (plan section 9, local cursor
    /// prediction).
    public private(set) var lastPointerSeq: UInt32?
    public private(set) var lastLocation: Point2?

    private var repeating: (key: UInt16, flags: UInt64, next: Duration)?
    private var lastHeard: Duration?
    private var lastActivity: Duration?
    /// Fractional scroll left over, so slow trackpad scrolls are not rounded away.
    private var scrollRemainder = Point2(0, 0)

    public init(settings: Settings = Settings(), displayBounds: @escaping @Sendable (UInt32) -> Rect2?) {
        self.settings = settings
        self.displayBounds = displayBounds
    }

    // MARK: Events

    public mutating func handle(_ event: InputEvent, at now: Duration) -> [PostedEvent] {
        lastHeard = now
        var out: [PostedEvent] = []
        if event != .heartbeat, lastActivity.map({ now - $0 >= settings.activityInterval }) ?? true {
            lastActivity = now
            out.append(.userActivity)
        }
        switch event {
        case let .pointerMove(display, x, y, seq):
            if let last = lastPointerSeq, !Self.isNewer(seq, than: last) { return out }
            guard let point = point(display: display, x: x, y: y) else { return out }
            lastPointerSeq = seq
            lastLocation = point
            out.append(.move(point, drag: held.dragButton))

        case let .pointerDelta(dx, dy):
            out.append(.delta(dx: Int64(dx.rounded()), dy: Int64(dy.rounded())))

        case let .button(number, down, clickCount, display, x, y):
            guard number >= 1, let point = point(display: display, x: x, y: y) ?? lastLocation else { return out }
            let button = MouseButton(number - 1)
            // An up for a button that is not held would confuse apps; a repeated down likewise.
            guard held.button(button, down: down) else { return out }
            lastLocation = point
            out.append(.button(button, down: down, at: point, clickCount: max(clickCount, 1)))

        case let .scroll(dx, dy, phase, momentum, continuous):
            if continuous {
                let x = dx + scrollRemainder.x
                let y = dy + scrollRemainder.y
                let ix = x.rounded(.towardZero), iy = y.rounded(.towardZero)
                scrollRemainder = Point2(x - ix, y - iy)
                if phase == .ended || phase == .cancelled || momentum == .ended { scrollRemainder = Point2(0, 0) }
                out.append(.scroll(dx: Int32(clamping: Int(ix)), dy: Int32(clamping: Int(iy)), pixels: true,
                                   phase: Self.cgScrollPhase(phase), momentum: Self.cgMomentumPhase(momentum)))
            } else {
                out.append(.scroll(dx: Int32(clamping: Int(dx.rounded())), dy: Int32(clamping: Int(dy.rounded())),
                                   pixels: false, phase: 0, momentum: 0))
            }

        case let .key(usage, down, modifiers):
            out += key(usage, down: down, modifiers: modifiers, at: now)

        case let .text(string):
            stopRepeat()
            out += TextChunker.chunks(string, maxUTF16: settings.textChunk).map { .text($0) }

        case .releaseAll:
            out += releaseAll()

        case .heartbeat:
            break
        }
        return out
    }

    /// Releases every key and button held, and stops any repeat (plan section 9, stuck keys).
    /// Plain keys first, then modifiers, then buttons.
    public mutating func releaseAll() -> [PostedEvent] {
        stopRepeat()
        var out: [PostedEvent] = []
        let modifierKeys = Set(postedModifiers.members.compactMap { $0.hidUsage }.compactMap(KeyMap.virtualKey(forHIDUsage:)))
        let (keys, buttons) = held.takeAll(isModifier: { modifierKeys.contains($0) })
        for key in keys {
            out.append(.key(key, down: false, flags: MacEventFlags.nonCoalesced, isRepeat: false))
        }
        postedModifiers = []
        let location = lastLocation ?? Point2(0, 0)
        for button in buttons {
            out.append(.button(button, down: false, at: location, clickCount: 1))
        }
        scrollRemainder = Point2(0, 0)
        return out
    }

    // MARK: Time

    /// When `advance` next has something to do, if anything.
    public var nextDeadline: Duration? {
        var deadlines: [Duration] = []
        if let repeating { deadlines.append(repeating.next) }
        if let lastHeard, !held.isEmpty { deadlines.append(lastHeard + settings.releaseSilence) }
        return deadlines.min()
    }

    /// Repeats that are due, and the release when the iPad has gone quiet.
    public mutating func advance(to now: Duration) -> [PostedEvent] {
        var out: [PostedEvent] = []
        if let lastHeard, !held.isEmpty, now - lastHeard >= settings.releaseSilence {
            return releaseAll()
        }
        while let current = repeating, current.next <= now {
            if let lastHeard, now - lastHeard >= settings.repeatSilence {
                // The network stalled with a key held: stop, rather than run away (section 9).
                stopRepeat()
                break
            }
            out.append(.key(current.key, down: true, flags: current.flags, isRepeat: true))
            repeating = (current.key, current.flags, current.next + settings.repeatInterval)
        }
        return out
    }

    // MARK: Keys

    private mutating func key(_ usage: UInt32, down: Bool, modifiers: ModifierSet, at now: Duration) -> [PostedEvent] {
        // Caps Lock is never posted (spike S2); its state rides in `modifiers`.
        if usage == KeyMap.Usage.capsLock { return [] }
        var out = reconcile(to: modifiers)
        if ModifierSet(hidUsage: usage) != nil {
            // Modifier keys were posted by the reconcile, in line with the set the iPad sent.
            if !down { stopRepeat() }
            return out
        }
        guard let code = KeyMap.virtualKey(forHIDUsage: usage) else { return out }
        let flags = MacEventFlags.flags(for: modifiers, virtualKey: code, isLetter: KeyMap.Usage.isLetter(usage))
        if down {
            held.key(code, down: true)
            out.append(.key(code, down: true, flags: flags, isRepeat: false))
            repeating = (code, flags, now + settings.repeatDelay)
        } else {
            // An up for a key not held is still posted: harmless, and it clears a key the Mac
            // might think is down.
            held.key(code, down: false)
            out.append(.key(code, down: false, flags: flags, isRepeat: false))
            if repeating?.key == code { stopRepeat() }
        }
        return out
    }

    /// Posts modifier key changes so the Mac holds exactly `wanted`. Modifier keys are posted as
    /// keys, which produces the flags-changed events apps expect (section 9).
    private mutating func reconcile(to wanted: ModifierSet) -> [PostedEvent] {
        var out: [PostedEvent] = []
        for change in ModifierReconciler.changes(posted: postedModifiers, wanted: wanted) {
            guard let code = KeyMap.virtualKey(forHIDUsage: change.usage), let bit = ModifierSet(hidUsage: change.usage) else { continue }
            if change.down { postedModifiers.insert(bit) } else { postedModifiers.remove(bit) }
            held.key(code, down: change.down)
            out.append(.key(code, down: change.down,
                            flags: MacEventFlags.flags(for: postedModifiers, virtualKey: code, isLetter: false), isRepeat: false))
        }
        return out
    }

    private mutating func stopRepeat() { repeating = nil }

    // MARK: Helpers

    private func point(display: UInt32, x: Double, y: Double) -> Point2? {
        guard let bounds = displayBounds(display) else { return nil }
        return DisplayMapping(bounds: bounds).global(fromNormalized: Point2(x, y))
    }

    /// Sequence comparison with wrap-around (RFC 1982 style).
    static func isNewer(_ a: UInt32, than b: UInt32) -> Bool {
        a != b && (a &- b) < 0x8000_0000
    }

    static func cgScrollPhase(_ phase: ScrollPhase) -> Int64 {
        switch phase {
        case .none: 0
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .cancelled: 8
        case .mayBegin: 128
        }
    }

    static func cgMomentumPhase(_ phase: ScrollPhase) -> Int64 {
        switch phase {
        case .none, .mayBegin: 0
        case .began: 1
        case .changed: 2
        case .ended, .cancelled: 3
        }
    }
}
