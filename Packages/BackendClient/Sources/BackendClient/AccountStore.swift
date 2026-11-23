import Foundation
import SecureStore

/// This device's sign-in: its token and account, in the keychain (plan section 14, account token).
public struct SignedInAccount: Codable, Sendable, Equatable {
    public var token: String
    public var accountID: String
    public var deviceID: String

    public init(token: String, accountID: String, deviceID: String) {
        self.token = token
        self.accountID = accountID
        self.deviceID = deviceID
    }
}

public struct AccountStore: Sendable {
    private let store: any SecretStore
    private static let name = "account"

    public init(store: any SecretStore) {
        self.store = store
    }

    public func load() -> SignedInAccount? {
        (try? store.data(for: Self.name)).flatMap { $0 }.flatMap { try? JSONDecoder().decode(SignedInAccount.self, from: $0) }
    }

    public func save(_ account: SignedInAccount) throws {
        try store.set(JSONEncoder().encode(account), for: Self.name)
    }

    public func clear() throws {
        try store.delete(Self.name)
    }
}
