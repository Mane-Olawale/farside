// The pure input model shared by both apps (plan section 9): the HID usage to macOS virtual key
// table, modifier sets and their reconciliation, the shortcut remap table, and the coordinate
// transforms from the iPad's view to the Mac's global display space. No platform types, so every
// rule tests on any machine.

/// Held mouse buttons as the wire's `PointerMove.buttons` bit set: 1 << (button - 1), with the
/// wire numbering left 1, right 2, middle 3.
public struct ButtonSet: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let left = ButtonSet(rawValue: 1 << 0)
    public static let right = ButtonSet(rawValue: 1 << 1)
    public static let middle = ButtonSet(rawValue: 1 << 2)

    /// The bit for a wire button number (1 left, 2 right, 3 middle).
    public init(wireButton: Int) {
        self.init(rawValue: wireButton >= 1 && wireButton <= 32 ? 1 << UInt32(wireButton - 1) : 0)
    }
}
