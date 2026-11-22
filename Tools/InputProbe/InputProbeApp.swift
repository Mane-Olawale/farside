import AppKit
import HostInput
import os
import Telemetry

/// Spike S2 rig. Posts synthetic input into its own window and checks what AppKit delivers.
/// With `--component` it runs Phase 2's input component tests instead (`ComponentSuite`).
///
///     --out path.json   report path, default ~/Library/Logs/Farside/s2-<time>.json
///     --component       the component tests; report default component-input-<time>.json
@main
@MainActor
final class InputProbeApp: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "app.farside.inputprobe", category: "s2")
    private var ui: ProbeWindow?
    private let recorder = Recorder()

    struct Report: Codable {
        var date: Date
        var error: String?
        var macOS: String
        var model: String
        var keyboardLayout: String
        var localEventsSuppressionInterval: Double?
        var passed: Int
        var failed: Int
        var recordedOnly: Int
        var injectedEventsTagged: String
        var focusLosses: [String]
        var cases: [CaseResult]
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = InputProbeApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let ui = ProbeWindow()
        self.ui = ui
        ui.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        recorder.start()

        guard EventInjector.hasPostAccess else {
            EventInjector.requestPostAccess()
            finish(error: "Accessibility is not granted. Allow InputProbe in System Settings › Privacy & Security › Accessibility, then launch it again.", cases: [], injector: nil)
            return
        }
        guard let injector = EventInjector() else {
            finish(error: "Could not create an event source.", cases: [], injector: nil)
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if CommandLine.arguments.contains("--component") {
                let suite = ComponentSuite(ui: ui, injector: injector, recorder: recorder)
                let cases = await suite.run()
                finish(error: suite.keyboardAborted ? "The window lost focus; keyboard cases were stopped." : nil,
                       cases: cases, injector: injector)
                return
            }
            let probe = Probe(ui: ui, injector: injector, recorder: recorder)
            let cases = await probe.run()
            finish(error: probe.keyboardAborted ? "The probe window lost focus; keyboard cases were stopped." : nil,
                   cases: cases, injector: injector, focusLosses: probe.focusLosses)
        }
    }

    private func finish(error: String?, cases: [CaseResult], injector: EventInjector?, focusLosses: [String] = []) {
        let inputTypes: Set<String> = ["leftMouseDown", "leftMouseUp", "rightMouseDown", "rightMouseUp", "otherMouseDown", "otherMouseUp",
                                       "mouseMoved", "leftMouseDragged", "scrollWheel", "keyDown", "keyUp", "flagsChanged"]
        let input = recorder.events.filter { inputTypes.contains($0.type) }
        let tagged = input.filter { $0.userData == EventInjector.defaultTag }.count
        let report = Report(
            date: Date(), error: error,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            model: Self.sysctl("hw.model"),
            keyboardLayout: Probe.keyboardLayoutName(),
            localEventsSuppressionInterval: injector?.localEventsSuppressionInterval,
            passed: cases.filter { $0.pass == true }.count,
            failed: cases.filter { $0.pass == false }.count,
            recordedOnly: cases.filter { $0.pass == nil }.count,
            injectedEventsTagged: "\(tagged) of \(input.count) input events carried the source user data tag",
            focusLosses: focusLosses,
            cases: cases)

        let url = Self.reportURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: url)
            log.info("Report written to \(url.path, privacy: .public)")
        } catch {
            log.error("Could not write report: \(error.localizedDescription, privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    private static func reportURL() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let prefix = args.contains("--component") ? "component-input" : "s2"
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Farside/\(prefix)-\(stamp).json")
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }
}
