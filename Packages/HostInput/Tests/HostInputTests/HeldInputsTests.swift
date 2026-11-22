import Testing
@testable import HostInput

@Suite struct HeldInputsTests {
    @Test func tracksDownAndUp() {
        var held = HeldInputs()
        let results = [
            held.key(0x28, down: true),
            held.key(0x28, down: true),
            held.key(0x28, down: false),
            held.key(0x28, down: false),
        ]
        #expect(results == [true, false, true, false])
        #expect(held.isEmpty)
    }

    @Test func dragButtonPrefersLeftThenRight() {
        var held = HeldInputs()
        held.button(.middle, down: true)
        #expect(held.dragButton == .middle)
        held.button(.right, down: true)
        #expect(held.dragButton == .right)
        held.button(.left, down: true)
        #expect(held.dragButton == .left)
    }

    @Test func takeAllReleasesPlainKeysBeforeModifiers() {
        var held = HeldInputs()
        held.key(0x38, down: true) // shift
        held.key(0x28, down: true) // k
        held.key(0x37, down: true) // command
        held.button(.left, down: true)
        let released = held.takeAll { [0x37, 0x38].contains($0) }
        #expect(released.keys == [0x28, 0x37, 0x38])
        #expect(released.buttons == [.left])
        #expect(held.isEmpty)
    }
}

@Suite struct TextChunkerTests {
    @Test func shortTextIsOneChunk() {
        #expect(TextChunker.chunks("hello") == ["hello"])
    }

    @Test func splitsAtLimit() {
        let text = String(repeating: "a", count: 45)
        #expect(TextChunker.chunks(text).map(\.count) == [20, 20, 5])
    }

    @Test func neverSplitsAGraphemeCluster() {
        let family = "👩‍👩‍👧" // 8 UTF-16 units
        let text = String(repeating: "a", count: 15) + family
        let chunks = TextChunker.chunks(text)
        #expect(chunks == [String(repeating: "a", count: 15), family])
        #expect(chunks.joined() == text)
    }

    @Test func oversizedClusterGoesAlone() {
        let flags = String(repeating: "🇳🇬", count: 1) + "\u{0301}\u{0301}\u{0301}"
        let chunks = TextChunker.chunks("ab" + flags, maxUTF16: 4)
        #expect(chunks.joined() == "ab" + flags)
        #expect(chunks.allSatisfy { $0.count <= 2 })
    }
}
