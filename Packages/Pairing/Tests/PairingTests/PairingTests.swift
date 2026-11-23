import CryptoKit
import Foundation
import SecureStore
import Testing
@testable import Pairing

func identity(_ name: String) throws -> LocalIdentity {
    try LocalIdentity.loadOrCreate(in: MemorySecretStore(), name: name, allowEnclave: false)
}

struct IdentityTests {
    @Test func deviceIDsAreWellFormedAndDistinct() {
        let a = DeviceID.generate(), b = DeviceID.generate()
        #expect(a != b)
        #expect(a.rawValue.count == 30)
        #expect(DeviceID(rawValue: a.rawValue) == a)
        #expect(DeviceID(rawValue: "dev_short") == nil)
        #expect(DeviceID(rawValue: "dev_" + String(repeating: "U", count: 26)) == nil)  // U is not Crockford
        #expect(DeviceID(rawValue: "usr_" + a.rawValue.dropFirst(4)) == nil)
    }

    @Test func base32MatchesAKnownValue() {
        #expect(DeviceID.base32([0xFF]) == "ZW")
        #expect(DeviceID.base32([0, 0, 0, 0, 0]) == "00000000")
    }

    @Test func identityIsStable() throws {
        let store = MemorySecretStore()
        let first = try LocalIdentity.loadOrCreate(in: store, name: "Mac", allowEnclave: false)
        let again = try LocalIdentity.loadOrCreate(in: store, name: "Mac", allowEnclave: false)
        #expect(first.id == again.id)
        #expect(first.publicKey == again.publicKey)
        try LocalIdentity.reset(in: store)
        let fresh = try LocalIdentity.loadOrCreate(in: store, name: "Mac", allowEnclave: false)
        #expect(fresh.id != first.id)
        #expect(fresh.publicKey != first.publicKey)
    }

    @Test func publicKeyRoundTripsThroughJSON() throws {
        let key = try identity("a").publicKey
        let decoded = try JSONDecoder().decode(PublicKey.self, from: JSONEncoder().encode(key))
        #expect(decoded == key)
        #expect(key.fingerprint.hex.count == 64)
        #expect(key.fingerprint.display.split(separator: " ").count == 8)
    }
}

/// Plan section 14, security work items: every signature failure has a test.
struct SignatureTests {
    let body = Data("offer with a=fingerprint:sha-256 AA:BB".utf8)

    @Test func goodSignatureVerifies() throws {
        let me = try identity("iPad")
        let signature = try me.sign(body, as: .signal)
        #expect(me.publicKey.verify(signature, for: body, as: .signal))
    }

    @Test func wrongKeyFails() throws {
        let me = try identity("iPad"), other = try identity("other")
        let signature = try me.sign(body, as: .signal)
        #expect(!other.publicKey.verify(signature, for: body, as: .signal))
    }

    @Test func alteredBodyFails() throws {
        let me = try identity("iPad")
        let signature = try me.sign(body, as: .signal)
        var tampered = body
        tampered[tampered.count - 1] ^= 1
        #expect(!me.publicKey.verify(signature, for: tampered, as: .signal))
    }

    @Test func signatureFromAnotherDomainFails() throws {
        let me = try identity("iPad")
        let signature = try me.sign(body, as: .hello)
        #expect(!me.publicKey.verify(signature, for: body, as: .signal))
    }

    @Test func garbageSignatureFails() throws {
        let me = try identity("iPad")
        #expect(!me.publicKey.verify(Data(repeating: 0, count: 64), for: body, as: .signal))
        #expect(!me.publicKey.verify(Data([1, 2, 3]), for: body, as: .signal))
    }
}

struct FreshnessTests {
    @Test func freshIncreasingEnvelopesPass() throws {
        var guardian = FreshnessGuard()
        try guardian.check(sender: "a", session: "s", seq: 1, ts: 1000, now: 1000)
        try guardian.check(sender: "a", session: "s", seq: 2, ts: 1001, now: 1001)
        // Another sender, or another session, has its own sequence.
        try guardian.check(sender: "b", session: "s", seq: 1, ts: 1001, now: 1001)
        try guardian.check(sender: "a", session: "t", seq: 1, ts: 1001, now: 1001)
    }

    @Test func staleTimestampFails() {
        var guardian = FreshnessGuard()
        #expect(throws: FreshnessGuard.Rejection.stale) { try guardian.check(sender: "a", session: "s", seq: 1, ts: 939, now: 1000) }
        #expect(throws: FreshnessGuard.Rejection.future) { try guardian.check(sender: "a", session: "s", seq: 1, ts: 1061, now: 1000) }
    }

    @Test func reusedSequenceFails() throws {
        var guardian = FreshnessGuard()
        try guardian.check(sender: "a", session: "s", seq: 5, ts: 1000, now: 1000)
        #expect(throws: FreshnessGuard.Rejection.replayed) { try guardian.check(sender: "a", session: "s", seq: 5, ts: 1000, now: 1000) }
        #expect(throws: FreshnessGuard.Rejection.replayed) { try guardian.check(sender: "a", session: "s", seq: 4, ts: 1000, now: 1000) }
    }

    @Test func nonceIsSingleUse() {
        var guardian = NonceGuard(lifetime: 600)
        let nonce = NonceGuard.make()
        let first = guardian.use(nonce, now: 0)
        let again = guardian.use(nonce, now: 10)
        let other = guardian.use(NonceGuard.make(), now: 10)
        #expect(first && !again && other)
    }
}

struct HelloTests {
    func transcript(nonce: Data = Data([1, 2])) -> HelloTranscript {
        HelloTranscript(session: "s1", client: DeviceID(rawValue: "dev_" + String(repeating: "A", count: 26))!,
                        host: DeviceID(rawValue: "dev_" + String(repeating: "B", count: 26))!,
                        clientCertificate: "sha-256 aa", hostCertificate: "sha-256 bb", clientNonce: nonce)
    }

    @Test func helloSignatureBindsTheConnection() throws {
        let ipad = try identity("iPad")
        let signature = try ipad.sign(transcript().helloBody, as: .hello)
        #expect(ipad.publicKey.verify(signature, for: transcript().helloBody, as: .hello))
        var otherCert = transcript()
        otherCert.hostCertificate = "sha-256 cc"
        #expect(!ipad.publicKey.verify(signature, for: otherCert.helloBody, as: .hello))
        #expect(!ipad.publicKey.verify(signature, for: transcript(nonce: Data([9])).helloBody, as: .hello))
        var otherSession = transcript()
        otherSession.session = "s2"
        #expect(!ipad.publicKey.verify(signature, for: otherSession.helloBody, as: .hello))
    }

    @Test func helloAckCoversTheHostNonce() throws {
        let mac = try identity("Mac")
        let signature = try mac.sign(transcript().helloAckBody(hostNonce: Data([7])), as: .helloAck)
        #expect(mac.publicKey.verify(signature, for: transcript().helloAckBody(hostNonce: Data([7])), as: .helloAck))
        #expect(!mac.publicKey.verify(signature, for: transcript().helloAckBody(hostNonce: Data([8])), as: .helloAck))
        #expect(!mac.publicKey.verify(signature, for: transcript().helloBody, as: .hello))
    }

    @Test func fieldsCannotSlideBetweenEachOther() {
        var a = transcript(), b = transcript()
        a.clientCertificate = "sha-256 a"; a.hostCertificate = "ab"
        b.clientCertificate = "sha-256 aa"; b.hostCertificate = "b"
        #expect(a.helloBody != b.helloBody)
    }

    @Test func fingerprintIsReadFromTheSDP() {
        let sdp = "v=0\r\na=group:BUNDLE 0\r\na=fingerprint:sha-256 AB:CD:EF\r\na=setup:actpass\r\n"
        #expect(SDPFingerprint.value(in: sdp) == "sha-256 ab:cd:ef")
        #expect(SDPFingerprint.value(in: "v=0\r\n") == nil)
    }
}

struct PairingFlowTests {
    @Test func inviteRoundTripsThroughItsURL() throws {
        let mac = try identity("Mac")
        let invite = PairingInvite(host: mac, now: 1000)
        let parsed = try PairingInvite.parse(invite.url.absoluteString, now: 1000)
        #expect(parsed == invite)
        #expect(invite.exp == 1120)
        #expect(throws: PairingInvite.ParseError.expired) { try PairingInvite.parse(invite.url.absoluteString, now: 1120) }
        #expect(throws: PairingInvite.ParseError.notAnInvite) { try PairingInvite.parse("https://example.com/pair", now: 1000) }
        #expect(throws: PairingInvite.ParseError.notAnInvite) { try PairingInvite.parse("farside://pair#AAAA", now: 1000) }
    }

    @Test func validRequestIsAcceptedOnce() throws {
        let mac = try identity("Mac"), ipad = try identity("iPad")
        var window = PairingWindow(invite: PairingInvite(host: mac, now: 1000))
        let request = PairingRequest(client: ipad, platform: "iPadOS", invite: window.invite)
        let peer = try window.accept(request, now: 1010)
        #expect(peer.id == ipad.id)
        #expect(peer.key == ipad.publicKey)
        #expect(peer.pairedAt == 1010)
        #expect(throws: PairingWindow.Failure.closed) { try window.accept(request, now: 1011) }
    }

    @Test func requestForAnotherInviteFails() throws {
        let mac = try identity("Mac"), ipad = try identity("iPad")
        var window = PairingWindow(invite: PairingInvite(host: mac, now: 1000))
        let other = PairingInvite(host: mac, now: 1000)
        #expect(throws: PairingWindow.Failure.badProof) {
            try window.accept(PairingRequest(client: ipad, platform: "iPadOS", invite: other), now: 1010)
        }
    }

    @Test func swappedKeyFailsTheProof() throws {
        let mac = try identity("Mac"), ipad = try identity("iPad"), attacker = try identity("x")
        var window = PairingWindow(invite: PairingInvite(host: mac, now: 1000))
        var request = PairingRequest(client: ipad, platform: "iPadOS", invite: window.invite)
        request.key = attacker.publicKey
        #expect(throws: PairingWindow.Failure.badProof) { try window.accept(request, now: 1010) }
    }

    @Test func repeatedBadProofsCloseTheWindow() throws {
        let mac = try identity("Mac"), ipad = try identity("iPad")
        var window = PairingWindow(invite: PairingInvite(host: mac, now: 1000))
        var bad = PairingRequest(client: ipad, platform: "iPadOS", invite: window.invite)
        bad.proof = Data(repeating: 0, count: 32)
        for _ in 0..<PairingWindow.maxBadProofs {
            #expect(throws: PairingWindow.Failure.badProof) { try window.accept(bad, now: 1010) }
        }
        #expect(!window.isOpen)
        let good = PairingRequest(client: ipad, platform: "iPadOS", invite: window.invite)
        #expect(throws: PairingWindow.Failure.closed) { try window.accept(good, now: 1010) }
    }

    @Test func expiredWindowRefuses() throws {
        let mac = try identity("Mac"), ipad = try identity("iPad")
        var window = PairingWindow(invite: PairingInvite(host: mac, now: 1000))
        let request = PairingRequest(client: ipad, platform: "iPadOS", invite: window.invite)
        #expect(throws: PairingWindow.Failure.expired) { try window.accept(request, now: 1120) }
    }

    @Test func codeDependsOnBothKeysAndTheSecret() throws {
        let mac = try identity("Mac"), ipad = try identity("iPad"), other = try identity("x")
        let invite = PairingInvite(host: mac, now: 1000)
        let code = PairingRequest.code(invite: invite, client: ipad.publicKey)
        #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        #expect(code == PairingRequest.code(invite: invite, client: ipad.publicKey))
        #expect(code != PairingRequest.code(invite: invite, client: other.publicKey))
        #expect(code != PairingRequest.code(invite: PairingInvite(host: mac, now: 1000), client: ipad.publicKey))
    }
}

struct PeerStoreTests {
    @Test func pinsAndRemoves() throws {
        let store = PeerStore(store: MemorySecretStore())
        let ipad = try identity("iPad")
        let peer = PairedPeer(id: ipad.id, name: "iPad", platform: "iPadOS", key: ipad.publicKey, pairedAt: 5)
        #expect(try store.key(for: ipad.id) == nil)
        try store.pin(peer)
        #expect(try store.key(for: ipad.id) == ipad.publicKey)
        #expect(try store.all() == [peer])
        try store.remove(ipad.id)
        #expect(try store.all().isEmpty)
    }
}
