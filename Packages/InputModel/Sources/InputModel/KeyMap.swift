/// USB HID keyboard usages (page 7) to macOS virtual key codes (plan section 9 and appendix D).
///
/// The iPad sends which physical key was pressed; the Mac's active keyboard layout then decides
/// the character, so Mac shortcuts work as on a keyboard plugged into the Mac. Keys the Mac has
/// no virtual key for map to nil and are dropped. Media and brightness keys are out of scope for
/// v1 (section 9, replay rules) and are left out on purpose.
public enum KeyMap {
    /// The macOS virtual key for a HID usage, or nil if the Mac has none.
    public static func virtualKey(forHIDUsage usage: UInt32) -> UInt16? {
        table[usage]
    }

    /// The HID usage for a macOS virtual key. Where two usages share a virtual key (the Non-US #
    /// and the backslash key), the first in the table wins.
    public static func hidUsage(forVirtualKey key: UInt16) -> UInt32? {
        reverse[key]
    }

    public static let table: [UInt32: UInt16] = {
        var map: [UInt32: UInt16] = [:]
        for (usage, key) in pairs where map[usage] == nil { map[usage] = key }
        return map
    }()

    private static let reverse: [UInt16: UInt32] = {
        var map: [UInt16: UInt32] = [:]
        for (usage, key) in pairs where map[key] == nil { map[key] = usage }
        return map
    }()

    /// HID usages, named for tests and callers.
    public enum Usage {
        public static let a: UInt32 = 0x04
        public static let z: UInt32 = 0x1D
        public static let one: UInt32 = 0x1E
        public static let zero: UInt32 = 0x27
        public static let returnKey: UInt32 = 0x28
        public static let escape: UInt32 = 0x29
        public static let deleteBackward: UInt32 = 0x2A
        public static let tab: UInt32 = 0x2B
        public static let space: UInt32 = 0x2C
        public static let graveAccent: UInt32 = 0x35
        public static let capsLock: UInt32 = 0x39
        public static let f1: UInt32 = 0x3A
        public static let f12: UInt32 = 0x45
        public static let home: UInt32 = 0x4A
        public static let pageUp: UInt32 = 0x4B
        public static let deleteForward: UInt32 = 0x4C
        public static let end: UInt32 = 0x4D
        public static let pageDown: UInt32 = 0x4E
        public static let rightArrow: UInt32 = 0x4F
        public static let leftArrow: UInt32 = 0x50
        public static let downArrow: UInt32 = 0x51
        public static let upArrow: UInt32 = 0x52
        public static let leftControl: UInt32 = 0xE0
        public static let leftShift: UInt32 = 0xE1
        public static let leftOption: UInt32 = 0xE2
        public static let leftCommand: UInt32 = 0xE3
        public static let rightControl: UInt32 = 0xE4
        public static let rightShift: UInt32 = 0xE5
        public static let rightOption: UInt32 = 0xE6
        public static let rightCommand: UInt32 = 0xE7
        /// Not a HID keyboard usage: the Mac's fn key, sent from the toolbar's sticky Fn,
        /// because iPadOS never gives Globe to apps as a modifier (spike S7). Chosen from the
        /// vendor range so it cannot collide.
        public static let function: UInt32 = 0xFF03

        public static func isLetter(_ usage: UInt32) -> Bool { (a...z).contains(usage) }
        public static func isModifier(_ usage: UInt32) -> Bool { (leftControl...rightCommand).contains(usage) || usage == function }
    }

    /// Virtual keys whose real key events carry extra flags on a Mac keyboard. Some apps check
    /// them, so posted events match hardware.
    public static func isArrow(virtualKey key: UInt16) -> Bool { (0x7B...0x7E).contains(key) }

    /// Function keys and the navigation block, which hardware marks with the secondary-fn flag.
    public static func isFunctionBlock(virtualKey key: UInt16) -> Bool {
        functionBlock.contains(key) || isArrow(virtualKey: key)
    }

    public static func isKeypad(virtualKey key: UInt16) -> Bool { keypad.contains(key) }

    private static let functionBlock: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,  // F1 to F12
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,                          // F13 to F20
        0x72, 0x73, 0x74, 0x75, 0x77, 0x79,                                      // Help, Home, Page Up, Forward Delete, End, Page Down
    ]

    private static let keypad: Set<UInt16> = [
        0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51,
        0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C,
    ]

    /// Usage, virtual key. Order matters only where two usages share a key.
    private static let pairs: [(UInt32, UInt16)] = [
        // Letters
        (0x04, 0x00), (0x05, 0x0B), (0x06, 0x08), (0x07, 0x02), (0x08, 0x0E), (0x09, 0x03),
        (0x0A, 0x05), (0x0B, 0x04), (0x0C, 0x22), (0x0D, 0x26), (0x0E, 0x28), (0x0F, 0x25),
        (0x10, 0x2E), (0x11, 0x2D), (0x12, 0x1F), (0x13, 0x23), (0x14, 0x0C), (0x15, 0x0F),
        (0x16, 0x01), (0x17, 0x11), (0x18, 0x20), (0x19, 0x09), (0x1A, 0x0D), (0x1B, 0x07),
        (0x1C, 0x10), (0x1D, 0x06),
        // Digits 1 to 9, then 0
        (0x1E, 0x12), (0x1F, 0x13), (0x20, 0x14), (0x21, 0x15), (0x22, 0x17), (0x23, 0x16),
        (0x24, 0x1A), (0x25, 0x1C), (0x26, 0x19), (0x27, 0x1D),
        // Return, Escape, Delete, Tab, Space
        (0x28, 0x24), (0x29, 0x35), (0x2A, 0x33), (0x2B, 0x30), (0x2C, 0x31),
        // Punctuation
        (0x2D, 0x1B), (0x2E, 0x18), (0x2F, 0x21), (0x30, 0x1E), (0x31, 0x2A),
        (0x32, 0x2A),  // Non-US # sits where backslash does
        (0x33, 0x29), (0x34, 0x27), (0x35, 0x32), (0x36, 0x2B), (0x37, 0x2F), (0x38, 0x2C),
        // Caps Lock. Mapped for completeness; the host never posts it (spike S2).
        (0x39, 0x39),
        // F1 to F12
        (0x3A, 0x7A), (0x3B, 0x78), (0x3C, 0x63), (0x3D, 0x76), (0x3E, 0x60), (0x3F, 0x61),
        (0x40, 0x62), (0x41, 0x64), (0x42, 0x65), (0x43, 0x6D), (0x44, 0x67), (0x45, 0x6F),
        // Print Screen, Scroll Lock, Pause become F13 to F15, as on Apple's extended keyboard
        (0x46, 0x69), (0x47, 0x6B), (0x48, 0x71),
        // Insert is Help on a Mac
        (0x49, 0x72),
        // Navigation
        (0x4A, 0x73), (0x4B, 0x74), (0x4C, 0x75), (0x4D, 0x77), (0x4E, 0x79),
        (0x4F, 0x7C), (0x50, 0x7B), (0x51, 0x7D), (0x52, 0x7E),
        // Keypad: Num Lock is Clear
        (0x53, 0x47), (0x54, 0x4B), (0x55, 0x43), (0x56, 0x4E), (0x57, 0x45), (0x58, 0x4C),
        (0x59, 0x53), (0x5A, 0x54), (0x5B, 0x55), (0x5C, 0x56), (0x5D, 0x57), (0x5E, 0x58),
        (0x5F, 0x59), (0x60, 0x5B), (0x61, 0x5C), (0x62, 0x52), (0x63, 0x41),
        // ISO section key, between left Shift and Z
        (0x64, 0x0A),
        // Application (context menu)
        (0x65, 0x6E),
        // Keypad equals
        (0x67, 0x51),
        // F13 to F20
        (0x68, 0x69), (0x69, 0x6B), (0x6A, 0x71), (0x6B, 0x6A), (0x6C, 0x40), (0x6D, 0x4F),
        (0x6E, 0x50), (0x6F, 0x5A),
        // Help
        (0x75, 0x72),
        // JIS: keypad comma, Ro, Yen, Kana, Eisu
        (0x85, 0x5F), (0x87, 0x5E), (0x89, 0x5D), (0x90, 0x68), (0x91, 0x66),
        // Modifiers
        (0xE0, 0x3B), (0xE1, 0x38), (0xE2, 0x3A), (0xE3, 0x37),
        (0xE4, 0x3E), (0xE5, 0x3C), (0xE6, 0x3D), (0xE7, 0x36),
        // fn, from the toolbar
        (0xFF03, 0x3F),
    ]
}
