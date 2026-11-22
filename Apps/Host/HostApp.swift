import AppKit
import HostCapture
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        controller.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()
        controller.start()
        if !ScreenRecordingAccess.atLaunch { showPermissions() }
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
        menu.removeAllItems()
        let status = NSMenuItem(title: controller.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        if controller.isInSession {
            menu.addItem(item("Disconnect", #selector(disconnect)))
        }
        menu.addItem(item(controller.needsAttention ? "Permissions… (action needed)" : "Permissions…", #selector(showPermissions)))
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
