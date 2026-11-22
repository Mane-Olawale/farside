#if os(macOS)
import CoreGraphics
import Foundation
import InputModel

extension EventInjector {
    /// Posts what `InputReplayer` produced, in order. Call on the replayer's serial queue.
    public func post(_ events: [PostedEvent]) {
        for event in events { post(event) }
    }

    public func post(_ event: PostedEvent) {
        switch event {
        case let .move(point, drag):
            move(to: CGPoint(x: point.x, y: point.y), dragging: drag)
        case let .delta(dx, dy):
            moveBy(dx: dx, dy: dy)
        case let .button(button, down, point, clickCount):
            self.button(button, down: down, at: CGPoint(x: point.x, y: point.y), clickCount: clickCount)
        case let .scroll(dx, dy, pixels, phase, momentum):
            scroll(ScrollInput(dx: dx, dy: dy, units: pixels ? .pixel : .line, phase: phase, momentumPhase: momentum))
        case let .key(code, down, flags, isRepeat):
            key(code, down: down, flags: CGEventFlags(rawValue: flags), isRepeat: isRepeat)
        case let .text(string):
            text(string, maxUTF16PerEvent: max(string.utf16.count, 1))
        case .userActivity:
            declareUserActivity()
        }
    }
}
#endif
