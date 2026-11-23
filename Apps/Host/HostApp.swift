import AppKit
import HostCapture
import Pairing
import SwiftUI

/// Menu bar app with no Dock icon (`LSUIElement`). Phase 4 adds the LaunchAgent and the rest of
/// the onboarding.
@main
@MainActor
final class HostApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let controller = HostController()
    private var permissionsWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = HostApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            // A copy opened from Finder hands over to the one launchd runs (plan section 6).
            guard await HostLaunch.shouldContinue() else { exit(0) }
            begin()
        }
    }

    private func begin() {
        DistributedNotificationCenter.default().addObserver(forName: HostLaunch.showNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPermissions() }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        controller.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()
        controller.start()
        Task {
            await controller.refreshScreenRecording()
            // The checklist opens whenever Screen Recording is not working right now, judged by
            // ScreenCaptureKit itself (spike S6), not only by the launch-time preflight.
            if controller.screenRecording != .granted || !controller.accessibility { showPermissions() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The iPad gets a Bye, so quitting ends the session cleanly there (Phase 1 exit criterion 5).
        controller.shutDown()
        return .terminateNow
    }

    private func updateIcon() {
        let symbol = controller.isInSession ? "macbook.and.ipad"
            : controller.needsAttention ? "exclamationmark.triangle" : "display"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Farside Host: \(controller.statusLine)")
    }

    // MARK: Menu, rebuilt each time it opens

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.refreshPeerToPeer()
        controller.refreshAccessibility()
        menu.removeAllItems()
        let status = NSMenuItem(title: controller.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let address = controller.connectAddress {
            let item = NSMenuItem(title: "Address: \(address)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = "Type this in Connect by Address on the iPad, for example over a VPN"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if controller.isInSession {
            menu.addItem(item("Disconnect", #selector(disconnect)))
        }
        if let backend = controller.backend, backend.status != .unavailable {
            if backend.status == .signedOut {
                menu.addItem(item("Sign In to Reach This Mac Anywhere…", #selector(signIn)))
            } else {
                let line = NSMenuItem(title: backend.status == .online ? "Reachable over the internet"
                                      : backend.status == .connecting ? "Connecting to the Farside service…"
                                      : "Farside service unreachable", action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            }
        }
        let keep = item("Keep This Mac Reachable", #selector(toggleKeepReachable))
        keep.state = controller.power.keepReachable ? .on : .off
        keep.toolTip = "Stops this Mac sleeping while idle, so your iPad can always reach it. The display may still sleep."
        menu.addItem(keep)
        if controller.power.keepReachable, let warning = controller.power.lidWarning {
            let line = NSMenuItem(title: warning, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        if let pairing = controller.pairing {
            menu.addItem(item("Pair New Device…", #selector(pairNewDevice)))
            let devices = NSMenuItem(title: "Paired Devices", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            if pairing.paired.isEmpty {
                let none = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
                none.isEnabled = false
                submenu.addItem(none)
            }
            for peer in pairing.paired {
                let row = NSMenuItem(title: peer.name, action: nil, keyEquivalent: "")
                let actions = NSMenu()
                let key = NSMenuItem(title: "Key: \(peer.key.fingerprint.display)", action: nil, keyEquivalent: "")
                key.isEnabled = false
                actions.addItem(key)
                let remove = item("Remove…", #selector(removePeer(_:)))
                remove.representedObject = peer.id.rawValue
                actions.addItem(remove)
                row.submenu = actions
                submenu.addItem(row)
            }
            devices.submenu = submenu
            menu.addItem(devices)
        }
        menu.addItem(item(controller.needsAttention ? "Permissions… (action needed)" : "Permissions…", #selector(showPermissions)))
        if controller.peerToPeer.anyOn {
            // A tip, not a fault: the stream works, just with stalls over Wi-Fi.
            menu.addItem(item("Smoother Wi-Fi: turn off \(controller.peerToPeer.names)…", #selector(showPermissions)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Farside Host", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func disconnect() {
        controller.disconnect()
    }

    @objc private func toggleKeepReachable() {
        controller.power.keepReachable.toggle()
    }

    @objc private func signIn() {
        controller.backend?.showSignIn()
    }

    @objc private func pairNewDevice() {
        controller.pairing?.open()
    }

    @objc private func removePeer(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = DeviceID(rawValue: raw),
              let peer = controller.pairing?.paired.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(peer.name)”?"
        alert.informativeText = "It will no longer be able to connect to this Mac until you pair it again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.pairing?.remove(id)
        // A session already running with it ends too.
        if controller.clientID == id { controller.disconnect() }
    }

    @objc private func showPermissions() {
        if permissionsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PermissionsView(controller: controller)))
            window.title = "Farside Host Permissions"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            permissionsWindow = window
        }
        NSApp.activate()
        permissionsWindow?.makeKeyAndOrderFront(nil)
    }
}
