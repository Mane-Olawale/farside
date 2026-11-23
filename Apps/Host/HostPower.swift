import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import os

/// Staying reachable (plan section 6): keep the system awake while idle if asked, end the session
/// cleanly before sleep, come back on wake, and say when closing the lid would put the Mac to
/// sleep. Main actor only.
@MainActor
final class HostPower {
    private let log = Logger(subsystem: "app.farside.host", category: "power")
    private var assertion: IOPMAssertionID = 0
    private var observers: [NSObjectProtocol] = []

    /// Keep this Mac reachable: no idle system sleep. The display may still sleep. On by default,
    /// since reaching the Mac is the point.
    var keepReachable: Bool {
        get { UserDefaults.standard.object(forKey: "keepReachable") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "keepReachable")
            apply()
        }
    }

    /// Called just before the Mac sleeps, and just after it wakes.
    func start(willSleep: @escaping @MainActor () -> Void, didWake: @escaping @MainActor () -> Void) {
        apply()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [log] _ in
            log.info("going to sleep")
            MainActor.assumeIsolated { willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [log] _ in
            log.info("woke")
            MainActor.assumeIsolated { didWake() }
        })
    }

    private func apply() {
        if keepReachable, assertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Farside: keep this Mac reachable" as CFString, &assertion)
            if result != kIOReturnSuccess {
                log.error("could not hold the reachability assertion: \(result)")
                assertion = 0
            }
        } else if !keepReachable, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    // MARK: Lid

    /// Why closing the lid would make this Mac unreachable, or nil when it would not. A laptop
    /// stays awake with the lid closed only on power with an external display; public API cannot
    /// change that, so the app says so (plan section 6).
    var lidWarning: String? {
        guard Self.hasBattery else { return nil }
        let external = NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
        switch (Self.onPower, external) {
        case (true, true): return nil
        case (false, _): return "Closing the lid will put this Mac to sleep: it's on battery."
        case (true, false): return "Closing the lid will put this Mac to sleep unless an external display is connected."
        }
    }

    private static var hasBattery: Bool {
        sources.contains { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
    }

    private static var onPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        return (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
    }

    private static var sources: [[String: Any]] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
    }
}
