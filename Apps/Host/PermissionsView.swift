import SwiftUI

/// The permission checklist (plan section 6). Phase 1 covers Screen Recording and Local Network;
/// Accessibility and the login item arrive with input (Phase 2) and the LaunchAgent (Phase 4).
struct PermissionsView: View {
    let controller: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Farside Host needs two permissions to show this Mac on your iPad.")
                .font(.headline)

            row(title: "Screen Recording",
                why: "Lets Farside Host capture the display it streams.",
                state: screenState,
                actions: {
                    switch controller.screenRecording {
                    case .missing, .revoked:
                        Button("Allow…") { controller.requestScreenRecording() }
                        Button("Open Settings") { controller.openSettings(.screenRecording) }
                    case .granted, .checking:
                        EmptyView()
                    }
                })

            row(title: "Local Network",
                why: "Lets your iPad find this Mac and connect to it directly.",
                state: networkState,
                actions: {
                    Button("Open Settings") { controller.openSettings(.localNetwork) }
                })

            if controller.peerToPeer.anyOn {
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                        .font(.title2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Smoother streaming over Wi-Fi").font(.body.weight(.semibold))
                        Text("\(controller.peerToPeer.names) \(controller.peerToPeer.airDrop && controller.peerToPeer.universalControl ? "are" : "is") on. While they are, this Mac's Wi-Fi pauses several times a second, and the picture on your iPad stutters. Turn them off while you use Farside.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        if controller.peerToPeer.airDrop {
                            Button("AirDrop Settings") { controller.openSettings(.airDrop) }
                        }
                        if controller.peerToPeer.universalControl {
                            Button("Display Settings") { controller.openSettings(.displays) }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if controller.restartSuggested || controller.screenRecording == .missing || controller.screenRecording == .revoked {
                Divider()
                HStack {
                    Text("macOS applies a new Screen Recording permission only after Farside Host restarts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Farside Host") { controller.relaunch() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            // ScreenCaptureKit is the only live signal (spike S6); poll it while the window is open.
            while !Task.isCancelled {
                await controller.refreshScreenRecording()
                controller.refreshPeerToPeer()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var screenState: (String, Color, String) {
        switch controller.screenRecording {
        case .checking: ("Checking…", .secondary, "circle.dotted")
        case .granted: ("Allowed", .green, "checkmark.circle.fill")
        case .missing: ("Not allowed", .orange, "exclamationmark.circle.fill")
        case .revoked: ("Turned off", .red, "xmark.circle.fill")
        }
    }

    private var networkState: (String, Color, String) {
        switch controller.localNetwork {
        case .unconfirmed: ("Not confirmed yet. It is confirmed the first time an iPad connects.", .secondary, "questionmark.circle")
        case .working: ("Working", .green, "checkmark.circle.fill")
        case .blocked: ("Blocked. Turn on Farside Host under Local Network.", .red, "xmark.circle.fill")
        }
    }

    private func row<Actions: View>(title: String, why: String, state: (String, Color, String),
                                    @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.2)
                .foregroundStyle(state.1)
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(why).font(.callout).foregroundStyle(.secondary)
                Text(state.0).font(.callout).foregroundStyle(state.1)
            }
            Spacer()
            VStack(alignment: .trailing) { actions() }
        }
        .accessibilityElement(children: .combine)
    }
}
