// macOS only. CGEvent injection, stuck-key protection, clipboard access.
// The pure parts below build on every platform so they test anywhere.

/// A mouse button as the wire protocol numbers it: 0 left, 1 right, 2 middle, then extras.
public struct MouseButton: Hashable, Sendable, Comparable {
    public let number: Int
    public init(_ number: Int) { self.number = number }
    public static let left = MouseButton(0)
    public static let right = MouseButton(1)
    public static let middle = MouseButton(2)
    public static func < (a: MouseButton, b: MouseButton) -> Bool { a.number < b.number }
}

/// Every key and button the host has pressed and not yet released (plan section 9, stuck keys).
public struct HeldInputs: Sendable, Equatable {
    public private(set) var keys: Set<UInt16> = []
    public private(set) var buttons: Set<MouseButton> = []

    public init() {}

    public var isEmpty: Bool { keys.isEmpty && buttons.isEmpty }

    /// Records a key change. Returns false for a repeated down or an up with nothing held,
    /// which the caller may still post but should not count as a state change.
    @discardableResult
    public mutating func key(_ code: UInt16, down: Bool) -> Bool {
        down ? keys.insert(code).inserted : keys.remove(code) != nil
    }

    @discardableResult
    public mutating func button(_ button: MouseButton, down: Bool) -> Bool {
        down ? buttons.insert(button).inserted : buttons.remove(button) != nil
    }

    /// The button whose drag type a move should use while held: left wins, then right, then
    /// the lowest other.
    public var dragButton: MouseButton? {
        if buttons.contains(.left) { return .left }
        if buttons.contains(.right) { return .right }
        return buttons.min()
    }

    /// What to release, in a safe order: non-modifier keys, then modifiers, then buttons.
    /// Clears the record.
    public mutating func takeAll(isModifier: (UInt16) -> Bool) -> (keys: [UInt16], buttons: [MouseButton]) {
        let plain = keys.filter { !isModifier($0) }.sorted()
        let modifiers = keys.filter(isModifier).sorted()
        let held = buttons.sorted()
        keys.removeAll()
        buttons.removeAll()
        return (plain + modifiers, held)
    }
}

/// Splits text for keyboard events that carry a Unicode string. Chunks never split a grapheme
/// cluster and stay within `maxUTF16` code units, except a single cluster longer than that,
/// which goes alone.
public enum TextChunker {
    public static func chunks(_ text: String, maxUTF16: Int = 20) -> [String] {
        var result: [String] = []
        var current = ""
        var units = 0
        for character in text {
            let size = character.utf16.count
            if units + size > maxUTF16, !current.isEmpty {
                result.append(current)
                current = ""
                units = 0
            }
            current.append(character)
            units += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
