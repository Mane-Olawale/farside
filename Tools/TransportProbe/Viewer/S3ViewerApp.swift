import ClientVideo
import MediaCore
import os
import SessionTransport
import SessionTransportWebRTC
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
    private var presenter: VideoPresenter?
    private var browser: LANBrowser?
    private var signaling: SignalingConnection?
    private var session: WebRTCTransport?
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

        // Paced by the display link, never blocking for a drawable (plan section 8). Spike S3 used
        // the blocking renderer and measured 36-43 ms from decoded to presented.
        guard let presenter = VideoPresenter(layer: videoView.metalLayer) else { return status("No Metal") }
        self.presenter = presenter
        videoView.onDrawableSize = { presenter.setDrawableSize($0) }
        videoView.setNeedsLayout()
        presenter.start()

        // Connects to the first Mac found, as the spike always did.
        let browser = LANBrowser(
            onHosts: { [weak self] hosts in
                guard let first = hosts.first else { return }
                Task { @MainActor in self?.connect(to: first) }
            },
            onState: { [weak self] state in Task { @MainActor in self?.log.info("browser \(String(describing: state), privacy: .public)") } })
        browser.start()
        self.browser = browser
    }

    private func connect(to host: DiscoveredHost) {
        guard signaling == nil else { return }
        let connection = SignalingConnection.connect(to: host.endpoint)
        connection.start(
            onState: { [weak self] state in
                Task { @MainActor in
                    if state == .ready { self?.status("Connected to the Mac, waiting for the offer") }
                    self?.log.info("signaling \(String(describing: state), privacy: .public)")
                }
            },
            onMessage: { [weak self] message in Task { @MainActor in self?.handle(message) } })
        signaling = connection
    }

    private func status(_ text: String) {
        label.text = text
        log.info("\(text, privacy: .public)")
    }

    /// The host puts the run's settings in the offer's `extra`, because field trials must be set
    /// before the first transport exists.
    private func handle(_ message: SignalMessage) {
        if message.kind == .offer, session == nil, let extra = message.body.extra {
            let codecs = (extra["codecs"] ?? "hevc,h264").split(separator: ",").compactMap { VideoCodec(rawValue: String($0)) }
            startSession(playout: extra["playout"].flatMap(PlayoutMode.init) ?? .standard, codecs: codecs, audio: extra["audio"] == "1")
        }
        session?.handle(message)
    }

    private var playout: AudioPlayout?

    private func startSession(playout mode: PlayoutMode, codecs: [VideoCodec], audio: Bool) {
        let playout = mode
        guard session == nil, let presenter else { return }
        status("Session \(playout.rawValue), codecs \(codecs.map(\.rawValue))")
        let reader = self.reader
        let counters = self.counters
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


        let log = self.log
        let session = WebRTCTransport(
            role: .client, configuration: TransportConfiguration(playout: playout, codecs: codecs), audio: audioRole,
            makeDecoder: { _ in VideoDecoder() },
            handlers: TransportHandlers(
                signal: { [weak self] message in Task { @MainActor in self?.signaling?.send(message) } },
                event: { event in
                    switch event {
                    case .message(.control, let data):
                        if case .cells(let cells)? = ProbeMessage.decode(data) { reader.value = cells }
                    case .message:
                        break
                    default:
                        log.info("\(String(describing: event), privacy: .public)")
                    }
                },
                frame: { pixels, _ in
                    counters.rendered()
                    var counter: UInt32?
                    if let r = reader.value {
                        counter = r.read(pixels.buffer)
                        if let counter { send.echo(counter, .decoded) } else { counters.unreadable() }
                    }
                    let readable = counter != nil
                    presenter.enqueue(pixels, tag: counter ?? 0) { tag, _ in
                        counters.presented()
                        if readable { send.echo(tag, .presented) }
                    }
                }))
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
    weak var session: WebRTCTransport?
    func echo(_ counter: UInt32, _ stage: ProbeMessage.EchoStage) {
        message(.echo(counter: counter, stage: stage))
    }
    func message(_ m: ProbeMessage) {
        session?.send(m.data, on: .control)
    }
}
