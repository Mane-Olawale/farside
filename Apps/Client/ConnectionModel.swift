import BackendClient
import ClientInput
import ClientVideo
import Foundation
import MediaCore
import Observation
import os
import Pairing
import QuartzCore
import SessionTransport
import SessionTransportWebRTC
import Synchronization
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
    /// How this connection reaches the Mac (plan section 12).
    enum Route {
        /// Same network, or a typed address: signaling straight to the Mac.
        case lan(DiscoveredHost)
        /// Anywhere else: signaling through the backend, with its STUN and TURN servers.
        case internet(api: BackendAPI, router: SignalRouter, relayOnly: Bool)
    }

    let id = UUID()
    let route: Route
    /// The paired Mac this connection must reach: its pinned key is checked at every step.
    let peer: PairedPeer
    var name: String { peer.name }
    /// Why connecting failed before a session existed, such as the service being down.
    private(set) var setupError: String?
    /// The session's recent log lines (states, path and transport errors; never input or
    /// keys), for the Details list when a connection fails.
    private(set) var recentLog: [String] = []

    func note(_ line: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        recentLog.append("\(stamp) \(line)")
        if recentLog.count > 40 { recentLog.removeFirst(recentLog.count - 40) }
    }
    /// The backend's session id, for the session record. Internet only.
    @ObservationIgnored private(set) var backendSession: String?
    @ObservationIgnored private let credentials: SessionCredentials

    private(set) var state: SessionState = .idle
    private(set) var hostInfo: DeviceInfo?
    private(set) var applied: Farside_V1_StreamConfigApplied?
    private(set) var stats = StatsSnapshot()
    /// From tapping Connect to the first frame on the display (Phase 1 exit criterion: 2 s).
    private(set) var timeToFirstFrame: Double?
    var showsStats = true
    /// The floating toolbar (plan section 7); a three-finger tap shows or hides it.
    var showsToolbar = true
    /// Direct touch or trackpad (plan section 7, input mode). Remembered on this iPad.
    var inputMode: TouchGestureRecognizer.Mode = TouchGestureRecognizer.Mode(
        rawValue: UserDefaults.standard.string(forKey: "inputMode") ?? "") ?? .direct {
        didSet { UserDefaults.standard.set(inputMode.rawValue, forKey: "inputMode") }
    }
    /// Runs on the main thread when the Mac applies a new stream configuration.
    @ObservationIgnored var onAppliedChange: (() -> Void)?
    /// Keys, modifiers and text for this session.
    @ObservationIgnored private(set) lazy var keyboard = KeyboardModel { [weak self] body in self?.sendInput(body) }

    /// The video surface. Lives as long as this connection.
    @ObservationIgnored let surface = VideoSurfaceView()
    @ObservationIgnored private var presenter: VideoPresenter?
    /// The Mac's cursor: shapes, the one in use, and its predicted position.
    @ObservationIgnored private(set) var cursor: CursorModel?
    @ObservationIgnored private var session: ClientSession?
    @ObservationIgnored private var transport: WebRTCTransport?
    @ObservationIgnored private var link: ClientLink?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var previous: TransportStats?
    @ObservationIgnored private var connectStarted: CFTimeInterval = 0
    @ObservationIgnored private let log = Logger(subsystem: "app.farside.client", category: "session")

    init(route: Route, peer: PairedPeer, credentials: SessionCredentials) {
        self.route = route
        self.peer = peer
        self.credentials = credentials
    }

    func start() {
        connectStarted = CACurrentMediaTime()
        switch route {
        case .lan(let host):
            begin(signaling: SignalingConnection.connect(to: host.endpoint, credentials: credentials, peer: peer.id),
                  configuration: .lan)
        case let .internet(api, router, relayOnly):
            state = .ringing
            Task {
                do {
                    let created = try await api.createSession(to: peer.id.rawValue)
                    guard state == .ringing else { return }  // Cancelled meanwhile.
                    backendSession = created.session
                    let log = self.log
                    let signaling = BackendSignaling(api: api, credentials: credentials, session: created.session, peer: peer.id,
                                                     role: .client, router: router, log: { [weak self] line in
                                                         log.info("\(line, privacy: .public)")
                                                         Task { @MainActor in self?.note(line) }
                                                     })
                    let servers = created.iceServers.map { TransportIceServer(urls: $0.urls, username: $0.username, credential: $0.credential) }
                    note("internet path\(relayOnly ? ", relay only" : ""), \(servers.count) ICE servers")
                    let hasRelay = servers.contains { $0.urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }
                    if relayOnly, !hasRelay {
                        // Relay only allows no other path, so with no TURN server nothing can connect.
                        setupError = "Relay only is on, but the Farside service has no relay server. Turn off Relay only under Your Macs."
                        signaling.close()
                        state = .ended(.internalError)
                        return
                    }
                    begin(signaling: signaling, configuration: .internet(iceServers: servers, relayOnly: relayOnly))
                } catch {
                    log.error("could not create the session: \(String(describing: error), privacy: .public)")
                    setupError = (error as? BackendError).map { Self.explain($0, mac: peer.name) } ?? "Could not start a session with \(peer.name)."
                    state = .ended(.internalError)
                }
            }
        }
    }

    static func explain(_ error: BackendError, mac: String) -> String {
        switch error {
        case .unauthorized: "Sign in again to reach \(mac) over the internet."
        case .notFound: "\(mac) is no longer on this account."
        case .unavailable: "The Farside service is unavailable. Macs on this network still work."
        case .rateLimited: "Too many attempts. Wait a minute and try again."
        case .network: "This iPad is offline."
        case .rejected, .malformed: "Could not start a session with \(mac)."
        }
    }

    private func begin(signaling: any SignalingChannel, configuration: TransportConfiguration) {
        guard let presenter = VideoPresenter(layer: surface.metalLayer) else {
            state = .ended(.internalError)
            return
        }
        surface.onDrawableSize = { presenter.setDrawableSize($0) }
        presenter.start()
        self.presenter = presenter

        let cursor = CursorModel(presenter: presenter)
        self.cursor = cursor
        let link = ClientLink(model: self)
        link.cursor.withLock { $0 = cursor }
        let log = self.log
        let session = ClientSession(signaling: signaling, local: Self.deviceInfo(), delegate: link,
                                    log: { [weak self] text in
                                        log.info("\(text, privacy: .public)")
                                        Task { @MainActor in self?.note(text) }
                                    })
        let firstFrame = FirstFrameClock(start: connectStarted) { [weak self] seconds in
            Task { @MainActor in self?.timeToFirstFrame = seconds }
        }
        let transport = WebRTCTransport(
            role: .client, configuration: configuration,
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

    // MARK: Input and drawing, for the session view controller

    /// Sends input to the Mac. Returns the envelope sequence number, or nil when not connected.
    @discardableResult
    func sendInput(_ body: Envelope.OneOf_Body) -> UInt32? {
        guard state == .streaming, let session else { return nil }
        return session.sendInput(body)
    }

    /// Where the video and cursor are drawn from the next refresh on.
    func setScene(_ scene: RenderScene) {
        presenter?.setScene(scene)
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
            recordEnded(reason)
        }
    }

    func appliedChanged(_ applied: Farside_V1_StreamConfigApplied) {
        self.applied = applied
        cursor?.setDisplay(applied.displayID)
        onAppliedChange?()
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
        FrameTimeline.shared.reset()
        let timing = TimingLog()
        statsTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let transport = self.transport else { return }
                let current = await transport.stats()
                self.update(with: current)
                tick += 1
                if tick % 5 == 0 {
                    let s = self.stats
                    timing.write(String(format: "rtt %.0f ms, jitter buffer %.1f ms; ", s.roundTripMs ?? -1, s.jitterBufferMs ?? -1)
                                 + FrameTimeline.shared.summary())
                }
            }
        }
    }

    /// The path kind for the overlay and the session record (plan section 12, path quality):
    /// both host candidates is the same network, any relay candidate is the relay, else direct.
    nonisolated static func pathType(local: String?, remote: String?) -> String? {
        guard let local, let remote else { return nil }
        if local == "relay" || remote == "relay" { return "relay" }
        return local == "host" && remote == "host" ? "lan" : "direct"
    }

    // MARK: Session record (internet sessions; plan section 13)

    @ObservationIgnored private var reportedConnected = false
    @ObservationIgnored private var recordPath: String?
    @ObservationIgnored private var bitrateSamples: [Double] = []
    @ObservationIgnored private var rttSamples: [Double] = []

    private func record(path: String?, bitrateMbps: Double?, rttMs: Double?) {
        guard case let .internet(api, _, _) = route, let session = backendSession else { return }
        if let path { recordPath = path }
        if state == .streaming {
            if let bitrateMbps { bitrateSamples.append(bitrateMbps) }
            if let rttMs { rttSamples.append(rttMs) }
        }
        guard !reportedConnected, state == .streaming, let path = recordPath else { return }
        reportedConnected = true
        Task { try? await api.report(SessionReport(type: .connected, pathType: path), session: session) }
    }

    private func recordEnded(_ reason: SessionEndReason) {
        guard case let .internet(api, _, _) = route, let session = backendSession else { return }
        func average(_ values: [Double]) -> Int? { values.isEmpty ? nil : Int(values.reduce(0, +) / Double(values.count)) }
        let report = SessionReport(type: .ended, pathType: recordPath, endReason: reason.rawValue,
                                   avgBitrate: average(bitrateSamples.map { $0 * 1000 }), avgRtt: average(rttSamples))
        Task { try? await api.report(report, session: session) }
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
        let path = Self.pathType(local: s.localCandidateType, remote: s.remoteCandidateType)
        next.path = path.map { ["lan": "Same network", "direct": "Direct", "relay": "Relay"][$0] ?? $0 }
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
        record(path: path, bitrateMbps: next.bitrateMbps, rttMs: next.roundTripMs)
    }

    // MARK: Identity

    nonisolated static var deviceModel: String { deviceInfo().model }

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

    /// Straight to the cursor model, off the main thread: shapes upload to the GPU here.
    let cursor = Mutex<CursorModel?>(nil)
    func clientSessionCursor(_ body: Envelope.OneOf_Body) {
        cursor.withLock { $0 }?.handle(body)
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

/// Diagnostics: the frame timeline every 5 s, appended to Documents/timing.log. Copy it off with
/// `xcrun devicectl device copy from --domain-type appDataContainer`.
final class TimingLog: Sendable {
    private let url = URL.documentsDirectory.appending(path: "timing.log")
    private let queue = DispatchQueue(label: "farside.timing-log", qos: .utility)
    private let log = Logger(subsystem: "app.farside.client", category: "timing")

    func write(_ line: String) {
        log.info("\(line, privacy: .public)")
        let stamped = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)\n"
        queue.async { [url] in
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
