import ClientVideo
import Foundation
import HostCapture
import MediaCore
import Synchronization
import Telemetry

enum Stage: String, CaseIterable, Codable {
    /// ScreenCaptureKit's displayTime to the sample buffer reaching us. Negative when the frame
    /// arrives before its display time.
    case capture
    /// Waiting for the encoder while it finished the previous frame.
    case gate
    case encode
    /// Length-prefixed to Annex B with parameter sets.
    case package
    /// Encoder thread to decode queue. Stands in for the network.
    case handoff
    case decode
    /// Decoded to on the glass, including the wait for a drawable and the next refresh.
    case render
    /// Decoded to `nextDrawable` returning.
    case drawableWait
    /// Command buffer committed to on the glass: the window server's compositing delay for a
    /// windowed layer.
    case presentDelay
    /// ScreenCaptureKit's displayTime (the frame's time on the Mac's glass) to compressed bits
    /// ready to send. The host's share of the budget: capture 4 ms plus encode 5 ms target,
    /// 27 ms ceiling (plan section 2).
    case glassToEncoded
    /// The Mac's glass to a decoded frame, with no network.
    case glassToDecoded
    /// The Mac's glass to the same frame on the preview's glass. Both are on one display, and
    /// the preview pays window compositing that a full-screen iPad view does not.
    case glassToGlass
    /// The pattern's layer update to its display link target time.
    case patternDrawnToTarget
    /// The pattern's layer update to ScreenCaptureKit's displayTime for the frame that shows it.
    case patternDrawnToDisplayTime
    /// ScreenCaptureKit's displayTime minus the pattern's display link target time.
    case displayTimeMinusTarget

}

enum Counter: String, CaseIterable, Codable {
    case encoded, decoded, presented, keyFrames, bytes, encodeFailures, decodeFailures, keyFrameRequests
    /// Decoded frames whose code row did not decode, or decoded to a counter no longer in history.
    case codeUnreadable, codeUnknown
}

/// One window of measurements: a second for the live readout, or the whole recorded run.
struct StatsWindow: Sendable {
    var stages: [Stage: SampleSet] = [:]
    var counters: [Counter: Int] = [:]

    mutating func merge(_ other: StatsWindow) {
        for (stage, set) in other.stages { stages[stage, default: SampleSet()].add(contentsOf: set) }
        for (counter, value) in other.counters { counters[counter, default: 0] += value }
    }

    func median(_ stage: Stage) -> Double? { stages[stage]?.summary?.median }
    func p95(_ stage: Stage) -> Double? { stages[stage]?.summary?.p95 }
}

final class LoopbackStats: Sendable {
    private let window = Mutex(StatsWindow())

    func count(_ counter: Counter, by amount: Int = 1) {
        window.withLock { $0.counters[counter, default: 0] += amount }
    }

    func encoded(bytes: Int, keyFrame: Bool) {
        window.withLock { w in
            w.counters[.encoded, default: 0] += 1
            w.counters[.bytes, default: 0] += bytes
            if keyFrame { w.counters[.keyFrames, default: 0] += 1 }
        }
    }

    func presented(_ t: FrameTiming, _ render: RenderTimes) {
        let presented = HostClock.ticks(seconds: render.presentedSeconds)
        let ms = HostClock.milliseconds
        let values: [(Stage, Double)] = [
            (.capture, ms(t.displayTicks, t.arrivalTicks)),
            (.gate, ms(t.arrivalTicks, t.encodeSubmitTicks)),
            (.encode, ms(t.encodeSubmitTicks, t.encodeOutputTicks)),
            (.package, ms(t.encodeOutputTicks, t.packagedTicks)),
            (.handoff, ms(t.packagedTicks, t.decodeSubmitTicks)),
            (.decode, ms(t.decodeSubmitTicks, t.decodeOutputTicks)),
            (.render, ms(t.decodeOutputTicks, presented)),
            (.drawableWait, ms(t.decodeOutputTicks, render.acquiredTicks)),
            (.presentDelay, ms(render.committedTicks, presented)),
            (.glassToEncoded, ms(t.displayTicks, t.encodeOutputTicks)),
            (.glassToDecoded, ms(t.displayTicks, t.decodeOutputTicks)),
            (.glassToGlass, ms(t.displayTicks, presented)),
        ] + (t.pattern.map { p -> [(Stage, Double)] in
            let target = HostClock.ticks(seconds: p.targetTime)
            let drawn = HostClock.ticks(seconds: p.drawnTime)
            return [
                (.patternDrawnToTarget, ms(drawn, target)),
                (.patternDrawnToDisplayTime, ms(drawn, t.displayTicks)),
                (.displayTimeMinusTarget, ms(target, t.displayTicks)),
            ]
        } ?? [])
        window.withLock { w in
            w.counters[.presented, default: 0] += 1
            for (stage, value) in values { w.stages[stage, default: SampleSet()].add(value) }
        }
    }

    /// Returns the current window and starts a new one.
    func roll() -> StatsWindow {
        window.withLock { w in
            defer { w = StatsWindow() }
            return w
        }
    }
}

/// Process CPU time as a share of all cores, between calls.
struct CPUMeter {
    private var lastCPU = CPUMeter.cpuSeconds()
    private var lastWall = Date()

    mutating func percentOfTotal() -> Double {
        let cpu = Self.cpuSeconds()
        let wall = Date()
        defer { lastCPU = cpu; lastWall = wall }
        let elapsed = wall.timeIntervalSince(lastWall)
        guard elapsed > 0 else { return 0 }
        return (cpu - lastCPU) / elapsed / Double(ProcessInfo.processInfo.activeProcessorCount) * 100
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}

/// Written as JSON at the end of a timed run.
struct S1Report: Codable {
    struct Machine: Codable {
        var model: String
        var chip: String
        var macOS: String
        var cores: Int
    }
    struct Display: Codable {
        var pixelWidth: Int
        var pixelHeight: Int
        var refreshHz: Double
    }
    struct Settings: Codable {
        var codec: VideoCodec
        var width: Int
        var height: Int
        var bitrateMbps: Double
        var framesPerSecond: Int
        var captureFPS: Int
        var maxFrameQP: Int?
        var conferencingPreset: Bool
    }
    struct PerSecond: Codable {
        var capturedFPS: SampleSummary?
        var idleFPS: SampleSummary?
        var presentedFPS: SampleSummary?
        var bitrateMbps: SampleSummary?
        var cpuPercentOfTotal: SampleSummary?
    }
    struct Totals: Codable {
        var captured: Int
        var idle: Int
        var gateReplaced: Int
        var renderReplaced: Int
        var counters: [String: Int]
    }
    struct ExitCriteria: Codable {
        var sixtyFPS: Bool
        /// The plan's wording: encoder submit to output. Fails at panel-size streams.
        var encodeP95AtMost10ms: Bool
        /// Mac glass to encoded bits, which is what the latency budget needs.
        var glassToEncodedP95AtMost10ms: Bool
        var decodeP95AtMost8ms: Bool
        /// sixtyFPS, glassToEncoded and decode.
        var pass: Bool
    }

    var date: Date
    var error: String?
    var machine: Machine
    var display: Display?
    var settings: Settings?
    var encoder: EncoderReport?
    var decoderHardwareAccelerated: Bool?
    var recordedSeconds: Double
    var stagesMs: [String: SampleSummary]
    var perSecond: PerSecond
    var totals: Totals?
    var exitCriteria: ExitCriteria?
}

enum MachineInfo {
    static func current() -> S1Report.Machine {
        S1Report.Machine(
            model: sysctl("hw.model"),
            chip: sysctl("machdep.cpu.brand_string"),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            cores: ProcessInfo.processInfo.activeProcessorCount
        )
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }
}
