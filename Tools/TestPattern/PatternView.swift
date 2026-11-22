import AppKit
import QuartzCore
import Synchronization
import Telemetry

/// Timing of every recent frame counter value, for readers in the same process (the loopback
/// rig). Times are `CACurrentMediaTime` seconds.
enum PatternHistory {
    struct Entry: Sendable {
        /// The display link's target time for the frame that shows this counter.
        let targetTime: CFTimeInterval
        /// When the layers were updated for this counter, just before the transaction commits.
        let drawnTime: CFTimeInterval
    }

    private static let entries = Mutex<[UInt32: Entry]>([:])

    static func record(_ counter: UInt32, _ entry: Entry) {
        entries.withLock { map in
            map[counter] = entry
            if map.count > 1024 { map = map.filter { counter &- $0.key < 600 } }
        }
    }

    static func entry(for counter: UInt32) -> Entry? {
        entries.withLock { $0[counter] }
    }
}

/// Draws the latency pattern on every display refresh.
///
/// - A wall-clock millisecond counter, for reading off a 240 fps camera.
/// - A bar that sweeps the width once per second over a ruler of 100 ms ticks.
/// - A block-coded frame counter (`FrameCode`) that the iPad can read from decoded frames.
/// - A click target that flips between black and white on each click, for click-to-photon.
///
/// Every value is computed for the display link's target time, the moment the frame appears.
final class PatternView: NSView {
    private let root = CALayer()
    private let codeStrip = CALayer()
    private let codeCells: [CALayer] = (0..<FrameCode.cellCount).map { _ in CALayer() }
    private let clockText = CATextLayer()
    private let frameText = CATextLayer()
    private let barBand = CALayer()
    private let ticks: [CALayer] = (0...10).map { _ in CALayer() }
    private let bar = CALayer()
    private let clickTarget = CALayer()
    private let infoText = CATextLayer()

    private var displayLink: CADisplayLink?
    private var frameCounter: UInt32 = 0
    private var clickIsWhite = false
    private var dayStart = Calendar.current.startOfDay(for: Date())

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        root.isGeometryFlipped = true
        layer?.addSublayer(root)

        codeStrip.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
        root.addSublayer(codeStrip)
        codeCells.forEach(codeStrip.addSublayer)

        for text in [clockText, frameText, infoText] {
            text.font = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .medium)
            text.foregroundColor = NSColor.white.cgColor
            root.addSublayer(text)
        }
        clockText.alignmentMode = .center
        frameText.alignmentMode = .center
        infoText.alignmentMode = .left

        barBand.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        root.addSublayer(barBand)
        for (index, tick) in ticks.enumerated() {
            tick.backgroundColor = NSColor(white: index % 5 == 0 ? 0.7 : 0.4, alpha: 1).cgColor
            barBand.addSublayer(tick)
        }
        bar.backgroundColor = NSColor.white.cgColor
        barBand.addSublayer(bar)

        clickTarget.backgroundColor = NSColor.black.cgColor
        clickTarget.borderColor = NSColor(white: 0.5, alpha: 1).cgColor
        clickTarget.borderWidth = 2
        root.addSublayer(clickTarget)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let size = bounds.size
        let margin: CGFloat = 24
        root.frame = bounds

        // Block row across the top, on a grey strip so black and white cells have clear edges.
        let cell = max(12, min(40, ((size.width - margin * 2) / CGFloat(FrameCode.cellCount + 1)).rounded(.down)))
        let pad = cell / 2
        codeStrip.frame = CGRect(
            x: margin, y: margin,
            width: cell * CGFloat(FrameCode.cellCount) + pad * 2,
            height: cell + pad * 2
        )
        for (index, layer) in codeCells.enumerated() {
            layer.frame = CGRect(x: pad + CGFloat(index) * cell, y: pad, width: cell, height: cell)
        }

        let clockSize = max(32, min(size.height * 0.16, size.width * 0.1))
        clockText.fontSize = clockSize
        clockText.frame = CGRect(x: 0, y: codeStrip.frame.maxY + margin, width: size.width, height: clockSize * 1.25)

        let frameSize = clockSize * 0.4
        frameText.fontSize = frameSize
        frameText.frame = CGRect(x: 0, y: clockText.frame.maxY, width: size.width, height: frameSize * 1.3)

        let bandTop = frameText.frame.maxY + margin
        let bandHeight = max(60, size.height * 0.22)
        barBand.frame = CGRect(x: margin, y: bandTop, width: size.width - margin * 2, height: bandHeight)
        for (index, tick) in ticks.enumerated() {
            let x = barBand.bounds.width * CGFloat(index) / 10
            let tall = index % 5 == 0
            tick.frame = CGRect(x: x - 1, y: 0, width: 2, height: bandHeight * (tall ? 0.5 : 0.3))
        }
        bar.frame = CGRect(x: 0, y: 0, width: max(6, barBand.bounds.width / 200), height: bandHeight)

        let target = min(140, size.height * 0.18)
        clickTarget.frame = CGRect(x: size.width - margin - target, y: size.height - margin - target, width: target, height: target)

        infoText.fontSize = 14
        infoText.frame = CGRect(x: margin, y: size.height - margin - 18, width: size.width / 2, height: 18)
    }

    override func mouseDown(with event: NSEvent) {
        let point = root.convert(convert(event.locationInWindow, from: nil), from: layer)
        guard clickTarget.frame.contains(point) else { return }
        clickIsWhite.toggle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clickTarget.backgroundColor = (clickIsWhite ? NSColor.white : NSColor.black).cgColor
        CATransaction.commit()
    }

    @objc private func tick(_ link: CADisplayLink) {
        frameCounter &+= 1
        // Values describe the moment this frame reaches the glass, not the moment we draw it.
        let lead = link.targetTimestamp - CACurrentMediaTime()
        let shownAt = Date().addingTimeInterval(lead)
        if shownAt.timeIntervalSince(dayStart) >= 86_400 {
            dayStart = Calendar.current.startOfDay(for: shownAt)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (layer, white) in zip(codeCells, FrameCode.encode(frameCounter)) {
            layer.backgroundColor = (white ? NSColor.white : NSColor.black).cgColor
        }
        PatternHistory.record(frameCounter % FrameCode.modulus,
                              .init(targetTime: link.targetTimestamp, drawnTime: CACurrentMediaTime()))

        clockText.string = Self.clockString(shownAt.timeIntervalSince(dayStart))
        frameText.string = String(format: "frame %08u", frameCounter % FrameCode.modulus)

        let phase = link.targetTimestamp.truncatingRemainder(dividingBy: 1)
        let travel = barBand.bounds.width - bar.bounds.width
        bar.position.x = bar.bounds.width / 2 + travel * CGFloat(phase)

        let hz = Int((1 / (link.targetTimestamp - link.timestamp)).rounded())
        let pixels = window.map { bounds.size.applying(CGAffineTransform(scaleX: $0.backingScaleFactor, y: $0.backingScaleFactor)) } ?? bounds.size
        infoText.string = "\(hz) Hz   \(Int(pixels.width))×\(Int(pixels.height)) px"
    }

    /// Centre of each code cell in global screen points (Cocoa, origin at the bottom left of the
    /// first screen).
    func codeCellCentresOnScreen() -> [CGPoint] {
        guard let window, let viewLayer = layer else { return [] }
        return codeCells.map { cell in
            let rect = cell.convert(cell.bounds, to: viewLayer)
            let inView = CGPoint(x: rect.midX, y: viewLayer.isGeometryFlipped ? bounds.height - rect.midY : rect.midY)
            return window.convertPoint(toScreen: convert(inView, to: nil))
        }
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 2
        for text in [clockText, frameText, infoText] { text.contentsScale = scale }
    }

    private static func clockString(_ secondsSinceMidnight: TimeInterval) -> String {
        let totalMs = Int((secondsSinceMidnight * 1000).rounded(.down))
        let ms = totalMs % 1000
        let s = (totalMs / 1000) % 60
        let m = (totalMs / 60_000) % 60
        let h = totalMs / 3_600_000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
