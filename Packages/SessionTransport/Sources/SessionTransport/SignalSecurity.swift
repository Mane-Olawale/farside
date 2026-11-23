import Foundation
import Pairing

/// Whose signatures a device accepts.
public enum PeerTrust: Sendable {
    /// Pinned keys only (plan section 14). The apps always use this.
    case pinned(@Sendable (DeviceID) -> PublicKey?)
    /// Any signer. For the spike rigs in Tools, which have no pairing; never in the apps.
    case anySignerForSpikeRigs
}

/// This device's identity and the peers it trusts, for signing and checking signaling.
public struct SessionCredentials: Sendable {
    public let identity: LocalIdentity
    public let trust: PeerTrust

    public init(identity: LocalIdentity, trust: PeerTrust) {
        self.identity = identity
        self.trust = trust
    }

    /// The pinned key for a peer. Nil when not paired, and always nil for the spike rigs, so a
    /// session handshake can never pass without a pin.
    public func pinnedKey(for id: DeviceID) -> PublicKey? {
        if case .pinned(let lookup) = trust { return lookup(id) }
        return nil
    }
}

/// Checks the envelopes arriving on one signaling connection (plan section 11): addressed to
/// this device, from the expected sender, signed by that sender's pinned key, and fresh.
public struct EnvelopeVerifier: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case wrongRecipient
        case badSender
        /// Correctly formed, from a device this one has not paired with.
        case notPaired
        case badSignature
        case unfresh(FreshnessGuard.Rejection)
    }

    private let credentials: SessionCredentials
    private var freshness = FreshnessGuard()

    public init(credentials: SessionCredentials) {
        self.credentials = credentials
    }

    /// Checks an envelope from a paired device. `expected` is the peer when already known.
    public mutating func check(_ envelope: SignalEnvelope, expected: DeviceID?, now: Int64) throws(Failure) -> DeviceID {
        guard envelope.to == credentials.identity.id.rawValue else { throw .wrongRecipient }
        guard let sender = DeviceID(rawValue: envelope.from) else { throw .badSender }
        if let expected, sender != expected { throw .badSender }
        switch credentials.trust {
        case .pinned(let lookup):
            guard let key = lookup(sender) else { throw .notPaired }
            guard envelope.isSigned(by: key) else { throw .badSignature }
        case .anySignerForSpikeRigs:
            guard envelope.sig != nil else { throw .badSignature }
        }
        try fresh(envelope, sender: sender, now: now)
        return sender
    }

    /// Checks a `pair` envelope, which no pin can cover yet: it must be signed by the key the
    /// request carries, from the device the request names. The pairing window then checks the
    /// request's proof.
    public mutating func checkPairing(_ envelope: SignalEnvelope, now: Int64) throws(Failure) -> PairingRequest {
        guard envelope.to == credentials.identity.id.rawValue else { throw .wrongRecipient }
        guard envelope.type == .pair, let request = envelope.body.pairing, envelope.from == request.id.rawValue else {
            throw .badSender
        }
        guard envelope.isSigned(by: request.key) else { throw .badSignature }
        try fresh(envelope, sender: request.id, now: now)
        return request
    }

    /// Checks the Mac's answer to a pairing request, signed by the key from its QR code.
    public mutating func checkPairingReply(_ envelope: SignalEnvelope, invite: PairingInvite, now: Int64) throws(Failure) {
        guard envelope.to == credentials.identity.id.rawValue else { throw .wrongRecipient }
        guard envelope.from == invite.id.rawValue else { throw .badSender }
        guard envelope.isSigned(by: invite.key) else { throw .badSignature }
        try fresh(envelope, sender: invite.id, now: now)
    }

    private mutating func fresh(_ envelope: SignalEnvelope, sender: DeviceID, now: Int64) throws(Failure) {
        do {
            try freshness.check(sender: sender.rawValue, session: envelope.session, seq: envelope.seq, ts: envelope.ts, now: now)
        } catch {
            throw .unfresh(error)
        }
    }
}

/// Five failed handshakes from one source within a minute, and that source is ignored for ten
/// minutes (plan section 14, authorization on the Mac).
public struct FailureLimiter: Sendable {
    public var limit = 5
    public var window: Int64 = 60
    public var penalty: Int64 = 600
    private var failures: [String: [Int64]] = [:]
    private var blockedUntil: [String: Int64] = [:]

    public init() {}

    public func isBlocked(_ source: String, now: Int64) -> Bool {
        (blockedUntil[source] ?? 0) > now
    }

    public mutating func failed(_ source: String, now: Int64) {
        var recent = (failures[source] ?? []).filter { now - $0 < window }
        recent.append(now)
        if recent.count >= limit {
            blockedUntil[source] = now + penalty
            recent = []
        }
        failures[source] = recent
        blockedUntil = blockedUntil.filter { $0.value > now }
    }
}
