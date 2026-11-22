// Arguments: width height hevc|h264 [submit fps, default 60] [ll|normal, default ll]
import CoreVideo
import Foundation
import HostCapture
import MediaCore
import Synchronization

// Encodes complete synthetic 4:2:0 frames at 60 fps and times submit to output.
let args = CommandLine.arguments
let width = Int(args[1])!, height = Int(args[2])!
let codec = VideoCodec(rawValue: args[3])!
let pace = args.count > 4 ? Double(args[4])! : 60
let lowLatency = args.count > 5 ? args[5] == "ll" : true
let encoder = try VideoEncoder(settings: EncoderSettings(codec: codec, width: width, height: height, bitrate: 20_000_000, lowLatencyRateControl: lowLatency))
let firstOut = Atomic<UInt64>(0), lastOut = Atomic<UInt64>(0), outs = Atomic<Int>(0)
var pool: CVPixelBufferPool?
CVPixelBufferPoolCreate(nil, nil, [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pool)
let samples = Mutex<[Double]>([])
let frames = 400
var ring: [CVPixelBuffer] = []
for i in 0..<8 {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    for row in 0..<height { memset(y + row * stride, Int32((row + i * 7) % 220 + 16), width) }
    let x = (i * 97) % (width - 64)
    for row in 0..<height { memset(y + row * stride + x, 235, 64) }
    let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
    memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * height / 2)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    ring.append(buffer)
}
let start = HostClock.now()
for i in 0..<frames {
    let buffer = ring[i % ring.count]
    let due = start + HostClock.ticks(seconds: Double(i) / pace)
    while HostClock.now() < due { Thread.sleep(forTimeInterval: 0.0005) }
    let now = HostClock.now()
    let frame = CapturedFrame(pixels: PixelBufferBox(buffer), number: UInt64(i), displayTicks: now, arrivalTicks: now)
    encoder.encode(frame, forceKeyFrame: i == 0) { out in
        guard let out, i >= 30 else { return }
        if i == 30 { firstOut.store(out.outputTicks, ordering: .relaxed) }
        lastOut.store(out.outputTicks, ordering: .relaxed); outs.add(1, ordering: .relaxed)
        samples.withLock { $0.append(HostClock.milliseconds(from: out.submitTicks, to: out.outputTicks)) }
    }
}
Thread.sleep(forTimeInterval: 0.2)
let s = samples.withLock { $0.sorted() }
func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
let span = HostClock.seconds(lastOut.load(ordering: .relaxed)) - HostClock.seconds(firstOut.load(ordering: .relaxed))
print(String(format: "%@ %dx%d %@ submit@%.0f  latency p50 %.2f p95 %.2f p99 %.2f max %.2f ms  output %.1f fps",
             codec.rawValue, width, height, lowLatency ? "LL" : "normal", pace, q(0.5), q(0.95), q(0.99), s.last!,
             Double(outs.load(ordering: .relaxed) - 1) / span))
