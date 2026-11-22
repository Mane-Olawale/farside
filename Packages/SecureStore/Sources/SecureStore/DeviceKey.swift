import CryptoKit
import Foundation
import Security

/// This device's identity key (plan section 14): P-256, created in the Secure Enclave where there
/// is one, so the private key never leaves the chip. Only an opaque handle is stored.
public protocol SigningKey: Sendable {
    var publicKey: P256.Signing.PublicKey { get }
    /// ECDSA with SHA-256 over `data`, as the 64-byte raw `r || s`.
    func signature(for data: Data) throws -> Data
}

/// A key held in software. Used in tests, and on devices with no Secure Enclave (the simulator).
public struct SoftwareSigningKey: SigningKey {
    private let key: P256.Signing.PrivateKey

    public init(_ key: P256.Signing.PrivateKey = .init()) {
        self.key = key
    }

    public var publicKey: P256.Signing.PublicKey { key.publicKey }
    public func signature(for data: Data) throws -> Data { try key.signature(for: data).rawRepresentation }
    var rawRepresentation: Data { key.rawRepresentation }
}

/// A key in the Secure Enclave. Usable after first unlock, so the Mac can sign while locked.
public struct EnclaveSigningKey: SigningKey {
    private let key: SecureEnclave.P256.Signing.PrivateKey

    init(_ key: SecureEnclave.P256.Signing.PrivateKey) {
        self.key = key
    }

    public var publicKey: P256.Signing.PublicKey { key.publicKey }
    public func signature(for data: Data) throws -> Data { try key.signature(for: data).rawRepresentation }
    var dataRepresentation: Data { key.dataRepresentation }
}

public enum DeviceKey {
    static let name = "device-key"

    public enum Kind: UInt8, Sendable {
        case enclave = 1
        case software = 2
    }

    /// The stored key, or a new one. The Secure Enclave is used whenever it is available.
    public static func loadOrCreate(in store: any SecretStore, allowEnclave: Bool = true) throws -> any SigningKey {
        if let stored = try store.data(for: name), let key = try? decode(stored) { return key }
        let (key, blob): (any SigningKey, Data)
        if allowEnclave, SecureEnclave.isAvailable {
            let enclave = try EnclaveSigningKey(SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl()))
            (key, blob) = (enclave, Data([Kind.enclave.rawValue]) + enclave.dataRepresentation)
        } else {
            let software = SoftwareSigningKey()
            (key, blob) = (software, Data([Kind.software.rawValue]) + software.rawRepresentation)
        }
        try store.set(blob, for: name)
        return key
    }

    /// Removes the key, so the next load makes a new identity. Pinned peers must pair again.
    public static func reset(in store: any SecretStore) throws {
        try store.delete(name)
    }

    static func decode(_ blob: Data) throws -> any SigningKey {
        guard let first = blob.first, let kind = Kind(rawValue: first) else { throw CryptoKitError.incorrectParameterSize }
        let body = blob.dropFirst()
        switch kind {
        case .enclave: return EnclaveSigningKey(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body))
        case .software: return SoftwareSigningKey(try P256.Signing.PrivateKey(rawRepresentation: body))
        }
    }

    private static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                            .privateKeyUsage, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return control
    }
}
