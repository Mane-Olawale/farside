import Testing
@testable import InputModel

@Suite struct KeyMapTests {
    /// Every row of the plan's appendix D.
    @Test(arguments: [
        (UInt32(0x04), UInt16(0x00)), (0x28, 0x24), (0x29, 0x35), (0x2A, 0x33), (0x2B, 0x30), (0x2C, 0x31),
        (0x39, 0x39), (0x3A, 0x7A), (0x4C, 0x75), (0x4F, 0x7C), (0x50, 0x7B), (0x51, 0x7D), (0x52, 0x7E),
        (0xE0, 0x3B), (0xE1, 0x38), (0xE2, 0x3A), (0xE3, 0x37),
    ])
    func appendixD(usage: UInt32, key: UInt16) {
        #expect(KeyMap.virtualKey(forHIDUsage: usage) == key)
    }

    /// The letters spell QWERTY on the Mac's virtual keys (kVK_ANSI_*).
    @Test func lettersMatchTheANSILayout() {
        let ansi: [UInt16] = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                              0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
        for (offset, key) in ansi.enumerated() {
            #expect(KeyMap.virtualKey(forHIDUsage: KeyMap.Usage.a + UInt32(offset)) == key, "letter \(offset)")
        }
    }

    @Test func digitsAndFunctionKeys() {
        let digits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        for (offset, key) in digits.enumerated() {
            #expect(KeyMap.virtualKey(forHIDUsage: KeyMap.Usage.one + UInt32(offset)) == key)
        }
        let functions: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (offset, key) in functions.enumerated() {
            #expect(KeyMap.virtualKey(forHIDUsage: KeyMap.Usage.f1 + UInt32(offset)) == key)
        }
    }

    /// Only the known aliases share a virtual key: Non-US # with backslash, and the PC keys that
    /// become F13 to F15 and Help.
    @Test func noAccidentalCollisions() {
        var byKey: [UInt16: [UInt32]] = [:]
        for (usage, key) in KeyMap.table { byKey[key, default: []].append(usage) }
        let shared = byKey.filter { $0.value.count > 1 }.mapValues { Set($0) }
        #expect(shared == [
            0x2A: [0x31, 0x32],  // backslash, Non-US #
            0x69: [0x46, 0x68],  // Print Screen, F13
            0x6B: [0x47, 0x69],  // Scroll Lock, F14
            0x71: [0x48, 0x6A],  // Pause, F15
            0x72: [0x49, 0x75],  // Insert, Help
        ])
    }

    @Test func mediaKeysAreLeftOut() {
        for usage: UInt32 in [0x7F, 0x80, 0x81] { #expect(KeyMap.virtualKey(forHIDUsage: usage) == nil) }
    }

    @Test func functionKeyFromTheToolbar() {
        #expect(KeyMap.virtualKey(forHIDUsage: KeyMap.Usage.function) == 0x3F)
    }
}

@Suite struct ModifierTests {
    @Test func bitsMatchTheHIDModifierByte() {
        for usage in UInt32(0xE0)...0xE7 {
            let bit = try! #require(ModifierSet(hidUsage: usage))
            #expect(bit.rawValue == 1 << (usage - 0xE0))
            #expect(bit.hidUsage == usage)
        }
        #expect(ModifierSet(hidUsage: KeyMap.Usage.function) == .function)
        #expect(ModifierSet.function.hidUsage == KeyMap.Usage.function)
        #expect(ModifierSet(hidUsage: KeyMap.Usage.a) == nil)
    }

    /// Spike S7: Command-period arrived with no Command flag. The set comes from keys seen going
    /// down, so Command is still there.
    @Test func trackerBuildsTheSetFromKeysNotFlags() {
        var tracker = ModifierTracker()
        tracker.key(KeyMap.Usage.leftCommand, down: true)
        #expect(tracker.key(0x37, down: true) == false)  // period
        #expect(tracker.current == .leftCommand)
        tracker.key(KeyMap.Usage.leftCommand, down: false)
        #expect(tracker.current == [])
    }

    @Test func capsLockToggles() {
        var tracker = ModifierTracker()
        tracker.key(KeyMap.Usage.capsLock, down: true)
        tracker.key(KeyMap.Usage.capsLock, down: false)
        #expect(tracker.current == .capsLock)
        tracker.key(KeyMap.Usage.capsLock, down: true)
        #expect(tracker.current == [])
    }

    @Test func stickyModifiersLastOneKey() {
        var tracker = ModifierTracker()
        tracker.setSticky(.leftCommand)
        tracker.setLocked(.leftShift)
        #expect(tracker.current == [.leftCommand, .leftShift])
        tracker.consumeSticky()
        #expect(tracker.current == .leftShift)
    }

    @Test func reconcilerReleasesBeforePressing() {
        let changes = ModifierReconciler.changes(posted: [.leftOption, .leftShift], wanted: [.leftCommand, .leftShift])
        #expect(changes == [.init(usage: KeyMap.Usage.leftOption, down: false), .init(usage: KeyMap.Usage.leftCommand, down: true)])
    }

    @Test func reconcilerNeverPostsCapsLock() {
        #expect(ModifierReconciler.changes(posted: [], wanted: .capsLock).isEmpty)
        #expect(ModifierReconciler.changes(posted: .leftShift, wanted: .leftShift).isEmpty)
    }

    /// Spike S2: the Mac's Caps Lock is never posted; letters get Shift instead.
    @Test func capsLockAddsShiftToLettersOnly() {
        let letter = MacEventFlags.flags(for: .capsLock, virtualKey: 0x00, isLetter: true)
        #expect(letter & MacEventFlags.shift != 0)
        let digit = MacEventFlags.flags(for: .capsLock, virtualKey: 0x12, isLetter: false)
        #expect(digit & MacEventFlags.shift == 0)
    }

    @Test func flagsMatchHardwareForArrowsAndFunctionKeys() {
        let arrow = MacEventFlags.flags(for: [], virtualKey: 0x7B, isLetter: false)
        #expect(arrow & MacEventFlags.numericPad != 0)
        #expect(arrow & MacEventFlags.secondaryFn != 0)
        let f5 = MacEventFlags.flags(for: [], virtualKey: 0x60, isLetter: false)
        #expect(f5 & MacEventFlags.secondaryFn != 0)
        #expect(f5 & MacEventFlags.numericPad == 0)
        let a = MacEventFlags.flags(for: [], virtualKey: 0x00, isLetter: true)
        #expect(a == MacEventFlags.nonCoalesced)
    }

    @Test func flagsKeepLeftAndRightApart() {
        let left = MacEventFlags.flags(for: .leftCommand, virtualKey: 0x00, isLetter: true)
        let right = MacEventFlags.flags(for: .rightCommand, virtualKey: 0x00, isLetter: true)
        #expect(left & MacEventFlags.command != 0)
        #expect(right & MacEventFlags.command != 0)
        #expect(left != right)
    }
}

@Suite struct ShortcutRemapTests {
    /// Hold Option, press Tab three times, release Option: the Mac sees Command held throughout,
    /// so the app switcher cycles and then commits.
    @Test func optionTabCyclesTheAppSwitcher() {
        var remap = ShortcutRemap()
        #expect(remap.translate(usage: KeyMap.Usage.leftOption, down: true, modifiers: .leftOption) == .leftOption)
        for _ in 0..<3 {
            #expect(remap.translate(usage: KeyMap.Usage.tab, down: true, modifiers: .leftOption) == .leftCommand)
            #expect(remap.translate(usage: KeyMap.Usage.tab, down: false, modifiers: .leftOption) == .leftCommand)
        }
        #expect(remap.translate(usage: KeyMap.Usage.leftOption, down: false, modifiers: []) == [])
        #expect(!remap.isActive)
        // The next plain Option is Option again.
        #expect(remap.translate(usage: KeyMap.Usage.leftOption, down: true, modifiers: .leftOption) == .leftOption)
    }

    @Test func otherOptionCombinationsPassThrough() {
        var remap = ShortcutRemap()
        #expect(remap.translate(usage: KeyMap.Usage.a, down: true, modifiers: .leftOption) == .leftOption)
        #expect(remap.translate(usage: KeyMap.Usage.tab, down: true, modifiers: [.leftOption, .leftShift]) == [.leftOption, .leftShift])
    }

    @Test func rightOptionMapsToRightCommand() {
        var remap = ShortcutRemap()
        #expect(remap.translate(usage: KeyMap.Usage.space, down: true, modifiers: .rightOption) == .rightCommand)
    }

    @Test func rulesSurviveCoding() throws {
        let data = try JSONEncoder().encode(ShortcutRemap())
        #expect(try JSONDecoder().decode(ShortcutRemap.self, from: data).rules == ShortcutRemap.defaults)
    }
}

import Foundation
