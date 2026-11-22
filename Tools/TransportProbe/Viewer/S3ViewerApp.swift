import ClientVideo
import MediaCore
import os
import SessionTransport
import Synchronization
import Telemetry
import UIKit

/// Spike S3 viewer. Finds the Mac over Bonjour, receives the stream, renders it full screen and
/// echoes each frame's block code back to the Mac when it is decoded and when it is presented.
@main
final class S3ViewerApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ViewerController()
        window.makeKeyAndVisible()
        self.window = window
        application.isIdleTimerDisabled = true
        return true
    }
}

final class MetalLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var onDrawableSize: ((CGSize) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? 2
        metalLayer.contentsScale = scale
        onDrawableSize?(CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }
}

/// Counters the viewer reports once a second.
final class ViewerCounters: Sendable {
    private let values = Mutex((rendered: 0, presented: 0, unreadable: 0))
    func rendered() { values.withLock { $0.rendered += 1 } }
    func presented() { values.withLock { $0.presented += 1 } }
    func unreadable() { values.withLock { $0.unreadable += 1 } }
    var snapshot: (rendered: Int, presented: Int, unreadable: Int) { values.withLock { $0 } }
}

final class ViewerController: UIViewController {
    private let log = Logger(subsystem: "app.farside.s3", category: "viewer")
    private let videoView = MetalLayerView()
    private let label = UILabel()
    private var renderer: MetalRenderer?
    private var signaling: LANSignaling?
    private var session: WebRTCSession?
    private let reader = ReaderBox()
    private let counters = ViewerCounters()
    private var timer: Timer?

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)
        label.frame = CGRect(x: 16, y: 16, width: 900, height: 60)
        label.numberOfLines = 3
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .systemGreen
        label.text = "Looking for a Mac running S3Host…"
        view.addSubview(label)

        guard let renderer = MetalRenderer(layer: videoView.metalLayer) else { return status("No Metal") }
        self.renderer = renderer
        videoView.onDrawableSize = { renderer.setDrawableSize($0) }
        videoView.setNeedsLayout()

        signaling = LANSignaling.connect(
            onConnect: { [weak self] in Task { @MainActor in self?.status("Connected to the Mac, waiting for config") } },
            onMessage: { [weak self] message in Task { @MainActor in self?.handle(message) } },
            onState: { [weak self] state in Task { @MainActor in self?.log.info("\(state, privacy: .public)") } })
    }

    private func status(_ text: String) {
        label.text = text
        log.info("\(text, privacy: .public)")
    }

    private func handle(_ message: SignalMessage) {
        if message.kind == .config {
            startSession(playout: message.playout ?? .standard, codecs: message.codecs ?? [.hevc, .h264], audio: message.audio ?? false)
        } else {
            session?.handle(message)
        }
    }

    private var playout: AudioPlayout?

    private func startSession(playout mode: PlayoutMode, codecs: [VideoCodec], audio: Bool) {
        let playout = mode
        guard session == nil, let renderer else { return }
        status("Session \(playout.rawValue), codecs \(codecs.map(\.rawValue))")
        let reader = self.reader
        let counters = self.counters
        let slot = LatestSlot<(PixelBufferBox, UInt32?)>()
        let renderQueue = DispatchQueue(label: "farside.viewer.render", qos: .userInteractive)
        let send = SendBox()
        var audioRole: AudioRole = .none
        if audio {
            let echoQueue = DispatchQueue(label: "farside.viewer.audio-echo")
            nonisolated(unsafe) var detector = OnsetDetector()
            let output = AudioPlayout { buffer, frames, _ in
                for i in 0..<frames {
                    switch detector.feed(Float(buffer[2 * i]) / 32768) {
                    case .onset?: echoQueue.async { send.message(.audioOnset) }
                    case .peak(let p)?: echoQueue.async { send.message(.audioPeak(p)) }
                    case nil: break
                    }
                }
            }
            self.playout = output
            audioRole = .receive(output)
        }

        @Sendable func render(_ first: (PixelBufferBox, UInt32?)) {
            var item = first
            while true {
                let counter = item.1
                renderer.draw(item.0.buffer) { _ in
                    counters.presented()
                    if let counter { send.echo(counter, .presented) }
                }
                guard let next = slot.finish() else { return }
                item = next
            }
        }

        let session = WebRTCSession(
            role: .client, playout: playout, codecs: codecs, audio: audioRole,
            makeDecoder: { _ in VideoDecoder() },
            onFrame: { pixels, _ in
                counters.rendered()
                var counter: UInt32?
                if let r = reader.value {
                    counter = r.read(pixels.buffer)
                    if let counter { send.echo(counter, .decoded) } else { counters.unreadable() }
                }
                if let first = slot.offer((pixels, counter)) { renderQueue.async { render(first) } }
            },
            signal: { [weak self] message in Task { @MainActor in self?.signaling?.send(message) } },
            onMessage: { channel, data in
                guard channel == .control, case .cells(let cells)? = ProbeMessage.decode(data) else { return }
                reader.value = cells
            },
            onState: { [weak self] state in Task { @MainActor in self?.log.info("\(state, privacy: .public)") } })
        send.session = session
        self.session = session

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportStats() }
        }
    }

    private var lastCounts = (rendered: 0, presented: 0, unreadable: 0)

    private func reportStats() {
        guard let session else { return }
        let counts = counters.snapshot
        let rendered = counts.rendered - lastCounts.rendered
        let presented = counts.presented - lastCounts.presented
        lastCounts = counts
        let hz = view.window?.screen.maximumFramesPerSecond ?? 0
        let latency = playout?.hardwareOutputLatency
        let ioBuffer = playout?.hardwareIOBufferDuration
        session.stats { [weak self] stats in
            let viewer = ViewerStats(transport: stats, framesRendered: counts.rendered, framesPresented: counts.presented,
                                     codeUnreadable: counts.unreadable, device: Self.model(), os: UIDevice.current.systemVersion, displayHz: hz,
                                     audioOutputLatency: latency, audioIOBufferDuration: ioBuffer)
            session.send(ProbeMessage.viewerStats(viewer).data, on: .control)
            let jb = stats.jitterBufferEmittedCount.flatMap { e in e > 0 ? (stats.jitterBufferDelay ?? 0) / e * 1000 : nil }
            let text = String(format: "%@ %dx%d  %d fps rendered, %d presented  jitter buffer avg %.1f ms  rtt %.1f ms",
                              stats.codec ?? "?", Int(stats.frameWidth ?? 0), Int(stats.frameHeight ?? 0), rendered, presented,
                              jb ?? -1, (stats.roundTripTime ?? 0) * 1000)
            Task { @MainActor in self?.label.text = text }
        }
    }

    nonisolated static func model() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// The code cell positions, set once the host sends them.
final class ReaderBox: Sendable {
    private let state = Mutex<FrameCodeReader?>(nil)
    var value: FrameCodeReader? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Sends echoes on the control channel from any thread.
final class SendBox: @unchecked Sendable {
    weak var session: WebRTCSession?
    func echo(_ counter: UInt32, _ stage: ProbeMessage.EchoStage) {
        message(.echo(counter: counter, stage: stage))
    }
    func message(_ m: ProbeMessage) {
        session?.send(m.data, on: .control)
    }
}
