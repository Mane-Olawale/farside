import Testing
@testable import HostCapture

@Suite struct StreamSizingTests {
    let panel13 = PixelSize(width: 2752, height: 2064)

    /// The S3 case: a 3440×1440 ultrawide on a 13-inch iPad Pro streams at 2752×1152.
    @Test func ultrawideFitsThePanelWidth() {
        #expect(StreamSizing.size(display: PixelSize(width: 3440, height: 1440), fit: panel13) == PixelSize(width: 2752, height: 1152))
    }

    @Test func retinaLaptopFitsThePanelHeight() {
        // 3456×2234 into 2752×2064: width limits first (0.796), height then fits at 1778.
        let size = StreamSizing.size(display: PixelSize(width: 3456, height: 2234), fit: panel13)
        #expect(size == PixelSize(width: 2752, height: 1778))
    }

    @Test func neverScalesUp() {
        #expect(StreamSizing.size(display: PixelSize(width: 1920, height: 1080), fit: panel13) == PixelSize(width: 1920, height: 1080))
    }

    @Test func longEdgeIsCappedWithNoClientLimit() {
        let size = StreamSizing.size(display: PixelSize(width: 3840, height: 2160), fit: PixelSize(width: 0, height: 0))
        #expect(size.longEdge <= StreamSizing.maxLongEdge)
        #expect(size == PixelSize(width: 2752, height: 1548))
    }

    @Test func portraitClientFit() {
        // An iPad held upright: the landscape display is limited by the panel's narrow width.
        let size = StreamSizing.size(display: PixelSize(width: 3440, height: 1440), fit: PixelSize(width: 2064, height: 2752))
        #expect(size == PixelSize(width: 2064, height: 864))
    }

    @Test(arguments: [(1001, 667), (3025, 1965), (5120, 2880), (2, 2)])
    func sidesAreEvenAndAspectIsKept(width: Int, height: Int) {
        let display = PixelSize(width: width, height: height)
        let size = StreamSizing.size(display: display, fit: panel13)
        #expect(size.width % 2 == 0 && size.height % 2 == 0)
        #expect(size.width <= max(display.width, 2) && size.height <= max(display.height, 2))
        let aspect = Double(width) / Double(height)
        #expect(abs(Double(size.width) / Double(size.height) - aspect) < 0.01 * aspect + 2.0 / Double(size.height))
    }

    @Test func degenerateDisplay() {
        #expect(StreamSizing.size(display: PixelSize(width: 0, height: 0), fit: panel13) == PixelSize(width: 2, height: 2))
    }
}

#if os(macOS)
@Suite struct DisplaysTests {
    /// Runs on whatever displays this Mac has. A CI runner has at least a virtual one.
    @Test func listIsConsistent() {
        let displays = Displays.current()
        #expect(displays.filter(\.isMain).count <= 1)
        if let first = displays.first, displays.contains(where: \.isMain) { #expect(first.isMain, "main display first") }
        for display in displays {
            #expect(display.pixels.width > 0 && display.pixels.height > 0)
            #expect(display.bounds.width > 0 && display.bounds.height > 0)
            #expect(display.scale >= 1)
            #expect(display.refreshRate > 0)
            #expect(!display.name.isEmpty)
        }
    }
}
#endif
