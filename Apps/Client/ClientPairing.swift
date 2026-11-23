import Foundation
import Network
import Observation
import os
import Pairing
import SecureStore
import SessionTransport
import UIKit

/// This iPad's identity and the Macs it has paired with (plan section 14). Main actor only.
@MainActor
@Observable
final class ClientPairing {
    let identity: LocalIdentity
    private(set) var paired: [PairedPeer] = []

    @ObservationIgnored private let peers: PeerStore
    @ObservationIgnored private let log = Logger(subsystem: "app.farside.client", category: "pairing")

    static let store = KeychainSecretStore(service: "app.farside.client")

    init() throws {
        identity = try LocalIdentity.loadOrCreate(in: Self.store, name: UIDevice.current.name)
        peers = PeerStore(store: Self.store)
        reload()
    }

    var credentials: SessionCredentials {
        let peers = self.peers
        return SessionCredentials(identity: identity, trust: .pinned { id in try? peers.key(for: id) })
    }

    func peer(_ id: String) -> PairedPeer? {
        paired.first { $0.id.rawValue == id }
    }

    enum PairOutcome: Equatable {
        case paired(PairedPeer)
        case refused
        case failed(String)
    }

    /// Sends this iPad's answer to the Mac's QR code and waits for the person at the Mac.
    func pair(with invite: PairingInvite, at endpoint: NWEndpoint) async -> PairOutcome {
        let request = PairingRequest(client: identity, platform: "iPadOS", invite: invite)
        let credentials = self.credentials
        let result: SignalingConnection.PairingResult = await withCheckedContinuation { continuation in
            let once = OnceBox(continuation)
            let connection = SignalingConnection.pair(to: endpoint, credentials: credentials, invite: invite, request: request) {
                once.resume($0)
            }
            // Long enough for someone to walk to the Mac and click Allow.
            Task {
                try? await Task.sleep(for: .seconds(90))
                once.resume(.failed("timed out"))
                connection.close()
            }
        }
        switch result {
        case .paired:
            let peer = PairedPeer(id: invite.id, name: invite.name, platform: "macOS", key: invite.key,
                                  pairedAt: Int64(Date().timeIntervalSince1970))
            do {
                try peers.pin(peer)
            } catch {
                log.error("could not save the pairing: \(String(describing: error), privacy: .public)")
                return .failed("This iPad could not save the pairing.")
            }
            reload()
            return .paired(peer)
        case .refused:
            return .refused
        case .failed(let reason):
            log.error("pairing failed: \(reason, privacy: .public)")
            return .failed(reason)
        }
    }

    func remove(_ id: DeviceID) {
        try? peers.remove(id)
        reload()
    }

    private func reload() {
        paired = (try? peers.all()) ?? []
    }
}

/// Resumes a continuation once, whichever of the answer or the timeout comes first.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SignalingConnection.PairingResult, Never>?

    init(_ continuation: CheckedContinuation<SignalingConnection.PairingResult, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: SignalingConnection.PairingResult) {
        let c = lock.withLock { () -> CheckedContinuation<SignalingConnection.PairingResult, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: result)
    }
}
