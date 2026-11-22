import CoreVideo
import Foundation
import MediaCore
import Metal
import QuartzCore
import Synchronization

/// Presents decoded frames paced by the display (plan section 8, renderer).
///
/// A `CAMetalDisplayLink` on a dedicated render thread asks for up to 120 Hz. At each refresh it
/// hands over a drawable; the presenter draws the newest frame that arrived since the last
/// refresh, or the last frame again if only the scene (viewport or cursor) changed, or nothing
/// if neither did. The cursor therefore moves at display rate even when video is at 0 fps. It never waits for a drawable: when none is free the display
/// link skips that refresh, and the newest frame is drawn at the next one. Frames that arrive
/// faster than the display refreshes replace each other, so at most one ever waits.
public final class VideoPresenter: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    public struct Counters: Sendable, Equatable {
        /// Frames handed to the GPU with a present.
        public var presented = 0
        /// Frames replaced by a newer one before a refresh came.
        public var replaced = 0
        /// Refreshes with no new frame to draw.
        public var idleRefreshes = 0
        /// Refreshes that drew the previous frame again for a new viewport or cursor position.
        public var redrawn = 0
        /// Refreshes the display link skipped, inferred from gaps between target times.
        public var skippedRefreshes = 0
        public init() {}
    }

    private struct Pending: Sendable {
        let pixels: PixelBufferBox
        let tag: UInt32
        let arrivedTicks: UInt64
        let presented: (@Sendable (UInt32, RenderTimes) -> Void)?
    }

    private let renderer: MetalRenderer
    private let preferredRate: Float
    private let pending = Mutex<Pending?>(nil)
    /// The frame on screen, kept to redraw when only the scene changes.
    private let last = Mutex<PixelBufferBox?>(nil)
    private let scene = Mutex<(value: RenderScene, dirty: Bool)>((RenderScene(), false))
    private let counters = Mutex(Counters())
    /// The previous refresh's target time, and the shortest gap seen so far, which is the
    /// display's real refresh interval (60 or 120 Hz, whatever was asked for).
    private let timing = Mutex<(last: CFTimeInterval, interval: CFTimeInterval)>((0, .infinity))
    private var link: CAMetalDisplayLink?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    /// Call on the main thread, where the layer was created.
    public init?(layer: CAMetalLayer, preferredFramesPerSecond: Int = 120) {
        guard let renderer = MetalRenderer(layer: layer) else { return nil }
        self.renderer = renderer
        self.preferredRate = Float(preferredFramesPerSecond)
        super.init()
    }

    /// Call on the main thread when the hosting view resizes. Size is in pixels.
    public func setDrawableSize(_ size: CGSize) {
        renderer.setDrawableSize(size)
    }

    /// Where the video and cursor go from the next refresh on. Any thread; cheap when unchanged.
    public func setScene(_ new: RenderScene) {
        scene.withLock { s in
            guard s.value != new else { return }
            s.value = new
            s.dirty = true
        }
    }

    /// Uploads a cursor image for `CursorPlacement`s with this id. Any thread.
    @discardableResult
    public func setCursorImage(id: UInt32, image: CGImage) -> Bool {
        renderer.setCursorImage(id: id, image: image)
    }

    public func hasCursorImage(id: UInt32) -> Bool { renderer.hasCursorImage(id: id) }

    /// Starts the display link on a new render thread. Does nothing if already running.
    public func start() {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let layer = renderer.layer
        let rate = preferredRate
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
            // Present as soon as the GPU is done: one frame of latency, not two.
            link.preferredFrameLatency = 1
            link.delegate = self
            link.add(to: .current, forMode: .default)
            self.link = link
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            // Runs until stop() invalidates the link and stops the loop.
            CFRunLoopRun()
        }
        thread.name = "farside.render"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
    }

    /// Stops the display link and lets the render thread finish.
    public func stop() {
        guard let runLoop, let link else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            link.invalidate()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        self.link = nil
        self.runLoop = nil
        thread = nil
        pending.withLock { $0 = nil }
        last.withLock { $0 = nil }
    }

    /// Offers a decoded frame from any thread. It is drawn at the next refresh unless a newer
    /// frame arrives first. `presented` runs once the frame is on the display, with its tag.
    public func enqueue(_ pixels: PixelBufferBox, tag: UInt32 = 0, presented: (@Sendable (UInt32, RenderTimes) -> Void)? = nil) {
        let item = Pending(pixels: pixels, tag: tag, arrivedTicks: HostClock.now(), presented: presented)
        let replaced = pending.withLock { slot -> Bool in
            defer { slot = item }
            return slot != nil
        }
        if replaced { counters.withLock { $0.replaced += 1 } }
    }

    /// Counters since the last call.
    public func takeCounters() -> Counters {
        counters.withLock { c in
            defer { c = Counters() }
            return c
        }
    }

    // MARK: CAMetalDisplayLinkDelegate

    public func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let target = update.targetPresentationTimestamp
        let missed = timing.withLock { t -> Int in
            defer { t.last = target }
            guard t.last > 0, target > t.last else { return 0 }
            let gap = target - t.last
            t.interval = min(t.interval, gap)
            return Int((gap / t.interval).rounded()) - 1
        }
        if missed > 0 { counters.withLock { $0.skippedRefreshes += missed } }

        let item = pending.withLock { slot -> Pending? in
            defer { slot = nil }
            return slot
        }
        let (current, dirty) = scene.withLock { s -> (RenderScene, Bool) in
            defer { s.dirty = false }
            return (s.value, s.dirty)
        }
        if let item {
            let tag = item.tag
            let callback = item.presented
            let drawn = renderer.encode(item.pixels.buffer, scene: current, into: update.drawable, acquiredTicks: HostClock.now()) { times in
                callback?(tag, times)
            }
            last.withLock { $0 = item.pixels }
            if drawn {
                counters.withLock { $0.presented += 1 }
                FrameTimeline.shared.mark(.presented, at: HostClock.ticks(seconds: target))
            }
        } else if dirty, let previous = last.withLock({ $0 }) {
            // Only the viewport or the cursor moved: draw the same frame again.
            if renderer.encode(previous.buffer, scene: current, into: update.drawable, acquiredTicks: HostClock.now(), presented: { _ in }) {
                counters.withLock { $0.redrawn += 1 }
            }
        } else {
            counters.withLock { $0.idleRefreshes += 1 }
        }
    }
}
