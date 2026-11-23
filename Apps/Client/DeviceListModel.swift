import BackendClient
import Foundation
import Network
import Observation
import os
import Pairing
import SessionTransport

/// The Macs on this network (plan section 7, Devices screen). Phase 3 adds the account's Macs.
@MainActor
@Observable
final class DeviceListModel {
    enum BrowseState: Equatable {
        case starting
        case browsing
        /// Usually Local Network access is off for Farside.
        case blocked(String)
    }

    private(set) var hosts: [DiscoveredHost] = []
    private(set) var state: BrowseState = .starting
    /// The session on screen, if any.
    var connection: ConnectionModel?
    /// This iPad's identity and paired Macs. Nil only if the keychain refused.
    let pairing: ClientPairing? = try? ClientPairing()
    /// Sign-in and online status, when this build has a backend.
    let backend: ClientBackend?

    init() {
        backend = pairing.map { ClientBackend(identity: $0.identity) }
    }

    @ObservationIgnored private var browser: LANBrowser?
    @ObservationIgnored private let log = Logger(subsystem: "app.farside.client", category: "discovery")

    func start() {
        backend?.start()
        guard browser == nil else { return }
        let log = self.log
        let browser = LANBrowser(
            onHosts: { [weak self] hosts in Task { @MainActor in self?.hosts = hosts } },
            onState: { [weak self] state in
                log.info("browser \(String(describing: state), privacy: .public)")
                Task { @MainActor in
                    switch state {
                    case .starting: self?.state = .starting
                    case .browsing: self?.state = .browsing
                    case .waiting(let reason), .failed(let reason): self?.state = .blocked(reason)
                    case .stopped: break
                    }
                }
            })
        browser.start()
        self.browser = browser
    }

    func stop() {
        browser?.stop()
        browser = nil
    }

    /// Connects to a paired Mac, found on this network or at a typed address.
    func connect(to host: DiscoveredHost, as peer: PairedPeer) {
        open(.lan(host), peer: peer)
    }

    /// Connects to a paired Mac through the backend, from any network (plan section 12).
    func connectOverInternet(to peer: PairedPeer) {
        guard let backend, let link = backend.link else { return }
        open(.internet(api: link.api, router: link.router, relay: backend.relayMode), peer: peer)
    }

    private func open(_ route: ConnectionModel.Route, peer: PairedPeer) {
        guard connection == nil, let pairing else { return }
        let connection = ConnectionModel(route: route, peer: peer, credentials: pairing.credentials)
        self.connection = connection
        connection.start()
    }

    /// Paired Macs, with where each was found on this network, if it was.
    var pairedHosts: [(peer: PairedPeer, host: DiscoveredHost?)] {
        (pairing?.paired ?? []).map { peer in (peer, hosts.first { $0.id == peer.id.rawValue }) }
    }

    /// Macs on this network that this iPad has not paired with.
    var unpairedHosts: [DiscoveredHost] {
        hosts.filter { pairing?.peer($0.id) == nil }
    }

    /// Where to reach a Mac for pairing: on this network, or at the last typed address.
    func endpoint(for id: DeviceID) -> NWEndpoint? {
        if let host = hosts.first(where: { $0.id == id.rawValue }) { return host.endpoint }
        return UserDefaults.standard.string(forKey: "lastAddress").flatMap(DiscoveredHost.address)?.endpoint
    }

    /// Closes the session screen.
    func close() {
        connection?.disconnect()
        connection = nil
    }
}
