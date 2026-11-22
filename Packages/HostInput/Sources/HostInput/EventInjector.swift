#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// A scroll as the iPad sends it (plan section 9, event model).
public struct ScrollInput: Sendable {
    public enum Units: Sendable { case pixel, line }

    public var dx: Int32
    public var dy: Int32
    public var units: Units
    /// `CGScrollPhase` raw value: 0 none, 1 began, 2 changed, 4 ended, 8 cancelled, 128 may begin.
    public var phase: Int64
    /// `CGMomentumScrollPhase` raw value: 0 none, 1 begin, 2 continue, 3 end.
    public var momentumPhase: Int64

    public init(dx: Int32 = 0, dy: Int32, units: Units = .pixel, phase: Int64 = 0, momentumPhase: Int64 = 0) {
        self.dx = dx
        self.dy = dy
        self.units = units
        self.phase = phase
        self.momentumPhase = momentumPhase
    }
}

/// Posts synthetic input at the HID event tap, following the replay rules in plan section 9.
/// Use from one serial queue. Every event carries `tag` in its source user data field, so the
/// host can tell its own events from a person at the Mac.
public final class EventInjector: @unchecked Sendable {
    public static let defaultTag: Int64 = 0x4641_5253 // "FARS"

    public let tag: Int64
    public private(set) var held = HeldInputs()
    private let source: CGEventSource
    private var lastLocation: CGPoint
    /// The user-activity assertion, reused for every declaration and released with the session.
    private var activityAssertion: IOPMAssertionID = 0

    public init?(tag: Int64 = EventInjector.defaultTag) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }
        // Zero, so the Mac's own keyboard and mouse keep working during a session.
        source.localEventsSuppressionInterval = 0
        self.source = source
        self.tag = tag
        lastLocation = CGEvent(source: nil)?.location ?? .zero
    }

    public var localEventsSuppressionInterval: Double { source.localEventsSuppressionInterval }

    public static var hasPostAccess: Bool { CGPreflightPostEventAccess() }
    @discardableResult public static func requestPostAccess() -> Bool { CGRequestPostEventAccess() }

    // MARK: Pointer

    /// Moves the pointer to `point` in global display points. Posts a dragged event while a
    /// button is held, because apps do not treat moved events as drags.
    public func move(to point: CGPoint) {
        move(to: point, dragging: held.dragButton)
    }

    /// Moves the pointer, posting the dragged event type for `drag` when a button is held.
    public func move(to point: CGPoint, dragging drag: MouseButton?) {
        let type: CGEventType
        let button: CGMouseButton
        switch drag {
        case .left?: (type, button) = (.leftMouseDragged, .left)
        case .right?: (type, button) = (.rightMouseDragged, .right)
        case .some: (type, button) = (.otherMouseDragged, .center)
        case nil: (type, button) = (.mouseMoved, .left)
        }
        post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)) { event in
            if let other = drag, other.number > 1 {
                event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(other.number))
            }
        }
        lastLocation = point
    }

    /// Relative movement for pointer-lock mode. The location stays put; apps read the deltas.
    public func moveBy(dx: Int64, dy: Int64) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: lastLocation, mouseButton: .left)) { event in
            event.setIntegerValueField(.mouseEventDeltaX, value: dx)
            event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        }
    }

    /// Presses or releases `button` at `point`. `clickCount` 2 or 3 makes double and triple
    /// clicks; the caller keeps them within the system double-click interval.
    public func button(_ button: MouseButton, down: Bool, at point: CGPoint, clickCount: Int = 1) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case .left: (type, cgButton) = (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (type, cgButton) = (down ? .rightMouseDown : .rightMouseUp, .right)
        default: (type, cgButton) = (down ? .otherMouseDown : .otherMouseUp, .center)
        }
        held.button(button, down: down)
        post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton)) { event in
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            if button.number > 1 { event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.number)) }
        }
        lastLocation = point
    }

    public func scroll(_ input: ScrollInput) {
        let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: input.units == .pixel ? .pixel : .line,
            wheelCount: 2, wheel1: input.dy, wheel2: input.dx, wheel3: 0)
        post(event) { event in
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: input.units == .pixel ? 1 : 0)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: input.phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: input.momentumPhase)
        }
    }

    // MARK: Keyboard

    /// Posts a key by macOS virtual key code. Modifier keys post as keys too, which makes the
    /// system send the flags-changed events apps expect. With `flags` nil the event takes the
    /// modifier state the HID source already holds.
    public func key(_ code: UInt16, down: Bool, flags: CGEventFlags? = nil, isRepeat: Bool = false) {
        held.key(code, down: down)
        post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)) { event in
            if let flags { event.flags = flags }
            if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        }
    }

    /// Tells macOS a person is using the Mac, which wakes a sleeping display and resets the idle
    /// timer (plan section 9: the first input wakes the display). Reuses one assertion, as the
    /// API asks; `endUserActivity` releases it.
    public func declareUserActivity() {
        IOPMAssertionDeclareUserActivity("Farside input" as CFString, kIOPMUserActiveLocal, &activityAssertion)
    }

    public func endUserActivity() {
        guard activityAssertion != 0 else { return }
        IOPMAssertionRelease(activityAssertion)
        activityAssertion = 0
    }

    /// Types `text` as keyboard events carrying Unicode strings, in chunks that never split a
    /// character.
    public func text(_ text: String, maxUTF16PerEvent: Int = 20) {
        for chunk in TextChunker.chunks(text, maxUTF16: maxUTF16PerEvent) {
            unicodeEvent(chunk)
        }
    }

    /// One key down and up carrying `string`, with no chunking. For probing limits.
    public func unicodeEvent(_ string: String) {
        let units = Array(string.utf16)
        for down in [true, false] {
            post(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)) { event in
                event.flags = []
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            }
        }
    }

    // MARK: Safety

    /// Releases every key and button this injector holds (plan section 9, stuck keys).
    public func releaseAll() {
        let (keys, buttons) = held.takeAll(isModifier: Self.isModifier)
        for code in keys {
            post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)) { _ in }
        }
        for button in buttons {
            held.button(button, down: true)
            self.button(button, down: false, at: lastLocation)
        }
    }

    /// Posts key ups for every modifier, in case a crash left one held (plan section 6).
    public func releaseModifiers() {
        for code in Self.modifierKeys {
            post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)) { event in event.flags = [] }
        }
    }

    public static let modifierKeys: [UInt16] = [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E, 0x3F]
    public static func isModifier(_ code: UInt16) -> Bool { modifierKeys.contains(code) }

    private func post(_ event: CGEvent?, configure: (CGEvent) -> Void) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        configure(event)
        event.post(tap: .cghidEventTap)
    }
}
#endif
