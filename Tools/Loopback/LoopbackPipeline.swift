import ClientVideo
import Foundation
import HostCapture
import MediaCore
import Synchronization
import Telemetry

/// Per-frame host-clock timestamps, carried with the frame from capture to present.
struct FrameTiming: Sendable {
    let number: UInt64
    let displayTicks: UInt64
    let arrivalTicks: UInt64
    let encodeSubmitTicks: UInt64
    let encodeOutputTicks: UInt64
    let packagedTicks: UInt64
    let decodeSubmitTicks: UInt64
    let decodeOutputTicks: UInt64
    /// The pattern's own timing for the frame in this capture, read from the embedded counter.
    /// Nil if the code row did not decode.
    let pattern: PatternHistory.Entry?
}

struct RenderItem: Sendable {
    let pixels: PixelBufferBox
    let timing: FrameTiming
}

final class Flag: Sendable {
    private let value: Atomic<Bool>
    init(_ initial: Bool) { value = Atomic(initial) }
    func set() { value.store(true, ordering: .relaxed) }
    func take() -> Bool { value.exchange(false, ordering: .relaxed) }
}

/// capture → gate → encode → Annex B → decode → gate → render, all in one process.
/// The hop from the encoder thread to the decode queue stands in for the network.
final class LoopbackPipeline: Sendable {
    let encoder: VideoEncoder
    let decoder: VideoDecoder
    let renderer: MetalRenderer
    let stats: LoopbackStats
    let encodeSlot = LatestSlot<CapturedFrame>()
    let renderSlot = LatestSlot<RenderItem>()
    private let keyFrameWanted = Flag(true)
    private let decodeQueue = DispatchQueue(label: "farside.decode", qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "farside.render", qos: .userInteractive)

    let codeReader: FrameCodeReader?

    init(encoder: VideoEncoder, renderer: MetalRenderer, stats: LoopbackStats, codeReader: FrameCodeReader?) {
        self.encoder = encoder
        self.codeReader = codeReader
        self.renderer = renderer
        self.stats = stats
        let wanted = keyFrameWanted
        decoder = VideoDecoder { event in
            switch event {
            case .needsKeyFrame:
                wanted.set()
                stats.count(.keyFrameRequests)
            case .decodeFailed:
                wanted.set()
                stats.count(.decodeFailures)
            }
        }
    }

    /// Called on the capture queue.
    func captured(_ frame: CapturedFrame) {
        if let start = encodeSlot.offer(frame) { encode(start) }
    }

    private func encode(_ frame: CapturedFrame) {
        let signpost = Signposts.pipeline
        let interval = signpost.beginInterval("Encode", id: signpost.makeSignpostID())
        let forceKey = keyFrameWanted.take()
        encoder.encode(frame, forceKeyFrame: forceKey) { [self] output in
            signpost.endInterval("Encode", interval)
            if let next = encodeSlot.finish() { encode(next) }
            guard let output else {
                stats.count(.encodeFailures)
                return
            }
            stats.encoded(bytes: output.frame.data.count, keyFrame: output.frame.isKeyFrame)
            decodeQueue.async { self.decode(output) }
        }
    }

    private func decode(_ encoded: EncodedOutput) {
        let signpost = Signposts.pipeline
        let interval = signpost.beginInterval("Decode", id: signpost.makeSignpostID())
        decoder.decode(encoded.frame) { [self] decoded in
            signpost.endInterval("Decode", interval)
            var pattern: PatternHistory.Entry?
            if let counter = codeReader?.read(decoded.pixels.buffer) {
                pattern = PatternHistory.entry(for: counter)
                if pattern == nil {
                    stats.count(.codeUnknown)
                }
            } else {
                stats.count(.codeUnreadable)
            }
            let timing = FrameTiming(
                number: encoded.frame.number,
                displayTicks: encoded.source.displayTicks,
                arrivalTicks: encoded.source.arrivalTicks,
                encodeSubmitTicks: encoded.submitTicks,
                encodeOutputTicks: encoded.outputTicks,
                packagedTicks: encoded.packagedTicks,
                decodeSubmitTicks: decoded.submitTicks,
                decodeOutputTicks: decoded.outputTicks,
                pattern: pattern
            )
            if let first = renderSlot.offer(RenderItem(pixels: decoded.pixels, timing: timing)) {
                renderQueue.async { self.render(first) }
            }
        }
    }

    /// Runs on the render queue until no frame is waiting.
    private func render(_ first: RenderItem) {
        var item = first
        while true {
            let timing = item.timing
            let signpost = Signposts.pipeline
            let interval = signpost.beginInterval("Render", id: signpost.makeSignpostID())
            let stats = self.stats
            renderer.draw(item.pixels.buffer) { times in
                signpost.endInterval("Render", interval)
                stats.presented(timing, times)
            }
            guard let next = renderSlot.finish() else { return }
            item = next
        }
    }
}
