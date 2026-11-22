import SwiftUI

@main
struct FarsideApp: App {
    var body: some Scene {
        WindowGroup {
            DevicesPlaceholderView()
        }
    }
}

/// Stands in for the Devices screen until Phase 1 adds Bonjour discovery.
struct DevicesPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Macs yet",
                systemImage: "desktopcomputer",
                description: Text("Macs running Farside Host on this network will appear here.")
            )
            .navigationTitle("Macs")
        }
    }
}

#Preview {
    DevicesPlaceholderView()
}
