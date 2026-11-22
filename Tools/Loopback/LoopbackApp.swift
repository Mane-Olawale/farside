import AppKit
import ClientVideo
import HostCapture
import MediaCore
import os
import Telemetry

/// Spike S1 rig. Opens the test pattern in one window and a floating preview in another, captures
/// the display without the preview, and runs capture → encode → decode → render in one process.
@main
@MainActor
final class LoopbackApp: NSObject, NSApplicationDelegate {
    private let options = LoopbackOptions(arguments: CommandLine.arguments)
    private let log = Logger(subsystem: "app.farside.loopback", category: "s1")
    private let stats = LoopbackStats()

    private var patternWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var metalView: MetalView?
    private var readout: NSTextField?

    private var capture: DisplayCapture?
    private var pipeline: LoopbackPipeline?
    private var timer: Timer?
    private var cpu = CPUMeter()
    private var startedAt: Date?

    private var display: S1Report.Display?
    private var settings: S1Report.Settings?
    private var run = StatsWindow()
    private var perSecond: [String: SampleSet] = [:]
    private var totals = (captured: 0, idle: 0, gate: 0, render: 0)
    private var recordedSeconds: Double = 0

    static func main() {
        let app = NSApplication.shared
        let delegate = LoopbackApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        openWindows()
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            fail("Screen Recording is not granted. Allow Loopback in System Settings › Privacy & Security › Screen & System Audio Recording, then launch it again.")
            return
        }
        Task { await start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Windows

    private func openWindows() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame

        let pattern = NSWindow(contentRect: area, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        pattern.title = "Pattern (captured)"
        pattern.contentView = PatternView(frame: NSRect(origin: .zero, size: area.size))
        pattern.setFrame(area, display: true)
        pattern.orderFront(nil)
        patternWindow = pattern

        let width = (area.width * 0.36).rounded()
        let height = (width * area.height / area.width).rounded() + 70
        let preview = NSWindow(
            contentRect: NSRect(x: area.maxX - width - 16, y: area.maxY - height - 16, width: width, height: height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        preview.title = "Loopback (not captured)"
        preview.level = .floating

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let metal = MetalView(frame: NSRect(x: 0, y: 70, width: width, height: height - 70))
        metal.autoresizingMask = [.width, .height]
        let text = NSTextField(wrappingLabelWithString: "Starting…")
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.frame = NSRect(x: 8, y: 4, width: width - 16, height: 62)
        text.autoresizingMask = [.width]
        content.addSubview(metal)
        content.addSubview(text)
        preview.contentView = content
        preview.makeKeyAndOrderFront(nil)
        previewWindow = preview
        metalView = metal
        readout = text
        NSApp.activate()
    }

    // MARK: Pipeline

    private func start() async {
        // Give the windows a moment to reach the window server so the preview can be excluded.
        try? await Task.sleep(for: .milliseconds(500))
        do {
            guard let patternScreen = patternWindow?.screen,
                  let displayID = patternScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let mode = CGDisplayCopyDisplayMode(displayID),
                  let previewNumber = previewWindow?.windowNumber
            else { return fail("Could not find the display.") }

            var width = mode.pixelWidth
            var height = mode.pixelHeight
            display = S1Report.Display(pixelWidth: width, pixelHeight: height, refreshHz: mode.refreshRate)
            let longEdge = max(width, height)
            if longEdge > options.longEdge {
                let scale = Double(options.longEdge) / Double(longEdge)
                width = Int(Double(width) * scale)
                height = Int(Double(height) * scale)
            }
            width &= ~1
            height &= ~1

            let captureFPS = options.captureFPS ?? options.framesPerSecond
            let encoderSettings = EncoderSettings(
                codec: options.codec, width: width, height: height,
                bitrate: options.bitrate, framesPerSecond: options.framesPerSecond,
                maxFrameQP: options.maxQP, useConferencingPreset: options.usePreset)
            let encoder = try VideoEncoder(settings: encoderSettings)
            settings = S1Report.Settings(
                codec: options.codec, width: width, height: height,
                bitrateMbps: Double(options.bitrate) / 1_000_000,
                framesPerSecond: options.framesPerSecond, captureFPS: captureFPS,
                maxFrameQP: encoderSettings.maxFrameQP, conferencingPreset: options.usePreset)

            guard let metalView, let renderer = MetalRenderer(layer: metalView.metalLayer) else {
                return fail("Metal is not available.")
            }
            metalView.onDrawableSize = { renderer.setDrawableSize($0) }
            metalView.needsLayout = true

            let reader = CodeReader.make(
                screenPoints: (patternWindow?.contentView as? PatternView)?.codeCellCentresOnScreen() ?? [],
                displayID: displayID,
                streamSize: CGSize(width: width, height: height))
            let pipeline = LoopbackPipeline(encoder: encoder, renderer: renderer, stats: stats, codeReader: reader)
            let log = self.log
            let capture = DisplayCapture(
                onFrame: { pipeline.captured($0) },
                onStop: { error in log.error("Capture stopped: \(String(describing: error), privacy: .public)") }
            )
            self.pipeline = pipeline
            self.capture = capture

            try await capture.start(
                displayID: displayID,
                excludingWindowIDs: [CGWindowID(previewNumber)],
                settings: CaptureSettings(width: width, height: height, framesPerSecond: captureFPS))
            log.info("Started \(self.options.codec.rawValue, privacy: .public) \(width)x\(height) at \(self.options.bitrate / 1_000_000) Mbps; encoder \(String(describing: encoder.report), privacy: .public)")

            startedAt = Date()
            _ = cpu.percentOfTotal()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            fail("Start failed: \(error)")
        }
    }

    private func tick() {
        guard let startedAt, let capture, let pipeline else { return }
        let window = stats.roll()
        let counters = capture.takeCounters()
        let gateReplaced = pipeline.encodeSlot.takeReplacedCount()
        let renderReplaced = pipeline.renderSlot.takeReplacedCount()
        let cpuPercent = cpu.percentOfTotal()
        let mbps = Double(window.counters[.bytes] ?? 0) * 8 / 1_000_000
        let presented = window.counters[.presented] ?? 0

        let elapsed = Date().timeIntervalSince(startedAt)
        let recording = elapsed > options.warmup
        if recording {
            run.merge(window)
            recordedSeconds += 1
            totals.captured += counters.complete
            totals.idle += counters.idle
            totals.gate += gateReplaced
            totals.render += renderReplaced
            perSecond["capturedFPS", default: SampleSet()].add(Double(counters.complete))
            perSecond["idleFPS", default: SampleSet()].add(Double(counters.idle))
            perSecond["presentedFPS", default: SampleSet()].add(Double(presented))
            perSecond["bitrateMbps", default: SampleSet()].add(mbps)
            perSecond["cpuPercentOfTotal", default: SampleSet()].add(cpuPercent)
        }

        func pair(_ stage: Stage) -> String {
            guard let m = window.median(stage), let p = window.p95(stage) else { return "–" }
            return String(format: "%.1f/%.1f", m, p)
        }
        let hw = pipeline.encoder.report.hardwareAccelerated.map { $0 ? "hw" : "sw" } ?? "?"
        let line1 = String(format: "%@ %d×%d  %.1f Mbps  enc %@  cpu %.1f%%  %@",
                           options.codec.rawValue.uppercased(), settings?.width ?? 0, settings?.height ?? 0,
                           mbps, hw, cpuPercent, recording ? "REC" : "warm-up")
        let line2 = "fps captured \(counters.complete) idle \(counters.idle) shown \(presented)   replaced gate \(gateReplaced) render \(renderReplaced)"
        let line3 = "p50/p95 ms  glass→bits \(pair(.glassToEncoded))  enc \(pair(.encode))  dec \(pair(.decode))  rnd \(pair(.render))  present \(pair(.presentDelay))  unread \(window.counters[.codeUnreadable] ?? 0)"
        readout?.stringValue = [line1, line2, line3].joined(separator: "\n")
        log.info("\(line1, privacy: .public) | \(line2, privacy: .public) | \(line3, privacy: .public)")

        if let duration = options.duration, recordedSeconds >= duration {
            finish(error: nil)
        }
    }

    // MARK: Report

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        readout?.stringValue = message
        if options.duration != nil { finish(error: message) }
    }

    private func finish(error: String?) {
        timer?.invalidate()
        timer = nil

        var stages: [String: SampleSummary] = [:]
        for stage in Stage.allCases {
            if let summary = run.stages[stage]?.summary { stages[stage.rawValue] = summary }
        }
        let presentedFPS = perSecond["presentedFPS"]?.summary
        let encodeP95 = stages[Stage.encode.rawValue]?.p95
        let decodeP95 = stages[Stage.decode.rawValue]?.p95
        let glassP95 = stages[Stage.glassToEncoded.rawValue]?.p95
        let criteria = presentedFPS.map { fps in
            let sixty = fps.median >= Double(options.framesPerSecond) - 1
            let encodeOK = (encodeP95 ?? .infinity) <= 10
            let glassOK = (glassP95 ?? .infinity) <= 10
            let decodeOK = (decodeP95 ?? .infinity) <= 8
            return S1Report.ExitCriteria(sixtyFPS: sixty, encodeP95AtMost10ms: encodeOK,
                                         glassToEncodedP95AtMost10ms: glassOK, decodeP95AtMost8ms: decodeOK,
                                         pass: sixty && glassOK && decodeOK)
        }

        let report = S1Report(
            date: Date(),
            error: error,
            machine: MachineInfo.current(),
            display: display,
            settings: settings,
            encoder: pipeline?.encoder.report,
            decoderHardwareAccelerated: pipeline?.decoder.hardwareAccelerated,
            recordedSeconds: recordedSeconds,
            stagesMs: stages,
            perSecond: S1Report.PerSecond(
                capturedFPS: perSecond["capturedFPS"]?.summary,
                idleFPS: perSecond["idleFPS"]?.summary,
                presentedFPS: presentedFPS,
                bitrateMbps: perSecond["bitrateMbps"]?.summary,
                cpuPercentOfTotal: perSecond["cpuPercentOfTotal"]?.summary),
            totals: S1Report.Totals(
                captured: totals.captured, idle: totals.idle,
                gateReplaced: totals.gate, renderReplaced: totals.render,
                counters: Dictionary(uniqueKeysWithValues: run.counters.map { ($0.key.rawValue, $0.value) })),
            exitCriteria: criteria
        )

        let url = options.reportURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: url)
            log.info("Report written to \(url.path, privacy: .public)")
        } catch {
            log.error("Could not write report: \(error.localizedDescription, privacy: .public)")
        }

        let capture = self.capture
        Task {
            await capture?.stop()
            NSApp.terminate(nil)
        }
    }
}
