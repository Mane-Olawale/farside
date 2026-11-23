import AppKit
import CoreImage.CIFilterBuiltins
import Observation
import os
import Pairing
import SecureStore
import SessionTransport
import SwiftUI

/// This Mac's identity, its paired devices, and the pairing window (plan section 14, pairing
/// once and in person). Main actor only.
@MainActor
@Observable
final class HostPairing {
    let identity: LocalIdentity
    private(set) var paired: [PairedPeer] = []
    /// The open invite, while the QR code is showing.
    private(set) var invite: PairingInvite?

    @ObservationIgnored private let peers: PeerStore
    @ObservationIgnored private var window: PairingWindow?
    @ObservationIgnored private var qrWindow: NSWindow?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "app.farside.host", category: "pairing")
    @ObservationIgnored var onChange: (() -> Void)?

    static let store = KeychainSecretStore(service: "app.farside.host")

    init() throws {
        identity = try LocalIdentity.loadOrCreate(in: Self.store, name: HostIdentity.name)
        peers = PeerStore(store: Self.store)
        reload()
    }

    /// Signaling checks every sender against these pins and nothing else.
    var credentials: SessionCredentials {
        let peers = self.peers
        return SessionCredentials(identity: identity, trust: .pinned { id in try? peers.key(for: id) })
    }

    // MARK: Pairing window

    /// Shows the QR code for 2 minutes.
    func open() {
        let now = Int64(Date().timeIntervalSince1970)
        let window = PairingWindow(invite: PairingInvite(host: identity, now: now))
        self.window = window
        invite = window.invite
        showQR()
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PairingInvite.lifetime))
            guard !Task.isCancelled else { return }
            self?.closeWindow()
        }
        onChange?()
    }

    func closeWindow() {
        window?.close()
        window = nil
        invite = nil
        expiry?.cancel()
        qrWindow?.close()
        onChange?()
    }

    /// An iPad answered the QR code. The proof is checked, then the person at the Mac decides.
    func handle(_ request: PairingRequest, from connection: SignalingConnection) {
        guard var window else {
            connection.replyToPairing(allowed: false)
            return
        }
        let peer: PairedPeer
        do {
            peer = try window.accept(request, now: Int64(Date().timeIntervalSince1970))
            self.window = window
        } catch {
            self.window = window
            log.error("pairing request refused: \(String(describing: error), privacy: .public)")
            connection.replyToPairing(allowed: false)
            if !window.isOpen { closeWindow() }
            return
        }
        closeWindow()
        let alert = NSAlert()
        alert.messageText = "Allow “\(peer.name)” to control this Mac?"
        alert.informativeText = """
            It will be able to see this Mac's screen and use its keyboard and mouse whenever it connects.

            Key: \(peer.key.fingerprint.display)
            """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.activate()
        let allowed = alert.runModal() == .alertFirstButtonReturn
        if allowed {
            do {
                try peers.pin(peer)
                log.info("paired with a new device")
            } catch {
                log.error("could not save the pairing: \(String(describing: error), privacy: .public)")
                connection.replyToPairing(allowed: false)
                return
            }
            reload()
        }
        connection.replyToPairing(allowed: allowed)
    }

    func remove(_ id: DeviceID) {
        try? peers.remove(id)
        reload()
    }

    private func reload() {
        paired = (try? peers.all()) ?? []
        onChange?()
    }

    // MARK: QR window

    private func showQR() {
        if qrWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PairingView(pairing: self)))
            window.title = "Pair New Device"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            qrWindow = window
        }
        NSApp.activate()
        qrWindow?.makeKeyAndOrderFront(nil)
    }

    static func qrImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width / 2, height: output.extent.height / 2))
    }
}

struct PairingView: View {
    let pairing: HostPairing

    var body: some View {
        VStack(spacing: 14) {
            if let invite = pairing.invite {
                Text("Scan with Farside on your iPad")
                    .font(.headline)
                if let image = HostPairing.qrImage(for: invite.url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .accessibilityLabel("Pairing code")
                }
                Text("This Mac's key: \(pairing.identity.publicKey.fingerprint.display)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(invite.exp) - Int(context.date.timeIntervalSince1970))
                    Text("Expires in \(left / 60):\(String(format: "%02d", left % 60))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("The pairing code has closed.")
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") { pairing.closeWindow() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 340)
    }
}
