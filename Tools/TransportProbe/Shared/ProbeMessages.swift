import Foundation
import SessionTransport
import Telemetry

/// Control channel messages between the S3 host and viewer. JSON, spike only; the product uses
/// the protobuf envelope (plan section 11).
enum ProbeMessage: Codable {
    /// Host to viewer: where the pattern's code cells sit in the stream.
    case cells(FrameCodeReader)
    /// Viewer to host: a frame with this counter was decoded or reached the viewer's glass.
    case echo(counter: UInt32, stage: EchoStage)
    /// Viewer to host, once a second.
    case viewerStats(ViewerStats)
    /// Viewer to host: an audio marker's onset reached the playout buffer.
    case audioOnset
    /// Viewer to host: the marker's peak level as played, 0 to 1. Sent once the burst ends.
    case audioPeak(Float)

    enum EchoStage: String, Codable { case decoded, presented }

    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ data: Data) -> ProbeMessage? { try? JSONDecoder().decode(ProbeMessage.self, from: data) }
}

struct ViewerStats: Codable {
    var transport: TransportStats
    var framesRendered: Int
    var framesPresented: Int
    var codeUnreadable: Int
    var device: String
    var os: String
    var displayHz: Int
    var audioOutputLatency: Double?
    var audioIOBufferDuration: Double?
}

/// Finds a marker burst: a sample above `threshold` after at least `quietFrames` of quiet, then
/// tracks the burst's peak over the next `peakFrames`.
struct OnsetDetector {
    var threshold: Float = 0.2
    var quietFrames = 9_600
    var peakFrames = 1_440
    private var quiet = 0
    private var peakRemaining = 0
    private var peak: Float = 0

    enum Event { case onset, peak(Float) }

    /// Feeds one sample, already scaled to -1...1.
    mutating func feed(_ sample: Float) -> Event? {
        let level = abs(sample)
        if peakRemaining > 0 {
            peak = max(peak, level)
            peakRemaining -= 1
            if peakRemaining == 0 { return .peak(peak) }
        }
        if level > threshold {
            let fired = quiet >= quietFrames
            quiet = 0
            if fired {
                peak = level
                peakRemaining = peakFrames
                return .onset
            }
        } else {
            quiet += 1
        }
        return nil
    }
}
