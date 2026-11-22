import InputModel
import Testing
@testable import ClientInput

@Suite struct KeyboardStateTests {
    typealias E = KeyboardState.KeyEvent
    let k: UInt32 = 0x0E, tab = KeyMap.Usage.tab, esc = KeyMap.Usage.escape
    let cmd = KeyMap.Usage.leftCommand, opt = KeyMap.Usage.leftOption, shift = KeyMap.Usage.leftShift

    /// Spike S7: Command-period arrived without the Command flag. The set comes from keys seen.
    @Test func hardwareModifiersComeFromKeysSeen() {
        var s = KeyboardState()
        _ = s.hardware(cmd, down: true)
        #expect(s.hardware(k, down: true) == [E(usage: k, down: true, modifiers: .leftCommand)])
        #expect(s.anyHeld)
        _ = s.hardware(k, down: false)
        #expect(s.hardware(cmd, down: false) == [E(usage: cmd, down: false, modifiers: [])])
        #expect(!s.anyHeld)
    }

    @Test func capsLockStateRidesAlong() {
        var s = KeyboardState()
        #expect(s.hardware(k, down: true, capsLock: true).first?.modifiers == .capsLock)
    }

    /// Option-Tab reaches the Mac as Command-Tab for as long as Option is held.
    @Test func remapAppliesToHardwareKeys() {
        var s = KeyboardState()
        _ = s.hardware(opt, down: true)
        #expect(s.hardware(tab, down: true).first?.modifiers == .leftCommand)
        _ = s.hardware(tab, down: false)
        #expect(s.hardware(opt, down: false).first?.modifiers == [])
    }

    /// Toolbar Command, then Tab on the keyboard: Command applies to Tab, then is released.
    @Test func stickyModifierAppliesOnceAndIsReleased() {
        var s = KeyboardState()
        #expect(s.setSticky(.leftCommand).isEmpty)
        let events = s.hardware(tab, down: true) + s.hardware(tab, down: false)
        #expect(events == [
            E(usage: tab, down: true, modifiers: .leftCommand),
            E(usage: tab, down: false, modifiers: .leftCommand),
            E(usage: cmd, down: false, modifiers: []),
        ])
        #expect(s.sticky == [])
    }

    @Test func lockedModifiersStay() {
        var s = KeyboardState()
        _ = s.setLocked(.leftShift)
        #expect(s.tap(esc) == [E(usage: esc, down: true, modifiers: .leftShift), E(usage: esc, down: false, modifiers: .leftShift)])
        #expect(s.setLocked([]) == [E(usage: shift, down: false, modifiers: [])])
    }

    @Test func turningStickyOffUnusedReleasesIt() {
        var s = KeyboardState()
        _ = s.setSticky(.leftOption)
        #expect(s.setSticky([]) == [E(usage: opt, down: false, modifiers: [])])
    }

    /// Shortcuts menu: Command-Shift-3 goes down together and comes back to nothing held.
    @Test func chordReturnsToWhatIsHeld() {
        var s = KeyboardState()
        let three: UInt32 = 0x20
        #expect(s.chord([.leftCommand, .leftShift], three) == [
            E(usage: three, down: true, modifiers: [.leftCommand, .leftShift]),
            E(usage: three, down: false, modifiers: [.leftCommand, .leftShift]),
            E(usage: shift, down: false, modifiers: []),
        ])
    }

    @Test func textUsesUpStickyModifiers() {
        var s = KeyboardState()
        _ = s.setSticky(.leftControl)
        #expect(s.textCommitted() == [E(usage: KeyMap.Usage.leftControl, down: false, modifiers: [])])
    }

    @Test func resetForgetsEverything() {
        var s = KeyboardState()
        _ = s.hardware(cmd, down: true)
        _ = s.hardware(k, down: true)
        _ = s.setLocked(.leftShift)
        s.reset()
        #expect(!s.anyHeld)
        #expect(s.tracker.current == [])
    }
}
