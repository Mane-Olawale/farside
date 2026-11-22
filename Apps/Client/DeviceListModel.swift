import Foundation
import Observation
import os
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

    @ObservationIgnored private var browser: LANBrowser?
    @ObservationIgnored private let log = Logger(subsystem: "app.farside.client", category: "discovery")

    func start() {
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

    func connect(to host: DiscoveredHost) {
        guard connection == nil else { return }
        let connection = ConnectionModel(host: host)
        self.connection = connection
        connection.start()
    }

    /// Closes the session screen.
    func close() {
        connection?.disconnect()
        connection = nil
    }
}
