import AppKit
import HostCapture
import HostInput
import InputModel
import os
import Synchronization
import WireProtocol

/// Replays the iPad's input on this Mac (plan section 9). Wire messages become `InputEvent`s, the
/// replayer decides what to post, and the injector posts it, all on one serial queue so events
/// keep their order. Timers for key repeat and the silence release run on the same queue.
final class HostInputHandler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "farside.input", qos: .userInteractive)
    private let log = Logger(subsystem: "app.farside.host", category: "input")
    private let injector: EventInjector?
    private var replayer: InputReplayer
    private let origin = ContinuousClock.now
    private var timer: DispatchSourceTimer?
    private let displays = DisplayTable()
    /// Accessibility, checked at most every 2 s: the check is a TCC call.
    private var access: (granted: Bool, checked: ContinuousClock.Instant)?
    private let onAccessMissing: @Sendable () -> Void
    private let lastSeq = Atomic<UInt32>(0)

    /// Reads the Mac's key repeat settings, so call on the main thread.
    @MainActor
    init(onAccessMissing: @escaping @Sendable () -> Void) {
        let settings = InputReplayer.Settings(
            repeatDelay: .milliseconds(Int(NSEvent.keyRepeatDelay * 1000)),
            repeatInterval: .milliseconds(max(Int(NSEvent.keyRepeatInterval * 1000), 15)))
        let displays = self.displays
        displays.set(Self.currentDisplays())
        replayer = InputReplayer(settings: settings) { id in displays.bounds(id) }
        injector = EventInjector()
        self.onAccessMissing = onAccessMissing
    }

    /// The newest pointer move posted, for cursor reports (plan section 9).
    var lastPointerSequence: UInt32 { lastSeq.load(ordering: .relaxed) }

    func refreshDisplays() {
        displays.set(Self.currentDisplays())
    }

    // MARK: Session hooks

    /// The iPad connected: wake the display so it sees the desktop, not a black screen (Phase 2:
    /// display wake on connect).
    func sessionStarted() {
        queue.async { [self] in injector?.declareUserActivity() }
    }

    /// Streaming stopped (pause, recovery, end): nothing may stay held (plan section 9, stuck keys).
    func releaseAll(reason: String) {
        queue.async { [self] in
            let events = replayer.releaseAll()
            if !events.isEmpty { log.info("released \(events.count) held inputs: \(reason, privacy: .public)") }
            injector?.post(events)
            reschedule()
        }
    }

    func sessionEnded() {
        releaseAll(reason: "session ended")
        queue.async { [self] in injector?.endUserActivity() }
    }

    func handle(_ body: Envelope.OneOf_Body, seq: UInt32) {
        guard let event = Self.event(from: body, seq: seq) else { return }
        queue.async { [self] in
            guard hasAccess() else { return }
            let events = replayer.handle(event, at: now())
            injector?.post(events)
            if let seq = replayer.lastPointerSeq { lastSeq.store(seq, ordering: .relaxed) }
            reschedule()
        }
    }

    // MARK: Internals, on the queue

    private func now() -> Duration { ContinuousClock.now - origin }

    private func hasAccess() -> Bool {
        let clock = ContinuousClock.now
        if let access, clock - access.checked < .seconds(2) { return access.granted }
        let granted = EventInjector.hasPostAccess && injector != nil
        if access?.granted != false, !granted {
            log.error("input dropped: no Accessibility access")
            onAccessMissing()
        }
        access = (granted, clock)
        return granted
    }

    /// One timer for the replayer's next deadline: a key repeat or the silence release.
    private func reschedule() {
        timer?.cancel()
        timer = nil
        guard let deadline = replayer.nextDeadline else { return }
        let delay = max(deadline - now(), .zero)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(delay.components.seconds * 1_000_000_000 + delay.components.attoseconds / 1_000_000_000)),
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let events = replayer.advance(to: now())
            if events.contains(where: { if case .key(_, false, _, _) = $0 { true } else { false } }) {
                log.info("released held input after the iPad went quiet")
            }
            injector?.post(events)
            reschedule()
        }
        timer.resume()
        self.timer = timer
    }

    // MARK: Mapping

    private static func currentDisplays() -> [UInt32: Rect2] {
        Dictionary(uniqueKeysWithValues: Displays.current().map { d in
            (d.id, Rect2(d.bounds.minX, d.bounds.minY, d.bounds.width, d.bounds.height))
        })
    }

    /// Wire message to replayer event. Nil for anything that is not input.
    static func event(from body: Envelope.OneOf_Body, seq: UInt32) -> InputEvent? {
        switch body {
        case .pointerMove(let m):
            .pointerMove(display: m.displayID, x: Double(m.x), y: Double(m.y), seq: seq)
        case .pointerDelta(let d):
            .pointerDelta(dx: Double(d.dx), dy: Double(d.dy))
        case .button(let b):
            .button(b.button.rawValue, down: b.down, clickCount: Int(b.clickCount), display: b.displayID, x: Double(b.x), y: Double(b.y))
        case .scroll(let s):
            .scroll(dx: Double(s.dx), dy: Double(s.dy), phase: phase(s.phase), momentum: phase(s.momentumPhase), continuous: s.continuous)
        case .key(let k):
            .key(hidUsage: k.hidUsage, down: k.down, modifiers: ModifierSet(rawValue: k.modifiers))
        case .text(let t):
            .text(t.text)
        case .releaseAll:
            .releaseAll
        case .inputHeartbeat:
            .heartbeat
        default:
            nil
        }
    }

    private static func phase(_ phase: Farside_V1_ScrollPhase) -> ScrollPhase {
        switch phase {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        case .mayBegin: .mayBegin
        case .none, .UNRECOGNIZED: .none
        }
    }
}

/// Display bounds by id, read on the input queue and replaced when displays change.
final class DisplayTable: Sendable {
    private let table = Mutex<[UInt32: Rect2]>([:])
    func set(_ value: [UInt32: Rect2]) { table.withLock { $0 = value } }
    func bounds(_ id: UInt32) -> Rect2? { table.withLock { $0[id] } }
}
