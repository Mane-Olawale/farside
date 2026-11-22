// macOS only. Display enumeration, capture stream, hardware encoder, cursor tracker, system audio.
#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import MediaCore
import ScreenCaptureKit
import Synchronization

public struct CaptureSettings: Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var queueDepth: Int
    public var capturesAudio: Bool
    /// The plan keeps the host's own sounds out. Test rigs that play markers turn this off.
    public var excludesCurrentProcessAudio: Bool
    /// Draw the cursor into the video. Off, because the iPad draws its own (plan section 10); on
    /// only as the fallback when the cursor's shape cannot be read.
    public var showsCursor: Bool

    public init(width: Int, height: Int, framesPerSecond: Int = 60, queueDepth: Int = 3,
                capturesAudio: Bool = false, excludesCurrentProcessAudio: Bool = true, showsCursor: Bool = false) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.queueDepth = queueDepth
        self.capturesAudio = capturesAudio
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.showsCursor = showsCursor
    }
}

/// System audio from the capture stream: 32-bit float planes, left and right (nil if mono),
/// the frame count, and the host time of the first sample. The pointers are valid only during
/// the call.
public typealias CapturedAudioHandler = @Sendable (UnsafePointer<Float>, UnsafePointer<Float>?, Int, UInt64) -> Void

/// A complete captured frame, ready for the encoder.
public struct CapturedFrame: Sendable {
    public let pixels: PixelBufferBox
    public let number: UInt64
    /// When the content was on the display, from `SCStreamFrameInfo.displayTime`.
    public let displayTicks: UInt64
    /// When the sample buffer reached our handler.
    public let arrivalTicks: UInt64

    public init(pixels: PixelBufferBox, number: UInt64, displayTicks: UInt64, arrivalTicks: UInt64) {
        self.pixels = pixels
        self.number = number
        self.displayTicks = displayTicks
        self.arrivalTicks = arrivalTicks
    }
}

public enum CaptureError: Error {
    case displayNotFound(CGDirectDisplayID)

    /// ScreenCaptureKit's "user declined" error, −3801. Spike S6: while the app runs, this is the
    /// only signal that the Screen Recording grant is missing or was revoked.
    public static func isPermissionDenied(_ error: Error) -> Bool {
        if let sc = error as? SCStreamError, sc.code == .userDeclined { return true }
        let ns = error as NSError
        return ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue
    }
}

/// Screen Recording status (plan section 6, permissions; spike S6).
public enum ScreenRecordingAccess {
    /// What `CGPreflightScreenCaptureAccess` said when this process started. The call keeps
    /// returning that value for the life of the process, so it counts only at launch.
    public static let atLaunch: Bool = CGPreflightScreenCaptureAccess()

    /// The live answer: whether ScreenCaptureKit will hand over a display list right now.
    /// Nil when it failed for some other reason.
    public static func live() async -> Bool? {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return CaptureError.isPermissionDenied(error) ? false : nil
        }
    }

    /// Shows the system prompt the first time; after that it only opens nothing. A grant takes
    /// effect after the app restarts.
    @discardableResult
    public static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

public struct CaptureCounters: Sendable {
    public var complete = 0
    public var idle = 0
    public var other = 0
    public init() {}
}

/// One `SCStream` on one display, configured per plan section 8. Delivers only complete frames;
/// idle frames are counted and dropped.
public final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "farside.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "farside.capture.audio", qos: .userInteractive)
    private let onFrame: @Sendable (CapturedFrame) -> Void
    private let onAudio: CapturedAudioHandler?
    private var scratch: [Float] = []
    private let onStop: @Sendable (Error?) -> Void
    private let counters = Mutex(CaptureCounters())
    private let sequence = Atomic<UInt64>(0)
    private var stream: SCStream?

    public init(onFrame: @escaping @Sendable (CapturedFrame) -> Void, onAudio: CapturedAudioHandler? = nil,
                onStop: @escaping @Sendable (Error?) -> Void = { _ in }) {
        self.onFrame = onFrame
        self.onAudio = onAudio
        self.onStop = onStop
    }

    public static func configuration(_ settings: CaptureSettings) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = settings.width & ~1
        config.height = settings.height & ~1
        // Slightly under the frame period. At exactly 1/60 s, normal vsync jitter on a 60 Hz
        // display makes ScreenCaptureKit skip about 2 frames a second (spike S1). On a 120 Hz
        // display this still delivers every second refresh, so the cap stays at 60.
        config.minimumFrameInterval = CMTime(seconds: 0.9 / Double(settings.framesPerSecond), preferredTimescale: 600_000)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.queueDepth = settings.queueDepth
        config.showsCursor = settings.showsCursor
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.captureResolution = .best
        config.shouldBeOpaque = true
        config.captureDynamicRange = .SDR
        config.showMouseClicks = false
        config.capturesAudio = settings.capturesAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = settings.excludesCurrentProcessAudio
        return config
    }

    /// Captures `displayID`, leaving out the given windows (for example a local preview).
    public func start(displayID: CGDirectDisplayID, excludingWindowIDs: Set<CGWindowID> = [], settings: CaptureSettings) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let stream = SCStream(filter: filter, configuration: Self.configuration(settings), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.capturesAudio, onAudio != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    public func takeCounters() -> CaptureCounters {
        counters.withLock { c in
            defer { c = CaptureCounters() }
            return c
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { return deliverAudio(sampleBuffer) }
        guard type == .screen else { return }
        let arrival = HostClock.now()
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let rawStatus = info[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else {
            counters.withLock { $0.other += 1 }
            return
        }
        switch status {
        case .complete:
            guard let pixels = sampleBuffer.imageBuffer else {
                counters.withLock { $0.other += 1 }
                return
            }
            counters.withLock { $0.complete += 1 }
            let number = sequence.add(1, ordering: .relaxed).newValue
            let displayTicks = (info[.displayTime] as? UInt64) ?? arrival
            onFrame(CapturedFrame(pixels: PixelBufferBox(pixels), number: number, displayTicks: displayTicks, arrivalTicks: arrival))
        case .idle:
            counters.withLock { $0.idle += 1 }
        default:
            counters.withLock { $0.other += 1 }
        }
    }

    private func deliverAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let onAudio, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else { return }
        let frames = sampleBuffer.numSamples
        let startTicks = HostClock.ticks(seconds: sampleBuffer.presentationTimeStamp.seconds)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(format.mChannelsPerFrame)
        try? sampleBuffer.withAudioBufferList { list, _ in
            if !interleaved {
                guard let left = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
                let right = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
                onAudio(UnsafePointer(left), right.map { UnsafePointer($0) }, frames, startTicks)
            } else {
                guard let data = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
                if scratch.count < frames * 2 { scratch = [Float](repeating: 0, count: frames * 2) }
                for i in 0..<frames {
                    scratch[i] = data[i * channels]
                    scratch[frames + i] = data[i * channels + (channels > 1 ? 1 : 0)]
                }
                scratch.withUnsafeBufferPointer { p in
                    onAudio(p.baseAddress!, p.baseAddress! + frames, frames, startTicks)
                }
            }
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}
#endif
