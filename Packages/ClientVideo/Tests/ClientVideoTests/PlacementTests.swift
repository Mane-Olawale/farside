import CoreGraphics
import Testing
@testable import ClientVideo

@Suite struct PlacementTests {
    @Test func fitLetterboxes() {
        // A 2752 x 1152 stream on a 2752 x 2064 iPad panel: full width, bars above and below.
        let rect = MetalRenderer.fit(CGSize(width: 2752, height: 1152), in: CGSize(width: 2752, height: 2064))
        #expect(rect == CGRect(x: 0, y: 456, width: 2752, height: 1152))
    }

    @Test func fitPillarboxes() {
        let rect = MetalRenderer.fit(CGSize(width: 1000, height: 1000), in: CGSize(width: 2000, height: 1000))
        #expect(rect == CGRect(x: 500, y: 0, width: 1000, height: 1000))
    }

    /// Top-left pixel rects become left, top, right, bottom in device coordinates, y up.
    @Test func ndcFlipsY() {
        let target = CGSize(width: 200, height: 100)
        #expect(MetalRenderer.ndc(CGRect(x: 0, y: 0, width: 200, height: 100), in: target) == SIMD4(-1, 1, 1, -1))
        #expect(MetalRenderer.ndc(CGRect(x: 100, y: 50, width: 50, height: 25), in: target) == SIMD4(0, 0, 0.5, -0.5))
    }

    /// A zoomed frame larger than the drawable goes past the edges, and the GPU clips it.
    @Test func zoomedFrameExtendsPastTheEdges() {
        let quad = MetalRenderer.ndc(CGRect(x: -100, y: -50, width: 400, height: 200), in: CGSize(width: 200, height: 100))
        #expect(quad == SIMD4(-2, 2, 2, -2))
    }

    @Test func scenesCompareByValue() {
        let a = RenderScene(videoRect: CGRect(x: 0, y: 0, width: 10, height: 10), cursor: CursorPlacement(id: 1, rect: .zero))
        var b = a
        #expect(a == b)
        b.cursor?.rect.origin.x = 1
        #expect(a != b)
    }
}
