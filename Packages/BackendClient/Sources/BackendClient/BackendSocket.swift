import Foundation

/// The standing WebSocket to the backend (plan section 13, signaling design): signaling for this
/// device arrives on `private-device.{id}`, and the account's presence channel says which
/// devices are online. Reconnects with backoff and subscribes again, until stopped or until the
/// token is refused.
public actor BackendSocket {
    public enum State: Sendable, Equatable {
        case connecting
        case connected
        case disconnected(String?)
        /// The backend refused the token: sign in again.
        case unauthorized
        case stopped
    }

    public struct Handlers: Sendable {
        public var onState: @Sendable (State) -> Void
        /// One signaling envelope, exactly as the sender signed it.
        public var onSignal: @Sendable (Data) -> Void
        /// Another device on the account was revoked: a Mac drops its pin.
        public var onRevoked: @Sendable (String) -> Void
        /// Everyone on the account's presence channel, by device id.
        public var onPresence: @Sendable ([String: PresenceMember]) -> Void

        public init(onState: @escaping @Sendable (State) -> Void = { _ in },
                    onSignal: @escaping @Sendable (Data) -> Void = { _ in },
                    onRevoked: @escaping @Sendable (String) -> Void = { _ in },
                    onPresence: @escaping @Sendable ([String: PresenceMember]) -> Void = { _ in }) {
            self.onState = onState
            self.onSignal = onSignal
            self.onRevoked = onRevoked
            self.onPresence = onPresence
        }
    }

    private let api: BackendAPI
    private let deviceChannel: String
    private let presenceChannel: String
    private let handlers: Handlers
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    /// Bumped on every connect and stop, so callbacks from an old socket are ignored.
    private var generation = 0
    private var running = false
    private var backoff = Backoff()
    private var presence = PresenceTracker()
    private var lastHeard = ContinuousClock.now
    private var activityTimeout = 30
    private var pinged = false

    public init(api: BackendAPI, deviceID: String, accountID: String, handlers: Handlers, session: URLSession = .shared) {
        self.api = api
        deviceChannel = "private-device.\(deviceID)"
        presenceChannel = "presence-account.\(accountID)"
        self.handlers = handlers
        self.session = session
    }

    public func start() {
        guard !running else { return }
        running = true
        backoff.reset()
        connect()
    }

    public func stop() {
        running = false
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        handlers.onState(.stopped)
    }

    /// Reconnects now, for example when the network changes.
    public func reconnect() {
        guard running else { return }
        task?.cancel(with: .goingAway, reason: nil)
        backoff.reset()
        connect()
    }

    // MARK: Internals

    private func connect() {
        generation += 1
        let current = generation
        let task = session.webSocketTask(with: api.config.socket)
        task.maximumMessageSize = 64 * 1024
        self.task = task
        lastHeard = .now
        pinged = false
        handlers.onState(.connecting)
        task.resume()
        Task { await self.receive(on: task, generation: current) }
        Task { await self.watch(generation: current) }
    }

    private func receive(on task: URLSessionWebSocketTask, generation current: Int) async {
        while current == generation {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                dropped(generation: current, reason: error.localizedDescription)
                return
            }
            guard current == generation else { return }
            switch message {
            case .string(let text): handle(text, generation: current)
            case .data(let data): handle(String(decoding: data, as: UTF8.self), generation: current)
            @unknown default: break
            }
        }
    }

    private func handle(_ text: String, generation current: Int) {
        lastHeard = .now
        pinged = false
        guard let message = Pusher.decode(text) else { return }
        if let (socketID, timeout) = Pusher.established(message) {
            activityTimeout = timeout
            backoff.reset()
            handlers.onState(.connected)
            for channel in [deviceChannel, presenceChannel] {
                Task { await self.subscribe(channel, socketID: socketID, generation: current) }
            }
            return
        }
        switch message.event {
        case "pusher:ping":
            send(Pusher.pong)
        case "signal" where message.channel == deviceChannel:
            if let envelope = Pusher.field("envelope", in: message) { handlers.onSignal(Data(envelope.utf8)) }
        case "revoked" where message.channel == deviceChannel:
            if let device = Pusher.field("device", in: message) { handlers.onRevoked(device) }
        case _ where message.channel == presenceChannel:
            if presence.apply(message) { handlers.onPresence(presence.members) }
        default:
            break
        }
    }

    private func subscribe(_ channel: String, socketID: String, generation current: Int) async {
        do {
            let auth = try await api.authorize(socketID: socketID, channel: channel)
            guard current == generation else { return }
            send(Pusher.subscribe(channel: channel, auth: auth))
        } catch .unauthorized {
            guard current == generation else { return }
            running = false
            generation += 1
            task?.cancel(with: .policyViolation, reason: nil)
            handlers.onState(.unauthorized)
        } catch {
            dropped(generation: current, reason: "could not subscribe: \(error)")
        }
    }

    private func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    /// Pings after the activity timeout with nothing heard, and gives up on the socket 15 s
    /// after that.
    private func watch(generation current: Int) async {
        while current == generation {
            try? await Task.sleep(for: .seconds(5))
            guard current == generation else { return }
            let quiet = ContinuousClock.now - lastHeard
            if quiet > .seconds(activityTimeout + 15) {
                dropped(generation: current, reason: "no reply to ping")
                return
            }
            if quiet > .seconds(activityTimeout), !pinged {
                pinged = true
                send(Pusher.ping)
            }
        }
    }

    private func dropped(generation current: Int, reason: String) {
        guard current == generation, running else { return }
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if !presence.members.isEmpty {
            presence = PresenceTracker()
            handlers.onPresence([:])
        }
        handlers.onState(.disconnected(reason))
        let delay = backoff.next()
        let retry = generation
        Task {
            try? await Task.sleep(for: delay)
            self.retry(ifStill: retry)
        }
    }

    private func retry(ifStill expected: Int) {
        guard running, generation == expected else { return }
        connect()
    }
}
