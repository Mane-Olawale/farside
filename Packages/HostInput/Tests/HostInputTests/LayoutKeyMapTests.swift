#if os(macOS)
import Testing
@testable import HostInput

@Suite @MainActor struct LayoutKeyMapTests {
    /// Letters, digits and space exist on every Latin layout; their codes vary by layout.
    @Test func mapsBasicCharacters() throws {
        let map = try #require(LayoutKeyMap.current())
        for character in "abcxyz0123456789 " {
            #expect(map.stroke(for: character) != nil, "no key for \(character) on \(map.layoutName)")
        }
        #expect(map.stroke(for: "A")?.shift == true)
        #expect(map.stroke(for: "a")?.shift == false)
    }

    @Test func spaceIsKey49() throws {
        let map = try #require(LayoutKeyMap.current())
        #expect(map.stroke(for: " ")?.code == 0x31)
    }
}
#endif
