import Foundation
import Synchronization

/// Diagnostics: when frames pass each stage of the pipeline, to find where an uneven stream
/// starts. Each stage records the gaps between consecutive frames. On the client, `arrived`
/// also records each frame's transit, local arrival time minus its RTP timestamp; its spread is
/// how much the network and jitter buffer delay varies, with no clock sync needed.
public final class FrameTimeline: Sendable {
    public enum Stage: Int, CaseIterable, Sendable {
        /// Host: a complete frame from ScreenCaptureKit.
        case captured
        /// Host: the encoder handed a frame to WebRTC.
        case encoded
        /// Client: WebRTC handed a complete frame to our decoder.
        case arrived
        /// Client: the decoder produced pixels.
        case decoded
        /// Client: a frame went on the glass.
        case presented
    }

    public static let shared = FrameTimeline()

    private struct StageStats {
        var last: UInt64 = 0
        var frames = 0
        var maxGapMs = 0.0
        var over25 = 0
        var over50 = 0
    }

    private struct State {
        var stages = [StageStats](repeating: StageStats(), count: Stage.allCases.count)
        var firstRTP: UInt32?
        var firstArrival: UInt64 = 0
        /// Lowest transit seen this session, the baseline the spread is measured from.
        var minTransitMs = Double.infinity
        var transits: [Double] = []
    }

    private let state = Mutex(State())

    public init() {}

    public func mark(_ stage: Stage, at ticks: UInt64 = HostClock.now()) {
        state.withLock { s in
            var st = s.stages[stage.rawValue]
            if st.last != 0 {
                let gap = HostClock.milliseconds(from: st.last, to: ticks)
                st.maxGapMs = max(st.maxGapMs, gap)
                if gap > 25 { st.over25 += 1 }
                if gap > 50 { st.over50 += 1 }
            }
            st.last = ticks
            st.frames += 1
            s.stages[stage.rawValue] = st
        }
    }

    /// Client: a frame arrived with this 90 kHz RTP timestamp.
    public func arrived(rtpTimestamp: UInt32, at ticks: UInt64 = HostClock.now()) {
        mark(.arrived, at: ticks)
        state.withLock { s in
            guard let first = s.firstRTP else {
                s.firstRTP = rtpTimestamp
                s.firstArrival = ticks
                return
            }
            let mediaMs = Double(Int32(bitPattern: rtpTimestamp &- first)) / 90
            let transit = HostClock.milliseconds(from: s.firstArrival, to: ticks) - mediaMs
            s.minTransitMs = min(s.minTransitMs, transit)
            s.transits.append(transit)
        }
    }

    /// One line for the window since the last call, then a fresh window.
    public func summary() -> String {
        state.withLock { s in
            var parts: [String] = []
            for stage in Stage.allCases {
                let st = s.stages[stage.rawValue]
                guard st.frames > 0 else { continue }
                parts.append(String(format: "%@ %d (gap max %.0f, >25ms %d, >50ms %d)",
                                    "\(stage)", st.frames, st.maxGapMs, st.over25, st.over50))
                s.stages[stage.rawValue] = StageStats(last: st.last)
            }
            if !s.transits.isEmpty {
                let extra = s.transits.map { $0 - s.minTransitMs }.sorted()
                func pct(_ p: Double) -> Double { extra[min(extra.count - 1, Int(Double(extra.count) * p))] }
                parts.append(String(format: "transit over best: p50 %.0f, p90 %.0f, p99 %.0f, max %.0f ms",
                                    pct(0.5), pct(0.9), pct(0.99), extra.last!))
                s.transits.removeAll(keepingCapacity: true)
            }
            return parts.joined(separator: "; ")
        }
    }

    public func reset() {
        state.withLock { $0 = State() }
    }
}
