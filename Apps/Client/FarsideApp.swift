import AuthenticationServices
import Pairing
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

/// The Devices screen (plan section 7): paired Macs first, then other Macs on this network.
struct DevicesView: View {
    @Bindable var model: DeviceListModel
    @State private var askingForAddress = false
    @State private var address = UserDefaults.standard.string(forKey: "lastAddress") ?? ""
    @State private var choosingMacFor: DiscoveredHost?
    @State private var pairing = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Group {
                if model.pairing == nil {
                    ContentUnavailableView("Farside cannot start", systemImage: "key.slash",
                                           description: Text("This iPad's identity key is unavailable."))
                } else if model.hosts.isEmpty && model.pairedHosts.isEmpty && model.backend?.status != .signedOut {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Macs")
            .toolbar {
                ToolbarItemGroup {
                    Button("Connect by Address…") { askingForAddress = true }
                        .disabled(model.pairedHosts.isEmpty)
                    Button("Pair a Mac…", systemImage: "qrcode.viewfinder") { pairing = true }
                }
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
                    let paired = model.pairedHosts.map(\.peer)
                    if paired.count == 1 { model.connect(to: host, as: paired[0]) } else { choosingMacFor = host }
                }
                .disabled(DiscoveredHost.address(address) == nil)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Farside Host's menu shows its address. Add :port only if it shows one.")
            }
            .confirmationDialog("Which Mac is at that address?", isPresented: .init(
                get: { choosingMacFor != nil }, set: { if !$0 { choosingMacFor = nil } })) {
                ForEach(model.pairedHosts.map(\.peer)) { peer in
                    Button(peer.name) {
                        if let host = choosingMacFor { model.connect(to: host, as: peer) }
                        choosingMacFor = nil
                    }
                }
            }
            .alert("Pair first", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("Pair a Mac…") { pairing = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
            .sheet(isPresented: $pairing) { PairingSheet(model: model) }
        }
        .fullScreenCover(item: $model.connection) { connection in
            SessionScreen(connection: connection) { model.close() }
        }
    }

    private var list: some View {
        List {
            if let backend = model.backend, backend.status == .signedOut {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Reach your Macs from anywhere").font(.headline)
                        Text("Sign in with the same Apple Account as Farside Host on your Macs. Macs on this network work without it.")
                            .font(.callout).foregroundStyle(.secondary)
                        SignInWithAppleButton(.signIn) { $0.requestedScopes = [] } onCompletion: { backend.completeSignIn($0) }
                            .frame(height: 44)
                        if let error = backend.signInError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            if !model.pairedHosts.isEmpty {
                Section {
                    ForEach(model.pairedHosts, id: \.peer.id) { entry in
                        let online = model.backend?.isOnline(entry.peer.id) == true
                        Button {
                            if let host = entry.host {
                                model.connect(to: host, as: entry.peer)
                            } else if online {
                                model.connectOverInternet(to: entry.peer)
                            }
                        } label: {
                            HostRow(name: entry.peer.name, detail: detail(host: entry.host, online: online))
                        }
                        .disabled(entry.host.map { !$0.isCompatible } ?? !online)
                        .swipeActions {
                            Button("Forget", role: .destructive) { model.pairing?.remove(entry.peer.id) }
                        }
                        .contextMenu {
                            if online {
                                Button("Connect over the Internet", systemImage: "globe") { model.connectOverInternet(to: entry.peer) }
                            }
                        }
                    }
                } header: {
                    Text("Your Macs")
                } footer: {
                    if let backend = model.backend, backend.status != .signedOut, backend.status != .unavailable {
                        Picker("Relay (testing)", selection: Binding(get: { backend.relayMode }, set: { backend.relayMode = $0 })) {
                            ForEach(ClientBackend.RelayMode.allCases) { Text($0.title).tag($0) }
                        }
                        .font(.caption)
                    }
                }
            }
            if !model.unpairedHosts.isEmpty {
                Section {
                    ForEach(model.unpairedHosts) { host in
                        Button {
                            notice = "To control \(host.name), choose Pair New Device in Farside Host's menu on that Mac, then scan the code with this iPad."
                        } label: {
                            HostRow(name: host.name, detail: "Not paired")
                        }
                    }
                } header: {
                    Text("Other Macs on this network")
                }
            }
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
            ContentUnavailableView {
                Label("Looking for Macs…", systemImage: "desktopcomputer")
            } description: {
                Text("Open Farside Host on a Mac on this network, then pair this iPad with it.")
            } actions: {
                Button("Pair a Mac…") { pairing = true }
            }
        }
    }
}

extension DevicesView {
    func detail(host: DiscoveredHost?, online: Bool) -> String {
        if let host { return host.isCompatible ? "On this network" : "Needs a matching version of Farside Host" }
        if online { return "Online" }
        switch model.backend?.status {
        case .online: return "Offline"
        case .connecting: return "Checking…"
        case .offline: return "Farside service unreachable"
        default: return "Not on this network"
        }
    }
}

private struct HostRow: View {
    let name: String
    let detail: String

    var body: some View {
        HStack {
            Image(systemName: "desktopcomputer").foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
