import AppKit
import CoreVideo
import Telemetry

/// Maps the test pattern's code cells from the screen to stream pixels.
enum CodeReader {
    /// Cell centres from Cocoa screen points to pixels of a stream of `streamSize` that captures
    /// display `displayID` with aspect preserved.
    @MainActor
    static func make(screenPoints: [CGPoint], displayID: CGDirectDisplayID, streamSize: CGSize) -> FrameCodeReader? {
        guard !screenPoints.isEmpty, let firstScreen = NSScreen.screens.first else { return nil }
        let bounds = CGDisplayBounds(displayID)
        let sx = streamSize.width / bounds.width
        let sy = streamSize.height / bounds.height
        return FrameCodeReader(cells: screenPoints.map { p in
            let quartzY = firstScreen.frame.height - p.y
            return SIMD2(Int(((p.x - bounds.minX) * sx).rounded()), Int(((quartzY - bounds.minY) * sy).rounded()))
        })
    }
}
