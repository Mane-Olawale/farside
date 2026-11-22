/// A size in pixels.
public struct PixelSize: Sendable, Equatable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var longEdge: Int { max(width, height) }
    public var description: String { "\(width)×\(height)" }
}

/// Picks the stream size for a display (plan section 8, adaptation ladder, rung 5).
public enum StreamSizing {
    /// The long edge of a 13-inch iPad Pro panel. At 3840 px an M3 Pro encodes only 45 fps,
    /// and 2752×2064 holds 60 fps with no headroom (spike S1).
    public static let maxLongEdge = 2752

    /// The display scaled down, never up, to fit inside `fit` (the client's panel, or what it
    /// asked for) and under `maxLongEdge`, keeping the display's aspect ratio. Both sides are
    /// even, as the encoder needs. A zero side in `fit` means no limit on that axis.
    public static func size(display: PixelSize, fit: PixelSize, maxLongEdge: Int = maxLongEdge) -> PixelSize {
        guard display.width > 0, display.height > 0 else { return PixelSize(width: 2, height: 2) }
        var scale = 1.0
        if fit.width > 0 { scale = min(scale, Double(fit.width) / Double(display.width)) }
        if fit.height > 0 { scale = min(scale, Double(fit.height) / Double(display.height)) }
        scale = min(scale, Double(maxLongEdge) / Double(display.longEdge))
        func even(_ value: Double) -> Int { max(2, Int(value.rounded(.down)) & ~1) }
        return PixelSize(width: even(Double(display.width) * scale), height: even(Double(display.height) * scale))
    }
}
