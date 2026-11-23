import AppKit
import AuthenticationServices
import BackendClient
import Foundation
import Observation
import os
import Pairing
import SessionTransport
import SwiftUI

/// The Mac's side of the backend (plan section 6, staying reachable; section 13): Sign in with
/// Apple, the standing socket, answering rings from paired iPads, and dropping pins for revoked
/// devices. Main actor only.
@MainActor
@Observable
final class HostBackend {
    enum Status: Equatable {
        /// No backend configured in this build: LAN only.
        case unavailable
        case signedOut
        case connecting
        case online
        case offline
    }

    private(set) var status: Status = .unavailable
    private(set) var signInError: String?

    @ObservationIgnored private(set) var link: BackendLink?
    @ObservationIgnored private weak var controller: HostController?
    @ObservationIgnored private let pairing: HostPairing
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private let log = Logger(subsystem: "app.farside.host", category: "backend")
    @ObservationIgnored var onChange: (() -> Void)?

    init(pairing: HostPairing, controller: HostController) {
        self.pairing = pairing
        self.controller = controller
        guard let config = BackendConfig.fromInfoPlist() else { return }
        var handlers = BackendLink.Handlers()
        let log = self.log
        handlers.onStatus = { [weak self] status in
            log.info("backend \(String(describing: status), privacy: .public)")
            Task { @MainActor in self?.statusChanged(status) }
        }
        handlers.onRevoked = { [weak self] id in Task { @MainActor in self?.revoked(id) } }
        let link = BackendLink(config: config, accounts: AccountStore(store: HostPairing.store), handlers: handlers)
        link.router.setRingHandler { [weak self] ring in Task { @MainActor in await self?.ring(ring) } }
        self.link = link
        status = link.account == nil ? .signedOut : .connecting
    }

    func start() {
        link?.start()
    }

    func signOut() {
        link?.signOut()
    }

    // MARK: Rings

    /// An iPad on the account is calling (plan section 12, over the internet, step 2). The ring
    /// comes from the backend unsigned, so it is only a hint: a device this Mac has not paired
    /// with is refused, and every envelope after this is checked against the pin.
    private func ring(_ ring: SignalEnvelope) async {
        guard let link, let controller, let caller = DeviceID(rawValue: ring.from),
              ring.to == pairing.identity.id.rawValue,
              abs(Int64(Date().timeIntervalSince1970) - ring.ts) <= 60 else { return }
        let log = self.log
        let signaling = BackendSignaling(api: link.api, credentials: pairing.credentials, session: ring.session, peer: caller,
                                         role: .host, router: link.router, log: { log.info("\($0, privacy: .public)") })
        guard pairing.paired.contains(where: { $0.id == caller }) else {
            log.info("refused a ring from a device this Mac has not paired with")
            signaling.send(.reject(.notPaired))
            signaling.close()
            return
        }
        guard !controller.isBusy else {
            signaling.send(.reject(.busy))
            signaling.close()
            return
        }
        let servers: IceServerList
        do {
            servers = try await link.api.iceServers()
        } catch {
            log.error("no ICE servers: \(String(describing: error), privacy: .public)")
            signaling.send(.reject(.internalError))
            signaling.close()
            return
        }
        guard !controller.isBusy else {
            signaling.send(.reject(.busy))
            signaling.close()
            return
        }
        signaling.send(.init(kind: .accept))
        let ice = servers.iceServers.map { TransportIceServer(urls: $0.urls, username: $0.username, credential: $0.credential) }
        controller.begin(signaling, configuration: .internet(iceServers: ice))
    }

    /// The backend may remove trust but never add it (plan section 14).
    private func revoked(_ id: String) {
        guard let device = DeviceID(rawValue: id), pairing.paired.contains(where: { $0.id == device }) else { return }
        log.info("a paired device was revoked on the account")
        pairing.remove(device)
        if controller?.clientID == device { controller?.disconnect() }
    }

    private func statusChanged(_ new: BackendLink.Status) {
        switch new {
        case .signedOut: status = .signedOut
        case .connecting: status = .connecting
        case .online:
            status = .online
            window?.close()
        case .offline: status = .offline
        }
        onChange?()
    }

    // MARK: Sign in

    func showSignIn() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HostSignInView(backend: self)))
            window.title = "Sign In to Farside"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

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
            let registration = DeviceRegistration(identity: pairing.identity, platform: "macOS", model: HostIdentity.model,
                                                   osVersion: HostIdentity.osVersion, appVersion: HostIdentity.appVersion)
            Task {
                do {
                    _ = try await link.signIn(identityToken: token, device: registration)
                } catch {
                    log.error("sign in failed: \(String(describing: error), privacy: .public)")
                    signInError = "Could not sign in: \(error)."
                }
            }
        }
    }
}

private struct HostSignInView: View {
    let backend: HostBackend

    var body: some View {
        VStack(spacing: 14) {
            Text("Reach this Mac from anywhere").font(.headline)
            Text("Sign in with the same Apple Account on this Mac and on your iPad. Paired iPads on this network work without it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            SignInWithAppleButton(.signIn) { $0.requestedScopes = [] } onCompletion: { backend.completeSignIn($0) }
                .frame(width: 240, height: 36)
            if let error = backend.signInError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
