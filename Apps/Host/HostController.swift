import AppKit
import Foundation
import HostCapture
import Observation
import os
import SessionTransport
import SessionTransportWebRTC

/// Screen Recording, read the way spike S6 found works: the preflight call only at launch, then
/// ScreenCaptureKit's own answer while running.
enum ScreenRecordingStatus: Equatable {
    case checking
    case granted
    /// Not granted when the app started. A grant made since needs a restart to take effect.
    case missing
    /// Granted at launch, refused by ScreenCaptureKit now.
    case revoked
}

/// Local Network has no status API (spike S6): a working connection is the only proof.
enum LocalNetworkStatus: Equatable {
    /// Nothing has connected yet this run, so the grant is unconfirmed.
    case unconfirmed
    /// An iPad reached this Mac on the network during this run.
    case working
    /// The listener could not start or is waiting, usually because access is off.
    case blocked(String)
}

/// The host's state for the menu and the permission window. Main actor only.
@MainActor
@Observable
final class HostController {
    enum Reachability: Equatable {
        case starting
        case reachable
        case notReachable(String)
    }

    private(set) var reachability: Reachability = .starting
    private(set) var screenRecording: ScreenRecordingStatus = .checking
    private(set) var localNetwork: LocalNetworkStatus = .unconfirmed
    private(set) var sessionState: SessionState = .idle
    private(set) var clientName: String?
    /// The user asked for access this run; a restart is what applies it.
    private(set) var restartSuggested = false

    @ObservationIgnored private let log = Logger(subsystem: "app.farside.host", category: "session")
    @ObservationIgnored private var advertiser: LANAdvertiser?
    @ObservationIgnored private var session: HostSession?
    @ObservationIgnored private var transport: WebRTCTransport?
    @ObservationIgnored private var media: HostMedia?
    @ObservationIgnored private var displayObserver: DisplayObserver?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    /// Changes whenever the menu should be rebuilt.
    @ObservationIgnored var onChange: (() -> Void)?

    var isInSession: Bool { sessionState.isActive }

    func start() {
        let log = self.log
        let advertiser = LANAdvertiser(
            id: HostIdentity.deviceID, name: HostIdentity.name,
            onConnection: { [weak self] connection in
                Task { @MainActor in self?.incoming(connection) }
            },
            onState: { [weak self] state in
                log.info("advertiser \(String(describing: state), privacy: .public)")
                Task { @MainActor in self?.advertiserChanged(state) }
            })
        do {
            try advertiser.start()
            self.advertiser = advertiser
        } catch {
            reachability = .notReachable("Could not listen: \(error.localizedDescription)")
        }
        displayObserver = DisplayObserver { [weak self] _ in
            Task { @MainActor in self?.session?.sendDisplays() }
        }
        Task { await refreshScreenRecording() }
    }

    // MARK: Permissions

    func refreshScreenRecording() async {
        let live = await ScreenRecordingAccess.live()
        switch (ScreenRecordingAccess.atLaunch, live) {
        case (_, true?): screenRecording = .granted
        case (true, false?): screenRecording = .revoked
        case (false, _): screenRecording = .missing
        case (true, nil): screenRecording = .granted
        }
        changed()
    }

    func requestScreenRecording() {
        ScreenRecordingAccess.request()
        restartSuggested = true
        openSettings(.screenRecording)
    }

    enum SettingsPane: String {
        case screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case localNetwork = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    }

    func openSettings(_ pane: SettingsPane) {
        if let url = URL(string: pane.rawValue) { NSWorkspace.shared.open(url) }
        if pane == .screenRecording { restartSuggested = true }
        changed()
    }

    /// A new Screen Recording grant applies only to a new process (spike S6). Phase 4 lets
    /// launchd do this; for now the app reopens itself.
    func relaunch() {
        session?.endAndFlush(.hostEnded)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private func advertiserChanged(_ state: LANAdvertiser.State) {
        switch state {
        case .starting: reachability = .starting
        case .ready: reachability = .reachable
        case .waiting(let reason):
            reachability = .notReachable("Waiting for the network")
            localNetwork = .blocked(reason)
        case .failed(let reason):
            reachability = .notReachable("Listener failed")
            localNetwork = .blocked(reason)
        case .stopped: reachability = .notReachable("Stopped")
        }
        changed()
    }

    // MARK: Sessions

    private func incoming(_ connection: SignalingConnection) {
        localNetwork = .working
        // One session at a time (plan section 6). Take over arrives in Phase 4.
        if let session, session.state.isActive {
            log.info("busy: refusing a second connection")
            connection.start(onState: { state in
                if state == .ready {
                    connection.send(.reject(.busy))
                    connection.close()
                }
            }, onMessage: { _ in })
            return
        }

        let media = HostMedia(
            onState: { [weak self] state, client in
                Task { @MainActor in self?.sessionChanged(state, client: client) }
            },
            onProblem: { [weak self] problem in
                Task { @MainActor in self?.mediaProblem(problem) }
            })
        let log = self.log
        let session = HostSession(signaling: connection, local: HostIdentity.deviceInfo(), delegate: media,
                                  log: { text in log.info("\(text, privacy: .public)") })
        let transport = WebRTCTransport(
            role: .host, configuration: .lan,
            makeEncoder: { codec, width, height, bitrate in
                try? VideoEncoder(settings: EncoderSettings(codec: codec, width: width, height: height, bitrate: bitrate))
            },
            handlers: session.transportHandlers())
        media.use(transport)
        self.media = media
        self.session = session
        self.transport = transport
        session.start(transport: transport)
    }

    private func sessionChanged(_ state: SessionState, client: DeviceInfo?) {
        sessionState = state
        clientName = client?.name
        switch state {
        case .securing, .streaming, .paused, .recovering:
            if state == .streaming, statsTask == nil { startStatsLog() }
            if activity == nil {
                // Keeps App Nap away and the display awake while someone is watching (plan section 6).
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
                    reason: "Farside session")
            }
        case .idle:
            endActivity()
            media?.use(nil)
            session = nil
            transport = nil
            media = nil
            clientName = nil
        case .ended(let reason):
            endActivity()
            log.info("session ended: \(reason.rawValue, privacy: .public)")
        case .ringing, .negotiating:
            break
        }
        changed()
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        statsTask?.cancel()
        statsTask = nil
    }

    /// One line every 5 s while streaming: what capture delivered and what the encoder sent.
    /// A static screen should show no complete frames and no new encoded frames.
    private func startStatsLog() {
        let log = self.log
        statsTask = Task { [weak self] in
            var last: TransportStats?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, let transport = self.transport, let media = self.media else { return }
                let s = await transport.stats()
                let c = media.takeCaptureCounters()
                let encoded = (s.framesEncoded ?? 0) - (last?.framesEncoded ?? 0)
                let bytes = (s.bytesSent ?? 0) - (last?.bytesSent ?? 0)
                last = s
                log.info("""
                stats 5s: captured \(c.complete) complete, \(c.idle) idle; encoded \(Int(encoded)) \
                (\(String(format: "%.1f", encoded / 5)) fps), sent \(String(format: "%.2f", bytes * 8 / 5 / 1e6)) Mbps, \
                target \(String(format: "%.1f", (s.targetBitrate ?? 0) / 1e6)) Mbps, \
                encode avg \(String(format: "%.1f", (s.totalEncodeTime ?? 0) / max(s.framesEncoded ?? 1, 1) * 1000)) ms, \
                rtt \(String(format: "%.1f", (s.roundTripTime ?? 0) * 1000)) ms, \
                \(Int(s.frameWidth ?? 0))x\(Int(s.frameHeight ?? 0)) \(s.codec ?? "?", privacy: .public), \
                limit \(s.qualityLimitationReason ?? "?", privacy: .public)
                """)
            }
        }
    }

    private func mediaProblem(_ problem: HostMedia.Problem) {
        switch problem {
        case .screenRecordingDenied:
            screenRecording = ScreenRecordingAccess.atLaunch ? .revoked : .missing
            session?.end(.permissionMissing)
        case .captureFailed(let reason):
            log.error("capture failed: \(reason, privacy: .public)")
            session?.end(.internalError)
        }
        changed()
    }

    func disconnect() {
        session?.end(.hostEnded)
    }

    /// For app termination: the iPad gets a Bye before this process exits.
    func shutDown() {
        if let session, session.state.isActive { session.endAndFlush(.hostEnded) }
        advertiser?.stop()
    }

    // MARK: Menu text

    var statusLine: String {
        switch sessionState {
        case .streaming: return "In session with \(clientName ?? "an iPad")"
        case .ringing, .negotiating, .securing: return "Connecting to \(clientName ?? "an iPad")…"
        case .recovering: return "Reconnecting to \(clientName ?? "the iPad")…"
        case .paused: return "Paused by \(clientName ?? "the iPad")"
        case .idle, .ended: break
        }
        if screenRecording == .missing || screenRecording == .revoked { return "Needs Screen Recording access" }
        switch reachability {
        case .starting: return "Starting…"
        case .reachable: return "Reachable on this network"
        case .notReachable(let reason): return "Not reachable: \(reason)"
        }
    }

    var needsAttention: Bool {
        screenRecording == .missing || screenRecording == .revoked || { if case .blocked = localNetwork { true } else { false } }()
    }

    private func changed() { onChange?() }
}
