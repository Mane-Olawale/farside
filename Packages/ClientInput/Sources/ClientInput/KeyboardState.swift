import InputModel

/// The iPad's keyboard state (plan section 9): the modifier set built from keys seen going down,
/// the toolbar's sticky and locked modifiers, the shortcut remaps, and the keys held. Every method
/// returns the key events to send, each carrying the full modifier set; the Mac reconciles its
/// modifier keys against that set, so a modifier is released by sending a set without it.
public struct KeyboardState: Sendable {
    public struct KeyEvent: Sendable, Equatable {
        public let usage: UInt32
        public let down: Bool
        public let modifiers: ModifierSet
        public init(usage: UInt32, down: Bool, modifiers: ModifierSet) {
            self.usage = usage
            self.down = down
            self.modifiers = modifiers
        }
    }

    public private(set) var tracker = ModifierTracker()
    public var remap = ShortcutRemap()
    /// Non-modifier keys held on the hardware keyboard.
    public private(set) var heldKeys: Set<UInt32> = []

    public init() {}

    /// Anything held that the Mac must hear heartbeats for (plan section 9, keyboard repeat).
    public var anyHeld: Bool { !heldKeys.isEmpty || !tracker.held.isEmpty }

    public var sticky: ModifierSet { tracker.sticky }
    public var locked: ModifierSet { tracker.locked }

    // MARK: Hardware keyboard

    /// A key from the hardware keyboard. `capsLock` is the system's Caps Lock state when known.
    public mutating func hardware(_ usage: UInt32, down: Bool, capsLock: Bool? = nil) -> [KeyEvent] {
        if let capsLock { tracker.setCapsLock(capsLock) }
        tracker.key(usage, down: down)
        let isModifier = KeyMap.Usage.isModifier(usage)
        if !isModifier, usage != KeyMap.Usage.capsLock {
            if down { heldKeys.insert(usage) } else { heldKeys.remove(usage) }
        }
        let modifiers = remap.translate(usage: usage, down: down, modifiers: tracker.current)
        var out = [KeyEvent(usage: usage, down: down, modifiers: modifiers)]
        if !down, !isModifier { out += consumeSticky(after: usage) }
        return out
    }

    // MARK: Toolbar

    /// A key tapped on the toolbar, such as Escape or an arrow: down and up with the current
    /// modifiers, sticky ones included, which are then used up.
    public mutating func tap(_ usage: UInt32) -> [KeyEvent] {
        let modifiers = tracker.current
        return [KeyEvent(usage: usage, down: true, modifiers: modifiers),
                KeyEvent(usage: usage, down: false, modifiers: modifiers)] + consumeSticky(after: usage)
    }

    /// A shortcut from the toolbar's menu: the modifiers go down, the key is pressed, then the
    /// modifiers return to what is held.
    public mutating func chord(_ modifiers: ModifierSet, _ usage: UInt32) -> [KeyEvent] {
        let held = tracker.current
        let with = held.union(modifiers)
        var out = [KeyEvent(usage: usage, down: true, modifiers: with),
                   KeyEvent(usage: usage, down: false, modifiers: with)]
        if let first = with.subtracting(held).members.first?.hidUsage {
            out.append(KeyEvent(usage: first, down: false, modifiers: held))
        }
        return out
    }

    /// Text from the software keyboard uses up one-shot modifiers too: none of them applies to it,
    /// so they are released.
    public mutating func textCommitted() -> [KeyEvent] {
        consumeSticky(after: nil)
    }

    /// Sets the toolbar's one-shot modifiers. Returns an event that releases any the Mac no longer
    /// needs, when some were turned off before use.
    public mutating func setSticky(_ set: ModifierSet) -> [KeyEvent] {
        let before = tracker.current
        tracker.setSticky(set)
        return releaseEvent(from: before)
    }

    public mutating func setLocked(_ set: ModifierSet) -> [KeyEvent] {
        let before = tracker.current
        tracker.setLocked(set)
        return releaseEvent(from: before)
    }

    /// Forgets everything held, as the Mac does on release-all.
    public mutating func reset() {
        tracker.reset()
        tracker.setLocked([])
        remap.reset()
        heldKeys = []
    }

    // MARK: Helpers

    private mutating func consumeSticky(after usage: UInt32?) -> [KeyEvent] {
        guard !tracker.sticky.isEmpty else { return [] }
        let before = tracker.current
        tracker.consumeSticky()
        return releaseEvent(from: before)
    }

    /// One modifier-up event carrying the new set, if the set shrank. The Mac releases every
    /// modifier missing from it.
    private func releaseEvent(from before: ModifierSet) -> [KeyEvent] {
        let now = tracker.current
        guard let usage = before.subtracting(now).intersection(.keys).members.first?.hidUsage else { return [] }
        return [KeyEvent(usage: usage, down: false, modifiers: now)]
    }
}
