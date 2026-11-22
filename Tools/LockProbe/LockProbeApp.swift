import AppKit
import CoreImage
import HostCapture
import HostInput
import MediaCore
import os
import Synchronization

/// Spike S5 rig. Captures the display, locks the Mac, probes typing into the lock screen and
/// optionally unlocks it with a password typed into this window. The password lives only in
/// memory, is never logged or written, and is cleared after use.
@main
@MainActor
final class LockProbeApp: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "app.farside.lockprobe", category: "s5")
    private var window: NSWindow?
    private var passwordField: NSSecureTextField?
    private var status: NSTextField?
    private var startButton: NSButton?

    private var capture: DisplayCapture?
    private let latest = LatestFrame()
    private var injector: EventInjector?
    private let start = Date()
    private var runDirectory: URL!
    private var timeline: [Entry] = []
    private var counterTimer: Timer?
    private var snapshotIndex = 0

    struct Entry: Codable {
        var t: Double
        var event: String
        var locked: Bool?
        var complete: Int?
        var idle: Int?
        var other: Int?
        var snapshot: String?
    }

    struct Report: Codable {
        var date: Date
        var macOS: String
        var keyboardLayout: String
        var passwordProvided: Bool
        var lockedBy: String
        var unlockedBy: String
        var secondsToUnlock: Double?
        var unmappedPasswordCharacters: Int
        var timeline: [Entry]
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = LockProbeApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Farside Lock Probe (spike S5)"
        let content = NSView(frame: w.contentLayoutRect)
        let intro = NSTextField(wrappingLabelWithString: """
        Start locks this Mac with Control-Command-Q, types a harmless probe at the lock screen, then unlocks. \
        Optional: type your login password below to test unlocking by injected keys. It stays in this app's memory \
        only, is never logged or saved, and is cleared after use. Leave it empty to unlock the Mac yourself.
        """)
        intro.frame = NSRect(x: 20, y: 140, width: 520, height: 100)
        let field = NSSecureTextField(frame: NSRect(x: 20, y: 105, width: 340, height: 24))
        field.placeholderString = "Login password (optional)"
        let button = NSButton(title: "Start", target: self, action: #selector(startRun))
        button.frame = NSRect(x: 380, y: 102, width: 100, height: 30)
        button.keyEquivalent = "\r"
        let text = NSTextField(wrappingLabelWithString: "Waiting for Start.")
        text.frame = NSRect(x: 20, y: 15, width: 520, height: 80)
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        [intro, field, button, text].forEach(content.addSubview)
        w.contentView = content
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        passwordField = field
        status = text
        startButton = button
        NSApp.activate()

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess(); text.stringValue = "Grant Screen Recording to LockProbe, then relaunch." }
        if !EventInjector.hasPostAccess { EventInjector.requestPostAccess(); text.stringValue += "\nGrant Accessibility to LockProbe, then relaunch." }
    }

    // MARK: Run

    @objc private func startRun() {
        guard CGPreflightScreenCaptureAccess(), EventInjector.hasPostAccess, let injector = EventInjector() else {
            status?.stringValue = "Missing Screen Recording or Accessibility grant."
            return
        }
        self.injector = injector
        startButton?.isEnabled = false
        passwordField?.isEditable = false
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        runDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Farside/s5/\(stamp)")
        try? FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        Task { await run(injector: injector) }
    }

    private func run(injector: EventInjector) async {
        guard let displayID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let mode = CGDisplayCopyDisplayMode(displayID) else { return note("no display") }
        let latest = self.latest
        let capture = DisplayCapture(onFrame: { latest.set($0.pixels) }, onStop: { [weak self] error in
            Task { @MainActor in self?.note("capture stopped: \(String(describing: error))") }
        })
        self.capture = capture
        do {
            try await capture.start(displayID: displayID, settings: CaptureSettings(width: mode.pixelWidth, height: mode.pixelHeight, framesPerSecond: 30))
        } catch {
            return note("capture failed to start: \(error)")
        }
        counterTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordCounters() }
        }
        let keyMap = LayoutKeyMap.current()

        await sleep(2)
        snapshot("01-before-lock")

        // Lock with the plan's shortcut (section 6, lock when session ends).
        note("posting Control-Command-Q")
        injector.key(0x3B, down: true, flags: .maskControl)
        injector.key(0x37, down: true, flags: [.maskControl, .maskCommand])
        injector.key(0x0C, down: true, flags: [.maskControl, .maskCommand])
        injector.key(0x0C, down: false, flags: [.maskControl, .maskCommand])
        injector.key(0x37, down: false, flags: .maskControl)
        injector.key(0x3B, down: false, flags: [])
        var lockedBy = "Control-Command-Q"
        if !(await waitFor(locked: true, seconds: 6)) {
            lockedBy = "person"
            note("shortcut did not lock; lock the Mac yourself within 30 s")
            if !(await waitFor(locked: true, seconds: 30)) { return finish(lockedBy: "not locked", unlockedBy: "n/a", unlockSeconds: nil, unmapped: 0) }
        }
        note("locked")
        await sleep(3)
        snapshot("02-locked-3s")

        // Wake the lock screen's password field.
        injector.key(0x38, down: true)
        injector.key(0x38, down: false)
        injector.move(to: CGPoint(x: 200, y: 200))
        injector.move(to: CGPoint(x: 260, y: 240))
        await sleep(2)
        snapshot("03-after-wake")

        // Probe: key codes, then Unicode text, each erased again.
        if let keyMap {
            injector.typeWithKeyCodes("abc", map: keyMap)
            note("typed abc by key code")
            await sleep(1.5)
            snapshot("04-after-abc-keycodes")
            for _ in 0..<3 { injector.key(0x33, down: true, flags: []); injector.key(0x33, down: false, flags: []) }
            await sleep(1)
            snapshot("05-after-delete")
        }
        injector.text("xyz")
        note("typed xyz as Unicode text")
        await sleep(1.5)
        snapshot("06-after-xyz-unicode")
        for _ in 0..<3 { injector.key(0x33, down: true, flags: []); injector.key(0x33, down: false, flags: []) }
        await sleep(1)
        snapshot("07-after-delete")

        // Unlock.
        var password = passwordField?.stringValue ?? ""
        passwordField?.stringValue = ""
        let provided = !password.isEmpty
        var unmapped = 0
        let unlockStart = Date()
        var unlockedBy = "person"
        if provided, let keyMap {
            let missing = injector.typeWithKeyCodes(password, map: keyMap)
            unmapped = missing.count
            if !missing.isEmpty { injector.text(String(missing)) }
            password = String(repeating: " ", count: password.count)
            password = ""
            injector.key(0x24, down: true, flags: [])
            injector.key(0x24, down: false, flags: [])
            note("typed the password by key code (\(unmapped) characters as text) and Return")
            if await waitFor(locked: false, seconds: 10) {
                unlockedBy = "injected password"
            } else {
                snapshot("08-after-password")
                note("still locked after the injected password; unlock the Mac yourself within 120 s")
                _ = await waitFor(locked: false, seconds: 120)
            }
        } else {
            note("unlock the Mac yourself within 120 s")
            if !(await waitFor(locked: false, seconds: 120)) { unlockedBy = "still locked" }
        }
        let unlockSeconds = Date().timeIntervalSince(unlockStart)
        note("unlocked by \(unlockedBy)")
        await sleep(2)
        snapshot("09-unlocked")
        await sleep(2)
        finish(lockedBy: lockedBy, unlockedBy: unlockedBy, unlockSeconds: unlockSeconds, unmapped: unmapped, provided: provided)
    }

    // MARK: Helpers

    private var elapsed: Double { Date().timeIntervalSince(start) }

    private static var isLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? ((dict["CGSSessionScreenIsLocked"] as? Int) == 1)
    }

    private func waitFor(locked: Bool, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Self.isLocked == locked { return true }
            await sleep(0.25)
        }
        return Self.isLocked == locked
    }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    private func note(_ event: String) {
        timeline.append(Entry(t: elapsed, event: event, locked: Self.isLocked))
        status?.stringValue = event
        log.info("\(event, privacy: .public)")
    }

    private func recordCounters() {
        guard let c = capture?.takeCounters() else { return }
        timeline.append(Entry(t: elapsed, event: "frames", locked: Self.isLocked, complete: c.complete, idle: c.idle, other: c.other))
    }

    private func snapshot(_ label: String) {
        let name = "\(label).jpg"
        var event = "snapshot \(label)"
        if let pixels = latest.get() {
            let image = CIImage(cvPixelBuffer: pixels.buffer)
            let scale = 1280 / image.extent.width
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let data = CIContext().jpegRepresentation(of: scaled, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]) {
                try? data.write(to: runDirectory.appending(path: name))
            }
        } else {
            event += " (no frame yet)"
        }
        timeline.append(Entry(t: elapsed, event: event, locked: Self.isLocked, snapshot: name))
    }

    private func finish(lockedBy: String, unlockedBy: String, unlockSeconds: Double?, unmapped: Int, provided: Bool = false) {
        counterTimer?.invalidate()
        recordCounters()
        let report = Report(date: Date(), macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                            keyboardLayout: LayoutKeyMap.current()?.layoutName ?? "unknown",
                            passwordProvided: provided, lockedBy: lockedBy, unlockedBy: unlockedBy,
                            secondsToUnlock: unlockSeconds, unmappedPasswordCharacters: unmapped, timeline: timeline)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(report).write(to: runDirectory.appending(path: "report.json"))
        status?.stringValue = "Done. Report and snapshots in \(runDirectory.path)"
        let capture = self.capture
        Task {
            await capture?.stop()
            try? await Task.sleep(for: .seconds(2))
            NSApp.terminate(nil)
        }
    }
}

final class LatestFrame: Sendable {
    private let frame = Mutex<PixelBufferBox?>(nil)
    func set(_ p: PixelBufferBox) { frame.withLock { $0 = p } }
    func get() -> PixelBufferBox? { frame.withLock { $0 } }
}
