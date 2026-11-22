#if os(macOS)
import AppKit
import CryptoKit

/// Reads the system cursor's shape for the iPad to draw (plan section 10, cursor).
///
/// Each distinct shape gets an id and is sent once; after that only the id travels. A normal
/// desktop session uses a handful of shapes, so the cache stays tiny. macOS 26 has no public way
/// to tell whether the cursor is hidden (`CGCursorIsVisible` is unavailable), so visibility is
/// always reported as shown.
@MainActor
public final class CursorShapes {
    public struct Shape: Sendable, Equatable {
        public let id: UInt32
        /// At `scale` pixels per point.
        public let png: Data
        /// Points.
        public let width: Double
        public let height: Double
        /// Points from the top left.
        public let hotX: Double
        public let hotY: Double
        public let scale: Double
    }

    /// Images larger than this are drawn into the video instead (plan section 10, fallback). The
    /// envelope limit is 64 KiB; chunking larger shapes is Phase 6 work.
    public static let maxPNGBytes = 48 * 1024

    private var ids: [Data: UInt32] = [:]
    private var nextID: UInt32 = 1
    /// The last cursor seen, by object identity and hot spot, so polling an unchanged cursor
    /// costs no rasterizing.
    private var last: (image: ObjectIdentifier, hot: NSPoint, shape: Shape)?

    public init() {}

    /// The current shape, and whether this is the first time it has been seen (so its image must be
    /// sent). Nil if the system cursor cannot be read.
    public func current(scale: Double = 2) -> (shape: Shape, isNew: Bool)? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let image = cursor.image
        let identity = ObjectIdentifier(image)
        if let last, last.image == identity, last.hot == cursor.hotSpot {
            return (last.shape, false)
        }
        guard let png = Self.png(image, scale: scale) else { return nil }
        // Same pixels and hot spot are the same shape, whatever object carries them.
        var key = png
        withUnsafeBytes(of: cursor.hotSpot.x) { key.append(contentsOf: $0) }
        withUnsafeBytes(of: cursor.hotSpot.y) { key.append(contentsOf: $0) }
        let digest = Data(SHA256.hash(data: key))
        var isNew = false
        let id: UInt32
        if let existing = ids[digest] {
            id = existing
        } else {
            id = nextID
            nextID += 1
            ids[digest] = id
            isNew = true
        }
        let shape = Shape(id: id, png: png, width: image.size.width, height: image.size.height,
                          hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y, scale: scale)
        last = (identity, cursor.hotSpot, shape)
        return (shape, isNew)
    }

    /// Forgets which shapes were sent, for a new session.
    public func reset() {
        ids = [:]
        nextID = 1
        last = nil
    }

    private static func png(_ image: NSImage, scale: Double) -> Data? {
        let width = Int((image.size.width * scale).rounded()), height = Int((image.size.height * scale).rounded())
        guard width > 0, height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]), data.count <= maxPNGBytes else { return nil }
        return data
    }
}
#endif
