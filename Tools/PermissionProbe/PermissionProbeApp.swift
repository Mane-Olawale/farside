import AppKit
import ApplicationServices
import Network
import os
import ScreenCaptureKit
import ServiceManagement
import UserNotifications

/// Spike S6 rig. Polls every permission API the host relies on (plan section 6) once a second,
/// tests real screen capture every 5 s, and logs each change with a timestamp. Buttons request
/// each permission or open its System Settings pane.
///
///     --check    one-shot: log one line of status and a real capture test, then quit. For a
///                periodic LaunchAgent that records how the capture grant behaves over weeks.
@main
@MainActor
final class PermissionProbeApp: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "app.farside.permprobe", category: "s6")
    private var window: NSWindow?
    private var table: NSTextField?
    private var status: [String: String] = [:]
    private var changes: [Change] = []
    private var browser: NWBrowser?
    private var timer: Timer?
    private var tick = 0
    private let launched = Date()
    private let logDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Farside/s6")

    struct Change: Codable {
        var date: Date
        var secondsSinceLaunch: Double
        var signal: String
        var from: String?
        var to: String
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = PermissionProbeApp()
        app.delegate = delegate
        if CommandLine.arguments.contains("--check") {
            app.setActivationPolicy(.prohibited)
        } else {
            app.setActivationPolicy(.regular)
        }
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--check") {
            Task { await oneShotCheck() }
            return
        }
        buildWindow()
        startLocalNetworkBrowser()
        record("process", "launched pid \(ProcessInfo.processInfo.processIdentifier)")
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: UI

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Farside Permission Probe (spike S6)"
        let content = NSView(frame: w.contentLayoutRect)
        let text = NSTextField(wrappingLabelWithString: "")
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.frame = NSRect(x: 20, y: 200, width: 680, height: 300)
        content.addSubview(text)
        table = text

        let buttons: [(String, Selector)] = [
            ("Request Screen Recording", #selector(requestScreen)),
            ("Open Screen Recording pane", #selector(openScreenPane)),
            ("Request Accessibility", #selector(requestAccessibility)),
            ("Open Accessibility pane", #selector(openAccessibilityPane)),
            ("Request Post Events", #selector(requestPost)),
            ("Open Local Network pane", #selector(openLocalNetworkPane)),
            ("Request Notifications", #selector(requestNotifications)),
            ("Open Login Items pane", #selector(openLoginItemsPane)),
            ("Relaunch probe", #selector(relaunch)),
            ("Save report and quit", #selector(saveAndQuit)),
        ]
        for (i, (title, action)) in buttons.enumerated() {
            let b = NSButton(title: title, target: self, action: action)
            b.frame = NSRect(x: 20 + CGFloat(i % 2) * 340, y: 150 - CGFloat(i / 2) * 32, width: 330, height: 28)
            content.addSubview(b)
        }
        w.contentView = content
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate()
    }

    private func render() {
        let order = ["screen.preflight", "screen.shareableContent", "screen.realCapture", "accessibility.axTrusted",
                     "accessibility.preflightPost", "localNetwork.browser", "loginItem.status", "notifications.authorization"]
        var lines = order.map { k in k.padding(toLength: 30, withPad: " ", startingAt: 0) + (status[k] ?? "…") }
        lines.append("")
        lines.append("Recent changes:")
        for c in changes.suffix(8) {
            lines.append(String(format: "%7.1fs  %@: %@ → %@", c.secondsSinceLaunch, c.signal, c.from ?? "–", c.to))
        }
        table?.stringValue = lines.joined(separator: "\n")
    }

    // MARK: Polling

    private func poll() {
        set("screen.preflight", CGPreflightScreenCaptureAccess() ? "granted" : "denied")
        set("accessibility.axTrusted", AXIsProcessTrusted() ? "trusted" : "not trusted")
        set("accessibility.preflightPost", CGPreflightPostEventAccess() ? "granted" : "denied")
        set("loginItem.status", Self.name(SMAppService.mainApp.status))
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let value = Self.name(settings.authorizationStatus)
            Task { @MainActor in self.set("notifications.authorization", value) }
        }
        if tick % 5 == 0 { Task { await self.testCapture() } }
        tick += 1
        render()
    }

    private func testCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            set("screen.shareableContent", "ok, \(content.displays.count) displays")
            guard let display = content.displays.first else { return }
            let config = SCStreamConfiguration()
            config.width = 64
            config.height = 36
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
            set("screen.realCapture", Self.describe(image))
        } catch {
            let ns = error as NSError
            set("screen.shareableContent", "error \(ns.domain) \(ns.code)")
            set("screen.realCapture", "failed")
        }
    }

    /// Mean brightness of a tiny capture: a blank frame reads near 0.
    nonisolated static func describe(_ image: CGImage) -> String {
        let w = 16, h = 9
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return "image" }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0
        for i in stride(from: 0, to: pixels.count, by: 4) { sum += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) }
        let mean = Double(sum) / Double(w * h * 3)
        return mean < 2 ? "blank image" : "image, mean \(Int(mean))"
    }

    private func startLocalNetworkBrowser() {
        let browser = NWBrowser(for: .bonjour(type: "_farside._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            let value: String = switch state {
            case .ready: "ready"
            case .waiting(let error): "waiting: \(error)"
            case .failed(let error): "failed: \(error)"
            case .setup: "setup"
            case .cancelled: "cancelled"
            @unknown default: "unknown"
            }
            Task { @MainActor in self?.set("localNetwork.browser", value) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func set(_ key: String, _ value: String) {
        let old = status[key]
        guard old != value else { return }
        status[key] = value
        record(key, value, from: old)
    }

    private func record(_ signal: String, _ value: String, from: String? = nil) {
        changes.append(Change(date: Date(), secondsSinceLaunch: Date().timeIntervalSince(launched), signal: signal, from: from, to: value))
        log.info("\(signal, privacy: .public): \(from ?? "–", privacy: .public) → \(value, privacy: .public)")
        appendJSONLine(["kind": "change", "signal": signal, "from": from ?? "", "to": value])
        render()
    }

    private func appendJSONLine(_ fields: [String: String]) {
        var f = fields
        f["date"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]) else { return }
        let url = logDir.appending(path: "events.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    // MARK: One-shot check for the LaunchAgent

    private func oneShotCheck() async {
        var fields: [String: String] = [
            "kind": "check",
            "screen.preflight": CGPreflightScreenCaptureAccess() ? "granted" : "denied",
            "accessibility.axTrusted": AXIsProcessTrusted() ? "trusted" : "not trusted",
        ]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first {
                let config = SCStreamConfiguration()
                config.width = 64
                config.height = 36
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
                fields["screen.realCapture"] = Self.describe(image)
            }
        } catch {
            let ns = error as NSError
            fields["screen.realCapture"] = "error \(ns.domain) \(ns.code)"
        }
        appendJSONLine(fields)
        NSApp.terminate(nil)
    }

    // MARK: Actions

    @objc private func requestScreen() { record("action", "CGRequestScreenCaptureAccess returned \(CGRequestScreenCaptureAccess())") }
    @objc private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary // kAXTrustedCheckOptionPrompt
        record("action", "AXIsProcessTrustedWithOptions(prompt) returned \(AXIsProcessTrustedWithOptions(options))")
    }
    @objc private func requestPost() { record("action", "CGRequestPostEventAccess returned \(CGRequestPostEventAccess())") }
    @objc private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in self.record("action", "notification request granted \(granted) \(error.map { "\($0)" } ?? "")") }
        }
    }

    private func open(_ url: String, _ name: String) {
        let ok = URL(string: url).map { NSWorkspace.shared.open($0) } ?? false
        record("action", "open \(name) pane (\(url)) returned \(ok)")
    }
    @objc private func openScreenPane() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", "Screen Recording") }
    @objc private func openAccessibilityPane() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", "Accessibility") }
    @objc private func openLocalNetworkPane() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork", "Local Network") }
    @objc private func openLoginItemsPane() { open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension", "Login Items") }

    @objc private func relaunch() {
        record("action", "relaunch")
        saveReport()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    @objc private func saveAndQuit() {
        saveReport()
        NSApp.terminate(nil)
    }

    private func saveReport() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let stamp = ISO8601DateFormatter().string(from: launched).replacingOccurrences(of: ":", with: "-")
        try? encoder.encode(changes).write(to: logDir.appending(path: "session-\(stamp).json"))
    }

    nonisolated static func name(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    nonisolated static func name(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
    }
}
