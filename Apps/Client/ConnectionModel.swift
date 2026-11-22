import ClientVideo
import Foundation
import MediaCore
import Observation
import os
import QuartzCore
import SessionTransport
import SessionTransportWebRTC
import UIKit
import WireProtocol

/// One second of numbers for the stats overlay (plan section 16). Nil where unknown.
struct StatsSnapshot: Equatable {
    var path: String?
    var roundTripMs: Double?
    var framesReceived: Double?
    var framesDecoded: Double?
    var framesPresented: Int = 0
    var bitrateMbps: Double?
    var resolution: String?
    var codec: String?
    var decodeMs: Double?
    var jitterBufferMs: Double?
    var packetsLost: Double?
    var freezes: Double?
    var framesDropped: Double?
    var replacedBeforeRefresh: Int = 0
    var skippedRefreshes: Int = 0
}

/// One session from the iPad's side: signaling, the transport, decode, presentation and stats.
/// Views read it; the session work runs in `ClientSession` and the transport (plan section 5,
/// rule 3).
@MainActor
@Observable
final class ConnectionModel: Identifiable {
    let id = UUID()
    let host: DiscoveredHost

    private(set) var state: SessionState = .idle
    private(set) var hostInfo: DeviceInfo?
    private(set) var applied: Farside_V1_StreamConfigApplied?
    private(set) var stats = StatsSnapshot()
    /// From tapping Connect to the first frame on the display (Phase 1 exit criterion: 2 s).
    private(set) var timeToFirstFrame: Double?
    var showsStats = true

    /// The video surface. Lives as long as this connection.
    @ObservationIgnored let surface = VideoSurfaceView()
    @ObservationIgnored private var presenter: VideoPresenter?
    @ObservationIgnored private var session: ClientSession?
    @ObservationIgnored private var transport: WebRTCTransport?
    @ObservationIgnored private var link: ClientLink?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var previous: TransportStats?
    @ObservationIgnored private var connectStarted: CFTimeInterval = 0
    @ObservationIgnored private let log = Logger(subsystem: "app.farside.client", category: "session")

    init(host: DiscoveredHost) {
        self.host = host
    }

    func start() {
        connectStarted = CACurrentMediaTime()
        guard let presenter = VideoPresenter(layer: surface.metalLayer) else {
            state = .ended(.internalError)
            return
        }
        surface.onDrawableSize = { presenter.setDrawableSize($0) }
        presenter.start()
        self.presenter = presenter

        let link = ClientLink(model: self)
        let log = self.log
        let signaling = SignalingConnection.connect(to: host.endpoint)
        let session = ClientSession(signaling: signaling, local: Self.deviceInfo(), delegate: link,
                                    log: { text in log.info("\(text, privacy: .public)") })
        let firstFrame = FirstFrameClock(start: connectStarted) { [weak self] seconds in
            Task { @MainActor in self?.timeToFirstFrame = seconds }
        }
        let transport = WebRTCTransport(
            role: .client, configuration: .lan,
            makeDecoder: { _ in VideoDecoder() },
            handlers: session.transportHandlers(frame: { pixels, _ in
                var onPresented: (@Sendable (UInt32, RenderTimes) -> Void)?
                if firstFrame.pending { onPresented = { _, times in firstFrame.presented(times) } }
                presenter.enqueue(pixels, presented: onPresented)
            }))
        self.link = link
        self.session = session
        self.transport = transport
        session.start(transport: transport)
        startStats()
    }

    func disconnect() {
        if state.isActive { session?.end(.userEnded) }
        statsTask?.cancel()
        statsTask = nil
        presenter?.stop()
    }

    /// The app left the foreground. Phase 4 pauses instead; Phase 1 ends the session cleanly.
    func appBackgrounded() {
        if state.isActive { session?.end(.userEnded) }
    }

    // MARK: From the session, via ClientLink

    func sessionChanged(_ state: SessionState, host: DeviceInfo?) {
        self.state = state
        if let host { hostInfo = host }
        UIApplication.shared.isIdleTimerDisabled = state.isActive
        if case .ended(let reason) = state {
            log.info("ended: \(reason.rawValue, privacy: .public)")
            statsTask?.cancel()
        }
    }

    func appliedChanged(_ applied: Farside_V1_StreamConfigApplied) {
        self.applied = applied
    }

    func roundTrip(_ seconds: Double) {
        stats.roundTripMs = seconds * 1000
    }

    /// What to ask the Mac for: its main display, fitted to this screen in pixels.
    nonisolated static func streamRequest(displays: [Farside_V1_Display], screenPixels: CGSize) -> Farside_V1_StreamConfig {
        let display = displays.first(where: \.main) ?? displays.first
        return .with {
            $0.displayID = display?.id ?? 0
            $0.width = UInt32(screenPixels.width)
            $0.height = UInt32(screenPixels.height)
            $0.frameRate = 60
            $0.codecPreference = [.hevc, .h264]
            $0.quality = .balanced
        }
    }

    /// This screen's size in pixels, the right way round for the current orientation.
    var screenPixels: CGSize {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return CGSize(width: 2752, height: 2064) }
        let native = scene.screen.nativeBounds.size
        let landscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
        let long = max(native.width, native.height), short = min(native.width, native.height)
        return landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    // MARK: Stats

    private func startStats() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let transport = self.transport else { return }
                let current = await transport.stats()
                self.update(with: current)
            }
        }
    }

    private func update(with s: TransportStats) {
        let counters = presenter?.takeCounters() ?? VideoPresenter.Counters()
        let p = previous
        previous = s
        func delta(_ key: KeyPath<TransportStats, Double?>) -> Double? {
            guard let now = s[keyPath: key] else { return nil }
            return now - (p?[keyPath: key] ?? 0)
        }
        var next = stats
        next.path = s.localCandidateType.map { $0 == "host" && s.remoteCandidateType == "host" ? "Same network" : "\($0) to \(s.remoteCandidateType ?? "?")" }
        if next.roundTripMs == nil, let rtt = s.roundTripTime { next.roundTripMs = rtt * 1000 }
        next.framesReceived = delta(\.framesReceived)
        next.framesDecoded = delta(\.framesDecoded)
        next.framesPresented = counters.presented
        next.replacedBeforeRefresh = counters.replaced
        next.skippedRefreshes = counters.skippedRefreshes
        next.bitrateMbps = delta(\.bytesReceived).map { $0 * 8 / 1_000_000 }
        if let w = s.frameWidth, let h = s.frameHeight { next.resolution = "\(Int(w))×\(Int(h))" }
        next.codec = s.codec?.replacingOccurrences(of: "video/", with: "")
        if let time = delta(\.totalDecodeTime), let frames = delta(\.framesDecoded), frames > 0 { next.decodeMs = time / frames * 1000 }
        if let jb = delta(\.jitterBufferDelay), let emitted = delta(\.jitterBufferEmittedCount), emitted > 0 { next.jitterBufferMs = jb / emitted * 1000 }
        next.packetsLost = s.packetsLost
        next.freezes = s.freezeCount
        next.framesDropped = s.framesDropped
        stats = next
    }

    // MARK: Identity

    nonisolated static func deviceInfo() -> DeviceInfo {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return DeviceInfo(name: "iPad", model: model,
                          osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                          appVersion: app, capabilities: .with {
                              $0.codecs = [.hevc, .h264]
                              // The 13-inch iPad Pro panel. The request itself carries the real screen.
                              $0.maxWidth = 2752
                              $0.maxHeight = 2064
                              $0.maxFrameRate = 120
                          })
    }
}

/// Measures connect-to-first-frame once.
private final class FirstFrameClock: @unchecked Sendable {
    private let start: CFTimeInterval
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var done = false

    init(start: CFTimeInterval, report: @escaping @Sendable (Double) -> Void) {
        self.start = start
        self.report = report
    }

    var pending: Bool { lock.withLock { !done } }

    func presented(_ times: RenderTimes) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { report(times.presentedSeconds - start) }
    }
}

/// The session's delegate. Called on the session queue; hops to the main actor.
private final class ClientLink: ClientSessionDelegate, @unchecked Sendable {
    private weak var model: ConnectionModel?
    private let screenPixels: CGSize

    @MainActor
    init(model: ConnectionModel) {
        self.model = model
        screenPixels = model.screenPixels
    }

    func clientSessionChooseStream(displays: [Farside_V1_Display], host: DeviceInfo) -> Farside_V1_StreamConfig {
        ConnectionModel.streamRequest(displays: displays, screenPixels: screenPixels)
    }

    func clientSessionApplied(_ applied: Farside_V1_StreamConfigApplied) {
        Task { @MainActor [weak model] in model?.appliedChanged(applied) }
    }

    func clientSessionDisplaysChanged(_ displays: [Farside_V1_Display]) {}

    func clientSessionStateChanged(_ state: SessionState, host: DeviceInfo?) {
        Task { @MainActor [weak model] in model?.sessionChanged(state, host: host) }
    }

    func clientSessionRoundTrip(_ seconds: Double) {
        Task { @MainActor [weak model] in model?.roundTrip(seconds) }
    }
}

/// A view whose layer is the Metal layer the presenter draws into.
final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var onDrawableSize: ((CGSize) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        onDrawableSize?(CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }
}
