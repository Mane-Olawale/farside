import AppKit
import QuartzCore

/// An NSView backed by a CAMetalLayer that reports its drawable size in pixels.
final class MetalView: NSView {
    let metalLayer = CAMetalLayer()
    var onDrawableSize: ((CGSize) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override func layout() {
        super.layout()
        reportSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportSize()
    }

    private func reportSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        onDrawableSize?(CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }
}
