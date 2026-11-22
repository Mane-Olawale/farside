import ClientInput
import InputModel
import Observation
import WireProtocol

/// The keyboard for one session (plan sections 7 and 9): hardware keys from the session view,
/// toolbar keys, sticky and locked modifiers, the shortcuts menu, and software keyboard text. The
/// rules live in `KeyboardState`; this sends what it returns.
@MainActor
@Observable
final class KeyboardModel {
    private(set) var sticky: ModifierSet = []
    private(set) var locked: ModifierSet = []
    var softwareKeyboardShown = false {
        didSet { if oldValue != softwareKeyboardShown { onSoftwareKeyboardChange?(softwareKeyboardShown) } }
    }

    @ObservationIgnored private var state = KeyboardState()
    @ObservationIgnored private let send: (Envelope.OneOf_Body) -> Void
    /// The session view shows or hides the software keyboard.
    @ObservationIgnored var onSoftwareKeyboardChange: ((Bool) -> Void)?

    init(send: @escaping (Envelope.OneOf_Body) -> Void) {
        self.send = send
    }

    var anyHeld: Bool { state.anyHeld }

    // MARK: Sources

    func hardware(_ usage: UInt32, down: Bool, capsLock: Bool?) {
        emit(state.hardware(usage, down: down, capsLock: capsLock))
    }

    /// A toolbar key, or Return and Delete from the software keyboard.
    func tap(_ usage: UInt32) {
        emit(state.tap(usage))
    }

    func chord(_ modifiers: ModifierSet, _ usage: UInt32) {
        emit(state.chord(modifiers, usage))
    }

    /// Committed text from the software keyboard: Return and Delete go as keys, the rest as text
    /// (plan section 9, software keyboard and text).
    func text(_ string: String) {
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            send(.text(.with { $0.text = buffer }))
            buffer = ""
            emit(state.textCommitted())
        }
        for character in string {
            if character == "\n" || character == "\r" {
                flush()
                tap(KeyMap.Usage.returnKey)
            } else if character == "\t" {
                flush()
                tap(KeyMap.Usage.tab)
            } else {
                buffer.append(character)
            }
        }
        flush()
    }

    /// The toolbar's modifier buttons: tap once for the next key, tap again to lock, tap a locked
    /// one to release it (plan section 7, floating toolbar).
    func toggle(_ bit: ModifierSet) {
        if locked.contains(bit) {
            emit(state.setLocked(state.locked.subtracting(bit)))
        } else if sticky.contains(bit) {
            emit(state.setSticky(state.sticky.subtracting(bit)))
            emit(state.setLocked(state.locked.union(bit)))
        } else {
            emit(state.setSticky(state.sticky.union(bit)))
        }
    }

    /// The Mac released everything; forget what the iPad thought was held.
    func reset() {
        state.reset()
        refresh()
    }

    // MARK: Helpers

    private func emit(_ events: [KeyboardState.KeyEvent]) {
        for event in events {
            send(.key(.with {
                $0.hidUsage = event.usage
                $0.down = event.down
                $0.modifiers = event.modifiers.rawValue
            }))
        }
        refresh()
    }

    private func refresh() {
        if sticky != state.sticky { sticky = state.sticky }
        if locked != state.locked { locked = state.locked }
    }
}
