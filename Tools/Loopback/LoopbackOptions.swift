import Foundation
import MediaCore

/// Command-line options. Pass them after `--args` when launching with `open`.
///
///     --codec hevc|h264     default hevc
///     --bitrate 20          Mbps, default 20
///     --long-edge 3840      cap on the stream's long edge in pixels, default 3840
///     --fps 60              encoder rate and target, default 60
///     --capture-fps 60      capture rate cap (minimumFrameInterval), default same as --fps
///     --no-preset           do not apply the encoder's conferencing preset
///     --max-qp 40|none      encoder quantizer cap, default 40
///     --duration 30         seconds to record after warm-up, then write the report and quit
///     --warmup 2            seconds ignored at the start, default 2
///     --out path.json       report path, default ~/Library/Logs/Farside/s1-<codec>-<time>.json
struct LoopbackOptions {
    var codec: VideoCodec = .hevc
    var bitrate = 20_000_000
    var longEdge = 3840
    var framesPerSecond = 60
    var captureFPS: Int?
    var usePreset = true
    var maxQP: Int? = 40
    var duration: Double?
    var warmup: Double = 2
    var out: URL?

    init(arguments: [String]) {
        var i = 1
        func value() -> String? {
            guard i + 1 < arguments.count else { return nil }
            i += 1
            return arguments[i]
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--codec": if let v = value(), let c = VideoCodec(rawValue: v) { codec = c }
            case "--bitrate": if let v = value().flatMap(Double.init) { bitrate = Int(v * 1_000_000) }
            case "--long-edge": if let v = value().flatMap(Int.init) { longEdge = v }
            case "--fps": if let v = value().flatMap(Int.init) { framesPerSecond = v }
            case "--capture-fps": captureFPS = value().flatMap(Int.init)
            case "--no-preset": usePreset = false
            case "--max-qp": maxQP = value().flatMap(Int.init)
            case "--duration": duration = value().flatMap(Double.init)
            case "--warmup": if let v = value().flatMap(Double.init) { warmup = v }
            case "--out": out = value().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            default: break
            }
            i += 1
        }
    }

    func reportURL() -> URL {
        if let out { return out }
        let logs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Farside")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return logs.appending(path: "s1-\(codec.rawValue)-\(stamp).json")
    }
}
