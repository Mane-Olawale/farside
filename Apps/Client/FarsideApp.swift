import SessionTransport
import SwiftUI

@main
struct FarsideApp: App {
    @State private var devices = DeviceListModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DevicesView(model: devices)
                .onAppear { devices.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Phase 4 pauses and resumes; in Phase 1 leaving the app ends the session.
                    if phase == .background { devices.connection?.appBackgrounded() }
                }
        }
    }
}

/// The Devices screen (plan section 7): Macs found on this network.
struct DevicesView: View {
    @Bindable var model: DeviceListModel
    @State private var askingForAddress = false
    @State private var address = UserDefaults.standard.string(forKey: "lastAddress") ?? ""

    var body: some View {
        NavigationStack {
            Group {
                if model.hosts.isEmpty {
                    emptyState
                } else {
                    List(model.hosts) { host in
                        Button {
                            model.connect(to: host)
                        } label: {
                            HostRow(host: host)
                        }
                        .disabled(!host.isCompatible)
                    }
                }
            }
            .navigationTitle("Macs")
            .toolbar {
                Button("Connect by Address…") { askingForAddress = true }
            }
            // Plan section 12: a typed host name or IP, for VPNs such as Tailscale.
            .alert("Connect by Address", isPresented: $askingForAddress) {
                TextField("Mac name or IP address", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Connect") {
                    guard let host = DiscoveredHost.address(address) else { return }
                    UserDefaults.standard.set(address, forKey: "lastAddress")
                    model.connect(to: host)
                }
                .disabled(DiscoveredHost.address(address) == nil)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Farside Host's menu shows its address. Add :port only if it shows one.")
            }
        }
        .fullScreenCover(item: $model.connection) { connection in
            SessionScreen(connection: connection) { model.close() }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.state {
        case .blocked:
            ContentUnavailableView {
                Label("Local Network access is off", systemImage: "network.slash")
            } description: {
                Text("Farside needs Local Network access to find your Mac.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .starting, .browsing:
            ContentUnavailableView(
                "Looking for Macs…",
                systemImage: "desktopcomputer",
                description: Text("Open Farside Host on a Mac on this network.")
            )
        }
    }
}

private struct HostRow: View {
    let host: DiscoveredHost

    var body: some View {
        HStack {
            Image(systemName: "desktopcomputer").foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(host.name)
                if !host.isCompatible {
                    Text("Needs a matching version of Farside Host").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("On this network").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
