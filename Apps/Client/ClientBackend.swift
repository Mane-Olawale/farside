import AuthenticationServices
import BackendClient
import Foundation
import Observation
import os
import Pairing
import UIKit

/// The iPad's side of the backend (plan section 7, Devices screen; section 13): Sign in with
/// Apple, the standing socket while the app is open, and which paired Macs are online.
@MainActor
@Observable
final class ClientBackend {
    enum Status: Equatable {
        /// No backend configured in this build: LAN only.
        case unavailable
        case signedOut
        case connecting
        case online
        case offline
    }

    private(set) var status: Status = .unavailable
    /// Devices on the account's presence channel, by device id.
    private(set) var online: [String: PresenceMember] = [:]
    private(set) var signInError: String?
    /// Plan section 12: the debug switch that forces the relay.
    var relayOnly = UserDefaults.standard.bool(forKey: "relayOnly") {
        didSet { UserDefaults.standard.set(relayOnly, forKey: "relayOnly") }
    }

    @ObservationIgnored private(set) var link: BackendLink?
    @ObservationIgnored private let identity: LocalIdentity
    @ObservationIgnored private let log = Logger(subsystem: "app.farside.client", category: "backend")

    init(identity: LocalIdentity) {
        self.identity = identity
        guard let config = BackendConfig.fromInfoPlist() else { return }
        var handlers = BackendLink.Handlers()
        let log = self.log
        handlers.onStatus = { [weak self] status in
            log.info("backend \(String(describing: status), privacy: .public)")
            Task { @MainActor in
                switch status {
                case .signedOut: self?.status = .signedOut
                case .connecting: self?.status = .connecting
                case .online: self?.status = .online
                case .offline: self?.status = .offline
                }
            }
        }
        handlers.onPresence = { [weak self] members in Task { @MainActor in self?.online = members } }
        link = BackendLink(config: config, accounts: AccountStore(store: ClientPairing.store), handlers: handlers)
        status = link?.account == nil ? .signedOut : .connecting
    }

    func start() {
        link?.start()
    }

    func isOnline(_ id: DeviceID) -> Bool {
        online[id.rawValue] != nil
    }

    /// The SignInWithAppleButton's result.
    func completeSignIn(_ result: Result<ASAuthorization, any Error>) {
        signInError = nil
        guard let link else { return }
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled { signInError = "Sign in with Apple did not finish." }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                signInError = "Sign in with Apple returned no token."
                return
            }
            let registration = DeviceRegistration(identity: identity, platform: "iPadOS", model: ConnectionModel.deviceModel,
                                                   osVersion: UIDevice.current.systemVersion,
                                                   appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            Task {
                do {
                    _ = try await link.signIn(identityToken: token, device: registration)
                } catch {
                    log.error("sign in failed: \(String(describing: error), privacy: .public)")
                    signInError = (error as? BackendError).map { ConnectionModel.explain($0, mac: "your Macs") }
                        ?? "Could not sign in."
                }
            }
        }
    }

    func signOut() {
        link?.signOut()
    }
}
