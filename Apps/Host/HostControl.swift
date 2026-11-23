import AppKit
import Carbon.HIToolbox
import os

/// Who is in control, and how the person at the Mac stays in charge (plan section 6, who may
/// connect): attended mode, the disconnect shortcut, and locking the Mac when a session ends.
/// Main actor only.
@MainActor
final class HostControl {
    private let log = Logger(subsystem: "app.farside.host", category: "control")
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onShortcut: (() -> Void)?

    /// Attended mode: ask before each session. Off by default for your own devices.
    var attended: Bool {
        get { UserDefaults.standard.bool(forKey: "attendedMode") }
        set { UserDefaults.standard.set(newValue, forKey: "attendedMode") }
    }

    /// Lock this Mac when a session ends, so whoever walks up to it meets the lock screen.
    var lockOnEnd: Bool {
        get { UserDefaults.standard.bool(forKey: "lockOnSessionEnd") }
        set { UserDefaults.standard.set(newValue, forKey: "lockOnSessionEnd") }
    }

    /// The disconnect shortcut: Control-Option-Command-D, from the Mac's own keyboard.
    static let shortcutDescription = "⌃⌥⌘D"

    // MARK: Attended mode

    /// Asks the person at the Mac. Declines by itself after `timeout`, before the iPad gives up.
    func ask(deviceName: String, takingOver: String?, timeout: Duration = .seconds(9)) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow “\(deviceName)” to control this Mac?"
        alert.informativeText = takingOver.map { "This ends the session with “\($0)”." }
            ?? "It will see this screen and use this Mac's keyboard and mouse."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Decline")
        NSApp.activate()
        let timer = Timer(timeInterval: Double(timeout.components.seconds), repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = alert.runModal()
        timer.invalidate()
        let allowed = response == .alertFirstButtonReturn
        log.info("attended mode: \(allowed ? "allowed" : "declined", privacy: .public)")
        return allowed
    }

    // MARK: Disconnect shortcut

    /// Registers the system-wide shortcut. A Carbon hot key needs no extra permission.
    func registerShortcut(_ action: @escaping () -> Void) {
        onShortcut = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return noErr }
            let control = Unmanaged<HostControl>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { control.onShortcut?() }
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x4653_4844), id: 1)  // "FSHD"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | optionKey | controlKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { log.error("disconnect shortcut not registered: \(status)") }
    }

    // MARK: Lock

    /// Locks the screen with Control-Command-Q, as the Apple menu's Lock Screen does. Needs
    /// Accessibility, which the host has for input.
    func lockScreen() {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        log.info("locked the screen after the session")
    }
}
