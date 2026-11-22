import CoreGraphics
import Foundation
import HostCapture
import MediaCore
import os
import SessionTransport
import WireProtocol

/// The host session's delegate: describes the displays, decides the stream, and runs capture
/// into the transport. Called on the session's queue; capture starts and stops on tasks.
final class HostMedia: HostSessionDelegate, @unchecked Sendable {
    enum Problem: Sendable {
        /// ScreenCaptureKit refused with -3801: the grant is missing or was revoked (spike S6).
        case screenRecordingDenied
        case captureFailed(String)
    }

    private let log = Logger(subsystem: "app.farside.host", category: "capture")
    private let lock = NSLock()
    private var transport: SessionTransport?
    private var capture: DisplayCapture?
    /// Bumped on every start and stop, so a start that finishes after a stop is undone.
    private var generation = 0

    private let onState: @Sendable (SessionState, DeviceInfo?) -> Void
    private let onProblem: @Sendable (Problem) -> Void

    init(onState: @escaping @Sendable (SessionState, DeviceInfo?) -> Void, onProblem: @escaping @Sendable (Problem) -> Void) {
        self.onState = onState
        self.onProblem = onProblem
    }

    func use(_ transport: SessionTransport?) {
        lock.withLock { self.transport = transport }
    }

    // MARK: HostSessionDelegate

    func hostSessionDisplays() -> [Farside_V1_Display] {
        Displays.current().map(Self.wire)
    }

    func hostSessionApply(_ request: Farside_V1_StreamConfig, client: DeviceInfo) -> Farside_V1_StreamConfigApplied? {
        let displays = Displays.current()
        guard let display = displays.first(where: { $0.id == request.displayID }) ?? displays.first(where: \.isMain) ?? displays.first
        else { return nil }
        // Fit what the iPad asked for, or else its panel.
        let fit = request.width > 0 && request.height > 0
            ? PixelSize(width: Int(request.width), height: Int(request.height))
            : PixelSize(width: Int(client.capabilities.maxWidth), height: Int(client.capabilities.maxHeight))
        let size = StreamSizing.size(display: display.pixels, fit: fit)
        let rate = min(Int(request.frameRate == 0 ? 60 : request.frameRate), 60)
        log.info("stream \(display.id) at \(size.description, privacy: .public), \(rate) fps for \(client.model, privacy: .public)")
        return .with {
            $0.displayID = display.id
            $0.width = UInt32(size.width)
            $0.height = UInt32(size.height)
            $0.frameRate = UInt32(rate)
            // The transport negotiates the codec; HEVC is first on both sides. Phase 5 reports
            // the negotiated one and adds the H.264 fallback.
            $0.codec = .hevc
            $0.quality = request.quality == .unspecified ? .balanced : request.quality
            $0.contentRect = .with { $0.width = Float(size.width); $0.height = Float(size.height) }
            $0.scale = Float(Double(size.width) / display.bounds.width)
        }
    }

    func hostSessionStartMedia(_ applied: Farside_V1_StreamConfigApplied) {
        let (capture, started) = lock.withLock { () -> (DisplayCapture, Int) in
            self.generation += 1
            let transport = self.transport
            let onProblem = self.onProblem
            let capture = DisplayCapture(
                onFrame: { frame in
                    transport?.push(frame.pixels, timestampNs: Int64(HostClock.seconds(frame.displayTicks) * 1_000_000_000))
                },
                onStop: { error in
                    guard let error else { return }
                    onProblem(CaptureError.isPermissionDenied(error) ? .screenRecordingDenied : .captureFailed("\(error)"))
                })
            self.capture = capture
            return (capture, self.generation)
        }
        let settings = CaptureSettings(width: Int(applied.width), height: Int(applied.height), framesPerSecond: Int(applied.frameRate))
        let displayID = CGDirectDisplayID(applied.displayID)
        Task { [self] in
            do {
                try await capture.start(displayID: displayID, settings: settings)
                log.info("capture started")
                // Stopped while starting: undo.
                if lock.withLock({ self.generation != started }) { await capture.stop() }
            } catch {
                log.error("capture failed: \(String(describing: error), privacy: .public)")
                onProblem(CaptureError.isPermissionDenied(error) ? .screenRecordingDenied : .captureFailed("\(error)"))
            }
        }
    }

    func hostSessionStopMedia() {
        let capture = lock.withLock { () -> DisplayCapture? in
            generation += 1
            defer { self.capture = nil }
            return self.capture
        }
        guard let capture else { return }
        Task { [log] in
            await capture.stop()
            log.info("capture stopped")
        }
    }

    func hostSessionStateChanged(_ state: SessionState, client: DeviceInfo?) {
        onState(state, client)
    }

    // MARK: Wire form

    static func wire(_ d: DisplayInfo) -> Farside_V1_Display {
        .with {
            $0.id = d.id
            $0.name = d.name
            $0.pixelWidth = UInt32(d.pixels.width)
            $0.pixelHeight = UInt32(d.pixels.height)
            $0.pointWidth = d.bounds.width
            $0.pointHeight = d.bounds.height
            $0.scale = d.scale
            $0.originX = d.bounds.minX
            $0.originY = d.bounds.minY
            $0.main = d.isMain
            $0.builtIn = d.isBuiltIn
            $0.refreshRate = d.refreshRate
        }
    }
}
