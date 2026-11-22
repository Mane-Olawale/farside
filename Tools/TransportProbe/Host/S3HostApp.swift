import AppKit
import AVFoundation
import ClientVideo
import HostCapture
import MediaCore
import os
import SessionTransport
import SessionTransportWebRTC
import Synchronization
import Telemetry

/// Spike S3 host. Captures the test pattern and sends it over WebRTC with our VideoToolbox codecs.
///
///     --mode local|serve     local: an in-process receiver with a preview window. serve: wait
///                            for the iPad viewer over Bonjour. Default local.
///     --codec hevc|h264      preferred codec, default hevc
///     --playout standard|receiverZero|senderZero|both   default standard
///     --long-edge 2752       stream long edge cap, default 2752 (plan rung 5)
///     --audio                also send system audio, with a 1 kHz marker burst every second
///     --duration 30          seconds to record after warm-up, then write the report and quit
///     --out path.json
@main
@MainActor
final class S3HostApp: NSObject, NSApplicationDelegate {
    private let args = CommandLine.arguments
    private let log = Logger(subsystem: "app.farside.s3", category: "host")
    private var patternWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var metalView: MetalView?
    private var readout: NSTextField?

    private var capture: DisplayCapture?
    private var host: WebRTCTransport?
    private var client: WebRTCTransport?
    private var advertiser: LANAdvertiser?
    private var signaling: SignalingConnection?
    private var renderer: MetalRenderer?
    private var timer: Timer?
    private var startedAt: Date?
    private var reader: FrameCodeReader?

    private let glassTimes = GlassTimes()
    private let samples = Samples()
    private var viewerStats: ViewerStats?
    private var hostStats: TransportStats?
    private var recordedSeconds = 0.0
    private var events: [String] = []

    private func value(_ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    private var mode: String { value("--mode") ?? "local" }
    private var codec: VideoCodec { value("--codec").flatMap(VideoCodec.init) ?? .hevc }
    private var playout: PlayoutMode { value("--playout").flatMap(PlayoutMode.init) ?? .standard }
    private var longEdge: Int { value("--long-edge").flatMap(Int.init) ?? 2752 }
    private var duration: Double? { value("--duration").flatMap(Double.init) }
    private var audio: Bool { args.contains("--audio") }
    private let audioInput = InjectedAudioInput()
    private let markers = MarkerClock()
    private var markerPlayer: MarkerPlayer?
    private var audioPlayout: AudioPlayout?
    private let warmup = 3.0

    static func main() {
        let app = NSApplication.shared
        let delegate = S3HostApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        openWindows()
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return finish(error: "Screen Recording is not granted for S3Host.")
        }
        Task { await start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
        let videoHeight = mode == "local" ? (width * area.height / area.width).rounded() : 0
        let height = videoHeight + 70
        let preview = NSWindow(contentRect: NSRect(x: area.maxX - width - 16, y: area.maxY - height - 16, width: width, height: height),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        preview.title = mode == "local" ? "S3 receiver (not captured)" : "S3 host: waiting for the iPad viewer"
        preview.level = .floating
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        if mode == "local" {
            let metal = MetalView(frame: NSRect(x: 0, y: 70, width: width, height: videoHeight))
            content.addSubview(metal)
            metalView = metal
        }
        let text = NSTextField(wrappingLabelWithString: "Starting…")
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.frame = NSRect(x: 8, y: 4, width: width - 16, height: 62)
        content.addSubview(text)
        preview.contentView = content
        preview.makeKeyAndOrderFront(nil)
        previewWindow = preview
        readout = text
        NSApp.activate()
    }

    private func start() async {
        try? await Task.sleep(for: .milliseconds(500))
        guard let screen = patternWindow?.screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let mode = CGDisplayCopyDisplayMode(displayID),
              let previewNumber = previewWindow?.windowNumber
        else { return finish(error: "No display") }

        var width = mode.pixelWidth, height = mode.pixelHeight
        let edge = max(width, height)
        if edge > longEdge {
            width = Int(Double(width) * Double(longEdge) / Double(edge))
            height = Int(Double(height) * Double(longEdge) / Double(edge))
        }
        width &= ~1
        height &= ~1
        reader = CodeReader.make(screenPoints: (patternWindow?.contentView as? PatternView)?.codeCellCentresOnScreen() ?? [],
                                 displayID: displayID, streamSize: CGSize(width: width, height: height))

        let codecs: [VideoCodec] = codec == .hevc ? [.hevc, .h264] : [.h264, .hevc]
        let playout = self.playout
        let log = self.log
        let onState: @Sendable (String) -> Void = { [weak self] state in
            log.info("\(state, privacy: .public)")
            Task { @MainActor in self?.events.append(state) }
        }
        /// Logs transport events; hands control-channel probe messages to `onProbe`.
        let events: @Sendable (String, (@Sendable (ProbeMessage) -> Void)?) -> @Sendable (TransportEvent) -> Void = { prefix, onProbe in
            { event in
                switch event {
                case .message(.control, let data):
                    if let onProbe, let message = ProbeMessage.decode(data) { onProbe(message) }
                case .message:
                    break
                default:
                    onState("\(prefix) \(event)")
                }
            }
        }
        let configuration = TransportConfiguration(playout: playout, codecs: codecs)
        let makeEncoder: @Sendable (VideoCodec, Int, Int, Int) -> FrameEncoding? = { codec, w, h, bitrate in
            try? VideoEncoder(settings: EncoderSettings(codec: codec, width: w, height: h, bitrate: bitrate))
        }

        let markers = self.markers, samples = self.samples
        var clientAudio: AudioRole = .none
        if audio && self.mode == "local" {
            nonisolated(unsafe) var detector = OnsetDetector()
            let playout = AudioPlayout(muted: true) { buffer, frames, pulledAt in
                for i in 0..<frames {
                    switch detector.feed(Float(buffer[2 * i]) / 32768) {
                    case .onset?:
                        let at = pulledAt + HostClock.ticks(seconds: Double(i) / 48_000)
                        if let captured = markers.lastCapture(within: 1) {
                            samples.add(.audioLocal, HostClock.milliseconds(from: captured, to: at))
                        }
                    case .peak(let p)?:
                        samples.add(.audioPeak, Double(p))
                    case nil:
                        break
                    }
                }
            }
            audioPlayout = playout
            clientAudio = .receive(playout)
        }
        let hostAudio: AudioRole = audio ? .send(audioInput) : .none

        if self.mode == "local" {
            guard let metalView, let renderer = MetalRenderer(layer: metalView.metalLayer) else { return finish(error: "No Metal") }
            metalView.onDrawableSize = { renderer.setDrawableSize($0) }
            metalView.needsLayout = true
            self.renderer = renderer
            let relay = SignalRelay()
            let glass = glassTimes, samples = self.samples, reader = self.reader
            let renderSlot = LatestSlot<(PixelBufferBox, UInt64?)>()
            let renderQueue = DispatchQueue(label: "farside.s3.render", qos: .userInteractive)
            @Sendable func render(_ first: (PixelBufferBox, UInt64?)) {
                var item = first
                while true {
                    let displayTicks = item.1
                    renderer.draw(item.0.buffer) { times in
                        if let displayTicks {
                            samples.add(.glassToGlass, HostClock.milliseconds(from: displayTicks, to: HostClock.ticks(seconds: times.presentedSeconds)))
                        }
                    }
                    guard let next = renderSlot.finish() else { return }
                    item = next
                }
            }
            let client = WebRTCTransport(
                role: .client, configuration: configuration, audio: clientAudio,
                makeDecoder: { _ in VideoDecoder() },
                handlers: TransportHandlers(
                signal: { message in relay.toHost(message) },
                event: events("client", nil),
                frame: { pixels, _ in
                    let now = HostClock.now()
                    var displayTicks: UInt64?
                    if let counter = reader?.read(pixels.buffer) {
                        displayTicks = glass.take(counter)
                        if let d = displayTicks { samples.add(.glassToDecoded, HostClock.milliseconds(from: d, to: now)) }
                    } else {
                        samples.count(.codeUnreadable)
                    }
                    samples.count(.framesRendered)
                    if let first = renderSlot.offer((pixels, displayTicks)) { renderQueue.async { render(first) } }
                }))
            let host = WebRTCTransport(
                role: .host, configuration: configuration, audio: hostAudio, makeEncoder: makeEncoder,
                handlers: TransportHandlers(signal: { message in relay.toClient(message) }, event: events("host", nil)))
            relay.connect(host: host, client: client)
            self.host = host
            self.client = client
            host.start()
        } else {
            // The viewer sets its field trials from the offer, so the run's settings ride along in it.
            let extra = ["playout": playout.rawValue, "codecs": codecs.map(\.rawValue).joined(separator: ","), "audio": audio ? "1" : "0"]
            let host = WebRTCTransport(
                role: .host, configuration: configuration, audio: hostAudio, makeEncoder: makeEncoder,
                handlers: TransportHandlers(
                    signal: { [weak self] message in
                        var message = message
                        if message.kind == .offer { message.body.extra = extra }
                        Task { @MainActor in self?.signaling?.send(message) }
                    },
                    event: events("host") { [weak self] message in
                        Task { @MainActor in self?.handle(message, at: HostClock.now()) }
                    }))
            self.host = host
            let advertiser = LANAdvertiser(
                id: "s3host", name: "Farside S3",
                onConnection: { [weak self] connection in
                    Task { @MainActor in
                        guard let self, self.signaling == nil else { return connection.close() }
                        self.signaling = connection
                        connection.start(
                            onState: { [weak self] state in
                                onState("signaling \(state)")
                                guard state == .ready else { return }
                                Task { @MainActor in
                                    self?.startedAt = Date()
                                    self?.host?.start()
                                }
                            },
                            onMessage: { [weak self] message in Task { @MainActor in self?.host?.handle(message) } })
                    }
                },
                onState: { onState("advertiser \($0)") })
            do {
                try advertiser.start()
            } catch {
                return finish(error: "Signaling failed: \(error)")
            }
            self.advertiser = advertiser
        }

        let host = self.host!
        let glass = glassTimes, reader = self.reader, input = audioInput
        nonisolated(unsafe) var captureDetector = OnsetDetector()
        let onAudio: CapturedAudioHandler = { left, right, frames, startTicks in
            let arrival = HostClock.now()
            var peak: Float = 0
            for i in 0..<frames { peak = max(peak, abs(left[i])) }
            samples.add(.capturePeak, Double(peak))
            samples.count(.audioCallbacks)
            for i in 0..<frames {
                if case .onset? = captureDetector.feed(left[i]) {
                    let at = startTicks + HostClock.ticks(seconds: Double(i) / 48_000)
                    markers.captured(at)
                    samples.add(.audioCaptureDelivery, HostClock.milliseconds(from: at, to: arrival))
                    if let played = markers.lastPlayed(within: 1) {
                        samples.add(.markerToCapture, HostClock.milliseconds(from: played, to: at))
                    }
                }
            }
            input.push(left: left, right: right, frames: frames, hostTime: startTicks)
        }
        let capture = DisplayCapture(onFrame: { frame in
            if let counter = reader?.read(frame.pixels.buffer) { glass.record(counter, displayTicks: frame.displayTicks) }
            host.push(frame.pixels, timestampNs: Int64(HostClock.seconds(frame.displayTicks) * 1_000_000_000))
        }, onAudio: audio ? onAudio : nil)
        self.capture = capture
        do {
            try await capture.start(displayID: displayID, excludingWindowIDs: [CGWindowID(previewNumber)],
                                    settings: CaptureSettings(width: width, height: height, capturesAudio: audio))
        } catch {
            return finish(error: "Capture failed: \(error)")
        }
        if self.mode == "local" { startedAt = Date() }
        if audio {
            let player = MarkerPlayer(clock: markers)
            player.start()
            markerPlayer = player
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        log.info("S3 host \(self.mode, privacy: .public) \(self.codec.rawValue, privacy: .public) playout \(playout.rawValue, privacy: .public) \(width)x\(height)")
    }

    private func handle(_ message: ProbeMessage, at now: UInt64) {
        switch message {
        case .echo(let counter, let stage):
            guard let displayTicks = glassTimes.peek(counter) else { return samples.count(.echoUnknown) }
            samples.add(stage == .decoded ? .echoDecoded : .echoPresented, HostClock.milliseconds(from: displayTicks, to: now))
        case .viewerStats(let stats):
            viewerStats = stats
        case .audioOnset:
            if let captured = markers.lastCapture(within: 1) {
                samples.add(.audioEcho, HostClock.milliseconds(from: captured, to: now))
            } else {
                samples.count(.audioEchoUnmatched)
            }
        case .audioPeak(let peak):
            samples.add(.audioPeak, Double(peak))
        case .cells:
            break
        }
    }

    private func tick() {
        guard let startedAt else {
            readout?.stringValue = "Waiting for the iPad viewer. \(events.last ?? "")"
            return
        }
        if mode == "serve", let reader { host?.send(ProbeMessage.cells(reader).data, on: .control) }
        host?.stats { [weak self] stats in Task { @MainActor in self?.hostStats = stats } }
        let window = samples.roll()
        let recording = Date().timeIntervalSince(startedAt) > warmup
        if recording {
            samples.keep(window)
            recordedSeconds += 1
        }
        func pair(_ s: Samples.Kind) -> String {
            guard let sum = window.sets[s]?.summary else { return "–" }
            return String(format: "%.1f/%.1f", sum.median, sum.p95)
        }
        let stage = mode == "local"
            ? "glass→decoded \(pair(.glassToDecoded))  glass→glass \(pair(.glassToGlass))  rendered \(window.counts[.framesRendered] ?? 0)/s"
            : "glass→iPad decoded+uplink \(pair(.echoDecoded))  presented \(pair(.echoPresented))"
        let audioLine = audio
            ? "  audio \(mode == "local" ? "local \(pair(.audioLocal))" : "echo \(pair(.audioEcho))") capture \(pair(.audioCaptureDelivery)) delivered \(audioInput.framesDelivered)"
            : ""
        let line = "\(codec.rawValue) \(playout.rawValue) \(mode) \(recording ? "REC" : "warm-up")  enc \(hostStats?.encoderImplementation ?? "?")\n\(stage)\nrtt \(hostStats?.roundTripTime.map { String(format: "%.1f ms", $0 * 1000) } ?? "–")  target \(hostStats?.targetBitrate.map { String(format: "%.1f Mbps", $0 / 1e6) } ?? "–")  \(events.last ?? "")\(audioLine)"
        readout?.stringValue = line
        log.info("\(line.replacingOccurrences(of: "\n", with: " | "), privacy: .public)")
        if let duration, recordedSeconds >= duration { finish(error: nil) }
    }

    private func finish(error: String?) {
        timer?.invalidate()
        timer = nil
        let group = DispatchGroup()
        nonisolated(unsafe) var clientStats: TransportStats?
        if let client {
            group.enter()
            client.stats { clientStats = $0; group.leave() }
        }
        group.notify(queue: .main) { [self] in
            MainActor.assumeIsolated { writeReport(error: error, receiver: clientStats ?? viewerStats?.transport) }
        }
    }

    private func writeReport(error: String?, receiver: TransportStats?) {
        let report = S3Report(
            date: Date(), error: error, mode: mode, codecPreferred: codec, playout: playout,
            recordedSeconds: recordedSeconds,
            latencyMs: Dictionary(uniqueKeysWithValues: samples.kept.sets.compactMap { k, v in v.summary.map { (k.rawValue, $0) } }),
            counts: Dictionary(uniqueKeysWithValues: samples.kept.counts.map { ($0.key.rawValue, $0.value) }),
            sender: hostStats, receiver: receiver,
            derived: S3Report.Derived(sender: hostStats, receiver: receiver),
            viewer: viewerStats.map { S3Report.Viewer(device: $0.device, os: $0.os, displayHz: $0.displayHz, framesRendered: $0.framesRendered, framesPresented: $0.framesPresented, codeUnreadable: $0.codeUnreadable, audioOutputLatency: $0.audioOutputLatency, audioIOBufferDuration: $0.audioIOBufferDuration) },
            audioFramesDelivered: audio ? audioInput.framesDelivered : nil,
            audioDeliverErrors: audio ? audioInput.deliverErrors : nil,
            audioPreferredFormat: audio ? audioInput.preferredFormat : nil,
            localPlayedBuffers: audioPlayout?.playedBuffers,
            localStereoBuffers: audioPlayout?.stereoBuffers,
            events: Array(events.suffix(40)))
        let url: URL = value("--out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Farside/s3-\(mode)-\(codec.rawValue)-\(playout.rawValue).json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(report).write(to: url)
        log.info("Report written to \(url.path, privacy: .public)")
        let capture = self.capture
        Task {
            await capture?.stop()
            host?.close()
            client?.close()
            signaling?.close()
            advertiser?.stop()
            NSApp.terminate(nil)
        }
    }
}

/// Passes signaling between two in-process peers, asynchronously so neither re-enters itself.
final class SignalRelay: @unchecked Sendable {
    private var host: WebRTCTransport?
    private var client: WebRTCTransport?
    private let queue = DispatchQueue(label: "farside.s3.relay")
    func connect(host: WebRTCTransport, client: WebRTCTransport) {
        queue.sync { self.host = host; self.client = client }
    }
    func toHost(_ m: SignalMessage) { queue.async { self.host?.handle(m) } }
    func toClient(_ m: SignalMessage) { queue.async { self.client?.handle(m) } }
}

/// Counter → the captured frame's display time on the Mac.
final class GlassTimes: Sendable {
    private let map = Mutex<[UInt32: UInt64]>([:])
    func record(_ counter: UInt32, displayTicks: UInt64) {
        map.withLock { m in
            if m[counter] == nil { m[counter] = displayTicks }
            if m.count > 2000 { m = m.filter { counter &- $0.key < 1200 } }
        }
    }
    func take(_ counter: UInt32) -> UInt64? { map.withLock { $0[counter] } }
    func peek(_ counter: UInt32) -> UInt64? { map.withLock { $0[counter] } }
}

final class Samples: Sendable {
    enum Kind: String, Codable, CaseIterable {
        /// Mac glass to the receiver's renderer callback (after jitter buffer and decode), same clock.
        case glassToDecoded
        /// Mac glass to the local preview's glass.
        case glassToGlass
        /// Mac glass to the iPad decoding the frame, plus the echo's trip back.
        case echoDecoded
        /// Mac glass to the iPad presenting the frame, plus the echo's trip back.
        case echoPresented
        /// Marker onset in the Mac's captured system audio to its onset in the iPad's playout pull,
        /// plus the echo's trip back.
        case audioEcho
        /// Same, to the local receiver's playout pull, one clock.
        case audioLocal
        /// Onset sample time to the capture callback.
        case audioCaptureDelivery
        /// The Mac starting the marker to its onset in captured audio.
        case markerToCapture
        /// Marker peak level as played by the receiver. Sent at 0.5.
        case audioPeak
        /// Peak level of each captured audio buffer.
        case capturePeak
        case framesRendered, codeUnreadable, echoUnknown, audioEchoUnmatched, audioCallbacks
    }
    struct Window: Sendable {
        var sets: [Kind: SampleSet] = [:]
        var counts: [Kind: Int] = [:]
    }
    private let current = Mutex(Window())
    private let all = Mutex(Window())
    func add(_ k: Kind, _ v: Double) { current.withLock { $0.sets[k, default: SampleSet()].add(v) } }
    func count(_ k: Kind) { current.withLock { $0.counts[k, default: 0] += 1 } }
    func roll() -> Window { current.withLock { w in defer { w = Window() }; return w } }
    func keep(_ w: Window) {
        all.withLock { a in
            for (k, s) in w.sets { a.sets[k, default: SampleSet()].add(contentsOf: s) }
            for (k, c) in w.counts { a.counts[k, default: 0] += c }
        }
    }
    var kept: Window { all.withLock { $0 } }
}

struct S3Report: Codable {
    struct Derived: Codable {
        var averageJitterBufferMs: Double?
        var averageJitterBufferTargetMs: Double?
        var averageDecodeMs: Double?
        var averageEncodeMs: Double?
        var receivedFPS: Double?
        init(sender: TransportStats?, receiver: TransportStats?) {
            if let r = receiver, let emitted = r.jitterBufferEmittedCount, emitted > 0 {
                averageJitterBufferMs = (r.jitterBufferDelay ?? 0) / emitted * 1000
                averageJitterBufferTargetMs = r.jitterBufferTargetDelay.map { $0 / emitted * 1000 }
            }
            if let r = receiver, let decoded = r.framesDecoded, decoded > 0 { averageDecodeMs = (r.totalDecodeTime ?? 0) / decoded * 1000 }
            if let s = sender, let encoded = s.framesEncoded, encoded > 0 { averageEncodeMs = (s.totalEncodeTime ?? 0) / encoded * 1000 }
        }
    }
    struct Viewer: Codable {
        var device: String
        var os: String
        var displayHz: Int
        var framesRendered: Int
        var framesPresented: Int
        var codeUnreadable: Int
        var audioOutputLatency: Double?
        var audioIOBufferDuration: Double?
    }
    var date: Date
    var error: String?
    var mode: String
    var codecPreferred: VideoCodec
    var playout: PlayoutMode
    var recordedSeconds: Double
    var latencyMs: [String: SampleSummary]
    var counts: [String: Int]
    var sender: TransportStats?
    var receiver: TransportStats?
    var derived: Derived
    var viewer: Viewer?
    var audioFramesDelivered: Int?
    var audioDeliverErrors: Int?
    var audioPreferredFormat: String?
    var localPlayedBuffers: Int?
    var localStereoBuffers: Int?
    var events: [String]
}

/// When the last marker was started and when its onset was captured, in host ticks.
final class MarkerClock: Sendable {
    private let times = Mutex((played: UInt64(0), captured: UInt64(0)))
    func played(_ t: UInt64) { times.withLock { $0.played = t } }
    func captured(_ t: UInt64) { times.withLock { $0.captured = t } }
    func lastPlayed(within seconds: Double) -> UInt64? { recent(times.withLock { $0.played }, seconds) }
    func lastCapture(within seconds: Double) -> UInt64? { recent(times.withLock { $0.captured }, seconds) }
    private func recent(_ t: UInt64, _ seconds: Double) -> UInt64? {
        t != 0 && HostClock.seconds(HostClock.now()) - HostClock.seconds(t) < seconds ? t : nil
    }
}

/// Plays a 30 ms, 1 kHz burst at half scale once a second from a separate `afplay` process.
/// ScreenCaptureKit did not capture this app's own AVAudioEngine output (spike S4), and the
/// product excludes its own audio anyway.
@MainActor
final class MarkerPlayer {
    private let clock: MarkerClock
    private var timer: Timer?
    private let file = FileManager.default.temporaryDirectory.appending(path: "farside-marker.wav")

    init(clock: MarkerClock) {
        self.clock = clock
    }

    func start() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_440)
        else { return }
        buffer.frameLength = 1_440
        for ch in 0..<2 {
            let data = buffer.floatChannelData![ch]
            for i in 0..<1_440 {
                let ramp = min(1, Float(min(i, 1_440 - i)) / 96)
                data[i] = 0.5 * ramp * sin(2 * .pi * 1_000 * Float(i) / 48_000)
            }
        }
        do {
            let out = try AVAudioFile(forWriting: file, settings: format.settings)
            try out.write(from: buffer)
        } catch {
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
    }

    private func fire() {
        clock.played(HostClock.now())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [file.path]
        try? process.run()
    }
}
