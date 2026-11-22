#if os(macOS)
import Carbon

/// Which key, with or without Shift, types each character on the Mac's current keyboard layout.
/// Typing by key code is the path for the lock screen's password field (plan section 9).
public struct LayoutKeyMap: Sendable {
    public struct Stroke: Sendable, Equatable {
        public let code: UInt16
        public let shift: Bool
    }

    public let layoutName: String
    private let strokes: [Character: Stroke]

    public func stroke(for character: Character) -> Stroke? { strokes[character] }

    /// Builds the map with UCKeyTranslate over every key code, with and without Shift. Dead keys
    /// are ignored, so accented characters reachable only through them have no stroke.
    /// Text Input Source calls must run on the main thread.
    @MainActor
    public static func current() -> LayoutKeyMap? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "unknown"
        var strokes: [Character: Stroke] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for shift in [false, true] {
                for code in UInt16(0)..<128 {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) : 0
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                    guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]),
                          scalar.value >= 0x20, scalar.value != 0x7F
                    else { continue }
                    let character = Character(scalar)
                    if strokes[character] == nil { strokes[character] = Stroke(code: code, shift: shift) }
                }
            }
        }
        return LayoutKeyMap(layoutName: name, strokes: strokes)
    }
}

extension EventInjector {
    /// Types `text` with real key codes on the current layout. Returns the characters it could
    /// not map, which the caller may send as text events instead.
    @discardableResult
    public func typeWithKeyCodes(_ text: String, map: LayoutKeyMap, delay: useconds_t = 15_000) -> [Character] {
        var unmapped: [Character] = []
        for character in text {
            guard let stroke = map.stroke(for: character) else {
                unmapped.append(character)
                continue
            }
            if stroke.shift { key(0x38, down: true, flags: .maskShift) }
            let flags: CGEventFlags = stroke.shift ? .maskShift : []
            key(stroke.code, down: true, flags: flags)
            key(stroke.code, down: false, flags: flags)
            if stroke.shift { key(0x38, down: false, flags: []) }
            usleep(delay)
        }
        return unmapped
    }
}
#endif
