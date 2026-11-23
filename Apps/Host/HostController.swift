import AppKit
import Foundation
import HostCapture
import HostInput
import MediaCore
import Observation
import os
import Pairing
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
    /// The port the advertiser got, for the address shown in the menu.
    private(set) var listenPort: UInt16?
    private(set) var screenRecording: ScreenRecordingStatus = .checking
    /// Accessibility, which lets the host post the iPad's input (plan section 6). Unlike Screen
    /// Recording, a grant applies to the running app.
    private(set) var accessibility = EventInjector.hasPostAccess
    private(set) var localNetwork: LocalNetworkStatus = .unconfirmed
    private(set) var sessionState: SessionState = .idle
    private(set) var clientName: String?
    /// The paired device in the current session.
    @ObservationIgnored private(set) var clientID: DeviceID?
    /// AirDrop and Universal Control, which stall the stream over Wi-Fi when on.
    private(set) var peerToPeer = PeerToPeerWiFi.off
    /// The user asked for access this run; a restart is what applies it.
    private(set) var restartSuggested = false

    @ObservationIgnored private let log = Logger(subsystem: "app.farside.host", category: "session")
    @ObservationIgnored private var advertiser: LANAdvertiser?
    @ObservationIgnored private var session: HostSession?
    @ObservationIgnored private var transport: WebRTCTransport?
    @ObservationIgnored private var media: HostMedia?
    @ObservationIgnored private var cursor: HostCursor?
    /// Whether the Mac's screen is locked (plan section 6, lock screen).
    @ObservationIgnored private var screenLocked = HostController.isScreenLockedNow()
    /// Whether this Mac's cursor shape can be read; checked once at launch.
    @ObservationIgnored private lazy var cursorShapesWork = HostCursor.shapesWork()
    @ObservationIgnored private var displayObserver: DisplayObserver?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    /// Changes whenever the menu should be rebuilt.
    @ObservationIgnored var onChange: (() -> Void)? {
        didSet {
            pairing?.onChange = onChange
            backend?.onChange = onChange
        }
    }
    /// Sign-in and rings over the internet, when this build has a backend.
    @ObservationIgnored private(set) var backend: HostBackend?
    /// Keep reachable, sleep and wake, and the lid warning (plan section 6).
    @ObservationIgnored let power = HostPower()
    /// This Mac's identity and paired devices. Nil only if the keychain refused, in which case
    /// nothing can connect.
    @ObservationIgnored private(set) var pairing: HostPairing?

    var isInSession: Bool { sessionState.isActive }

    func start() {
        let log = self.log
        let pairing: HostPairing
        do {
            pairing = try HostPairing()
        } catch {
            log.error("identity unavailable: \(String(describing: error), privacy: .public)")
            reachability = .notReachable("This Mac's identity key is unavailable")
            return
        }
        pairing.onChange = onChange
        self.pairing = pairing
        let backend = HostBackend(pairing: pairing, controller: self)
        backend.onChange = onChange
        self.backend = backend
        backend.start()
        power.start(
            willSleep: { [weak self] in
                guard let self else { return }
                // Plan section 6: close the session cleanly and go offline before sleeping.
                if let session, session.state.isActive { session.endAndFlush(.hostSleeping) }
                self.backend?.pause()
            },
            didWake: { [weak self] in
                guard let self else { return }
                self.backend?.resume()
                self.restartAdvertiserIfIdle()
            })
        let advertiser = LANAdvertiser(
            credentials: pairing.credentials, name: HostIdentity.name,
            onConnection: { [weak self] connection in
                Task { @MainActor in self?.incoming(connection) }
            },
            onPairing: { [weak self] request, connection in
                Task { @MainActor in
                    guard let pairing = self?.pairing else { return connection.replyToPairing(allowed: false) }
                    pairing.handle(request, from: connection)
                }
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
            Task { @MainActor in
                self?.media?.input.refreshDisplays()
                self?.session?.sendDisplays()
            }
        }
        Task { await refreshScreenRecording() }
        refreshPeerToPeer()
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenLocked = locked
                    self?.media?.input.setScreenLocked(locked)
                }
            }
        }
        // A grant made in System Settings applies at once; notice it without the menu opening.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if !self.accessibility { self.refreshAccessibility() }
            }
        }
    }

    /// Rereads the AirDrop and Universal Control settings. Cheap; called whenever the menu or
    /// the checklist is shown and when a session starts.
    func refreshPeerToPeer() {
        let now = PeerToPeerWiFi.current()
        guard now != peerToPeer else { return }
        peerToPeer = now
        log.info("peer-to-peer Wi-Fi: AirDrop \(now.airDrop ? "on" : "off", privacy: .public), Universal Control \(now.universalControl ? "on" : "off", privacy: .public)")
        changed()
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
        log.info("screen recording: at launch \(ScreenRecordingAccess.atLaunch), live \(String(describing: live), privacy: .public) -> \(String(describing: self.screenRecording), privacy: .public)")
        changed()
    }

    func refreshAccessibility() {
        let now = EventInjector.hasPostAccess
        guard now != accessibility else { return }
        accessibility = now
        log.info("accessibility: \(now ? "granted" : "missing", privacy: .public)")
        changed()
    }

    func requestAccessibility() {
        EventInjector.requestPostAccess()
        openSettings(.accessibility)
    }

    func requestScreenRecording() {
        ScreenRecordingAccess.request()
        restartSuggested = true
        openSettings(.screenRecording)
    }

    enum SettingsPane: String {
        case screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case localNetwork = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case airDrop = "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension"
        case displays = "x-apple.systempreferences:com.apple.Displays-Settings.extension"
    }

    func openSettings(_ pane: SettingsPane) {
        if let url = URL(string: pane.rawValue) { NSWorkspace.shared.open(url) }
        if pane == .screenRecording { restartSuggested = true }
        changed()
    }

    /// A new Screen Recording grant applies only to a new process (spike S6); launchd starts
    /// the app again.
    func relaunch() {
        HostLaunch.restart { session?.endAndFlush(.hostEnded) }
    }

    /// Open at login (plan section 6): the LaunchAgent's state, for the checklist.
    var loginItem: HostLaunch.LoginItem { HostLaunch.loginItem }

    private func advertiserChanged(_ state: LANAdvertiser.State) {
        switch state {
        case .starting: reachability = .starting
        case .ready(let port):
            reachability = .reachable
            listenPort = port
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
        if isBusy {
            log.info("busy: refusing a second connection")
            connection.start(onState: { state in
                if state == .ready { connection.sendAndClose(.reject(.busy)) }
            }, onMessage: { _ in })
            return
        }
        begin(connection, configuration: .lan)
    }

    var isBusy: Bool { session?.state.isActive == true }

    /// A paired device's session, over the LAN or through the backend.
    func begin(_ connection: any SignalingChannel, configuration: TransportConfiguration) {
        clientID = connection.peer
        let input = HostInputHandler(onAccessMissing: { [weak self] in
            Task { @MainActor in self?.refreshAccessibility() }
        })
        screenLocked = Self.isScreenLockedNow()
        input.setScreenLocked(screenLocked)
        let media = HostMedia(
            input: input,
            cursorInVideo: !cursorShapesWork,
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
            role: .host, configuration: configuration,
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
            if state == .streaming, statsTask == nil {
                startStatsLog()
                refreshPeerToPeer()
                refreshAccessibility()
            }
            if state == .streaming, cursor == nil, let session, let media {
                let cursor = HostCursor(session: session, media: media)
                cursor.start()
                self.cursor = cursor
            }
            if activity == nil {
                // Keeps App Nap away and the display awake while someone is watching (plan section 6).
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
                    reason: "Farside session")
            }
        case .idle:
            endActivity()
            cursor?.stop()
            cursor = nil
            media?.use(nil)
            session = nil
            transport = nil
            media = nil
            clientName = nil
        case .ended(let reason):
            endActivity()
            cursor?.stop()
            cursor = nil
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
                (\(String(format: "%.1f", encoded / 5), privacy: .public) fps), \
                sent \(String(format: "%.2f", bytes * 8 / 5 / 1e6), privacy: .public) Mbps, \
                target \(String(format: "%.1f", (s.targetBitrate ?? 0) / 1e6), privacy: .public) Mbps, \
                encode avg \(String(format: "%.1f", (s.totalEncodeTime ?? 0) / max(s.framesEncoded ?? 1, 1) * 1000), privacy: .public) ms, \
                rtt \(String(format: "%.1f", (s.roundTripTime ?? 0) * 1000), privacy: .public) ms, \
                \(Int(s.frameWidth ?? 0))x\(Int(s.frameHeight ?? 0)) \(s.codec ?? "?", privacy: .public), \
                limit \(s.qualityLimitationReason ?? "?", privacy: .public)
                """)
                log.info("timeline 5s: \(FrameTimeline.shared.summary(), privacy: .public)")
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

    /// After wake the listener may be stale; with no session, start it again.
    private func restartAdvertiserIfIdle() {
        guard !isBusy, let advertiser else { return }
        advertiser.stop()
        do { try advertiser.start() } catch { log.error("listener did not restart: \(error.localizedDescription, privacy: .public)") }
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
        if !accessibility { return "Needs Accessibility access for input" }
        switch reachability {
        case .starting: return "Starting…"
        case .reachable: return "Reachable on this network"
        case .notReachable(let reason): return "Not reachable: \(reason)"
        }
    }

    var needsAttention: Bool {
        screenRecording == .missing || screenRecording == .revoked || !accessibility
            || { if case .blocked = localNetwork { true } else { false } }()
    }

    /// What to type in the iPad's Connect by Address: this Mac's address on its main network, and
    /// the port only when it is not the default.
    var connectAddress: String? {
        guard let ip = Self.primaryIPv4() else { return nil }
        guard let port = listenPort, port != LAN.defaultPort else { return ip }
        return "\(ip):\(port)"
    }

    /// The first IPv4 address on an active Wi-Fi or Ethernet interface (en0, en1, …).
    static func primaryIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, ip: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            candidates.append((name, String(cString: host)))
        }
        // The LAN first; a VPN tunnel (utun) after.
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.ip
    }

    /// The console session's lock state, for when the app starts with the Mac already locked.
    static func isScreenLockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? (session["CGSSessionScreenIsLocked"] as? Int).map { $0 != 0 } ?? false
    }

    private func changed() { onChange?() }
}
