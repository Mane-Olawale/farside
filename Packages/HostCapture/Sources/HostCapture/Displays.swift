#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

/// One Mac display, as the host describes it to the client (plan section 10, displays).
public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public let id: CGDirectDisplayID
    public var name: String
    /// The current mode's backing pixels.
    public var pixels: PixelSize
    /// Bounds in the global coordinate space, in points. CGEvent uses the same space, so input
    /// mapping needs only these (plan section 9, coordinate mapping).
    public var bounds: CGRect
    public var scale: Double
    public var isMain: Bool
    public var isBuiltIn: Bool
    public var refreshRate: Double

    public init(id: CGDirectDisplayID, name: String, pixels: PixelSize, bounds: CGRect, scale: Double,
                isMain: Bool, isBuiltIn: Bool, refreshRate: Double) {
        self.id = id
        self.name = name
        self.pixels = pixels
        self.bounds = bounds
        self.scale = scale
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
        self.refreshRate = refreshRate
    }
}

/// The active displays, from Core Graphics. Unlike ScreenCaptureKit's list, this needs no Screen
/// Recording grant, so the host can describe its displays even before capture is allowed.
public enum Displays {
    public static func current() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let names = screenNames()
        let rates = screenRates()
        return ids.prefix(Int(count)).compactMap { id in
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            let bounds = CGDisplayBounds(id)
            let pixels = PixelSize(width: mode.pixelWidth, height: mode.pixelHeight)
            let scale = bounds.width > 0 ? Double(mode.pixelWidth) / bounds.width : 1
            // Built-in panels with variable refresh report 0 here; NSScreen knows the maximum.
            let rate = mode.refreshRate > 0 ? mode.refreshRate : (rates[id] ?? 60)
            return DisplayInfo(id: id, name: names[id] ?? "Display \(id)", pixels: pixels, bounds: bounds, scale: scale,
                               isMain: CGDisplayIsMain(id) != 0, isBuiltIn: CGDisplayIsBuiltin(id) != 0, refreshRate: rate)
        }
        .sorted { lhs, rhs in lhs.isMain != rhs.isMain ? lhs.isMain : lhs.bounds.minX < rhs.bounds.minX }
    }

    public static func main() -> DisplayInfo? { current().first(where: \.isMain) ?? current().first }

    private static func screens() -> [(CGDirectDisplayID, NSScreen)] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[key] as? NSNumber).map { (CGDirectDisplayID($0.uint32Value), screen) }
        }
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        Dictionary(screens().map { ($0.0, $0.1.localizedName) }, uniquingKeysWith: { a, _ in a })
    }

    private static func screenRates() -> [CGDirectDisplayID: Double] {
        Dictionary(screens().map { ($0.0, Double($0.1.maximumFramesPerSecond)) }, uniquingKeysWith: { a, _ in a })
    }
}

/// Calls back on the main queue whenever the display configuration changes, coalesced (plan
/// section 10: the list is resent on every change). Keep the object alive to keep observing.
public final class DisplayObserver: @unchecked Sendable {
    private let onChange: @Sendable ([DisplayInfo]) -> Void
    private var pending = false
    private var registered = false

    public init(onChange: @escaping @Sendable ([DisplayInfo]) -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        registered = CGDisplayRegisterReconfigurationCallback(Self.callback, context) == .success
    }

    deinit {
        if registered {
            CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private static let callback: CGDisplayReconfigurationCallBack = { _, flags, context in
        // Each change arrives once with beginConfiguration and again when done; act on the second.
        guard let context, !flags.contains(.beginConfigurationFlag) else { return }
        Unmanaged<DisplayObserver>.fromOpaque(context).takeUnretainedValue().schedule()
    }

    private func schedule() {
        DispatchQueue.main.async { [self] in
            guard !pending else { return }
            pending = true
            // One callback per display per change; wait for the burst to finish.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                pending = false
                onChange(Displays.current())
            }
        }
    }
}
#endif
