import Foundation
import Security
import Synchronization

/// Small secrets by name: the device key's blob, pinned peers, the account token (plan section
/// 14, secrets and where they live). The keychain in the apps, memory in tests.
public protocol SecretStore: Sendable {
    func data(for name: String) throws -> Data?
    func set(_ data: Data, for name: String) throws
    func delete(_ name: String) throws
    /// Every stored name that starts with `prefix`.
    func names(prefix: String) throws -> [String]
}

public enum SecretStoreError: Error, Equatable {
    case status(OSStatus)
}

/// The data protection keychain, this device only, readable after first unlock so the Mac can
/// sign while its screen is locked. Never synchronized. Ported from Porthole's
/// `KeychainSecureStore`.
public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func data(for name: String) throws -> Data? {
        var query = base(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SecretStoreError.status(status) }
        return data
    }

    public func set(_ data: Data, for name: String) throws {
        let update = SecItemUpdate(base(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.status(update) }
        var query = base(name)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.status(status) }
    }

    public func delete(_ name: String) throws {
        let status = SecItemDelete(base(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.status(status) }
    }

    public func names(prefix: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SecretStoreError.status(status) }
        let rows = item as? [[String: Any]] ?? []
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func base(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// For tests and previews.
public final class MemorySecretStore: SecretStore {
    private let items = Mutex<[String: Data]>([:])

    public init() {}

    public func data(for name: String) throws -> Data? { items.withLock { $0[name] } }
    public func set(_ data: Data, for name: String) throws { items.withLock { $0[name] = data } }
    public func delete(_ name: String) throws { _ = items.withLock { $0.removeValue(forKey: name) } }
    public func names(prefix: String) throws -> [String] {
        items.withLock { $0.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    }
}
