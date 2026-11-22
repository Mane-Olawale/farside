import CoreVideo

/// Reads `FrameCode` out of a 4:2:0 frame's luma plane (plan section 17, embedded counter).
public struct FrameCodeReader: Sendable, Codable {
    /// Cell centres in stream pixels.
    public let cells: [SIMD2<Int>]

    public init(cells: [SIMD2<Int>]) { self.cells = cells }

    /// The counter, or nil if the row does not decode (guards or parity wrong, or out of frame).
    public func read(_ pixels: CVPixelBuffer) -> UInt32? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixels) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        var bits: [Bool] = []
        bits.reserveCapacity(cells.count)
        for c in cells {
            guard c.x >= 1, c.y >= 1, c.x < width - 1, c.y < height - 1 else { return nil }
            var sum = 0
            for dy in -1...1 { for dx in -1...1 { sum += Int(luma[(c.y + dy) * stride + c.x + dx]) } }
            bits.append(sum / 9 > 126)
        }
        return FrameCode.decode(bits)
    }
}
