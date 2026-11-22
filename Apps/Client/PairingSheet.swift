import Pairing
import SessionTransport
import SwiftUI
import VisionKit

/// Pairing with a Mac (plan section 14): scan its QR code, check its name and key, send this
/// iPad's details, then wait while the person at the Mac allows it.
struct PairingSheet: View {
    let model: DeviceListModel
    @Environment(\.dismiss) private var dismiss

    enum Step: Equatable {
        case scanning
        case confirm(PairingInvite)
        case waiting(PairingInvite)
        case done(String)
        case failed(String)
    }

    @State private var step = Step.scanning

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Pair a Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(step == .scanning ? "Cancel" : "Close") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .scanning:
            VStack(spacing: 16) {
                if DataScannerViewController.isSupported {
                    QRScanner { text in
                        guard step == .scanning else { return }
                        do {
                            step = .confirm(try PairingInvite.parse(text, now: Int64(Date().timeIntervalSince1970)))
                        } catch PairingInvite.ParseError.expired {
                            step = .failed("That code has expired. Choose Pair New Device again on the Mac.")
                        } catch {
                            step = .failed("That is not a Farside pairing code.")
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ContentUnavailableView("This iPad cannot scan codes", systemImage: "camera",
                                           description: Text("Farside needs the camera to pair."))
                }
                Text("On the Mac, open Farside Host's menu and choose Pair New Device. Then point this iPad's camera at the code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()

        case .confirm(let invite):
            VStack(spacing: 20) {
                Image(systemName: "desktopcomputer").font(.system(size: 48)).foregroundStyle(.tint)
                Text("Pair with “\(invite.name)”?").font(.title2.bold())
                VStack(spacing: 4) {
                    Text("Its key").font(.caption).foregroundStyle(.secondary)
                    Text(invite.key.fingerprint.display).font(.callout.monospaced())
                }
                Text("Check that the Mac's Pair New Device window shows the same key.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Pair") { start(invite) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(32)

        case .waiting(let invite):
            VStack(spacing: 16) {
                ProgressView()
                Text("Click Allow on \(invite.name)").font(.title3.bold())
                Text("The Mac is asking whether to allow “\(model.pairing?.identity.name ?? "this iPad")”.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(32)

        case .done(let name):
            ContentUnavailableView {
                Label("Paired with \(name)", systemImage: "checkmark.circle")
            } actions: {
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Not paired", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Scan Again") { step = .scanning }
            }
        }
    }

    private func start(_ invite: PairingInvite) {
        guard let pairing = model.pairing else { return }
        guard let endpoint = model.endpoint(for: invite.id) else {
            step = .failed("\(invite.name) is not on this network. Pairing needs the iPad and the Mac on the same network, or the Mac's address in Connect by Address.")
            return
        }
        step = .waiting(invite)
        Task {
            switch await pairing.pair(with: invite, at: endpoint) {
            case .paired(let peer): step = .done(peer.name)
            case .refused: step = .failed("\(invite.name) did not allow this iPad.")
            case .failed: step = .failed("Could not reach \(invite.name). Make sure both are on the same network and try again.")
            }
        }
    }
}

/// VisionKit's live scanner, looking for QR codes only.
private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                if let text = code.payloadStringValue { onCode(text) }
            }
        }
    }
}
