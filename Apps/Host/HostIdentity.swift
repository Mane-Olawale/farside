import Foundation
import SessionTransport
import WireProtocol

/// Who this Mac says it is, in Bonjour and in HelloAck.
enum HostIdentity {
    /// Stable for this install. Phase 3 replaces it with the Secure Enclave key's identifier.
    static let deviceID: String = {
        let key = "farside.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    static var name: String { Host.current().localizedName ?? "Mac" }

    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func deviceInfo() -> DeviceInfo {
        DeviceInfo(name: name, model: model, osVersion: osVersion, appVersion: appVersion, capabilities: .with {
            $0.codecs = [.hevc, .h264]
            $0.maxFrameRate = 60
        })
    }
}
