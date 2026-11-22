import Foundation

/// macOS features that keep AWDL, Apple's peer-to-peer Wi-Fi, busy. While it is busy the Mac's
/// Wi-Fi radio leaves the network's channel several times a second, and the stream to the iPad
/// stalls for about 100 ms each time (measured in Phase 1: four stalls a second with AirDrop
/// and Universal Control on, none with both off). Farside cannot turn AWDL off without a
/// privileged helper, so the host only tells the user.
///
/// AWDL's own interface status is no use here: `awdl0` reported active before and after the
/// change. The settings below are what made the difference. Both are undocumented preference
/// keys; a key that is not set means the feature has its system default, which is on.
struct PeerToPeerWiFi: Equatable {
    var airDrop: Bool
    var universalControl: Bool

    var anyOn: Bool { airDrop || universalControl }

    /// The features that are on, for display: "AirDrop and Universal Control".
    var names: String {
        [airDrop ? "AirDrop" : nil, universalControl ? "Universal Control" : nil]
            .compactMap { $0 }
            .joined(separator: " and ")
    }

    static let off = PeerToPeerWiFi(airDrop: false, universalControl: false)

    /// The current settings. Reads straight from the preference files, so changes made in
    /// System Settings or Control Centre show up at once.
    static func current() -> PeerToPeerWiFi {
        let sharing = "com.apple.sharingd" as CFString
        CFPreferencesAppSynchronize(sharing)
        // "Off", "Contacts Only" or "Everyone". Unset means the system default, Contacts Only.
        let mode = CFPreferencesCopyAppValue("DiscoverableMode" as CFString, sharing) as? String
        let airDrop = mode.map { $0 != "Off" } ?? true

        let control = "com.apple.universalcontrol" as CFString
        CFPreferencesSynchronize(control, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        let disabled = CFPreferencesCopyValue("Disable" as CFString, control, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        // Unset means on, the system default. Only an explicit Disable turns it off.
        let universalControl = !((disabled as? Bool) ?? (disabled as? Int).map { $0 != 0 } ?? false)

        return PeerToPeerWiFi(airDrop: airDrop, universalControl: universalControl)
    }
}
