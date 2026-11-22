import AppKit

/// One event as the app received it. Fields that do not apply to the event's type are nil.
struct RecordedEvent: Codable, Sendable {
    var type: String
    /// `systemUptime` when the event reached the app's local monitor.
    var arrival: TimeInterval
    /// The event's own timestamp, same clock.
    var timestamp: TimeInterval
    /// Global display points, origin at the top left of the main display.
    var location: CGPoint?
    var clickCount: Int?
    var buttonNumber: Int?
    var keyCode: UInt16?
    var characters: String?
    var charactersIgnoringModifiers: String?
    var isARepeat: Bool?
    var flags: UInt
    var scrollDX: Double?
    var scrollDY: Double?
    var precise: Bool?
    var phase: UInt?
    var momentumPhase: UInt?
    var directionInverted: Bool?
    var deltaX: Double?
    var deltaY: Double?
    var userData: Int64?

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: flags) }
}

/// Records every event delivered to this app through a local monitor.
@MainActor
final class Recorder {
    private(set) var events: [RecordedEvent] = []
    private var monitor: Any?

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .any) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return event
        }
    }

    var mark: Int { events.count }
    func since(_ mark: Int) -> [RecordedEvent] { Array(events[mark...]) }

    private func record(_ event: NSEvent) {
        let arrival = ProcessInfo.processInfo.systemUptime
        var r = RecordedEvent(
            type: Self.name(event.type), arrival: arrival, timestamp: event.timestamp,
            flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        r.userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            r.location = Self.global(event)
            r.clickCount = event.clickCount
            r.buttonNumber = event.buttonNumber
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            r.location = Self.global(event)
            r.buttonNumber = event.buttonNumber
            r.deltaX = event.deltaX
            r.deltaY = event.deltaY
        case .mouseMoved:
            r.location = Self.global(event)
            r.deltaX = event.deltaX
            r.deltaY = event.deltaY
        case .scrollWheel:
            r.location = Self.global(event)
            r.scrollDX = event.scrollingDeltaX
            r.scrollDY = event.scrollingDeltaY
            r.precise = event.hasPreciseScrollingDeltas
            r.phase = event.phase.rawValue
            r.momentumPhase = event.momentumPhase.rawValue
            r.directionInverted = event.isDirectionInvertedFromDevice
        case .keyDown, .keyUp:
            r.keyCode = event.keyCode
            r.characters = event.characters
            r.charactersIgnoringModifiers = event.charactersIgnoringModifiers
            r.isARepeat = event.isARepeat
        case .flagsChanged:
            r.keyCode = event.keyCode
        default:
            break
        }
        events.append(r)
    }

    static func global(_ event: NSEvent) -> CGPoint {
        let screenPoint = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: screenPoint.x, y: height - screenPoint.y)
    }

    static func name(_ type: NSEvent.EventType) -> String {
        switch type {
        case .leftMouseDown: "leftMouseDown"
        case .leftMouseUp: "leftMouseUp"
        case .rightMouseDown: "rightMouseDown"
        case .rightMouseUp: "rightMouseUp"
        case .otherMouseDown: "otherMouseDown"
        case .otherMouseUp: "otherMouseUp"
        case .mouseMoved: "mouseMoved"
        case .leftMouseDragged: "leftMouseDragged"
        case .rightMouseDragged: "rightMouseDragged"
        case .otherMouseDragged: "otherMouseDragged"
        case .scrollWheel: "scrollWheel"
        case .keyDown: "keyDown"
        case .keyUp: "keyUp"
        case .flagsChanged: "flagsChanged"
        case .mouseEntered: "mouseEntered"
        case .mouseExited: "mouseExited"
        case .appKitDefined: "appKitDefined"
        case .systemDefined: "systemDefined"
        case .applicationDefined: "applicationDefined"
        case .periodic: "periodic"
        case .cursorUpdate: "cursorUpdate"
        default: "type\(type.rawValue)"
        }
    }
}
