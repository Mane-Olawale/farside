import Foundation
import Synchronization

/// One device's connection to the backend: its sign-in, the API with its token, the standing
/// socket, and the router that hands signaling to sessions. Both apps wrap it.
public final class BackendLink: Sendable {
    public enum Status: Sendable, Equatable {
        case signedOut
        case connecting
        case online
        case offline(String?)
    }

    public struct Handlers: Sendable {
        public var onStatus: @Sendable (Status) -> Void
        /// Who is on the account's presence channel, by device id.
        public var onPresence: @Sendable ([String: PresenceMember]) -> Void
        /// Another device on the account was revoked.
        public var onRevoked: @Sendable (String) -> Void

        public init(onStatus: @escaping @Sendable (Status) -> Void = { _ in },
                    onPresence: @escaping @Sendable ([String: PresenceMember]) -> Void = { _ in },
                    onRevoked: @escaping @Sendable (String) -> Void = { _ in }) {
            self.onStatus = onStatus
            self.onPresence = onPresence
            self.onRevoked = onRevoked
        }
    }

    public let config: BackendConfig
    public let api: BackendAPI
    public let router = SignalRouter()
    private let accounts: AccountStore
    private let handlers: Handlers
    private let state: LinkState

    public init(config: BackendConfig, accounts: AccountStore, handlers: Handlers) {
        self.config = config
        self.accounts = accounts
        self.handlers = handlers
        let state = LinkState(account: accounts.load())
        self.state = state
        api = BackendAPI(config: config, token: { state.withLock { $0.account?.token } })
    }

    public var account: SignedInAccount? { state.withLock { $0.account } }

    /// Connects the socket if signed in.
    public func start() {
        guard let account else {
            handlers.onStatus(.signedOut)
            return
        }
        connect(account)
    }

    /// Exchanges an Apple identity token for this device's token, and connects.
    public func signIn(identityToken: String, device: DeviceRegistration) async throws(BackendError) -> SignedInAccount {
        let result = try await api.signInWithApple(identityToken: identityToken, device: device)
        let account = SignedInAccount(token: result.token, accountID: result.accountID, deviceID: result.device.id)
        do {
            try accounts.save(account)
        } catch {
            throw .malformed
        }
        state.withLock { $0.account = account }
        connect(account)
        return account
    }

    /// Forgets the token here. The device stays registered; Remove on another device revokes it.
    public func signOut() {
        let socket = state.withLock { current -> BackendSocket? in
            defer { current = (nil, nil) }
            return current.socket
        }
        try? accounts.clear()
        if let socket { Task { await socket.stop() } }
        handlers.onPresence([:])
        handlers.onStatus(.signedOut)
    }

    /// Disconnects but stays signed in, for example before the Mac sleeps, so its presence
    /// leaves at once. `start()` connects again.
    public func pause() {
        let socket = state.withLock { current -> BackendSocket? in
            defer { current.socket = nil }
            return current.socket
        }
        if let socket { Task { await socket.stop() } }
        handlers.onPresence([:])
        handlers.onStatus(.offline("paused"))
    }

    /// Reconnects now, for example when the network changes.
    public func reconnect() {
        guard let socket = state.withLock({ $0.socket }) else { return }
        Task { await socket.reconnect() }
    }

    private func connect(_ account: SignedInAccount) {
        let handlers = self.handlers
        let router = self.router
        let socket = BackendSocket(api: api, deviceID: account.deviceID, accountID: account.accountID, handlers: .init(
            onState: { [weak self] state in
                switch state {
                case .connecting: handlers.onStatus(.connecting)
                case .connected: handlers.onStatus(.online)
                case .disconnected(let reason): handlers.onStatus(.offline(reason))
                case .stopped: break
                case .unauthorized:
                    // The token was revoked or replaced: this device must sign in again.
                    self?.signOut()
                }
            },
            onSignal: { router.receive($0) },
            onRevoked: { handlers.onRevoked($0) },
            onPresence: { handlers.onPresence($0) }))
        let old = state.withLock { current -> BackendSocket? in
            defer { current.socket = socket }
            return current.socket
        }
        Task {
            await old?.stop()
            await socket.start()
        }
    }
}

/// The sign-in and socket, shared with the API's token closure.
final class LinkState: Sendable {
    private let value: Mutex<(account: SignedInAccount?, socket: BackendSocket?)>

    init(account: SignedInAccount?) {
        value = Mutex((account, nil))
    }

    func withLock<T>(_ body: (inout (account: SignedInAccount?, socket: BackendSocket?)) -> T) -> T {
        value.withLock { body(&$0) }
    }
}

extension BackendConfig {
    /// From the app's Info.plist (`FarsideAPIURL`, `FarsideReverbURL`, `FarsideReverbKey`), which
    /// the build fills from xcconfig. Nil when no backend is configured: LAN only.
    public static func fromInfoPlist(_ bundle: Bundle = .main) -> BackendConfig? {
        func value(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        }
        guard let api = value("FarsideAPIURL").flatMap(URL.init(string:)),
              let reverb = value("FarsideReverbURL").flatMap(URL.init(string:)),
              let key = value("FarsideReverbKey") else { return nil }
        return BackendConfig(api: api, reverbHost: reverb, appKey: key)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
