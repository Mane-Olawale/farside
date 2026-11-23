import AppKit
import os
import ServiceManagement

/// Starting at login, restarting after a crash, and one running copy (plan section 6, process
/// model). launchd runs the app from the LaunchAgent in its bundle; a copy opened from Finder hands
/// over to that one and exits.
@MainActor
enum HostLaunch {
    private static let log = Logger(subsystem: "app.farside.host", category: "launch")
    static let bundleID = Bundle.main.bundleIdentifier ?? "app.farside.host"
    static var label: String { "\(bundleID).agent" }
    static var service: SMAppService { .agent(plistName: "\(label).plist") }

    /// Set by the LaunchAgent's environment: this copy is the one launchd runs and restarts.
    static let isAgent = ProcessInfo.processInfo.environment["FARSIDE_AGENT"] == "1"

    /// The notification a second copy posts to ask the running one to show its window.
    static let showNotification = Notification.Name("\(bundleID).show")

    /// Exit status that asks launchd to start the app again (KeepAlive on unsuccessful exit).
    static let restartStatus: Int32 = 75

    enum LoginItem: Equatable {
        case enabled
        /// Registered, waiting for the person to allow it in System Settings, Login Items.
        case needsApproval
        case off
        case unavailable(String)
    }

    static var loginItem: LoginItem {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        case .notRegistered: .off
        // Never registered, or the plist is missing from the bundle; registering tells which.
        case .notFound: .off
        @unknown default: .unavailable("Unknown status")
        }
    }

    /// Called first at launch. Returns false when this copy has handed over and must exit.
    static func shouldContinue() async -> Bool {
        log.info("launched \(isAgent ? "by launchd" : "directly", privacy: .public); login item \(String(describing: service.status.rawValue), privacy: .public)")
        if isAgent { return true }
        // A LaunchAgent that was never registered reports not found, not not registered.
        if service.status == .notRegistered || service.status == .notFound {
            do {
                try service.register()
                log.info("registered the login item: \(String(describing: service.status.rawValue), privacy: .public)")
            } catch {
                log.error("login item not registered: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard service.status == .enabled else { return true }
        // launchd's copy is the one that stays. Start it if it is not running, then hand over.
        if otherCopy == nil { kickstart() }
        for _ in 0..<30 where otherCopy == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard otherCopy != nil else {
            log.error("launchd did not start the agent; running this copy instead")
            return true
        }
        DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
        log.info("handed over to the running copy")
        return false
    }

    /// Restarts the app, for a new Screen Recording grant. launchd does it when it runs the app;
    /// otherwise a new copy is opened first.
    static func restart(beforeExit: () -> Void) {
        beforeExit()
        if isAgent, service.status == .enabled {
            exit(restartStatus)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func setLoginItem(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            log.error("login item change failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var otherCopy: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
    }

    private static func kickstart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        try? process.run()
    }
}
