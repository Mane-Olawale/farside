import CryptoKit
import Foundation
import Testing
@testable import SecureStore

struct SecretStoreTests {
    @Test func memoryStoreRoundTrips() throws {
        let store = MemorySecretStore()
        try store.set(Data([1, 2]), for: "peer.a")
        try store.set(Data([3]), for: "peer.b")
        try store.set(Data([4]), for: "token")
        #expect(try store.data(for: "peer.a") == Data([1, 2]))
        #expect(try store.names(prefix: "peer.") == ["peer.a", "peer.b"])
        try store.delete("peer.a")
        #expect(try store.data(for: "peer.a") == nil)
        try store.delete("missing")
    }
}

struct DeviceKeyTests {
    @Test func softwareKeyIsStoredAndReloaded() throws {
        let store = MemorySecretStore()
        let first = try DeviceKey.loadOrCreate(in: store, allowEnclave: false)
        let again = try DeviceKey.loadOrCreate(in: store, allowEnclave: false)
        #expect(first.publicKey.rawRepresentation == again.publicKey.rawRepresentation)
        #expect(try store.data(for: DeviceKey.name)?.first == DeviceKey.Kind.software.rawValue)
    }

    @Test func signaturesVerifyWithThePublicKey() throws {
        let key = try DeviceKey.loadOrCreate(in: MemorySecretStore(), allowEnclave: false)
        let message = Data("hello".utf8)
        let raw = try key.signature(for: message)
        #expect(raw.count == 64)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        #expect(key.publicKey.isValidSignature(signature, for: message))
        #expect(!key.publicKey.isValidSignature(signature, for: Data("hellp".utf8)))
    }

    @Test func resetMakesANewKey() throws {
        let store = MemorySecretStore()
        let first = try DeviceKey.loadOrCreate(in: store, allowEnclave: false)
        try DeviceKey.reset(in: store)
        let second = try DeviceKey.loadOrCreate(in: store, allowEnclave: false)
        #expect(first.publicKey.rawRepresentation != second.publicKey.rawRepresentation)
    }

    @Test func garbageBlobIsReplaced() throws {
        let store = MemorySecretStore()
        try store.set(Data([9, 9, 9]), for: DeviceKey.name)
        _ = try DeviceKey.loadOrCreate(in: store, allowEnclave: false)
        #expect(try store.data(for: DeviceKey.name)?.first == DeviceKey.Kind.software.rawValue)
    }

    /// The Secure Enclave on this Mac, when the test runner may use it.
    @Test(.enabled(if: SecureEnclave.isAvailable)) func enclaveKeyReloads() throws {
        let store = MemorySecretStore()
        let first = try DeviceKey.loadOrCreate(in: store)
        #expect(try store.data(for: DeviceKey.name)?.first == DeviceKey.Kind.enclave.rawValue)
        let again = try DeviceKey.loadOrCreate(in: store)
        #expect(first.publicKey.rawRepresentation == again.publicKey.rawRepresentation)
        let raw = try again.signature(for: Data("x".utf8))
        #expect(first.publicKey.isValidSignature(try .init(rawRepresentation: raw), for: Data("x".utf8)))
    }
}
