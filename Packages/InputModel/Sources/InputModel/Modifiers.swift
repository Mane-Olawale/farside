/// The full modifier state that travels with every key (plan section 9). The raw values are the
/// wire protocol's `Modifier` bits: the low byte is the USB HID modifier byte, left and right kept
/// apart, then Function and Caps Lock.
public struct ModifierSet: OptionSet, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let leftControl = ModifierSet(rawValue: 0x01)
    public static let leftShift = ModifierSet(rawValue: 0x02)
    public static let leftOption = ModifierSet(rawValue: 0x04)
    public static let leftCommand = ModifierSet(rawValue: 0x08)
    public static let rightControl = ModifierSet(rawValue: 0x10)
    public static let rightShift = ModifierSet(rawValue: 0x20)
    public static let rightOption = ModifierSet(rawValue: 0x40)
    public static let rightCommand = ModifierSet(rawValue: 0x80)
    public static let function = ModifierSet(rawValue: 0x100)
    /// The iPad's Caps Lock is on. Never posted as a key (spike S2).
    public static let capsLock = ModifierSet(rawValue: 0x200)

    public static let control: ModifierSet = [.leftControl, .rightControl]
    public static let shift: ModifierSet = [.leftShift, .rightShift]
    public static let option: ModifierSet = [.leftOption, .rightOption]
    public static let command: ModifierSet = [.leftCommand, .rightCommand]

    /// The bits that are real keys the Mac posts: everything but Caps Lock.
    public static let keys: ModifierSet = [.leftControl, .leftShift, .leftOption, .leftCommand,
                                           .rightControl, .rightShift, .rightOption, .rightCommand, .function]

    /// The modifier bit a HID usage holds down, if it is a modifier key.
    public init?(hidUsage usage: UInt32) {
        switch usage {
        case 0xE0...0xE7: self.init(rawValue: 1 << (usage - 0xE0))
        case KeyMap.Usage.function: self = .function
        default: return nil
        }
    }

    /// The HID usage of the key behind a single-key bit.
    public var hidUsage: UInt32? {
        switch self {
        case .function: KeyMap.Usage.function
        case _ where rawValue != 0 && rawValue & 0xFF == rawValue && rawValue & (rawValue - 1) == 0:
            0xE0 + UInt32(rawValue.trailingZeroBitCount)
        default: nil
        }
    }

    /// Each single-key bit in this set, in HID order.
    public var members: [ModifierSet] {
        (0..<10).map { ModifierSet(rawValue: 1 << $0) }.filter { contains($0) }
    }

    public var description: String {
        let names: [(ModifierSet, String)] = [
            (.leftControl, "lctrl"), (.leftShift, "lshift"), (.leftOption, "lopt"), (.leftCommand, "lcmd"),
            (.rightControl, "rctrl"), (.rightShift, "rshift"), (.rightOption, "ropt"), (.rightCommand, "rcmd"),
            (.function, "fn"), (.capsLock, "caps"),
        ]
        let present = names.filter { contains($0.0) }.map(\.1)
        return present.isEmpty ? "[]" : "[" + present.joined(separator: " ") + "]"
    }
}

/// iPad side: the modifier set to send, built from the modifier keys seen going down and up, not
/// from each event's own flags. Spike S7 saw Command-period arrive with no Command flag while
/// Command was held.
public struct ModifierTracker: Sendable, Equatable {
    public private(set) var held: ModifierSet = []
    /// Caps Lock state, toggled by each Caps Lock press.
    public private(set) var capsLock = false
    /// One-shot modifiers from the toolbar: they apply to the next non-modifier key, then clear.
    public private(set) var sticky: ModifierSet = []
    /// Locked modifiers from the toolbar: they stay until unlocked.
    public private(set) var locked: ModifierSet = []

    public init() {}

    /// The set to send with the next event.
    public var current: ModifierSet {
        held.union(sticky).union(locked).union(capsLock ? .capsLock : [])
    }

    /// Records a key. Returns true if it was a modifier or Caps Lock, which change the state.
    @discardableResult
    public mutating func key(_ usage: UInt32, down: Bool) -> Bool {
        if usage == KeyMap.Usage.capsLock {
            if down { capsLock.toggle() }
            return true
        }
        guard let bit = ModifierSet(hidUsage: usage) else { return false }
        if down { held.insert(bit) } else { held.remove(bit) }
        return true
    }

    /// Sets Caps Lock from the system's own state, when the iPad reports one.
    public mutating func setCapsLock(_ on: Bool) { capsLock = on }

    public mutating func setSticky(_ set: ModifierSet) { sticky = set.intersection(.keys) }
    public mutating func setLocked(_ set: ModifierSet) { locked = set.intersection(.keys) }

    /// Call after a non-modifier key has gone up: one-shot toolbar modifiers are used up.
    public mutating func consumeSticky() { sticky = [] }

    /// Everything the iPad still thinks is held, for release-all.
    public mutating func reset() {
        held = []
        sticky = []
    }
}

/// Mac side: the modifier key events that bring what the host has posted in line with the set
/// the iPad says is held (plan section 9: "The Mac compares the set with its own record and
/// corrects any drift"). Caps Lock is never posted.
public enum ModifierReconciler {
    public struct Change: Equatable, Sendable {
        public let usage: UInt32
        public let down: Bool
        public init(usage: UInt32, down: Bool) {
            self.usage = usage
            self.down = down
        }
    }

    /// Releases first, then presses, each in HID order, so a swap such as Option for Command
    /// never shows both at once.
    public static func changes(posted: ModifierSet, wanted: ModifierSet) -> [Change] {
        let posted = posted.intersection(.keys)
        let wanted = wanted.intersection(.keys)
        let up = posted.subtracting(wanted).members.compactMap { $0.hidUsage }.map { Change(usage: $0, down: false) }
        let down = wanted.subtracting(posted).members.compactMap { $0.hidUsage }.map { Change(usage: $0, down: true) }
        return up + down
    }
}

/// The modifier flags a Mac keyboard puts on a key event, as raw `CGEventFlags` values. Pure so it
/// tests anywhere; the host turns the result into `CGEventFlags(rawValue:)`.
public enum MacEventFlags {
    public static let shift: UInt64 = 0x0002_0000
    public static let control: UInt64 = 0x0004_0000
    public static let option: UInt64 = 0x0008_0000
    public static let command: UInt64 = 0x0010_0000
    public static let numericPad: UInt64 = 0x0020_0000
    public static let secondaryFn: UInt64 = 0x0080_0000
    /// The flag a real key event carries when no modifier is down.
    public static let nonCoalesced: UInt64 = 0x0000_0100

    // Device-dependent bits that tell left from right (IOKit's NX_DEVICE* masks).
    static let leftControl: UInt64 = 0x0001
    static let leftShift: UInt64 = 0x0002
    static let rightShift: UInt64 = 0x0004
    static let leftCommand: UInt64 = 0x0008
    static let rightCommand: UInt64 = 0x0010
    static let leftOption: UInt64 = 0x0020
    static let rightOption: UInt64 = 0x0040
    static let rightControl: UInt64 = 0x2000

    /// Flags for a key event on `virtualKey` with `modifiers` held. Caps Lock adds Shift to
    /// letters only (spike S2: the Mac's own Caps Lock is left alone).
    public static func flags(for modifiers: ModifierSet, virtualKey: UInt16?, isLetter: Bool) -> UInt64 {
        var flags: UInt64 = nonCoalesced
        var effective = modifiers
        if modifiers.contains(.capsLock), isLetter, effective.isDisjoint(with: .shift) {
            effective.insert(.leftShift)
        }
        if !effective.isDisjoint(with: .shift) { flags |= shift }
        if !effective.isDisjoint(with: .control) { flags |= control }
        if !effective.isDisjoint(with: .option) { flags |= option }
        if !effective.isDisjoint(with: .command) { flags |= command }
        if effective.contains(.function) { flags |= secondaryFn }
        if effective.contains(.leftControl) { flags |= leftControl }
        if effective.contains(.rightControl) { flags |= rightControl }
        if effective.contains(.leftShift) { flags |= leftShift }
        if effective.contains(.rightShift) { flags |= rightShift }
        if effective.contains(.leftOption) { flags |= leftOption }
        if effective.contains(.rightOption) { flags |= rightOption }
        if effective.contains(.leftCommand) { flags |= leftCommand }
        if effective.contains(.rightCommand) { flags |= rightCommand }
        if let key = virtualKey {
            if KeyMap.isArrow(virtualKey: key) || KeyMap.isKeypad(virtualKey: key) { flags |= numericPad }
            if KeyMap.isFunctionBlock(virtualKey: key) { flags |= secondaryFn }
        }
        return flags
    }
}
